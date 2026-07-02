#!/usr/bin/env python3
"""Validate the shared MegaLinter configuration and its overrides.

Two classes of checks:

Structural (no MegaLinter source required)
    - Every config file parses as a YAML mapping.
    - ENABLE_LINTERS / DISABLE_LINTERS contain no duplicates.
    - A linter is never both enabled and disabled.
    - The changed-files override (.mega-linter-changed.yml) preserves the
      documented invariant: EXTENDS the base and enables exactly the base's
      linters minus the REPOSITORY_* entries (no leak, nothing missing).

Descriptor-backed (requires the pinned MegaLinter source clone)
    - Every enabled/disabled key is a real linter key accepted by MegaLinter
      (present in the schema's enum_linter_keys).
    - Every key is installable by our *slim* flavor: its DESCRIPTOR_ID prefix
      matches a real descriptor. This catches keys that pass the schema but
      have no descriptor (e.g. OPENAPI_SPECTRAL vs the real API_SPECTRAL),
      which the flavor generator would silently drop from the image.
"""

import argparse
import json
import logging
import sys
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger(__name__)

REPOSITORY_PREFIX = "REPOSITORY_"
DESCRIPTOR_GLOB = "*.megalinter-descriptor.yml"
SCHEMA_RELPATH = "schemas/megalinter-configuration.jsonschema.json"


class ConfigError(Exception):
    """Raised when a configuration file cannot be read or parsed."""


# ---------------------------------------------------------------------------
# Loading
# ---------------------------------------------------------------------------


def load_config(config_path: str | Path) -> dict[str, Any]:
    """Parse a MegaLinter config file into a mapping.

    Args:
        config_path: Path to a .mega-linter*.yml file.

    Returns:
        The parsed configuration mapping.

    Raises:
        ConfigError: If the file is missing, invalid YAML, or not a mapping.
    """
    path = Path(config_path)
    if not path.exists():
        msg = f"Configuration file not found: {config_path}"
        raise ConfigError(msg)

    try:
        content = path.read_text(encoding="utf-8")
        config = yaml.safe_load(content)
    except yaml.YAMLError as e:
        msg = f"Invalid YAML in {config_path}: {e}"
        raise ConfigError(msg) from e
    except OSError as e:
        msg = f"Error reading {config_path}: {e}"
        raise ConfigError(msg) from e

    if not isinstance(config, dict):
        msg = f"Configuration must be a YAML mapping: {config_path}"
        raise ConfigError(msg)

    return config


def linter_list(config: dict[str, Any], key: str) -> list[str]:
    """Return a linter list (ENABLE_LINTERS / DISABLE_LINTERS) from a config.

    A missing key yields an empty list; a present-but-non-list value is an
    error, since MegaLinter would reject it.

    Raises:
        ConfigError: If the key is present but not a list.
    """
    value = config.get(key, [])
    if not isinstance(value, list):
        msg = f"{key} must be a list"
        raise ConfigError(msg)
    return value


def find_descriptors_dir(cache_root: str | Path = ".cache") -> Path | None:
    """Locate the cached MegaLinter descriptors directory.

    The flavor:clone task caches the source at
    .cache/megalinter-v<version>/megalinter/descriptors. The version is
    discovered rather than hardcoded so this tracks MEGALINTER_VERSION.

    Returns:
        The descriptors directory, or None if the clone is absent.
    """
    root = Path(cache_root)
    if not root.is_dir():
        return None
    for clone in sorted(root.glob("megalinter-v*")):
        descriptors = clone / "megalinter" / "descriptors"
        if descriptors.is_dir():
            return descriptors
    return None


def _resolve_ref(schema: dict[str, Any], ref: str) -> dict[str, Any]:
    """Resolve a local JSON-Schema $ref (e.g. #/definitions/foo)."""
    node: Any = schema
    for part in ref.lstrip("#/").split("/"):
        node = node[part]
    return node


def load_valid_linter_keys(descriptors_dir: str | Path) -> set[str]:
    """Return the authoritative set of linter keys MegaLinter accepts.

    Read from the descriptor schema's ENABLE_LINTERS enum (resolving the
    $ref it points at). This is the same list MegaLinter validates config
    against, so it is the ground truth for "is this a real linter key".

    Raises:
        ConfigError: If the schema is missing or lacks the expected enum.
    """
    schema_path = Path(descriptors_dir) / SCHEMA_RELPATH
    if not schema_path.exists():
        msg = f"MegaLinter schema not found: {schema_path}"
        raise ConfigError(msg)

    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        msg = f"Error reading schema {schema_path}: {e}"
        raise ConfigError(msg) from e

    try:
        items = schema["properties"]["ENABLE_LINTERS"]["items"]
        node = _resolve_ref(schema, items["$ref"]) if "$ref" in items else items
        enum = node["enum"]
    except (KeyError, TypeError) as e:
        msg = f"Schema has no ENABLE_LINTERS enum: {schema_path}"
        raise ConfigError(msg) from e

    if not enum:
        msg = f"Schema ENABLE_LINTERS enum is empty: {schema_path}"
        raise ConfigError(msg)

    return set(enum)


def load_descriptor_ids(descriptors_dir: str | Path) -> set[str]:
    """Return every descriptor_id defined in the MegaLinter source.

    A linter key is DESCRIPTOR_ID + "_" + LINTER, so the descriptor_id set is
    what determines which keys our slim flavor generator can install.

    Raises:
        ConfigError: If no descriptors are found.
    """
    descriptors = Path(descriptors_dir)
    ids: set[str] = set()
    for desc_file in sorted(descriptors.glob(DESCRIPTOR_GLOB)):
        try:
            data = yaml.safe_load(desc_file.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError) as e:
            msg = f"Error reading descriptor {desc_file}: {e}"
            raise ConfigError(msg) from e
        if isinstance(data, dict) and data.get("descriptor_id"):
            ids.add(data["descriptor_id"])

    if not ids:
        msg = f"No descriptors found in {descriptors}"
        raise ConfigError(msg)

    return ids


# ---------------------------------------------------------------------------
# Checks (each returns a list of human-readable error strings)
# ---------------------------------------------------------------------------


def duplicate_keys(keys: list[str]) -> list[str]:
    """Return keys that appear more than once, in first-seen order."""
    seen: set[str] = set()
    dupes: list[str] = []
    for key in keys:
        if key in seen and key not in dupes:
            dupes.append(key)
        seen.add(key)
    return dupes


def enable_disable_overlap(enable: list[str], disable: list[str]) -> list[str]:
    """Return keys that are both enabled and disabled (a contradiction)."""
    disabled = set(disable)
    seen: set[str] = set()
    overlap: list[str] = []
    for key in enable:
        if key in disabled and key not in seen:
            overlap.append(key)
        seen.add(key)
    return overlap


def unknown_linter_keys(keys: list[str], valid_keys: set[str]) -> list[str]:
    """Return keys MegaLinter does not recognize (typos/hallucinations)."""
    return [key for key in keys if key not in valid_keys]


def uninstallable_linter_keys(
    keys: list[str],
    descriptor_ids: set[str],
) -> list[str]:
    """Return keys whose DESCRIPTOR_ID prefix matches no real descriptor.

    Such keys may pass MegaLinter's schema yet be silently dropped from the
    generated slim flavor, so the built image would lack that linter.
    """
    return [
        key
        for key in keys
        if not any(key.startswith(f"{did}_") for did in descriptor_ids)
    ]


def _derive_linter_key(descriptor_id: str, linter: dict[str, Any]) -> str:
    """Derive a MegaLinter linter key from a descriptor entry.

    Mirrors the flavor generator's derive_linter_name: an explicit ``name``
    wins, otherwise DESCRIPTOR_ID + "_" + linter_name (uppercased, hyphens to
    underscores).
    """
    explicit = linter.get("name")
    if explicit:
        return explicit
    linter_name = linter.get("linter_name", "")
    return f"{descriptor_id}_{linter_name}".upper().replace("-", "_")


def cargo_toolchain_linter_keys(descriptors_dir: str | Path) -> set[str]:
    """Return every linter key whose install needs a Rust/cargo toolchain.

    A descriptor declares ``install: cargo:`` (at descriptor or linter level)
    for linters installed as crates via ``cargo install``. Our slim flavor
    generator emits a bare ``cargo install`` with no rustup bootstrap, so any
    such enabled linter fails the image build with ``cargo: not found``.

    Raises:
        ConfigError: If a descriptor file cannot be read or parsed.
    """
    descriptors = Path(descriptors_dir)
    keys: set[str] = set()
    for desc_file in sorted(descriptors.glob(DESCRIPTOR_GLOB)):
        try:
            data = yaml.safe_load(desc_file.read_text(encoding="utf-8"))
        except (OSError, yaml.YAMLError) as e:
            msg = f"Error reading descriptor {desc_file}: {e}"
            raise ConfigError(msg) from e
        if not isinstance(data, dict):
            continue
        descriptor_id = data.get("descriptor_id", "")
        descriptor_cargo = bool((data.get("install") or {}).get("cargo"))
        for linter in data.get("linters", []) or []:
            if not isinstance(linter, dict):
                continue
            linter_cargo = bool((linter.get("install") or {}).get("cargo"))
            if descriptor_cargo or linter_cargo:
                keys.add(_derive_linter_key(descriptor_id, linter))
    return keys


def cargo_toolchain_linters(
    keys: list[str],
    descriptors_dir: str | Path,
) -> list[str]:
    """Return enabled keys that need a Rust/cargo toolchain to install.

    The slim flavor generator cannot bootstrap rustup/cargo, so keeping any of
    these in ENABLE_LINTERS breaks the image build. Callers must keep this
    empty; a consuming Rust repo can re-enable clippy and build its own flavor.
    """
    cargo_keys = cargo_toolchain_linter_keys(descriptors_dir)
    return [key for key in keys if key in cargo_keys]


def override_invariant_errors(
    base_enable: list[str],
    override_enable: list[str],
) -> list[str]:
    """Check the changed-files override preserves the documented invariant.

    The override must enable exactly the base linters minus REPOSITORY_*
    (which are skipped in changed-files mode). Any REPOSITORY_* leak, missing
    base linter, or stray extra linter is an error.
    """
    errors: list[str] = []
    expected = [k for k in base_enable if not k.startswith(REPOSITORY_PREFIX)]
    override_set = set(override_enable)
    expected_set = set(expected)

    leaked = sorted(k for k in override_set if k.startswith(REPOSITORY_PREFIX))
    if leaked:
        errors.append(
            "override enables REPOSITORY_* linters"
            f" (must be skipped in changed mode): {', '.join(leaked)}",
        )

    missing = sorted(expected_set - override_set)
    if missing:
        errors.append(
            "override is missing base linters: " + ", ".join(missing),
        )

    extra = sorted(
        k
        for k in override_set - expected_set
        if not k.startswith(REPOSITORY_PREFIX)
    )
    if extra:
        errors.append(
            "override enables linters absent from the base: "
            + ", ".join(extra),
        )

    return errors


def extends_errors(config: dict[str, Any], expected: str) -> list[str]:
    """Check a config's EXTENDS target matches the expected parent."""
    actual = config.get("EXTENDS")
    if actual != expected:
        return [f"EXTENDS should be {expected!r}, found {actual!r}"]
    return []


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def _collect_errors(
    base_path: Path,
    changed_path: Path | None,
    descriptors_dir: Path | None,
) -> list[str]:
    """Run every applicable check and return the aggregated error list."""
    errors: list[str] = []

    base = load_config(base_path)
    enable = linter_list(base, "ENABLE_LINTERS")
    disable = linter_list(base, "DISABLE_LINTERS")

    if not enable:
        errors.append("ENABLE_LINTERS is empty in the base config")

    for label, keys in (("ENABLE_LINTERS", enable), ("DISABLE_LINTERS", disable)):
        errors.extend(
            f"duplicate {label} entry: {dupe}"
            for dupe in duplicate_keys(keys)
        )

    errors.extend(
        f"linter is both enabled and disabled: {key}"
        for key in enable_disable_overlap(enable, disable)
    )

    if descriptors_dir is not None:
        valid = load_valid_linter_keys(descriptors_dir)
        ids = load_descriptor_ids(descriptors_dir)
        for label, keys in (
            ("ENABLE_LINTERS", enable),
            ("DISABLE_LINTERS", disable),
        ):
            errors.extend(
                f"unknown {label} key (not a MegaLinter linter): {key}"
                for key in unknown_linter_keys(keys, valid)
            )
            errors.extend(
                f"{label} key {key} has no matching descriptor"
                " (slim flavor would omit it)"
                for key in uninstallable_linter_keys(keys, ids)
            )
        errors.extend(
            f"ENABLE_LINTERS key {key} needs a Rust/cargo toolchain the slim"
            " flavor cannot bootstrap (image build fails: cargo not found)"
            for key in cargo_toolchain_linters(enable, descriptors_dir)
        )
    else:
        logger.warning(
            "MegaLinter clone not found; skipping linter-key validation."
            " Run 'task flavor:clone' for full checks.",
        )

    if changed_path is not None:
        changed = load_config(changed_path)
        errors.extend(extends_errors(changed, base_path.name))
        changed_enable = linter_list(changed, "ENABLE_LINTERS")
        errors.extend(override_invariant_errors(enable, changed_enable))

    return errors


def main() -> None:
    """CLI entry point."""
    logging.basicConfig(level=logging.INFO, format="%(message)s")

    parser = argparse.ArgumentParser(
        description="Validate the shared MegaLinter config and overrides.",
    )
    parser.add_argument(
        "base_config",
        nargs="?",
        default=".mega-linter.yml",
        help="Base MegaLinter config (default: .mega-linter.yml)",
    )
    parser.add_argument(
        "--changed",
        default=".mega-linter.d/.mega-linter-changed.yml",
        help="Changed-files override config to cross-check against the base",
    )
    parser.add_argument(
        "--descriptors-dir",
        default=None,
        help="MegaLinter descriptors dir (default: auto-discover under .cache)",
    )
    args = parser.parse_args()

    base_path = Path(args.base_config)
    changed_path = Path(args.changed) if args.changed else None
    if changed_path is not None and not changed_path.exists():
        changed_path = None

    descriptors_dir = (
        Path(args.descriptors_dir)
        if args.descriptors_dir
        else find_descriptors_dir()
    )

    try:
        errors = _collect_errors(base_path, changed_path, descriptors_dir)
    except ConfigError:
        logger.exception("Configuration error")
        sys.exit(1)

    if errors:
        logger.error("Configuration validation failed:")
        for error in errors:
            logger.error("  - %s", error)
        sys.exit(1)

    logger.info("Configuration validation passed.")


if __name__ == "__main__":
    main()
