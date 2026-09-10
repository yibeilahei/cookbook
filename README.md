# cookbook

macOS 14+ app (Apple Silicon and Intel) that converts ebooks and PDFs for eink readers:

- **`.xtch`** — Xteink / CrossPoint devices
- **Panel-sized PDF** — Kindle, Sony DPT, and similar

Ebook → PDF uses **WebKit** (EPUB, HTML, TXT, Kindle MOBI/AZW/AZW3) or Calibre's
`ebook-convert` (any format Calibre supports). PDF → `.xtch` is packed in Swift
([format](docs/xtch.md)). Calibre is optional unless you convert FB2 or similar.

## Install

Builds are unsigned. A browser-downloaded `.dmg` is blocked by Gatekeeper;
install with:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/yibeilahei/cookbook/main/install.sh)"
```

The script copies `Cookbook.app` to `~/Applications` and opens it. EPUB, HTML,
TXT, Kindle (MOBI/AZW/AZW3), and PDF work with the built-in WebKit engine. For
FB2 and other formats, install Calibre and switch **Engine** to Calibre in
Settings:

```sh
brew install --cask calibre
```

## Using the app

1. Pick **`.xtch`** or **`.pdf`** and a target device.
2. Drop ebooks/PDFs (or folders), or use **Add files…**.
3. **Convert** is on each file row (becomes **Cancel** while that file
   runs). **Preview** appears after a successful `.xtch` convert.
4. Click the chevron on a row to expand or fold the conversion log.

Outputs go to `output/` next to each input, or to a folder you pick.

## Devices and settings

Built-in profiles: Xteink X3/X4 (`.xtch`), Kindle Paperwhite 11th and Sony
DPT-RP1 (panel PDF). **Edit devices…** adds or changes them; the app stores
edits in UserDefaults.

| Setting | Meaning |
| --- | --- |
| Engine | **WebKit** converts EPUB, HTML, TXT, and Kindle (MOBI/AZW/AZW3) without Calibre. **Calibre** handles FB2 and other formats. |
| Language | Script bucket for font presets. Detected from the OS and, when possible, from book metadata. |
| Fonts / size | Families and default size Calibre uses for ebook → PDF. |
| Page compression | `.xtch` only. Raw-DEFLATE per page when smaller. Only lazahata firmware supports this; leave off otherwise. |

`.xtch` filenames and chapter names are Latin-folded to ASCII.

`.xtch` height must be a multiple of 8. Landscape swaps width/height so
pages are laid out sideways.

Simplified vs Traditional Chinese is not in Calibre’s language code.
Detection looks at title/author characters; pick the language by hand if
needed.

## Develop and release

See [docs/development.md](docs/development.md).
