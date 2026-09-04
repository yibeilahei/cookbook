# cookbook

macOS app that converts ebooks and PDFs for eink readers:

- **`.xtch`** — Xteink / CrossPoint devices
- **Panel-sized PDF** — Kindle, Sony DPT, and similar

Ebook → PDF uses Calibre's `ebook-convert`. PDF → `.xtch` is packed in
Swift ([format](docs/xtch.md)).

## Install

Builds are unsigned. A browser-downloaded `.dmg` is blocked by Gatekeeper;
install with:

```sh
brew install --cask calibre
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/yibeilahei/cookbook/main/install.sh)"
```

Skip the Calibre line if it is already installed. Calibre is required for
ebook → PDF, not for PDF → `.xtch`. The script copies `Cookbook.app` to
`~/Applications` and opens it.

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
