"""Conversion job execution, driven by the desktop UI over the backend
protocol (see server.py). This mirrors what the old toxtch.py/topdf.py CLI
used to do, but reports progress via a callback instead of printing to a
TTY, and collects structured results instead of exiting the process on the
first error.
"""

from __future__ import annotations

import time
from pathlib import Path
from typing import Callable, Optional

from lib import common
from lib.common import ConversionCancelled

# on_progress(file, stage, message, percent) -- stage is one of:
#   "convert" (ebook -> PDF via Calibre), "pack" (PDF -> .xtch),
#   "done", "error", "cancelled"
# `percent` is 0-100 within the current stage, or None when not known
# (e.g. the "done"/"error"/"cancelled" stages, or a Calibre message with no
# % prefix).
ProgressFn = Callable[[str, str, str, Optional[int]], None]

# on_batch(completed, total, elapsed_seconds, eta_seconds) -- called after
# each input file finishes (success, skip, error, or cancel), so the UI can
# show an overall "3/8 files, ~45s left" readout. `eta_seconds` is None until
# at least one file has completed (nothing to average yet).
BatchFn = Callable[[int, int, float, Optional[float]], None]


def run(kind: str, config: dict, device: str, paths: list[str],
        output_dir: Optional[str], on_progress: ProgressFn,
        on_batch: Optional[BatchFn] = None,
        should_cancel: Optional[Callable[[], bool]] = None) -> dict:
    """Convert `paths` for `device` under `kind` ("xtch" or "pdf").

    `should_cancel`, if given, is polled between files (and, inside the
    Calibre/pdf2xtch stages, between output lines/pages) so a running batch
    can be aborted early; already-finished files are kept, the file that was
    in flight is reported as "cancelled" (not an error), and every remaining
    file is recorded in `skipped` with reason "cancelled".

    Returns {"done": [{"file","output"}], "skipped": [{"file","reason"}],
    "errors": [{"file","message"}], "cancelled": bool}.
    """
    if device not in config.get("devices", {}):
        raise ValueError(f"Unknown device '{device}'.")
    dev = config["devices"][device]
    width, height, supersample, size = common.panel_size(dev, device)
    ascii_romanization = common.ascii_romanization_from_config(config) if kind == "xtch" else None
    page_compression = bool(config.get("page_compression")) if kind == "xtch" else False

    inputs = common.expand_inputs([Path(p) for p in paths])
    out_dir_path = Path(output_dir).resolve() if output_dir else None

    skipped: list[dict] = []
    jobs = common.plan_jobs(
        inputs, device, kind, out_dir_path, ascii_romanization,
        on_skip=lambda src, reason: skipped.append({"file": str(src), "reason": reason}))

    done: list[dict] = []
    errors: list[dict] = []
    fonts = font_size = ebook_convert = None

    total = len(jobs)
    completed = 0
    cancelled = False
    start_time = time.monotonic()

    def _emit_batch() -> None:
        if on_batch is None:
            return
        elapsed = time.monotonic() - start_time
        eta = None
        if completed > 0 and completed < total:
            eta = (elapsed / completed) * (total - completed)
        on_batch(completed, total, elapsed, eta)

    for src, out_dir, dest in jobs:
        if should_cancel is not None and should_cancel():
            cancelled = True
            break
        try:
            if kind == "xtch":
                if src.suffix.lower() == ".pdf":
                    pdf = src
                else:
                    if fonts is None:
                        fonts = common.fonts_for_os(config)
                        font_size = common.font_size_for(config)
                    if ebook_convert is None:
                        ebook_convert = common.find_ebook_convert()
                    pdf = out_dir / f"{src.stem}_{device}.pdf"

                    def _convert_progress(percent: int, message: str, _src=src) -> None:
                        on_progress(str(_src), "convert", message, percent)

                    on_progress(str(src), "convert", "Converting to PDF via Calibre", 0)
                    common.ebook_to_pdf(ebook_convert, src, pdf, size, fonts, font_size,
                                         on_progress=_convert_progress,
                                         should_cancel=should_cancel)

                page_state = {"n": 0, "total": 0}

                def _pack_progress(n: int, page_count: int, _src=src) -> None:
                    page_state["n"], page_state["total"] = n, page_count
                    percent = int(n / page_count * 100) if page_count else 0
                    on_progress(str(_src), "pack", f"Packing page {n}/{page_count}", percent)

                on_progress(str(src), "pack", "Packing .xtch", 0)
                from lib.pdf2xtch import convert as pack_xtch
                dest.parent.mkdir(parents=True, exist_ok=True)
                pack_xtch(str(pdf.resolve()), str(dest), supersample, 0, "", "", 0,
                          width, height, ascii_romanization=ascii_romanization, on_page=_pack_progress,
                          should_cancel=should_cancel, page_compression=page_compression)
            else:  # kind == "pdf"
                if fonts is None:
                    fonts = common.fonts_for_os(config)
                    font_size = common.font_size_for(config)
                if ebook_convert is None:
                    ebook_convert = common.find_ebook_convert()

                def _convert_progress(percent: int, message: str, _src=src) -> None:
                    on_progress(str(_src), "convert", message, percent)

                on_progress(str(src), "convert", "Converting to PDF via Calibre", 0)
                common.ebook_to_pdf(ebook_convert, src, dest, size, fonts, font_size,
                                     on_progress=_convert_progress,
                                     should_cancel=should_cancel)

            on_progress(str(src), "done", str(dest), 100)
            done.append({"file": str(src), "output": str(dest)})
        except ConversionCancelled:
            on_progress(str(src), "cancelled", "Cancelled", None)
            skipped.append({"file": str(src), "reason": "cancelled"})
            cancelled = True
            break
        except SystemExit as e:
            message = str(e.code) if e.code else "conversion failed"
            on_progress(str(src), "error", message, None)
            errors.append({"file": str(src), "message": message})
        except Exception as e:  # noqa: BLE001 - report to UI, keep processing the rest
            on_progress(str(src), "error", str(e), None)
            errors.append({"file": str(src), "message": str(e)})
        finally:
            completed += 1
            _emit_batch()

    if cancelled:
        remaining = jobs[completed:]
        for src, _out_dir, _dest in remaining:
            skipped.append({"file": str(src), "reason": "cancelled"})

    return {"done": done, "skipped": skipped, "errors": errors, "cancelled": cancelled}


def preview(kind: str, config: dict, device: str, path: str,
            on_progress: Optional[ProgressFn] = None, max_pages: int = 15) -> dict:
    """Render up to `max_pages` pages of `path` (as it would look on
    `device` under `kind`) for an in-app preview, without writing anything
    into the user's chosen output location.

    If `path` isn't already a PDF, it's converted first via Calibre into a
    throwaway temp file (cleaned up before returning), same as a real
    conversion's first stage -- so previewing costs about the same as
    running "convert" up through that stage, just without the page-packing
    stage after it.

    Returns {"page_count": <total pages in the book>,
             "previewed": <how many were actually rendered>,
             "pages": [<PNG bytes>, ...]}.
    """
    import shutil
    import tempfile
    from lib.pdf2xtch import render_preview

    if device not in config.get("devices", {}):
        raise ValueError(f"Unknown device '{device}'.")
    dev = config["devices"][device]
    width, height, supersample, size = common.panel_size(dev, device)

    src = Path(path).resolve()
    if not src.is_file():
        raise ValueError(f"Not a file: {src}")

    tmp_dir = None
    try:
        if src.suffix.lower() == ".pdf":
            pdf_path = src
        else:
            fonts = common.fonts_for_os(config)
            font_size = common.font_size_for(config)
            ebook_convert = common.find_ebook_convert()
            tmp_dir = Path(tempfile.mkdtemp(prefix="cookbook-preview-"))
            pdf_path = tmp_dir / f"{src.stem}_preview.pdf"

            def _convert_progress(percent: int, message: str) -> None:
                if on_progress is not None:
                    on_progress(str(src), "convert", message, percent)

            if on_progress is not None:
                on_progress(str(src), "convert", "Converting to PDF via Calibre", 0)
            common.ebook_to_pdf(ebook_convert, src, pdf_path, size, fonts, font_size,
                                 on_progress=_convert_progress)

        if on_progress is not None:
            on_progress(str(src), "pack", "Rendering preview pages", 0)
        pages, page_count = render_preview(
            str(pdf_path), supersample, width, height, max_pages, quantize=(kind == "xtch"))
        return {"page_count": page_count, "previewed": len(pages), "pages": pages}
    finally:
        if tmp_dir is not None:
            shutil.rmtree(tmp_dir, ignore_errors=True)


