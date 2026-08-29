#!/usr/bin/env python3
"""Convert a PDF into a CrossPoint .xtch book.

Each PDF page is rasterized, fitted to the panel, and packed exactly the way
lib/Xtc/Xtc/XtcParser.cpp expects to read it back: an XTCH container holding
XTH pages (2-bit grayscale, four gray levels). Pages are pre-rendered images,
so vertical Japanese (or anything the source PDF already lays out) is
reproduced as-is.

Dependencies: pymupdf, pillow, numpy  (see requirements.txt)
"""

import argparse
import os
import struct
import sys

import fitz  # PyMuPDF
import numpy as np
from PIL import Image

try:
    from .common import (
        DEFAULT_CJK_LANGUAGE, ascii_slug, normalize_cjk_language, to_ascii,
    )
except ImportError:
    from common import (
        DEFAULT_CJK_LANGUAGE, ascii_slug, normalize_cjk_language, to_ascii,
    )

# Default panel geometry in CrossPoint portrait orientation (X4). The X3 is
# 528x792. Overridable via --width/--height (see lib/Xtc/Xtc/XtcTypes.h).
DEFAULT_WIDTH = 480
DEFAULT_HEIGHT = 800

XTCH_MAGIC = 0x48435458  # "XTCH" container (2-bit XTH pages)
XTH_MAGIC = 0x00485458   # "XTH\0" page (2-bit grayscale)
XTCH_EXT = ".xtch"

HEADER_SIZE = 56
TITLE_OFF = 0x38
TITLE_LEN = 128
AUTHOR_OFF = 0xB8
AUTHOR_LEN = 64
# The metadata block is a fixed 256 bytes (title, author, publisher, language,
# createTime, coverPage, chapterCount, reserved); chapters start after it.
METADATA_SIZE = 256
CHAPTER_TABLE_OFF = TITLE_OFF + METADATA_SIZE  # 0x138 (chapters, then page table)
PAGE_TABLE_ENTRY_SIZE = 16
XTH_PAGE_HEADER_SIZE = 22
CHAPTER_ENTRY_SIZE = 96
CHAPTER_NAME_LEN = 80

# struct layouts (little-endian, packed) — must match XtcTypes.h exactly.
HEADER_FMT = "<IBBHBBBBIQQQQII"
PAGE_TABLE_ENTRY_FMT = "<QIHH"
XTH_PAGE_HEADER_FMT = "<IHHBBIQ"
# name[80] + startPage(u16) + endPage(u16) + 12 bytes padding = 96 bytes
CHAPTER_ENTRY_FMT = "<80sHH12x"


def fit_to_panel(img: Image.Image, width: int, height: int) -> Image.Image:
    """Scale to fit width x height preserving aspect ratio, centered on white."""
    gray = img.convert("L")
    scale = min(width / gray.width, height / gray.height)
    new_w = max(1, round(gray.width * scale))
    new_h = max(1, round(gray.height * scale))
    resized = gray.resize((new_w, new_h), Image.LANCZOS)
    canvas = Image.new("L", (width, height), 255)
    canvas.paste(resized, ((width - new_w) // 2, (height - new_h) // 2))
    return canvas


def quantize_to_xth(gray: np.ndarray) -> bytes:
    """Pack an (H, W) uint8 grayscale array into XTH two-plane bytes.

    Gray -> pixelValue: brighter is whiter. The decoder reads
    pixelValue=(bit1<<1)|bit2 with 0=White, 2=Light Grey, 1=Dark Grey,
    3=Black, so the luminance->value map is deliberately non-monotonic.
    """
    pv = np.full(gray.shape, 3, dtype=np.uint8)  # darkest bucket = Black
    pv[gray >= 64] = 1   # Dark Grey
    pv[gray >= 128] = 2  # Light Grey
    pv[gray >= 192] = 0  # White

    bit1 = ((pv >> 1) & 1).astype(np.uint8)
    bit2 = (pv & 1).astype(np.uint8)

    # Column-major, right-to-left: reverse X, then pack each column's rows
    # MSB-first (top pixel = bit 7). packbits along the row axis of the
    # transposed array yields (W, H/8) in exactly byteOffset=col*colBytes+row/8.
    plane1 = np.packbits(bit1[:, ::-1].T, axis=1).tobytes()
    plane2 = np.packbits(bit2[:, ::-1].T, axis=1).tobytes()
    return plane1 + plane2


def _page_data_size(width: int, height: int) -> int:
    return XTH_PAGE_HEADER_SIZE + ((width * height + 7) // 8) * 2


def render_page(page: fitz.Page, dpi: int, width: int, height: int) -> np.ndarray:
    mat = fitz.Matrix(dpi / 72.0, dpi / 72.0)
    pix = page.get_pixmap(matrix=mat, colorspace=fitz.csGRAY, alpha=False)
    img = Image.frombytes("L", (pix.width, pix.height), pix.samples)
    canvas = fit_to_panel(img, width, height)
    return np.asarray(canvas, dtype=np.uint8)


def _truncate_utf8(text: str, limit: int) -> bytes:
    """Encode text to at most `limit` UTF-8 bytes without splitting a codepoint."""
    raw = text.encode("utf-8")
    if len(raw) <= limit:
        return raw
    return raw[:limit].decode("utf-8", "ignore").encode("utf-8")


def _fixed_bytes(text: str, length: int) -> bytes:
    raw = _truncate_utf8(text, length - 1)  # leave room for null terminator
    return raw + b"\x00" * (length - len(raw))


def _build_metadata(title: str, author: str, chapter_count: int) -> bytes:
    """Pack the 256-byte metadata block written at metadataOffset (0x38)."""
    return (_fixed_bytes(title, TITLE_LEN)
            + _fixed_bytes(author, AUTHOR_LEN)
            + _fixed_bytes("", 32)          # 0xC0 publisher
            + _fixed_bytes("", 16)          # 0xE0 language
            + struct.pack("<IHH8x", 0, 0, chapter_count))  # createTime, coverPage, chapterCount


def build_chapters(doc: fitz.Document, page_count: int,
                   cjk_language: str = DEFAULT_CJK_LANGUAGE) -> list:
    """Extract (name, startPage, endPage) 1-based ranges from the PDF outline.

    Pages are stored 1-based; the device decrements them to a 0-based index.
    Entries beyond page_count (e.g. when --max-pages clips the book) are dropped.
    """
    toc = doc.get_toc(simple=True)
    entries = []
    for _level, title, page in toc:
        if page is None or page < 1 or page > page_count:
            continue
        # Chapter names are stored in a fixed-size, null-terminated field the
        # device reads as plain text, so transliterate to ASCII (e.g. CJK/
        # accented titles) rather than risk mojibake on the reader.
        name = to_ascii(title.strip(), cjk_language)
        if name:
            entries.append((name, page))
    entries.sort(key=lambda e: e[1])

    chapters = []
    for i, (name, start) in enumerate(entries):
        end = entries[i + 1][1] - 1 if i + 1 < len(entries) else page_count
        end = min(max(end, start), page_count)
        chapters.append((name, start, end))
    return chapters


def _write_book(out_path: str, doc: fitz.Document, page_indices: list, chapters: list,
                dpi: int, read_direction: int, title: str, author: str,
                width: int, height: int) -> None:
    """Write the given 0-based page indices of `doc` to an XTCH container.

    `chapters` holds (name, startPage, endPage) 1-based ranges relative to
    `page_indices` (page 1 == page_indices[0]).
    """
    page_count = len(page_indices)
    chapter_table = bytearray()
    for name, start, end in chapters:
        chapter_table += struct.pack(
            CHAPTER_ENTRY_FMT, _truncate_utf8(name, CHAPTER_NAME_LEN), start, end)
    chapter_offset = CHAPTER_TABLE_OFF if chapters else 0
    page_table_off = CHAPTER_TABLE_OFF + len(chapter_table)
    data_offset = page_table_off + page_count * PAGE_TABLE_ENTRY_SIZE
    page_data_size = _page_data_size(width, height)

    header = struct.pack(
        HEADER_FMT,
        XTCH_MAGIC,          # magic
        1, 0,                # versionMajor, versionMinor
        page_count,          # pageCount
        read_direction,      # readDirection
        1,                   # hasMetadata
        0,                   # hasThumbnails
        1 if chapters else 0,  # hasChapters
        1,                   # currentPage (1-based)
        TITLE_OFF,           # metadataOffset
        page_table_off,      # pageTableOffset
        data_offset,         # dataOffset
        0,                   # thumbOffset
        chapter_offset,      # chapterOffset
        0,                   # padding
    )

    page_table = bytearray()
    for i in range(page_count):
        entry_offset = data_offset + i * page_data_size
        page_table += struct.pack(
            PAGE_TABLE_ENTRY_FMT, entry_offset, page_data_size, width, height)

    page_header = struct.pack(
        XTH_PAGE_HEADER_FMT,
        XTH_MAGIC, width, height, 0, 0,
        page_data_size - XTH_PAGE_HEADER_SIZE, 0)

    with open(out_path, "wb") as f:
        f.write(header)
        f.write(_build_metadata(title, author, len(chapters)))
        f.write(chapter_table)
        f.write(page_table)
        for n, page_index in enumerate(page_indices):
            gray = render_page(doc.load_page(page_index), dpi, width, height)
            f.write(page_header)
            f.write(quantize_to_xth(gray))
            print(f"  page {n + 1}/{page_count}", end="\r", file=sys.stderr, flush=True)

    print(f"\nWrote {out_path} ({page_count} pages, {len(chapters)} chapters)",
          file=sys.stderr)


def convert(pdf_path: str, out_path: str, dpi: int, read_direction: int,
            title: str, author: str, max_pages: int, width: int, height: int,
            *, cjk_language: str = DEFAULT_CJK_LANGUAGE) -> None:
    # XTH planes are column-major with 8 vertical pixels per byte, but the
    # declared dataSize is ((w*h+7)/8)*2; the two only agree when height is a
    # multiple of 8, otherwise every page offset would be wrong.
    if height % 8 != 0:
        raise SystemExit(f"error: --height {height} must be a multiple of 8")

    doc = fitz.open(pdf_path)
    page_count = doc.page_count
    if max_pages > 0:
        page_count = min(page_count, max_pages)
    if page_count == 0:
        raise SystemExit(f"error: {pdf_path} has no pages")
    if page_count > 0xFFFF:
        raise SystemExit(f"error: {page_count} pages exceeds the 65535 limit")

    meta = doc.metadata or {}
    title = title or meta.get("title") or ""
    author = author or meta.get("author") or ""

    _write_book(out_path, doc, list(range(page_count)),
                build_chapters(doc, page_count, cjk_language),
                dpi, read_direction, title, author, width, height)


def main() -> None:
    if sys.platform == "win32":
        for stream in (sys.stdout, sys.stderr):
            try:
                stream.reconfigure(encoding="utf-8", errors="replace")
            except (AttributeError, OSError):
                pass

    parser = argparse.ArgumentParser(description="Convert a PDF to a .xtch book.")
    parser.add_argument("pdf", help="Input PDF path")
    parser.add_argument("-o", "--output", help="Output .xtch path (default: alongside PDF)")
    parser.add_argument("--dpi", type=int, default=200,
                        help="Rasterization DPI before fitting to --width x --height (default: 200)")
    parser.add_argument("--read-direction", type=int, default=0, choices=(0, 1, 2),
                        help="XTCH readDirection byte stored in the header (default: 0)")
    parser.add_argument("--title", default="", help="Override book title metadata")
    parser.add_argument("--author", default="", help="Override book author metadata")
    parser.add_argument("--max-pages", type=int, default=0,
                        help="Limit page count (0 = all; useful for quick tests)")
    parser.add_argument("--width", type=int, default=DEFAULT_WIDTH,
                        help=f"Panel width in portrait orientation (default: {DEFAULT_WIDTH}; X3: 528)")
    parser.add_argument("--height", type=int, default=DEFAULT_HEIGHT,
                        help=f"Panel height in portrait orientation (default: {DEFAULT_HEIGHT}; X3: 792)")
    parser.add_argument(
        "--cjk-language", default=DEFAULT_CJK_LANGUAGE,
        help="CJK romanization for chapter names and the default output filename: "
             "japanese (default), chinese, or korean")
    args = parser.parse_args()
    cjk_language = normalize_cjk_language(args.cjk_language)

    if args.output:
        output = args.output
    else:
        stem = ascii_slug(
            os.path.splitext(os.path.basename(args.pdf))[0], cjk_language)
        output = os.path.join(os.path.dirname(args.pdf) or ".", stem + XTCH_EXT)

    convert(args.pdf, output, args.dpi, args.read_direction,
            args.title, args.author, args.max_pages, args.width, args.height,
            cjk_language=cjk_language)


if __name__ == "__main__":
    main()
