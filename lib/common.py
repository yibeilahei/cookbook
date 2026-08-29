"""Shared helpers for toxtch.py and topdf.py."""

from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path

from slugify import slugify
from unidecode import unidecode

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    import tomli as tomllib  # type: ignore[no-redef]

ROOT = Path(__file__).resolve().parent.parent

# How to romanize CJK before ASCII-safe filenames/chapter names.
# Japanese is the default because Unidecode's CJK table is Mandarin pinyin.
CJK_LANGUAGES = ("japanese", "chinese", "korean")
DEFAULT_CJK_LANGUAGE = "japanese"
_CJK_LANGUAGE_ALIASES = {
    "japanese": "japanese", "ja": "japanese", "jp": "japanese", "jpn": "japanese",
    "chinese": "chinese", "zh": "chinese", "cn": "chinese", "chi": "chinese",
    "zho": "chinese",
    "korean": "korean", "ko": "korean", "kr": "korean", "kor": "korean",
}

# Revised Romanization of Hangul (syllable-by-syllable, no sandhi).
_HANGUL_CHO = (
    "g", "kk", "n", "d", "tt", "r", "m", "b", "pp", "s", "ss", "",
    "j", "jj", "ch", "k", "t", "p", "h",
)
_HANGUL_JUNG = (
    "a", "ae", "ya", "yae", "eo", "e", "yeo", "ye", "o", "wa", "wae", "oe",
    "yo", "u", "wo", "we", "wi", "yu", "eu", "ui", "i",
)
_HANGUL_JONG = (
    "", "g", "kk", "gs", "n", "nj", "nh", "d", "l", "lg", "lm", "lb", "ls",
    "lt", "lp", "lh", "m", "b", "bs", "s", "ss", "ng", "j", "ch", "k", "t",
    "p", "h",
)

_kakasi = None
# Kanji/kana only — applying kakasi to Latin/hangul mangles those scripts.
_JP_RUN = re.compile(
    r"["
    r"\u3005\u3006\u303B"      # 々 〆 〻
    r"\u3040-\u309F"           # hiragana
    r"\u30A0-\u30FF"           # katakana + prolonged sound mark
    r"\u31F0-\u31FF"           # katakana phonetic extensions
    r"\u3400-\u4DBF"           # CJK ext A
    r"\u4E00-\u9FFF"           # CJK unified
    r"\uF900-\uFAFF"           # CJK compatibility ideographs
    r"\uFF66-\uFF9F"           # halfwidth katakana
    r"]+"
)

EBOOK_EXTS = {
    "epub", "mobi", "azw", "azw3", "fb2", "lit", "lrf", "pdb", "rtf", "txt",
    "htmlz", "html", "cbz", "cbr", "cbc", "chm", "djvu", "docx", "odt", "prc",
    "pml", "rb", "snb", "tcr",
}


def config_path(kind: str) -> Path:
    return ROOT / f"devices.{kind}.toml"


def load_config(kind: str) -> dict:
    path = config_path(kind)
    if not path.exists():
        sys.exit(f"Config not found: {path}")
    with open(path, "rb") as f:
        return tomllib.load(f)


def normalize_cjk_language(value: str | None) -> str:
    """Map a config/CLI value to japanese, chinese, or korean."""
    raw = (value or DEFAULT_CJK_LANGUAGE).strip().lower()
    lang = _CJK_LANGUAGE_ALIASES.get(raw)
    if lang is None:
        allowed = ", ".join(CJK_LANGUAGES)
        sys.exit(f"Invalid cjk_language '{value}' (use {allowed}).")
    return lang


def cjk_language_from_config(config: dict) -> str:
    return normalize_cjk_language(config.get("cjk_language"))


def _hepburn(text: str) -> str:
    global _kakasi
    if _kakasi is None:
        import pykakasi
        _kakasi = pykakasi.kakasi()
    parts = _kakasi.convert(text)
    return " ".join(
        (p.get("hepburn") or p.get("orig") or "") for p in parts
    )


def _romanize_japanese(text: str) -> str:
    """Hepburn romaji via pykakasi on kanji/kana runs only."""
    return _JP_RUN.sub(lambda m: _hepburn(m.group(0)), text)


def _romanize_chinese(text: str) -> str:
    """Pinyin without tone marks; non-Han characters are kept as-is."""
    from pypinyin import lazy_pinyin
    return " ".join(lazy_pinyin(text, errors="default"))


def _romanize_hangul_char(ch: str) -> str:
    code = ord(ch)
    if not (0xAC00 <= code <= 0xD7A3):
        return ch
    s = code - 0xAC00
    return (
        _HANGUL_CHO[s // 588]
        + _HANGUL_JUNG[(s % 588) // 28]
        + _HANGUL_JONG[s % 28]
    )


def _romanize_korean(text: str) -> str:
    return "".join(_romanize_hangul_char(ch) for ch in text)


def to_ascii(text: str, language: str | None = None) -> str:
    """Transliterate text to ASCII using language-specific CJK romanization.

    Remaining non-ASCII (accents, leftover ideographs, macrons from Hepburn)
    is passed through Unidecode. Whitespace is collapsed.
    """
    language = normalize_cjk_language(language)
    if language == "japanese":
        text = _romanize_japanese(text)
    elif language == "chinese":
        text = _romanize_chinese(text)
    else:
        text = _romanize_korean(text)
    return " ".join(unidecode(text).split())


def ascii_slug(text: str, language: str | None = None) -> str:
    """ASCII-safe filename stem; 'book' if nothing remains."""
    return slugify(to_ascii(text, language)) or "book"


def configure_stdio() -> None:
    """Avoid UnicodeEncodeError when printing Japanese paths on Windows consoles."""
    if sys.platform != "win32":
        return
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
        except (AttributeError, OSError):
            pass


def choose_device(config: dict) -> str:
    """Interactive device menu; config default if stdin is not a TTY."""
    devices = config.get("devices") or {}
    if not devices:
        sys.exit("No devices in the config file.")

    default = config.get("default") or next(iter(devices))
    if default not in devices:
        sys.exit(f"Unknown device '{default}' (check the config file).")

    if not sys.stdin.isatty():
        return default

    keys = list(devices)
    print("Select target device:")
    for i, key in enumerate(keys, 1):
        d = devices[key]
        mark = " (default)" if key == default else ""
        print(f"  {i}. {key:<7} {d.get('label', '')}  {d['width']}x{d['height']}{mark}")
    while True:
        choice = input(f"Device [1-{len(keys)}, Enter for {default}]: ").strip()
        if not choice:
            return default
        if choice.isdigit() and 1 <= int(choice) <= len(keys):
            return keys[int(choice) - 1]
        if choice in devices:
            return choice
        print("Invalid choice.")


def fonts_for_os(config: dict) -> dict:
    """Pick serif/sans/mono for this OS from the device config."""
    fonts = config.get("fonts") or {}
    os_key = {"Darwin": "macos", "Windows": "windows"}.get(platform.system())
    section = fonts.get(os_key) if os_key else None
    if isinstance(section, dict) and section.get("serif"):
        chosen = section
    elif fonts.get("serif"):
        chosen = fonts
    else:
        where = f"[fonts.{os_key}]" if os_key else "[fonts]"
        sys.exit(f"No fonts configured for this OS. Add a {where} table.")
    for key in ("serif", "sans", "mono"):
        if key not in chosen:
            sys.exit(f"fonts.{key} is missing in the config file")
    return {k: chosen[k] for k in ("serif", "sans", "mono")}


def font_size_for(dev: dict, device: str) -> int:
    if "font_size" not in dev:
        sys.exit(f"Device '{device}' is missing font_size in the config file.")
    return dev["font_size"]


def panel_size(dev: dict, device: str) -> tuple[int, int, int, str]:
    """Return (width, height, dpi, '{width}x{height}') in the device orientation."""
    width, height = dev["width"], dev["height"]
    dpi = dev.get("dpi", 200)
    orientation = dev.get("orientation", "portrait")
    if orientation not in ("portrait", "landscape"):
        sys.exit(
            f"Invalid orientation '{orientation}' for device '{device}' "
            "(use 'portrait' or 'landscape').")
    if orientation == "landscape":
        width, height = height, width
    return width, height, dpi, f"{width}x{height}"


def _calibre_install_hint() -> str:
    system = platform.system()
    if system == "Darwin":
        how = "  brew install --cask calibre\n  or download from https://calibre-ebook.com"
    elif system == "Windows":
        how = "  winget install -e --id calibre.calibre\n  or download from https://calibre-ebook.com"
    else:
        how = "  download from https://calibre-ebook.com"
    return (
        "ebook-convert not found. Install Calibre:\n"
        f"{how}\n"
        "Or set EBOOK_CONVERT to the ebook-convert binary."
    )


def find_ebook_convert() -> str:
    """Locate ebook-convert on PATH or in the usual desktop-app install locations."""
    env = os.environ.get("EBOOK_CONVERT")
    if env:
        p = Path(env)
        if p.is_file():
            return str(p)
        sys.exit(f"EBOOK_CONVERT is set but not a file: {env}")

    exe = shutil.which("ebook-convert") or shutil.which("ebook-convert.exe")
    if exe:
        return exe

    home = Path.home()
    candidates: list[Path] = []
    system = platform.system()
    if system == "Darwin":
        candidates += [
            Path("/Applications/calibre.app/Contents/MacOS/ebook-convert"),
            home / "Applications/calibre.app/Contents/MacOS/ebook-convert",
        ]
    elif system == "Windows":
        roots = [
            os.environ.get("ProgramFiles"),
            os.environ.get("ProgramFiles(x86)"),
        ]
        local = os.environ.get("LOCALAPPDATA")
        if local:
            roots.append(str(Path(local) / "Programs"))
        for root in roots:
            if not root:
                continue
            candidates += [
                Path(root) / "Calibre2" / "ebook-convert.exe",
                Path(root) / "Calibre" / "ebook-convert.exe",
            ]
    else:
        candidates += [
            Path("/usr/bin/ebook-convert"),
            Path("/usr/local/bin/ebook-convert"),
            home / "calibre-bin" / "ebook-convert",
        ]

    for path in candidates:
        if path.is_file():
            return str(path)

    sys.exit(_calibre_install_hint())


def parse_args(description: str) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=description)
    parser.add_argument(
        "--output-dir", type=Path,
        help="Write all outputs here (default: output/ next to the input file)")
    parser.add_argument(
        "paths", nargs="+", metavar="PATH",
        help="Ebook/PDF files or directories of them")
    return parser.parse_args()


def expand_inputs(paths) -> list[Path]:
    """Expand directories into the ebook/PDF files they contain."""
    exts = EBOOK_EXTS | {"pdf"}
    inputs: list[Path] = []
    for arg in paths:
        p = Path(arg)
        if p.is_dir():
            inputs += sorted(
                f for f in p.iterdir()
                if f.is_file() and f.suffix.lower().lstrip(".") in exts
            )
        else:
            inputs.append(p)
    return inputs


def ebook_to_pdf(ebook_convert, src: Path, pdf: Path, size: str,
                 fonts: dict, font_size: int) -> None:
    src = src.resolve()
    pdf.parent.mkdir(parents=True, exist_ok=True)
    print(f"Converting: {src} -> {pdf}")
    subprocess.run(
        [
            ebook_convert, str(src), str(pdf),
            "--custom-size", size,
            "--unit", "point",
            "--pdf-page-margin-left", "0",
            "--pdf-page-margin-right", "0",
            "--pdf-page-margin-top", "0",
            "--pdf-page-margin-bottom", "0",
            "--pdf-default-font-size", str(font_size),
            "--pdf-serif-family", fonts["serif"],
            "--pdf-sans-family", fonts["sans"],
            "--pdf-mono-family", fonts["mono"],
            # Embed (subset) fonts so CJK renders on PDF-target devices that
            # lack the host's CJK fonts; harmless for the rasterized .xtch path.
            "--embed-all-fonts",
            "--subset-embedded-fonts",
        ],
        check=True,
    )


def plan_jobs(inputs: list[Path], device: str, ext: str,
              output_dir: Path | None,
              cjk_language: str | None = None) -> list[tuple[Path, Path, Path]]:
    """Resolve (src, out_dir, dest) jobs; skip already-PDFs and path collisions."""
    jobs: list[tuple[Path, Path, Path]] = []
    seen: dict[Path, Path] = {}
    for src in inputs:
        src = src.resolve()
        if src.suffix.lower() == ".pdf" and ext == "pdf":
            print(f"Skipping (already PDF): {src}")
            continue
        out_dir = (output_dir or (src.parent / "output")).resolve()
        # .xtch filenames must stay ASCII-safe for the CrossPoint reader's
        # filesystem, so romanize CJK (per cjk_language) then slugify.
        # PDFs keep the original stem.
        stem = ascii_slug(src.stem, cjk_language) if ext == "xtch" else src.stem
        dest = (out_dir / f"{stem}_{device}.{ext}").resolve()
        if dest in seen:
            print(f"Skipping (same output as {seen[dest]}): {src} -> {dest}",
                  file=sys.stderr)
            continue
        seen[dest] = src
        jobs.append((src, out_dir, dest))
    return jobs
