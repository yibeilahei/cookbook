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
import io
import multiprocessing
import os
import shutil
import struct
import sys
import tempfile
import zlib
from concurrent.futures import ProcessPoolExecutor

import pymupdf as fitz  # PyMuPDF; `fitz` is the deprecated alias for this module
import numpy as np
from PIL import Image

try:
    from .common import (
        DEFAULT_ASCII_ROMANIZATION, ConversionCancelled, ascii_slug, normalize_ascii_romanization, to_ascii,
    )
except ImportError:
    from common import (
        DEFAULT_ASCII_ROMANIZATION, ConversionCancelled, ascii_slug, normalize_ascii_romanization, to_ascii,
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


def compress_page(raw: bytes) -> tuple:
    """Raw-DEFLATE compress `raw` (no zlib/gzip wrapper, matches lib/Xtch's puff
    decoder). Falls back to storing the page uncompressed if deflate doesn't
    actually shrink it (e.g. already-noisy bitmaps), so compression is always a
    net win or a no-op.

    Returns (body, compression) where compression is the XTH PageHeader byte
    (0=raw, 1=raw-DEFLATE).
    """
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    compressed = compressor.compress(raw) + compressor.flush()
    if len(compressed) < len(raw):
        return compressed, 1
    return raw, 0


def pack_page(raw: bytes, width: int, height: int, compress: bool) -> bytes:
    """Build an XTH page's "header + body" bytes from quantized plane data.

    When `compress` is false the page is stored raw (compression byte 0).
    Off by default: currently the only firmware that supports page
    compression is lazahata.
    """
    if compress:
        body, compression = compress_page(raw)
    else:
        body, compression = raw, 0
    page_header = struct.pack(
        XTH_PAGE_HEADER_FMT, XTH_MAGIC, width, height, 0, compression, len(body), 0)
    return page_header + body


def render_page(page: fitz.Page, supersample: int, width: int, height: int) -> np.ndarray:
    mat = fitz.Matrix(supersample, supersample)
    pix = page.get_pixmap(matrix=mat, colorspace=fitz.csGRAY, alpha=False)
    img = Image.frombytes("L", (pix.width, pix.height), pix.samples)
    canvas = fit_to_panel(img, width, height)
    return np.asarray(canvas, dtype=np.uint8)


def preview_png_bytes(gray: np.ndarray, quantize: bool) -> bytes:
    """Encode a rendered page (see render_page) as PNG bytes for the UI.

    When `quantize` is true (xtch mode), the same four gray buckets used by
    quantize_to_xth are applied first, so the preview matches what the
    e-ink panel will actually show rather than the PDF's full grayscale.
    """
    if quantize:
        arr = np.select(
            [gray >= 192, gray >= 128, gray >= 64],
            [255, 170, 85],
            default=0,
        ).astype(np.uint8)
    else:
        arr = gray
    buf = io.BytesIO()
    Image.fromarray(arr, mode="L").save(buf, format="PNG")
    return buf.getvalue()


def render_preview(pdf_path: str, supersample: int, width: int, height: int,
                    max_pages: int, quantize: bool) -> tuple[list, int]:
    """Render up to `max_pages` pages of `pdf_path` for an in-app preview.

    Returns (png_bytes_per_page, total_page_count). Pages are rendered
    sequentially (no process pool) since 15-ish pages is fast enough that
    the pool-spawn overhead wouldn't pay for itself.
    """
    with fitz.open(pdf_path) as doc:
        page_count = doc.page_count
        n = min(max_pages, page_count) if max_pages > 0 else page_count
        pages = [
            preview_png_bytes(render_page(doc.load_page(i), supersample, width, height), quantize)
            for i in range(n)
        ]
    return pages, page_count


def _render_page_body(pdf_path: str, page_index: int, supersample: int, width: int,
                      height: int, compress: bool = False) -> bytes:
    """Render+quantize+optionally-compress one page into its "header + body" bytes.

    Runs in a worker process (see _write_book): opens its own fitz.Document
    since Document/Page objects aren't picklable across the process boundary.
    Reopening per call (rather than per worker) keeps this stateless and
    simple; PyMuPDF opens are cheap relative to rendering a page.
    """
    with fitz.open(pdf_path) as doc:
        gray = render_page(doc.load_page(page_index), supersample, width, height)
    return pack_page(quantize_to_xth(gray), width, height, compress)


# Below this page count, process-pool overhead (spawning workers, pickling,
# IPC) outweighs the benefit of parallelizing; just render sequentially.
PARALLEL_PAGE_THRESHOLD = 8


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
                   ascii_romanization: str = DEFAULT_ASCII_ROMANIZATION) -> list:
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
        name = to_ascii(title.strip(), ascii_romanization)
        if name:
            entries.append((name, page))
    entries.sort(key=lambda e: e[1])

    chapters = []
    for i, (name, start) in enumerate(entries):
        end = entries[i + 1][1] - 1 if i + 1 < len(entries) else page_count
        end = min(max(end, start), page_count)
        chapters.append((name, start, end))
    return chapters


def _write_book(out_path: str, pdf_path: str, doc: fitz.Document, page_indices: list,
                chapters: list, supersample: int, read_direction: int, title: str,
                author: str, width: int, height: int, *, on_page=None,
                should_cancel=None, page_compression: bool = False) -> None:
    """Write the given 0-based page indices of `doc` to an XTCH container.

    `chapters` holds (name, startPage, endPage) 1-based ranges relative to
    `page_indices` (page 1 == page_indices[0]).

    `on_page`, if given, is called as `on_page(n, page_count)` after each
    page is rendered (1-based `n`), so callers (the desktop backend) can
    surface live packing progress instead of just a spinner.

    `should_cancel`, if given, is called as `should_cancel()` after each
    page is rendered; when it returns truthy, remaining work is abandoned
    and `ConversionCancelled` is raised (no partial file is left behind,
    since the real output file isn't opened until pass 2, below).

    When `page_compression` is on, pages are compressed independently
    (per-page raw-DEFLATE, falling back to raw storage if that doesn't help),
    so their on-disk size varies. Offsets aren't known until every page has
    been rendered, so this writes page bodies to a spooled temp file first
    (pass 1), then writes the real file with the now-known page table
    followed by a straight copy of the temp file's contents (pass 2).
    Compression is off by default: currently the only firmware that
    supports it is lazahata.
    """
    page_count = len(page_indices)
    chapter_table = bytearray()
    for name, start, end in chapters:
        chapter_table += struct.pack(
            CHAPTER_ENTRY_FMT, _truncate_utf8(name, CHAPTER_NAME_LEN), start, end)
    chapter_offset = CHAPTER_TABLE_OFF if chapters else 0
    page_table_off = CHAPTER_TABLE_OFF + len(chapter_table)
    data_offset = page_table_off + page_count * PAGE_TABLE_ENTRY_SIZE

    # Pass 1: render (+ optionally compress) each page, spooling
    # "page_header + body" to a temp file so peak memory stays O(1-ish)
    # pages regardless of book length. Pages are independent, so for books
    # past PARALLEL_PAGE_THRESHOLD this is farmed out to a process pool
    # (CPU-bound: rasterize + numpy quantize + optional zlib compress).
    # Futures are submitted (and collected) in page order, so the spool is
    # still written page-by-page in the book's natural order, and
    # not-yet-started futures can be dropped on cancellation.
    page_sizes = []
    workers = min(os.cpu_count() or 1, page_count)
    # 64 MiB spool threshold before falling back to a real temp file; either
    # way this is scratch space, never the final .xtch bytes.
    with tempfile.SpooledTemporaryFile(max_size=64 * 1024 * 1024) as spool:
        if workers > 1 and page_count >= PARALLEL_PAGE_THRESHOLD:
            with ProcessPoolExecutor(max_workers=workers) as pool:
                futures = [
                    pool.submit(_render_page_body, pdf_path, page_index, supersample,
                                width, height, page_compression)
                    for page_index in page_indices
                ]
                for n, future in enumerate(futures):
                    page_bytes = future.result()
                    spool.write(page_bytes)
                    page_sizes.append(len(page_bytes))
                    print(f"  page {n + 1}/{page_count}", end="\r",
                          file=sys.stderr, flush=True)
                    if on_page is not None:
                        on_page(n + 1, page_count)
                    if should_cancel is not None and should_cancel():
                        for pending in futures[n + 1:]:
                            pending.cancel()
                        raise ConversionCancelled("cancelled")
        else:
            for n, page_index in enumerate(page_indices):
                gray = render_page(doc.load_page(page_index), supersample, width, height)
                page_bytes = pack_page(
                    quantize_to_xth(gray), width, height, page_compression)
                spool.write(page_bytes)
                page_sizes.append(len(page_bytes))
                print(f"  page {n + 1}/{page_count}", end="\r", file=sys.stderr, flush=True)
                if on_page is not None:
                    on_page(n + 1, page_count)
                if should_cancel is not None and should_cancel():
                    raise ConversionCancelled("cancelled")

        # Pass 2: now that every page's on-disk size is known, compute offsets,
        # write the fixed-size prefix (header/metadata/chapters/page table),
        # then copy the spooled page data across verbatim.
        page_table = bytearray()
        offset = data_offset
        for i in range(page_count):
            page_table += struct.pack(
                PAGE_TABLE_ENTRY_FMT, offset, page_sizes[i], width, height)
            offset += page_sizes[i]

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

        with open(out_path, "wb") as f:
            f.write(header)
            f.write(_build_metadata(title, author, len(chapters)))
            f.write(chapter_table)
            f.write(page_table)
            spool.seek(0)
            shutil.copyfileobj(spool, f)

    raw_total = sum(_page_data_size(width, height) for _ in page_indices)
    packed_total = sum(page_sizes)
    saved_pct = 100 * (1 - packed_total / raw_total) if raw_total else 0
    print(f"\nWrote {out_path} ({page_count} pages, {len(chapters)} chapters, "
          f"{packed_total} bytes packed vs {raw_total} raw, {saved_pct:.0f}% smaller)",
          file=sys.stderr)


def convert(pdf_path: str, out_path: str, supersample: int, read_direction: int,
            title: str, author: str, max_pages: int, width: int, height: int,
            *, ascii_romanization: str = DEFAULT_ASCII_ROMANIZATION, on_page=None,
            should_cancel=None, page_compression: bool = False) -> None:
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

    _write_book(out_path, pdf_path, doc, list(range(page_count)),
                build_chapters(doc, page_count, ascii_romanization),
                supersample, read_direction, title, author, width, height, on_page=on_page,
                should_cancel=should_cancel, page_compression=page_compression)


def main() -> None:
    parser = argparse.ArgumentParser(description="Convert a PDF to a .xtch book.")
    parser.add_argument("pdf", help="Input PDF path")
    parser.add_argument("-o", "--output", help="Output .xtch path (default: alongside PDF)")
    parser.add_argument("--supersample", type=int, default=3,
                        help="Rasterization supersample multiplier before downscaling to "
                             "--width x --height (default: 3; higher = sharper but slower)")
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
        "--ascii-romanization", default=DEFAULT_ASCII_ROMANIZATION,
        help="Romanization pass for chapter names and the default output filename: "
             "japanese (default), chinese, korean, or none (skip romanization)")
    parser.add_argument(
        "--page-compression", action="store_true", default=False,
        help="Raw-DEFLATE compress each page when that shrinks it. Off by default: "
             "currently the only firmware that supports page compression is lazahata.")
    args = parser.parse_args()
    ascii_romanization = normalize_ascii_romanization(args.ascii_romanization)

    if args.output:
        output = args.output
    else:
        stem = ascii_slug(
            os.path.splitext(os.path.basename(args.pdf))[0], ascii_romanization)
        output = os.path.join(os.path.dirname(args.pdf) or ".", stem + XTCH_EXT)

    convert(args.pdf, output, args.supersample, args.read_direction,
            args.title, args.author, args.max_pages, args.width, args.height,
            ascii_romanization=ascii_romanization,
            page_compression=args.page_compression)


if __name__ == "__main__":
    multiprocessing.freeze_support()
    main()
