# cookbook

Two converters for eink readers, macOS and Windows:

- **`toxtch.py`** — ebooks/PDFs → `.xtch` (Xteink / CrossPoint)
- **`topdf.py`** — ebooks → panel-sized PDFs (Kindle, Sony DPT, …)

## Setup

Python 3.11+ recommended. Then:

```sh
pip install -r requirements.txt
```

Calibre is a desktop app (not a pip package) and is required for ebook → PDF
conversion. Packing an existing PDF to `.xtch` does not need it.

**macOS**

```sh
brew install --cask calibre
```

**Windows**

```powershell
winget install -e --id calibre.calibre
```

Or download the installer from https://calibre-ebook.com. If `ebook-convert`
is not on your PATH after installing, set `EBOOK_CONVERT` to the binary
(`ebook-convert` on macOS, `ebook-convert.exe` on Windows — usually under
`C:\Program Files\Calibre2\`).

## Usage

You'll be prompted to pick a target device for that app. Then:

- **Ebook** → converted to a panel-sized PDF (via Calibre). `toxtch.py` packs
  that PDF into `.xtch`; `topdf.py` stops there.
- **PDF** → `toxtch.py` packs it directly; `topdf.py` skips it.

Filenames are `{stem}_{device}.xtch` or `{stem}_{device}.pdf`, written to an
`output/` folder next to the input file (`~/books/input/foo.epub` →
`~/books/input/output/foo_x3.xtch`). Override with `--output-dir`. Re-running
the same book for the same device overwrites; two inputs that would write the
same file: the first wins, the rest are skipped.

```sh
python toxtch.py mybook.epub             # ./output/mybook_<device>.xtch
python toxtch.py ~/books/input/          # every ebook/PDF in input/
python topdf.py mybook.epub              # ./output/mybook_<device>.pdf
python topdf.py --output-dir ~/out b.epub
```

Low-level packer (already a PDF): `python -m lib.pdf2xtch book.pdf`.

## Adding or changing devices

- [`devices.xtch.toml`](devices.xtch.toml) — `toxtch.py`
- [`devices.pdf.toml`](devices.pdf.toml) — `topdf.py`

Copy an existing block and adjust:

```toml
[devices.mydevice]
label = "My Reader"    # shown in the menu
width = 1080           # panel native width  (portrait, pixels)
height = 1440          # panel native height (portrait, pixels)
dpi = 200              # rasterization DPI (toxtch.py only)
font_size = 56         # Calibre PDF default font size
```

- `default` sets which device is pre-selected in that app's menu.
- `cjk_language` (`devices.xtch.toml` only) controls how CJK in `.xtch`
  filenames and chapter names is turned into ASCII. `japanese` (default)
  uses Hepburn romaji, `chinese` uses pinyin, `korean` uses Revised
  Romanization of hangul. The low-level packer accepts `--cjk-language`.
- `[fonts.macos]` / `[fonts.windows]` set the CJK fonts used for ebook → PDF
  conversion on each OS. Change these if a family is not installed.
