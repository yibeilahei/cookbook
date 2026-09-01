# cookbook

Desktop app (macOS and Windows) that converts ebooks/PDFs for eink readers:

- **`.xtch`** output (Xteink / CrossPoint devices)
- **Panel-sized PDF** output (Kindle, Sony DPT, …)

Under the hood it's an Electron UI driving a Python backend (Calibre does
ebook → PDF conversion; a bundled packer turns PDFs into `.xtch`).

## Setup (running from source)

Python 3.11+ and Node 20+ recommended.

```sh
pip install -r requirements.txt
cd electron && npm install
```

Calibre is a desktop app (not a pip package) and is required for ebook → PDF
conversion. Converting an existing PDF to `.xtch` does not need it.

**macOS**

```sh
brew install --cask calibre
```

**Windows**

```powershell
winget install -e --id calibre.calibre
```

Or download the installer from https://calibre-ebook.com. If the app can't
find Calibre after installing, set `EBOOK_CONVERT` to the `ebook-convert`
binary (usually under `/Applications/calibre.app/Contents/MacOS/` on macOS or
`C:\Program Files\Calibre2\` on Windows).

## Running

```sh
cd electron && npm start
```

Drag and drop ebooks/PDFs (or whole folders) into the window, pick a mode
(`.xtch` or Panel PDF) and a target device, and hit Convert. Outputs are
written to an `output/` folder next to each input by default, or to a
folder you pick.

## Building a distributable app

PyInstaller doesn't cross-compile, so the Python backend must be frozen on
each OS you're targeting before packaging the Electron app:

```sh
pip install -r requirements.txt -r requirements-dev.txt
pyinstaller packaging/pyinstaller/backend-server.spec \
    --distpath packaging/dist --workpath packaging/build --noconfirm

cd electron
npm ci
npm run dist:mac    # -> electron/dist/*.dmg (run this leg on macOS)
npm run dist:win    # -> electron/dist/*.exe (run this leg on Windows)
```

`.github/workflows/build-desktop.yml` runs both legs on a `macos-latest` /
`windows-latest` CI matrix. Builds are currently unsigned (no Gatekeeper
notarization / Windows code-signing cert yet), so macOS will warn on first
launch and Windows SmartScreen may flag the installer.

## Adding or changing devices

Devices are editable from the app itself ("Edit devices…" next to the device
picker) — add, edit, delete, and set the default device for each mode. Edits
are saved to a per-user config file (not the repo), seeded on first run from:

- [`devices.xtch.toml`](devices.xtch.toml) — `.xtch` mode
- [`devices.pdf.toml`](devices.pdf.toml) — Panel PDF mode

If you'd rather hand-edit the TOML directly, copy an existing block and
adjust:

```toml
[devices.mydevice]
label = "My Reader"    # shown in the app's device picker
width = 1080           # panel native width  (portrait, pixels)
height = 1440          # panel native height (portrait, pixels)
supersample = 3        # rasterization multiplier before downscaling to the
                       # panel size (.xtch mode only; not the panel's PPI)
```

- `default` sets which device is pre-selected in that mode's picker.
- `font_size` (top-level, not per-device) is the Calibre PDF default font
  size used when converting ebooks; editable from the in-app Settings panel.
- `cjk_language` (`.xtch` mode only) controls how CJK in `.xtch` filenames
  and chapter names is turned into ASCII. `japanese` (default) uses Hepburn
  romaji, `chinese` uses pinyin, `korean` uses Revised Romanization of
  hangul, `none` skips romanization (plain Unidecode fallback only).
- `[fonts.macos]` / `[fonts.windows]` set the CJK fonts used for ebook → PDF
  conversion on each OS. Change these if a family is not installed.

Low-level packer, for scripting (already a PDF, skips the app entirely):
`python -m lib.pdf2xtch book.pdf`.
