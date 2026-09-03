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

## Install

**macOS** — paste this in Terminal (same idea as Homebrew). Do not download
the `.dmg` in a browser: Gatekeeper will block it, and any helper `.command`
inside it.

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/yibeilahei/cookbook/main/install.sh)"
```

That fetches the latest GitHub Release, copies `Cookbook.app` to
`~/Applications`, and opens it. After that, launch it from there (or drag
it to `/Applications`) like any other app.

**Windows** — paste this in PowerShell or cmd (same idea). Do not download
the `.exe` in a browser: SmartScreen will block it.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/yibeilahei/cookbook/main/install.ps1 | iex"
```

That fetches the latest GitHub Release, copies Cookbook to
`%LOCALAPPDATA%\Programs\Cookbook`, unblocks it, and opens it. After that,
launch it from the Start menu.

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

`.github/workflows/release-desktop.yml` runs both legs on a `macos-latest` /
`windows-latest` CI matrix when a `v*.*.*` tag is pushed.

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
- `language` (top-level) is a script-family bucket used to recommend fonts
  and (in `.xtch` mode) whether CJK-romanization is applicable. One of
  `latin` (default; covers English, French, German, Spanish, etc.),
  `japanese`, `chinese_simplified`, `chinese_traditional`, `korean`,
  `cyrillic` (Russian, Ukrainian, etc.), `greek`, `arabic` (also
  Persian/Urdu/Pashto), `hebrew`, `devanagari` (Hindi, Marathi, etc.),
  `thai`, `bengali`, `tamil`, `telugu`, `kannada`, `malayalam`, `gujarati`,
  `gurmukhi` (Punjabi), `odia`, `sinhala`, `myanmar`, `ethiopic` (Amharic,
  Tigrinya), `khmer`, or `other` (any script without a curated font preset
  -- pick fonts manually). Together these cover the scripts used by the
  world's ~100 most-spoken languages. Auto-detected from the system locale by default, and re-detected
  per-book from its own metadata when a book is added, if possible;
  editable from the in-app Settings panel. Simplified vs. Traditional
  Chinese can't be told apart from Calibre's language metadata alone (it
  normalizes `zh`, `zh-CN`, `zh-TW`, `zh-Hans`, `zh-Hant`, etc. all down to
  the same generic code), so per-book auto-detection instead inspects the
  book's title/author text for script-distinguishing characters; when a
  title has none (e.g. very short, or spelled the same in both scripts),
  detection is skipped and the language must be picked manually.
- `font_size` (top-level, not per-device) is the Calibre PDF default font
  size used when converting ebooks; editable from the in-app Settings panel.
- `page_compression` (`.xtch` mode only, default off) stores each page as
  raw-DEFLATE when that shrinks it. Currently the only firmware that
  supports page compression is lazahata; leave this off for other
  firmware. Editable from the in-app Settings panel.
- `ascii_romanization` (`.xtch` mode only) controls how CJK in `.xtch`
  filenames and chapter names is turned into ASCII. `japanese` (default)
  uses Hepburn romaji, `chinese` uses pinyin (used for both
  `chinese_simplified` and `chinese_traditional` -- pinyin doesn't depend
  on which script a book uses), `korean` uses Revised Romanization of
  hangul, `none` skips this extra pass (every other language, and every
  script including these three, still always gets a plain Unidecode
  ASCII-fallback for `.xtch` filenames -- this setting only controls
  whether a higher-quality Japanese/Chinese/Korean-specific pass runs
  first). Named for what it controls (ASCII-safety), not a language
  selection -- it's a byproduct of the `language` setting above, not a
  separate user-facing language choice.
- `[fonts.macos]` / `[fonts.windows]` set the CJK fonts used for ebook → PDF
  conversion on each OS. Change these if a family is not installed.

Low-level packer, for scripting (already a PDF, skips the app entirely):
`python -m lib.pdf2xtch book.pdf`.
