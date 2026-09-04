# Development

## Layout

```
cookbook/
  README.md                 install and usage
  docs/                     format + this file
  install.sh                unsigned GitHub Release installer
  macos/                    SwiftUI app (SwiftPM)
    Package.swift
    Info.plist
    scripts/build-app.sh    Cookbook.app + .dmg → dist/
    Sources/Cookbook/
      App/                  @main, NSApplicationDelegate
      Views/                window, convert list, settings, sheets
      Model/                app state and file-list types
      Calibre/              ebook-convert / ebook-meta
      Packer/               PDF → XTCH and preview unpack
      Config/               built-in device defaults + UserDefaults
      Support/              l10n, fonts
      Resources/strings.json
  .github/workflows/        tag `v*.*.*` → Release with .dmg
```

Default devices live in `Config/DeviceConfig.swift`. User edits are stored
under UserDefaults keys `dev.cookbook.config.xtch` and
`dev.cookbook.config.pdf`.

## Run from source

macOS 14+, Xcode or Command Line Tools. Calibre for ebook → PDF.

```sh
brew install --cask calibre          # if needed
cd macos && swift run
```

If `ebook-convert` is not on `PATH`, set `EBOOK_CONVERT` to
`/Applications/calibre.app/Contents/MacOS/ebook-convert`.

## Package

```sh
macos/scripts/build-app.sh           # dist/Cookbook.app and dist/Cookbook.dmg
```

Calibre is not bundled. Builds are ad-hoc signed (no Developer ID).

## Release

Push a `v*.*.*` tag. [release-desktop.yml](../.github/workflows/release-desktop.yml)
builds the `.dmg` on `macos-latest`. Bump `macos/Info.plist`
(`CFBundleShortVersionString`) separately if the in-app version should match.
