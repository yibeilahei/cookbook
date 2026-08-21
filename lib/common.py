"""Shared helpers for toxtch.py and topdf.py."""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    import tomli as tomllib  # type: ignore[no-redef]

ROOT = Path(__file__).resolve().parent.parent

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
              output_dir: Path | None) -> list[tuple[Path, Path, Path]]:
    """Resolve (src, out_dir, dest) jobs; skip already-PDFs and path collisions."""
    jobs: list[tuple[Path, Path, Path]] = []
    seen: dict[Path, Path] = {}
    for src in inputs:
        src = src.resolve()
        if src.suffix.lower() == ".pdf" and ext == "pdf":
            print(f"Skipping (already PDF): {src}")
            continue
        out_dir = (output_dir or (src.parent / "output")).resolve()
        dest = (out_dir / f"{src.stem}_{device}.{ext}").resolve()
        if dest in seen:
            print(f"Skipping (same output as {seen[dest]}): {src} -> {dest}",
                  file=sys.stderr)
            continue
        seen[dest] = src
        jobs.append((src, out_dir, dest))
    return jobs
