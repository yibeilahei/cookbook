#!/usr/bin/env python3
"""Ebook/PDF -> .xtch for CrossPoint panels.

Ebooks are converted to a panel-sized PDF via Calibre, then packed by
lib.pdf2xtch. PDFs are packed directly. Device geometry lives in devices.xtch.toml.
"""

import sys
from pathlib import Path

from lib import common


def pdf_to_xtch(pdf: Path, xtch: Path, width: int, height: int, dpi: int) -> None:
    from lib.pdf2xtch import convert as pack_xtch

    pdf = pdf.resolve()
    xtch.parent.mkdir(parents=True, exist_ok=True)
    print(f"Packing: {pdf} -> {xtch}")
    pack_xtch(str(pdf), str(xtch), dpi, 0, "", "", 0, width, height)


def main() -> None:
    common.configure_stdio()
    args = common.parse_args("Convert ebooks/PDFs to .xtch books.")

    config = common.load_config("xtch")
    inputs = common.expand_inputs(args.paths)
    if not inputs:
        sys.exit("No ebook or PDF files found.")

    device = common.choose_device(config)
    dev = config["devices"][device]
    width, height, dpi, size = common.panel_size(dev, device)

    jobs = common.plan_jobs(inputs, device, "xtch", args.output_dir)
    if not jobs:
        sys.exit("Nothing to do.")

    fonts = None
    font_size = None
    ebook_convert = None
    for src, out_dir, dest in jobs:
        if src.suffix.lower() == ".pdf":
            pdf = src
        else:
            if fonts is None:
                fonts = common.fonts_for_os(config)
                font_size = common.font_size_for(dev, device)
            if ebook_convert is None:
                ebook_convert = common.find_ebook_convert()
            pdf = out_dir / f"{src.stem}_{device}.pdf"
            common.ebook_to_pdf(ebook_convert, src, pdf, size, fonts, font_size)
        pdf_to_xtch(pdf, dest, width, height, dpi)


if __name__ == "__main__":
    main()
