"""User-writable device config management.

The repo ships devices.xtch.toml / devices.pdf.toml as read-only defaults
(see lib.common.config_path). The desktop app instead needs a place it can
write in-app device edits that survives app updates/reinstalls, so on first
use for a given kind we seed a user-writable copy under a directory the app
controls (`~/Library/Application Support/Cookbook/device-config`) and
read/write that copy from then on. The bundled defaults themselves are
never modified.
"""

from __future__ import annotations

import shutil
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:  # Python < 3.11
    import tomli as tomllib  # type: ignore[no-redef]

import tomli_w

from lib import common

_user_dir: Path | None = None


def set_user_dir(path: str) -> None:
    """Set the writable directory for user device configs. Call once at startup."""
    global _user_dir
    _user_dir = Path(path)
    _user_dir.mkdir(parents=True, exist_ok=True)


def _user_config_path(kind: str) -> Path:
    if _user_dir is None:
        raise RuntimeError("config.set_user_dir() must be called before use")
    return _user_dir / f"devices.{kind}.toml"


def load(kind: str) -> dict:
    """Load the user's config, seeding it from the bundled default on first use."""
    user_path = _user_config_path(kind)
    if not user_path.exists():
        shutil.copyfile(common.config_path(kind), user_path)
    with open(user_path, "rb") as f:
        config = tomllib.load(f)
    # Migrate the old "cjk_language" field name (pre-rename) transparently
    # so existing on-disk user configs keep working.
    if "cjk_language" in config and "ascii_romanization" not in config:
        config["ascii_romanization"] = config.pop("cjk_language")
    return config


def save(kind: str, config: dict) -> None:
    """Validate and persist an edited config to the user's config path."""
    validate(kind, config)
    with open(_user_config_path(kind), "wb") as f:
        tomli_w.dump(config, f)


def validate(kind: str, config: dict) -> None:
    """Raise ValueError with a human-readable message if `config` is unusable."""
    devices = config.get("devices")
    if not isinstance(devices, dict) or not devices:
        raise ValueError("Config must define at least one [devices.*] entry.")

    default = config.get("default")
    if default is not None and default not in devices:
        raise ValueError(f"default '{default}' is not one of the defined devices.")

    for key, dev in devices.items():
        if not isinstance(dev, dict):
            raise ValueError(f"devices.{key} must be a table.")
        for field in ("width", "height"):
            if field not in dev:
                raise ValueError(f"devices.{key} is missing '{field}'.")
            if not isinstance(dev[field], int) or isinstance(dev[field], bool) \
                    or dev[field] <= 0:
                raise ValueError(f"devices.{key}.{field} must be a positive integer.")
        if "supersample" in dev and (not isinstance(dev["supersample"], int)
                                      or isinstance(dev["supersample"], bool)
                                      or dev["supersample"] <= 0):
            raise ValueError(f"devices.{key}.supersample must be a positive integer.")
        orientation = dev.get("orientation", "portrait")
        if orientation not in ("portrait", "landscape"):
            raise ValueError(
                f"devices.{key}.orientation must be 'portrait' or 'landscape'.")

    if kind == "xtch":
        if config.get("ascii_romanization") is not None:
            try:
                common.normalize_ascii_romanization(config["ascii_romanization"])
            except SystemExit as e:
                raise ValueError(str(e.code)) from e
        page_compression = config.get("page_compression")
        if page_compression is not None and not isinstance(page_compression, bool):
            raise ValueError("page_compression must be a boolean.")

    language = config.get("language")
    if language is not None and language not in common.FONT_LANGUAGES:
        allowed = ", ".join(common.FONT_LANGUAGES)
        raise ValueError(f"language must be one of: {allowed}.")

    font_size = config.get("font_size")
    if font_size is not None and (not isinstance(font_size, int)
                                   or isinstance(font_size, bool) or font_size <= 0):
        raise ValueError("font_size must be a positive integer.")

    fonts = config.get("fonts")
    if fonts is not None and not isinstance(fonts, dict):
        raise ValueError("fonts must be a table.")
