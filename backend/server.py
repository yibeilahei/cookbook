#!/usr/bin/env python3
"""JSON-lines backend for the SwiftUI Mac app.

Spawned as a child process by the app and killed when it quits. Talks a
line-delimited JSON protocol over stdio:

    Request   {"id": <int>, "cmd": "<name>", ...params}
    Response  {"id": <int>, "ok": true, "result": ...}
           or {"id": <int>, "ok": false, "error": "<message>"}
    Progress  {"id": <int>, "type": "progress", "file", "stage", "message",
               "percent"}
              (zero or more; only for "convert"/"preview"; always followed
              by the final response with the same id). "percent" is 0-100
              within the current stage, or null when not known. "stage" is
              one of "convert", "pack", "done", "error", or "cancelled".
    Batch     {"id": <int>, "type": "batch", "completed", "total",
               "elapsed_seconds", "eta_seconds"}
              (sent once per input file as it finishes, alongside "progress";
              "eta_seconds" is null until at least one file has completed)

Commands
--------
list_devices   {kind: "xtch"|"pdf"}                 -> {devices: {...}, default}
get_config     {kind}                                -> full parsed config
save_config    {kind, config}                        -> {} (raises on invalid config)
find_calibre   {}                                    -> {found, path?, hint?}
expand_inputs  {paths: [str]}                        -> {files: [str]}
detect_language {paths: [str]}                       -> {languages: {path: lang|null}}
                 Best-effort per-file language detection from book metadata
                 (via Calibre's ebook-meta), mapped to one of the "Language"
                 setting's buckets (english/japanese/chinese/korean). null
                 when undetectable (no metadata, unsupported format/language,
                 or ebook-meta missing) -- the UI just skips auto-applying a
                 language in that case.
convert        {kind, device, paths, output_dir?}    -> {done, skipped, errors,
                                                          cancelled}
                 Runs in a background thread so other commands (in particular
                 "cancel") can be dispatched and answered while it's in
                 flight. Only one convert may be in flight at a time; a
                 second "convert" sent before the first responds is rejected.
preview        {kind, device, path, max_pages?}      -> {page_count, previewed,
                                                          pages: [<data URL>]}
                 Renders up to `max_pages` (default 15) pages of `path` as it
                 would look on `device`, as PNG data URLs, without touching
                 the user's chosen output location. Also runs in a
                 background thread (any number may run concurrently with
                 each other and with an in-flight "convert").
cancel         {}                                    -> {cancelled: bool}
                 Requests early stop of the in-flight "convert" (there's at
                 most one, since a second is rejected while one is running).
                 Returns true if a convert was in fact in flight and
                 signalled (it still finishes the file it's mid-way through,
                 then stops and sends its normal response with
                 result.cancelled = true); false if there was nothing to
                 cancel (already finished, or none was running).
shutdown       {}                                    -> {} (then the process exits)

IMPORTANT: lib.common / lib.pdf2xtch call print() directly (progress/log
messages meant for a human at a terminal). Left alone, those would land on
stdout and corrupt this JSON-lines protocol, since the UI parses stdout
line-by-line as JSON. So immediately below we swap sys.stdout for sys.stderr
process-wide, and use `_STDOUT` (the real, original stream) exclusively for
protocol I/O.
"""

from __future__ import annotations

import argparse
import json
import multiprocessing
import sys
import threading

_STDOUT = sys.stdout          # the only stream protocol messages are written to
sys.stdout = sys.stderr       # any stray print() from lib code now goes to stderr

from backend import config as device_config  # noqa: E402
from backend import jobs  # noqa: E402
from lib import common  # noqa: E402

_send_lock = threading.Lock()


def _send(message: dict) -> None:
    with _send_lock:
        _STDOUT.write(json.dumps(message, ensure_ascii=False) + "\n")
        _STDOUT.flush()


def _respond_ok(req_id, result=None) -> None:
    _send({"id": req_id, "ok": True, "result": result})


def _respond_error(req_id, message: str) -> None:
    _send({"id": req_id, "ok": False, "error": message})


def _cmd_list_devices(params: dict) -> dict:
    cfg = device_config.load(params["kind"])
    return {"devices": cfg.get("devices", {}), "default": cfg.get("default")}


def _cmd_get_config(params: dict) -> dict:
    return device_config.load(params["kind"])


def _cmd_save_config(params: dict) -> dict:
    device_config.save(params["kind"], params["config"])
    return {}


def _cmd_find_calibre(_params: dict) -> dict:
    try:
        path = common.find_ebook_convert()
        return {"found": True, "path": path}
    except SystemExit as e:
        return {"found": False, "hint": str(e.code)}


def _cmd_expand_inputs(params: dict) -> dict:
    from pathlib import Path
    files = common.expand_inputs([Path(p) for p in params["paths"]])
    return {"files": [str(f.resolve()) for f in files]}


def _cmd_detect_language(params: dict) -> dict:
    return {"languages": {p: common.detect_book_language(p) for p in params["paths"]}}


# req_id -> threading.Event for every convert currently running, so a
# "cancel" command (handled inline on the main stdin-reading thread, since
# convert runs on its own thread below) can signal it to stop early.
_active_converts: dict[int, threading.Event] = {}
_active_converts_lock = threading.Lock()


def _cmd_cancel(_params: dict, _req_id) -> dict:
    with _active_converts_lock:
        events = list(_active_converts.values())
    for event in events:
        event.set()
    return {"cancelled": len(events) > 0}


def _run_convert(params: dict, req_id, cancel_event: threading.Event) -> dict:
    cfg = device_config.load(params["kind"])

    def on_progress(file: str, stage: str, message: str, percent) -> None:
        _send({"id": req_id, "type": "progress",
               "file": file, "stage": stage, "message": message, "percent": percent})

    def on_batch(completed: int, total: int, elapsed: float, eta) -> None:
        _send({"id": req_id, "type": "batch", "completed": completed, "total": total,
               "elapsed_seconds": elapsed, "eta_seconds": eta})

    return jobs.run(
        params["kind"], cfg, params["device"], params["paths"],
        params.get("output_dir"), on_progress, on_batch,
        should_cancel=cancel_event.is_set,
    )


def _convert_thread_main(request: dict, req_id, cancel_event: threading.Event) -> None:
    try:
        result = _run_convert(request, req_id, cancel_event)
        _respond_ok(req_id, result)
    except (ValueError, KeyError) as e:
        _respond_error(req_id, str(e))
    except SystemExit as e:
        _respond_error(req_id, str(e.code) if e.code else "command failed")
    except Exception as e:  # noqa: BLE001 - never let one bad request kill the server
        _respond_error(req_id, f"{type(e).__name__}: {e}")
    finally:
        with _active_converts_lock:
            _active_converts.pop(req_id, None)


def _run_preview(params: dict, req_id) -> dict:
    import base64

    cfg = device_config.load(params["kind"])

    def on_progress(file: str, stage: str, message: str, percent) -> None:
        _send({"id": req_id, "type": "progress",
               "file": file, "stage": stage, "message": message, "percent": percent})

    result = jobs.preview(
        params["kind"], cfg, params["device"], params["path"], on_progress,
        max_pages=params.get("max_pages", 15),
    )
    return {
        "page_count": result["page_count"],
        "previewed": result["previewed"],
        "pages": [
            "data:image/png;base64," + base64.b64encode(png).decode("ascii")
            for png in result["pages"]
        ],
    }


def _preview_thread_main(request: dict, req_id) -> None:
    try:
        result = _run_preview(request, req_id)
        _respond_ok(req_id, result)
    except (ValueError, KeyError) as e:
        _respond_error(req_id, str(e))
    except SystemExit as e:
        _respond_error(req_id, str(e.code) if e.code else "command failed")
    except Exception as e:  # noqa: BLE001 - never let one bad request kill the server
        _respond_error(req_id, f"{type(e).__name__}: {e}")


_HANDLERS = {
    "list_devices": lambda p, _id: _cmd_list_devices(p),
    "get_config": lambda p, _id: _cmd_get_config(p),
    "save_config": lambda p, _id: _cmd_save_config(p),
    "find_calibre": lambda p, _id: _cmd_find_calibre(p),
    "expand_inputs": lambda p, _id: _cmd_expand_inputs(p),
    "detect_language": lambda p, _id: _cmd_detect_language(p),
    "cancel": _cmd_cancel,
}


def _dispatch(request: dict) -> None:
    req_id = request.get("id")
    cmd = request.get("cmd")
    if cmd == "shutdown":
        _respond_ok(req_id, {})
        raise SystemExit(0)

    if cmd == "convert":
        # Runs in its own thread so this loop stays free to read/dispatch a
        # "cancel" (or anything else) while the conversion is in progress.
        # Only one convert at a time -- a second one before the first
        # responds would race it for stdout/on_progress bookkeeping in
        # jobs.run(), so it's rejected outright (the UI already disables the
        # Convert button while one is in flight). The cancel_event is
        # registered here (before the thread starts, on the same thread that
        # reads the next stdin line) so a "cancel" sent immediately after
        # can't race the thread's own startup.
        with _active_converts_lock:
            if _active_converts:
                _respond_error(req_id, "A conversion is already in progress.")
                return
            cancel_event = threading.Event()
            _active_converts[req_id] = cancel_event
        threading.Thread(
            target=_convert_thread_main, args=(request, req_id, cancel_event),
            daemon=True,
        ).start()
        return

    if cmd == "preview":
        # Also backgrounded, since it involves the same potentially-slow
        # Calibre step as convert; unlike convert, any number of these can
        # run at once (each uses its own throwaway temp file, see
        # jobs.preview), so there's no busy-check here.
        threading.Thread(
            target=_preview_thread_main, args=(request, req_id), daemon=True,
        ).start()
        return

    handler = _HANDLERS.get(cmd)
    if handler is None:
        _respond_error(req_id, f"Unknown command '{cmd}'.")
        return

    try:
        result = handler(request, req_id)
        _respond_ok(req_id, result)
    except (ValueError, KeyError) as e:
        _respond_error(req_id, str(e))
    except SystemExit as e:
        _respond_error(req_id, str(e.code) if e.code else "command failed")
    except Exception as e:  # noqa: BLE001 - never let one bad request kill the server
        _respond_error(req_id, f"{type(e).__name__}: {e}")



def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--user-config-dir", required=True,
        help="Writable directory for in-app device config edits "
             "(the app's Application Support path)")
    args = parser.parse_args()
    device_config.set_user_dir(args.user_config_dir)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError as e:
            _send({"ok": False, "error": f"Invalid JSON request: {e}"})
            continue
        try:
            _dispatch(request)
        except SystemExit:
            break


if __name__ == "__main__":
    multiprocessing.freeze_support()  # required for ProcessPoolExecutor once frozen
    main()
