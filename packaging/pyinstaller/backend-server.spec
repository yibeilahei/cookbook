# -*- mode: python ; coding: utf-8 -*-
"""PyInstaller spec for backend/server.py (the Electron app's JSON-protocol
conversion worker).

Build from the repo root, with the project venv activated and PyInstaller
installed (`pip install -r requirements.txt pyinstaller`):

    pyinstaller packaging/pyinstaller/backend-server.spec \
        --distpath packaging/dist --workpath packaging/build --noconfirm

Produces packaging/dist/backend-server/ (a onedir build: the frozen
"backend-server"/"backend-server.exe" executable next to its bundled Python
runtime, native libs, and resources). electron-builder later copies this
whole folder into the app bundle as extraResources.

PyInstaller does not cross-compile: this must be run once on macOS (for the
macOS app) and once on Windows (for the Windows app), e.g. as two legs of a
CI matrix.
"""

from pathlib import Path

from PyInstaller.utils.hooks import collect_data_files, collect_submodules

# SPECPATH is packaging/pyinstaller; the repo root is two levels up.
REPO_ROOT = Path(SPECPATH).resolve().parent.parent

# Bundled as fallback defaults; backend/config.py copies these into the
# user-writable config dir (Electron's userData) on first run, and reads
# lib.common.config_path(), which resolves relative to ROOT = the frozen
# bundle's own root -- so these must land next to the "lib" package below,
# not in a "data" subfolder.
datas = [
    (str(REPO_ROOT / "devices.xtch.toml"), "."),
    (str(REPO_ROOT / "devices.pdf.toml"), "."),
]
# pykakasi ships its romanization dictionaries as package data (read via
# importlib.resources), and pymupdf ships fonts/ICC profiles it needs at
# runtime -- both are invisible to PyInstaller's default import analysis.
datas += collect_data_files("pykakasi")
datas += collect_data_files("pymupdf")

hiddenimports = collect_submodules("pykakasi")

a = Analysis(
    [str(REPO_ROOT / "backend" / "server.py")],
    pathex=[str(REPO_ROOT)],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    noarchive=False,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name="backend-server",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=False,
    console=True,
    disable_windowed_traceback=False,
    argv_emulation=False,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    upx_exclude=[],
    name="backend-server",
)
