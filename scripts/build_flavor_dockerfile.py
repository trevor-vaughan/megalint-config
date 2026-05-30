#!/usr/bin/env python3
"""Generate a slim MegaLinter custom flavor Dockerfile.

Reads MegaLinter descriptor YAML files, filters by enabled linters,
and generates a Dockerfile that installs only those linters.
"""

import argparse
import importlib.util
import logging
import re
import sys
from pathlib import Path
from typing import Any

import yaml

logger = logging.getLogger(__name__)

DESCRIPTOR_GLOB = "*.megalinter-descriptor.yml"

# Minimum COPY instruction part count: COPY <from> <src> <dest>
_MIN_COPY_PARTS = 3

BASE_APK_PACKAGES = [
    "bash",
    "ca-certificates",
    "curl",
    "gcc",
    "gcompat",
    "git",
    "git-lfs",
    "libffi-dev",
    "make",
    "musl-dev",
    "openssh",
]

NPM_APK_PACKAGES = [
    "npm",
    "nodejs-current",
    "yarn",
]

GEM_APK_PACKAGES = [
    "ruby",
    "ruby-dev",
    "ruby-bundler",
    "ruby-rdoc",
]


def load_descriptors(
    descriptors_dir: Path,
) -> list[dict[str, Any]]:
    """Load all MegaLinter descriptor YAML files.

    Args:
        descriptors_dir: Directory containing descriptor
            YAML files.

    Returns:
        List of parsed descriptor dicts.
    """
    descriptors_dir = Path(descriptors_dir)
    descriptors = []
    for desc_file in sorted(
        descriptors_dir.glob(DESCRIPTOR_GLOB),
    ):
        if not desc_file.is_file():
            continue
        with desc_file.open(encoding="utf-8") as f:
            data = yaml.safe_load(f)
        if isinstance(data, dict):
            descriptors.append(data)
    return descriptors


def derive_linter_name(
    descriptor_id: str,
    linter: dict[str, Any],
) -> str:
    """Derive the MegaLinter linter name.

    When a descriptor linter has an explicit 'name' field,
    use it. Otherwise, derive from the descriptor ID and
    linter_name: DESCRIPTOR_ID_LINTER_NAME (uppercased,
    hyphens become underscores).
    """
    explicit = linter.get("name")
    if explicit:
        return explicit
    linter_name = linter.get("linter_name", "")
    return (
        f"{descriptor_id}_{linter_name}"
        .upper()
        .replace("-", "_")
    )


def _dedup_preserve_order(
    items: list[str],
) -> list[str]:
    """Deduplicate a list while preserving order."""
    seen: set[str] = set()
    result: list[str] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            result.append(item)
    return result


def _build_apk_list(
    extra_apk: list[str],
    npm_packages: list[str],
    gem_packages: list[str],
) -> list[str]:
    """Merge base APK packages with extras and conditionals.

    Adds NPM/GEM runtime packages when those package
    managers are needed, deduplicates, and sorts.
    """
    all_apk = list(BASE_APK_PACKAGES)
    if npm_packages:
        all_apk.extend(NPM_APK_PACKAGES)
    if gem_packages:
        all_apk.extend(GEM_APK_PACKAGES)
    all_apk.extend(extra_apk)

    seen: set[str] = set()
    deduped: list[str] = []
    for pkg in all_apk:
        if pkg not in seen:
            seen.add(pkg)
            deduped.append(pkg)
    deduped.sort()
    return deduped


def collect_installs(
    descriptors: list[dict[str, Any]],
    enabled_linters: list[str],
) -> dict[str, Any]:
    """Collect install instructions for enabled linters.

    For each descriptor, if any of its linters match
    enabled_linters, collect both descriptor-level and
    matching linter-level install instructions.

    Args:
        descriptors: List of parsed descriptor dicts.
        enabled_linters: List of enabled linter names.

    Returns:
        Dict with keys: apk, npm, pip, gem, cargo,
        dockerfile.
    """
    enabled = set(enabled_linters)
    apk_set: list[str] = []
    npm_list: list[str] = []
    pip_dict: dict[str, list[str]] = {}
    gem_list: list[str] = []
    cargo_list: list[str] = []
    dockerfile_lines: list[str] = []

    for descriptor in descriptors:
        descriptor_id = descriptor.get(
            "descriptor_id", "",
        )
        linters = descriptor.get("linters", [])
        matched_linters = [
            linter
            for linter in linters
            if derive_linter_name(
                descriptor_id, linter,
            ) in enabled
        ]
        if not matched_linters:
            continue

        # Descriptor-level install
        desc_install = descriptor.get("install", {})
        if desc_install:
            apk_set.extend(
                desc_install.get("apk", []),
            )
            npm_list.extend(
                desc_install.get("npm", []),
            )
            gem_list.extend(
                desc_install.get("gem", []),
            )
            cargo_list.extend(
                desc_install.get("cargo", []),
            )
            dockerfile_lines.extend(
                desc_install.get("dockerfile", []),
            )

        # Linter-level install
        for linter in matched_linters:
            linter_install = linter.get(
                "install", {},
            )
            if not linter_install:
                continue
            apk_set.extend(
                linter_install.get("apk", []),
            )
            npm_list.extend(
                linter_install.get("npm", []),
            )
            gem_list.extend(
                linter_install.get("gem", []),
            )
            cargo_list.extend(
                linter_install.get("cargo", []),
            )
            dockerfile_lines.extend(
                linter_install.get("dockerfile", []),
            )
            pip_packages = linter_install.get(
                "pip", [],
            )
            if pip_packages:
                derived = derive_linter_name(
                    descriptor_id, linter,
                )
                pip_dict[derived] = pip_packages

    # Deduplicate npm, gem, cargo (preserve order)
    deduped_npm = _dedup_preserve_order(npm_list)
    deduped_gem = _dedup_preserve_order(gem_list)

    return {
        "apk": _build_apk_list(
            apk_set, deduped_npm, deduped_gem,
        ),
        "npm": deduped_npm,
        "pip": pip_dict,
        "gem": deduped_gem,
        "cargo": _dedup_preserve_order(cargo_list),
        "dockerfile": dockerfile_lines,
    }


def _effective_instruction(line: str) -> str:
    """Get the effective Dockerfile instruction.

    Descriptor lines can be multiline strings with
    embedded newlines (e.g., "# comment\\nARG FOO=bar").
    Returns the first non-comment, non-empty line so that
    multiline FROM stage blocks are correctly classified.
    """
    parts = line.strip().split("\n")
    for part in parts:
        stripped = part.strip()
        if stripped and not stripped.startswith("#"):
            return stripped
    for part in reversed(parts):
        stripped = part.strip()
        if stripped:
            return stripped
    return ""


def classify_dockerfile_lines(
    lines: list[str],
) -> dict[str, list[str]]:
    """Classify raw Dockerfile instruction strings.

    Returns:
        Dict with keys: from_lines, argtop_lines,
        arg_lines, copy_lines, other_lines.
    """
    from_lines: list[str] = []
    arg_lines: list[str] = []
    copy_lines: list[str] = []
    other_lines: list[str] = []

    # First pass: classify by effective instruction
    for line in lines:
        effective = _effective_instruction(line)
        if effective.startswith("FROM "):
            from_lines.append(line)
        elif effective.startswith("ARG "):
            arg_lines.append(line)
        elif effective.startswith("COPY "):
            copy_lines.append(line)
        elif effective:
            other_lines.append(line)

    # Second pass: identify ARGs referenced by FROM
    # lines and promote them to argtop
    from_text = "\n".join(from_lines)
    referenced_vars = set(
        re.findall(r"\$\{(\w+)\}", from_text),
    )

    argtop_lines: list[str] = []
    remaining_args: list[str] = []
    for line in arg_lines:
        effective = _effective_instruction(line)
        match = re.match(
            r"ARG\s+(\w+)", effective,
        )
        if match and match.group(1) in referenced_vars:
            argtop_lines.append(line)
        else:
            remaining_args.append(line)

    # Deduplicate ARGs by variable name, keeping first
    def _dedup_args(
        lines: list[str],
    ) -> list[str]:
        seen: set[str] = set()
        result: list[str] = []
        for line in lines:
            eff = _effective_instruction(line)
            m = re.match(r"ARG\s+(\w+)", eff)
            var = m.group(1) if m else ""
            if var and var in seen:
                continue
            if var:
                seen.add(var)
            result.append(line)
        return result

    return {
        "from_lines": from_lines,
        "argtop_lines": _dedup_args(argtop_lines),
        "arg_lines": _dedup_args(remaining_args),
        "copy_lines": copy_lines,
        "other_lines": other_lines,
    }


def _dedup_from_stages(
    from_lines: list[str],
) -> list[str]:
    """Deduplicate FROM stages by alias name.

    If two entries produce the same 'AS alias', keep the
    first occurrence and discard duplicates. Multiline
    entries (full stage blocks) match on the first FROM
    line's alias.
    """
    seen_aliases: set[str] = set()
    result: list[str] = []
    for entry in from_lines:
        match = re.search(
            r"FROM\s+\S+\s+AS\s+(\S+)",
            entry, re.IGNORECASE,
        )
        if match:
            alias = match.group(1)
            if alias in seen_aliases:
                continue
            seen_aliases.add(alias)
        result.append(entry)
    return result


def _qualify_from_image(line: str) -> str:
    """Qualify short Docker Hub image names with docker.io/.

    Podman prompts for registry selection when a FROM image
    lacks a domain component.  Prefixing Docker Hub short
    names (e.g. ``alpine:3``, ``user/repo:tag``) with
    ``docker.io/`` makes the reference unambiguous.

    Images that already contain a registry domain (contain a
    ``.`` before the first ``/``) or use a ``${}`` variable
    as the entire image reference are left unchanged.
    """
    match = re.match(
        r"(FROM\s+)(\S+)(.*)", line, re.IGNORECASE,
    )
    if not match:
        return line
    prefix, image, rest = match.groups()
    # Strip tag/digest for domain check
    name = image.split(":")[0].split("@")[0]
    # Already fully qualified (contains a dot before /)
    if "/" in name and "." in name.split("/")[0]:
        return line
    # Pure variable reference — leave as-is
    if name.startswith("${"):
        return line
    return f"{prefix}docker.io/{image}{rest}"


def _qualify_from_lines(
    from_lines: list[str],
) -> list[str]:
    """Qualify all FROM lines in a list."""
    return [_qualify_from_image(line) for line in from_lines]


def _dedup_copy_lines(
    copy_lines: list[str],
) -> list[str]:
    """Deduplicate COPY instructions by source+destination.

    Uses the --from alias plus destination as the dedup key.
    Two COPY lines from different stages to the same
    directory are both kept; only exact duplicates
    (same stage, same dest) are removed.
    """
    seen: set[str] = set()
    result: list[str] = []
    for line in copy_lines:
        effective = _effective_instruction(line)
        from_match = re.search(
            r"--from=(\S+)", effective,
        )
        parts = effective.split()
        alias = from_match.group(1) if from_match else ""
        dest = parts[-1] if len(parts) >= _MIN_COPY_PARTS else ""
        key = f"{alias}:{dest}"
        if key in seen:
            continue
        seen.add(key)
        result.append(line)
    return result


def replace_section(
    template: str,
    tag: str,
    content: str,
) -> str:
    """Replace content between #TAG__START and #TAG__END.

    Args:
        template: Dockerfile template string.
        tag: Section tag name (e.g., "APK").
        content: Replacement content.

    Returns:
        Template with section replaced.
    """
    pattern = re.compile(
        rf"(#{tag}__START\n).*?(#{tag}__END)",
        re.DOTALL,
    )
    return pattern.sub(
        rf"\g<1>{content}\g<2>",
        template,
    )


def _linter_venv_name(linter_name: str) -> str:
    """Derive venv name from linter name.

    Takes the part after the first underscore,
    lowercases it, and replaces underscores with hyphens.
    E.g., PYTHON_RUFF -> ruff,
    CLOUDFORMATION_CFN_LINT -> cfn-lint.
    """
    parts = linter_name.split("_", 1)
    if len(parts) > 1:
        return parts[1].lower().replace("_", "-")
    return linter_name.lower()


def build_apk_section(
    packages: list[str],
) -> str:
    """Generate APK install section.

    Args:
        packages: Sorted, deduplicated list of Alpine
            packages.

    Returns:
        Dockerfile RUN instruction or empty string.
    """
    if not packages:
        return "# No additional APK packages\n"
    lines = [
        "RUN apk -U --no-cache upgrade \\",
        "    && apk add --no-cache \\",
    ]
    lines.extend(
        f"                {pkg} \\" for pkg in packages
    )
    lines.append(
        "    && git config --global"
        " core.autocrlf true",
    )
    return "\n".join(lines) + "\n"


def build_pipvenv_section(
    pip_installs: dict[str, list[str]],
) -> str:
    """Generate per-linter venv section using uv.

    Args:
        pip_installs: Dict mapping linter_name to list of
            pip packages.

    Returns:
        Dockerfile instructions for venvs.
    """
    if not pip_installs:
        return "# No pip packages\n"

    parts: list[str] = []
    env_paths: list[str] = []

    for linter_name, packages in pip_installs.items():
        venv_name = _linter_venv_name(linter_name)
        venv_path = f"/venvs/{venv_name}"
        pkg_str = " ".join(packages)

        parts.append(
            f'RUN uv venv --seed --no-project'
            f' --no-managed-python --no-cache'
            f' "{venv_path}" \\\n'
            f'    && VIRTUAL_ENV="{venv_path}"'
            f" uv pip install --no-cache"
            f" {pkg_str} \\\n"
            f'    && VIRTUAL_ENV="{venv_path}"'
            f" uv pip install --no-cache --upgrade"
            f' "wheel>=0.46.2" "setuptools>=75.8.0"'
            f" \\\n"
            f"    && find {venv_path}"
            f" \\( -type f \\( -iname \\*.pyc"
            f" -o -iname \\*.pyo \\)"
            f" -o -type d -iname __pycache__ \\)"
            f" -delete",
        )
        env_paths.append(f"{venv_path}/bin")

    result = "\n".join(parts) + "\n"
    if env_paths:
        path_str = ":".join(env_paths)
        result += (
            f'ENV PATH="${{PATH}}":{path_str}\n'
        )
    return result


def build_npm_section(
    packages: list[str],
) -> str:
    """Generate NPM install section.

    Args:
        packages: List of npm packages.

    Returns:
        Dockerfile instructions for npm install.
    """
    if not packages:
        return ""

    pkg_lines = []
    for i, pkg in enumerate(packages):
        suffix = "" if i == len(packages) - 1 else " \\"
        pkg_lines.append(
            f"                {pkg}{suffix}",
        )

    joined_pkgs = "\n".join(pkg_lines)
    return (
        "WORKDIR /node-deps\n"
        "RUN npm --no-cache install"
        " --ignore-scripts --omit=dev \\\n"
        f"{joined_pkgs} && \\\n"
        '    echo "Cleaning npm cache..." \\\n'
        "    && (npm cache clean --force || true)"
        " \\\n"
        '    && echo "Changing owner of'
        ' node_modules files..." \\\n'
        '    && chown -R "$(id -u)":"$(id -g)"'
        " node_modules\n"
        "WORKDIR /\n"
    )


def build_gem_section(
    packages: list[str],
) -> str:
    """Generate gem install section.

    Args:
        packages: List of gem packages.

    Returns:
        Dockerfile instructions for gem install.
    """
    if not packages:
        return ""
    pkg_str = " \\\n          ".join(packages)
    return (
        "RUN echo 'gem: --no-document'"
        " >> ~/.gemrc && \\\n"
        f"    gem install \\\n"
        f"          {pkg_str}\n"
    )


def build_cargo_section(
    packages: list[str],
) -> str:
    """Generate cargo install section.

    Args:
        packages: List of cargo crate names.

    Returns:
        Dockerfile instructions for cargo install.
    """
    if not packages:
        return ""
    pkg_str = " ".join(packages)
    return (
        "RUN cargo install"
        f" {pkg_str}\n"
    )


def build_flavor_section(
    _flavor_name: str,
) -> str:
    """Generate flavor ENV section.

    Custom flavors must use ``MEGALINTER_FLAVOR=all`` because
    MegaLinter's ``flavor_factory.check_active_linters_match_flavor``
    only accepts ``all``, ``none``, or one of the 18 official flavor
    names registered in ``all_flavors.json``.  Setting ``all`` causes
    the check to short-circuit, which is correct for a custom image
    that already contains exactly the desired linters.

    Args:
        _flavor_name: Name of the custom flavor (unused in the ENV
            instruction but kept in the signature for symmetry with
            :func:`write_flavor_config`).

    Returns:
        Dockerfile ENV instruction.
    """
    return "ENV MEGALINTER_FLAVOR=all\n"


def generate_dockerfile(
    template_path: Path,
    installs: dict[str, Any],
    flavor_name: str,
) -> str:
    """Generate a complete Dockerfile from template.

    Reads the upstream template, classifies collected
    Dockerfile lines, and replaces each section.

    Args:
        template_path: Path to the upstream Dockerfile
            template.
        installs: Output from collect_installs().
        flavor_name: Name for the custom flavor.

    Returns:
        Generated Dockerfile as a string.
    """
    template_path = Path(template_path)
    template = template_path.read_text(
        encoding="utf-8",
    )

    # Classify raw Dockerfile lines from descriptors
    classified = classify_dockerfile_lines(
        installs["dockerfile"],
    )

    # Build each section
    argtop_content = "\n".join(
        classified["argtop_lines"],
    )
    if argtop_content:
        argtop_content += "\n"

    deduped_from = _dedup_from_stages(
        classified["from_lines"],
    )
    from_content = "\n".join(deduped_from)
    if from_content:
        from_content += "\n"

    arg_content = "\n".join(
        classified["arg_lines"],
    )
    if arg_content:
        arg_content += "\n"

    deduped_copy = _dedup_copy_lines(
        classified["copy_lines"],
    )
    copy_content = "\n".join(deduped_copy)
    if copy_content:
        copy_content += "\n"

    other_content = "\n".join(
        classified["other_lines"],
    )
    if other_content:
        other_content += "\n"

    # Replace each section in the template
    result = template
    result = replace_section(
        result, "ARGTOP", argtop_content,
    )
    result = replace_section(
        result, "FROM", from_content,
    )
    result = replace_section(
        result, "ARG", arg_content,
    )
    result = replace_section(
        result, "APK", build_apk_section(
            installs["apk"],
        ),
    )
    result = replace_section(
        result, "CARGO", build_cargo_section(
            installs["cargo"],
        ),
    )
    result = replace_section(
        result, "COPY", copy_content,
    )
    result = replace_section(
        result, "GEM", build_gem_section(
            installs["gem"],
        ),
    )
    result = replace_section(
        result, "PIPVENV", build_pipvenv_section(
            installs["pip"],
        ),
    )
    result = replace_section(
        result, "NPM", build_npm_section(
            installs["npm"],
        ),
    )
    result = replace_section(
        result, "OTHER", other_content,
    )
    result = replace_section(
        result, "FLAVOR", build_flavor_section(
            flavor_name,
        ),
    )

    # Add COPY for flavor config file before ENTRYPOINT
    flavor_copy = (
        "COPY mega-linter-flavor.yml"
        " /megalinter-flavor.yml\n"
    )
    result = result.replace(
        "#EXTRA_DOCKERFILE_LINES__START\n",
        f"{flavor_copy}"
        "#EXTRA_DOCKERFILE_LINES__START\n",
    )

    # Qualify all FROM image references with docker.io/
    # so Podman does not prompt for registry selection
    return "\n".join(
        _qualify_from_image(line)
        if line.lstrip().upper().startswith("FROM ")
        else line
        for line in result.split("\n")
    )


def write_flavor_config(
    output_dir: Path,
    flavor_name: str,
    linters: list[str],
) -> Path:
    """Write mega-linter-flavor.yml with flavor metadata.

    Args:
        output_dir: Directory to write the config file.
        flavor_name: Name of the custom flavor.
        linters: List of enabled linter names.

    Returns:
        Path to the written config file.
    """
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    config = {
        "flavor": flavor_name,
        "linters": sorted(linters),
    }
    config_path = output_dir / "mega-linter-flavor.yml"
    with config_path.open("w", encoding="utf-8") as f:
        yaml.dump(
            config,
            f,
            default_flow_style=False,
            sort_keys=False,
        )
    return config_path


def _load_parse_config():
    """Load parse_megalinter_config module dynamically."""
    module_path = (
        Path(__file__).parent / "parse_megalinter_config.py"
    )
    mod_spec = importlib.util.spec_from_file_location(
        "parse_megalinter_config", module_path,
    )
    module = importlib.util.module_from_spec(mod_spec)
    mod_spec.loader.exec_module(module)
    return module.parse_config


def build_flavor(
    config_path: str,
    megalinter_src: str,
    output_dir: str,
    flavor_name: str = "custom",
) -> dict[str, Any]:
    """Orchestrate slim flavor generation.

    Parses the MegaLinter config, loads descriptors,
    collects install instructions, generates a
    Dockerfile, and writes the flavor config.

    Args:
        config_path: Path to .mega-linter.yml.
        megalinter_src: Path to cloned MegaLinter source.
        output_dir: Directory for generated output.
        flavor_name: Name for the custom flavor.

    Returns:
        Metadata dict with flavor_name, linters, and
        output_dir.
    """
    parse_config = _load_parse_config()
    config = parse_config(config_path)
    enabled_linters = config["linters"]

    src_path = Path(megalinter_src)
    descriptors_dir = (
        src_path / "megalinter" / "descriptors"
    )
    template_path = src_path / "Dockerfile"

    descriptors = load_descriptors(descriptors_dir)
    installs = collect_installs(
        descriptors, enabled_linters,
    )
    dockerfile_content = generate_dockerfile(
        template_path, installs, flavor_name,
    )

    out_path = Path(output_dir)
    out_path.mkdir(parents=True, exist_ok=True)
    dockerfile_path = out_path / "Dockerfile"
    dockerfile_path.write_text(
        dockerfile_content, encoding="utf-8",
    )

    write_flavor_config(
        out_path, flavor_name, enabled_linters,
    )

    logger.info(
        "Generated flavor '%s' with %d linters in %s",
        flavor_name,
        len(enabled_linters),
        out_path,
    )

    return {
        "flavor_name": flavor_name,
        "linters": enabled_linters,
        "output_dir": str(out_path),
    }


def main():
    """CLI entry point."""
    parser = argparse.ArgumentParser(
        description=(
            "Generate a slim MegaLinter custom flavor"
            " Dockerfile"
        ),
    )
    parser.add_argument(
        "config_path",
        help="Path to .mega-linter.yml",
    )
    parser.add_argument(
        "megalinter_src",
        help="Path to cloned MegaLinter source",
    )
    parser.add_argument(
        "output_dir",
        help="Output directory for generated files",
    )
    parser.add_argument(
        "--flavor-name",
        default="custom",
        help="Name for the custom flavor"
        " (default: custom)",
    )
    parser.add_argument(
        "--version",
        default="0.0.0",
        help="MegaLinter version for labeling"
        " (default: 0.0.0)",
    )

    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(levelname)s: %(message)s",
    )

    try:
        result = build_flavor(
            config_path=args.config_path,
            megalinter_src=args.megalinter_src,
            output_dir=args.output_dir,
            flavor_name=args.flavor_name,
        )
        logger.info(
            "Flavor '%s' generated with %d linters",
            result["flavor_name"],
            len(result["linters"]),
        )
    except Exception:
        logger.exception("Failed to generate flavor")
        sys.exit(1)


if __name__ == "__main__":
    main()
