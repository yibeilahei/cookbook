#!/usr/bin/env python3
"""Ebook -> panel-sized PDF.

Calibre converts ebooks to the selected device's page size. Device geometry
and fonts live in devices.pdf.toml.
"""

import sys

from lib import common


def main() -> None:
    common.configure_stdio()
    args = common.parse_args("Convert ebooks to panel-sized PDFs.")

    config = common.load_config("pdf")
    inputs = common.expand_inputs(args.paths)
    if not inputs:
        sys.exit("No ebook or PDF files found.")

    device = common.choose_device(config)
    dev = config["devices"][device]
    _width, _height, _dpi, size = common.panel_size(dev, device)

    jobs = common.plan_jobs(inputs, device, "pdf", args.output_dir)
    if not jobs:
        sys.exit("Nothing to do.")

    fonts = common.fonts_for_os(config)
    font_size = common.font_size_for(dev, device)

    ebook_convert = None
    for src, _out_dir, dest in jobs:
        if ebook_convert is None:
            ebook_convert = common.find_ebook_convert()
        common.ebook_to_pdf(ebook_convert, src, dest, size, fonts, font_size)


if __name__ == "__main__":
    main()
