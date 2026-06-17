# tests/test_build_flavor_dockerfile.py
import importlib.util
from pathlib import Path

import yaml

# Import the script under test using the same
# importlib pattern as test_parse_megalinter_config.py
script_path = (
    Path(__file__).parent.parent
    / "scripts"
    / "build_flavor_dockerfile.py"
)
spec = importlib.util.spec_from_file_location(
    "build_flavor_dockerfile", script_path,
)
build_flavor_dockerfile = (
    importlib.util.module_from_spec(spec)
)
spec.loader.exec_module(build_flavor_dockerfile)

derive_linter_name = (
    build_flavor_dockerfile.derive_linter_name
)
load_descriptors = (
    build_flavor_dockerfile.load_descriptors
)
collect_installs = (
    build_flavor_dockerfile.collect_installs
)
classify_dockerfile_lines = (
    build_flavor_dockerfile.classify_dockerfile_lines
)
replace_section = (
    build_flavor_dockerfile.replace_section
)
build_apk_section = (
    build_flavor_dockerfile.build_apk_section
)
build_pipvenv_section = (
    build_flavor_dockerfile.build_pipvenv_section
)
build_npm_section = (
    build_flavor_dockerfile.build_npm_section
)
build_gem_section = (
    build_flavor_dockerfile.build_gem_section
)
build_cargo_section = (
    build_flavor_dockerfile.build_cargo_section
)
build_flavor_section = (
    build_flavor_dockerfile.build_flavor_section
)
generate_dockerfile = (
    build_flavor_dockerfile.generate_dockerfile
)
write_flavor_config = (
    build_flavor_dockerfile.write_flavor_config
)
build_flavor = (
    build_flavor_dockerfile.build_flavor
)
_inject_sarif_fmt = (
    build_flavor_dockerfile._inject_sarif_fmt  # noqa: SLF001 — test exercises private helper
)
SARIF_FMT_VERSION = (
    build_flavor_dockerfile.SARIF_FMT_VERSION
)


# ── Fixtures ──────────────────────────────────────


BASH_DESCRIPTOR = {
    "descriptor_id": "BASH",
    "install": {
        "apk": ["bash"],
    },
    "linters": [
        {
            "name": "BASH_SHELLCHECK",
            "install": {
                "dockerfile": [
                    (
                        "# renovate: datasource=docker"
                        " depName=koalaman/shellcheck\n"
                        "ARG BASH_SHELLCHECK_VERSION"
                        "=v0.11.0"
                    ),
                    (
                        "FROM koalaman/shellcheck:"
                        "${BASH_SHELLCHECK_VERSION}"
                        " AS shellcheck"
                    ),
                    (
                        "COPY --link --from=shellcheck"
                        " /bin/shellcheck"
                        " /usr/bin/shellcheck"
                    ),
                ],
            },
        },
        {
            "name": "BASH_SHFMT",
            "install": {
                "dockerfile": [
                    (
                        "# renovate: datasource=docker"
                        " depName=mvdan/shfmt\n"
                        "ARG BASH_SHFMT_VERSION"
                        "=v3.13.1-alpine"
                    ),
                    (
                        "FROM mvdan/shfmt:"
                        "${BASH_SHFMT_VERSION} AS shfmt"
                    ),
                    (
                        "COPY --link --from=shfmt"
                        " /bin/shfmt /usr/bin/"
                    ),
                ],
            },
        },
    ],
}

PYTHON_DESCRIPTOR = {
    "descriptor_id": "PYTHON",
    "linters": [
        {
            "name": "PYTHON_RUFF",
            "install": {
                "dockerfile": [
                    (
                        "# renovate: datasource=pypi"
                        " depName=ruff\n"
                        "ARG PIP_RUFF_VERSION=0.15.13"
                    ),
                ],
                "pip": ["ruff==${PIP_RUFF_VERSION}"],
            },
        },
        {
            "name": "PYTHON_PYLINT",
            "install": {
                "dockerfile": [
                    (
                        "# renovate: datasource=pypi"
                        " depName=pylint\n"
                        "ARG PIP_PYLINT_VERSION=4.0.5"
                    ),
                ],
                "pip": [
                    "pylint==${PIP_PYLINT_VERSION}",
                ],
            },
        },
    ],
}

COPYPASTE_DESCRIPTOR = {
    "descriptor_id": "COPYPASTE",
    "linters": [
        {
            "name": "COPYPASTE_JSCPD",
            "install": {
                "dockerfile": [
                    (
                        "# renovate: datasource=npm"
                        " depName=jscpd\n"
                        "ARG NPM_JSCPD_VERSION=4.0.5"
                    ),
                ],
                "npm": [
                    "jscpd@${NPM_JSCPD_VERSION}",
                ],
            },
        },
    ],
}

DUPLICATE_APK_DESCRIPTOR = {
    "descriptor_id": "SHELL_EXTRA",
    "install": {
        "apk": ["bash", "curl"],
    },
    "linters": [
        {
            "name": "SHELL_EXTRA_TOOL",
            "install": {
                "apk": ["curl", "git"],
            },
        },
    ],
}


# ── TestLoadDescriptors ───────────────────────────


class TestLoadDescriptors:
    def test_loads_single_descriptor(self, tmp_path):
        desc_dir = tmp_path / "descriptors"
        desc_dir.mkdir()
        desc_file = (
            desc_dir
            / "bash.megalinter-descriptor.yml"
        )
        desc_file.write_text(
            yaml.dump(BASH_DESCRIPTOR),
            encoding="utf-8",
        )

        result = load_descriptors(desc_dir)

        assert len(result) == 1
        assert result[0]["descriptor_id"] == "BASH"

    def test_loads_multiple_descriptors(self, tmp_path):
        desc_dir = tmp_path / "descriptors"
        desc_dir.mkdir()
        for name, data in [
            ("bash", BASH_DESCRIPTOR),
            ("python", PYTHON_DESCRIPTOR),
        ]:
            f = (
                desc_dir
                / f"{name}.megalinter-descriptor.yml"
            )
            f.write_text(
                yaml.dump(data), encoding="utf-8",
            )

        result = load_descriptors(desc_dir)

        assert len(result) == 2  # noqa: PLR2004
        ids = {d["descriptor_id"] for d in result}
        assert ids == {"BASH", "PYTHON"}

    def test_ignores_non_descriptor_files(
        self, tmp_path,
    ):
        desc_dir = tmp_path / "descriptors"
        desc_dir.mkdir()
        desc_file = (
            desc_dir
            / "bash.megalinter-descriptor.yml"
        )
        desc_file.write_text(
            yaml.dump(BASH_DESCRIPTOR),
            encoding="utf-8",
        )
        # Non-descriptor file should be ignored
        other = desc_dir / "README.md"
        other.write_text("# hello", encoding="utf-8")
        subdir = desc_dir / "additional"
        subdir.mkdir()

        result = load_descriptors(desc_dir)

        assert len(result) == 1


# ── TestCollectInstalls ───────────────────────────


class TestCollectInstalls:
    def test_collects_apk_from_descriptor_level(self):
        result = collect_installs(
            [BASH_DESCRIPTOR], ["BASH_SHELLCHECK"],
        )
        assert "bash" in result["apk"]

    def test_collects_dockerfile_from_linter(self):
        result = collect_installs(
            [BASH_DESCRIPTOR], ["BASH_SHELLCHECK"],
        )
        assert len(result["dockerfile"]) > 0
        has_from = any(
            "FROM" in line
            for line in result["dockerfile"]
        )
        assert has_from

    def test_excludes_unselected_linters(self):
        result = collect_installs(
            [BASH_DESCRIPTOR], ["BASH_SHELLCHECK"],
        )
        shfmt_lines = [
            line
            for line in result["dockerfile"]
            if "shfmt" in line.lower()
        ]
        assert len(shfmt_lines) == 0

    def test_includes_multiple_selected(self):
        result = collect_installs(
            [BASH_DESCRIPTOR],
            ["BASH_SHELLCHECK", "BASH_SHFMT"],
        )
        has_shellcheck = any(
            "shellcheck" in line.lower()
            for line in result["dockerfile"]
        )
        has_shfmt = any(
            "shfmt" in line.lower()
            for line in result["dockerfile"]
        )
        assert has_shellcheck
        assert has_shfmt

    def test_collects_pip(self):
        result = collect_installs(
            [PYTHON_DESCRIPTOR], ["PYTHON_RUFF"],
        )
        assert "PYTHON_RUFF" in result["pip"]
        assert (
            "ruff==${PIP_RUFF_VERSION}"
            in result["pip"]["PYTHON_RUFF"]
        )

    def test_collects_npm(self):
        result = collect_installs(
            [COPYPASTE_DESCRIPTOR],
            ["COPYPASTE_JSCPD"],
        )
        assert (
            "jscpd@${NPM_JSCPD_VERSION}"
            in result["npm"]
        )

    def test_descriptor_level_install_only_when_linter_selected(
        self,
    ):
        desc = {
            "descriptor_id": "CUSTOM",
            "install": {"apk": ["custom-pkg"]},
            "linters": [
                {"name": "CUSTOM_TOOL", "install": {}},
            ],
        }
        result = collect_installs(
            [desc], ["PYTHON_RUFF"],
        )
        assert "custom-pkg" not in result["apk"]

    def test_deduplicates_apk(self):
        result = collect_installs(
            [DUPLICATE_APK_DESCRIPTOR],
            ["SHELL_EXTRA_TOOL"],
        )
        assert result["apk"].count("curl") == 1
        assert result["apk"].count("bash") == 1
        # Should be sorted
        assert result["apk"] == sorted(result["apk"])


# ── TestDeriveLinterName ─────────────────────────


class TestDeriveLinterName:
    def test_explicit_name_used(self):
        linter = {"name": "MY_LINTER", "linter_name": "x"}
        assert derive_linter_name("DESC", linter) == "MY_LINTER"

    def test_derived_from_descriptor_and_linter_name(self):
        linter = {"linter_name": "shellcheck"}
        assert (
            derive_linter_name("BASH", linter)
            == "BASH_SHELLCHECK"
        )

    def test_hyphens_become_underscores(self):
        linter = {"linter_name": "cfn-lint"}
        assert (
            derive_linter_name("CLOUDFORMATION", linter)
            == "CLOUDFORMATION_CFN_LINT"
        )

    def test_lowercase_linter_name_uppercased(self):
        linter = {"linter_name": "ruff"}
        assert (
            derive_linter_name("python", linter)
            == "PYTHON_RUFF"
        )

    def test_empty_name_field_derives(self):
        linter = {"name": "", "linter_name": "hadolint"}
        assert (
            derive_linter_name("DOCKERFILE", linter)
            == "DOCKERFILE_HADOLINT"
        )


# ── TestBaseApkPackages ──────────────────────────


class TestBaseApkPackages:
    def test_base_packages_always_included(self):
        result = collect_installs(
            [{"descriptor_id": "X", "linters": [
                {"name": "X_TOOL", "install": {}},
            ]}],
            ["X_TOOL"],
        )
        for pkg in ["bash", "git", "curl", "gcc"]:
            assert pkg in result["apk"]

    def test_npm_runtime_packages_when_npm_present(self):
        result = collect_installs(
            [COPYPASTE_DESCRIPTOR],
            ["COPYPASTE_JSCPD"],
        )
        assert "npm" in result["apk"]
        assert "nodejs-current" in result["apk"]
        assert "yarn" in result["apk"]

    def test_no_npm_runtime_packages_without_npm(self):
        result = collect_installs(
            [PYTHON_DESCRIPTOR],
            ["PYTHON_RUFF"],
        )
        assert "npm" not in result["apk"]
        assert "nodejs-current" not in result["apk"]


# ── TestClassifyDockerfileLines ───────────────────


class TestClassifyDockerfileLines:
    def test_classifies_from_lines(self):
        lines = [
            "FROM alpine:3.23 AS builder",
        ]
        result = classify_dockerfile_lines(lines)
        assert lines[0] in result["from_lines"]

    def test_classifies_arg_lines(self):
        lines = ["ARG MY_VERSION=1.0"]
        result = classify_dockerfile_lines(lines)
        assert lines[0] in result["arg_lines"]

    def test_classifies_copy_lines(self):
        lines = [
            "COPY --link --from=builder"
            " /out/bin /usr/bin/",
        ]
        result = classify_dockerfile_lines(lines)
        assert lines[0] in result["copy_lines"]

    def test_classifies_other_lines(self):
        lines = [
            "RUN apk add --no-cache bash",
            "ENV PATH=/usr/bin:$PATH",
        ]
        result = classify_dockerfile_lines(lines)
        assert len(result["other_lines"]) == 2  # noqa: PLR2004

    def test_multiline_arg_with_comment(self):
        line = (
            "# renovate: datasource=docker"
            " depName=foo\n"
            "ARG FOO_VERSION=1.0"
        )
        result = classify_dockerfile_lines([line])
        assert line in result["arg_lines"]

    def test_argtop_for_from_referenced_args(self):
        lines = [
            (
                "# renovate: datasource=docker"
                " depName=foo\n"
                "ARG FOO_VERSION=1.0"
            ),
            "FROM foo:${FOO_VERSION} AS foo-stage",
            "COPY --link --from=foo-stage /bin/foo"
            " /usr/bin/foo",
            "ARG OTHER_VERSION=2.0",
        ]
        result = classify_dockerfile_lines(lines)
        assert lines[0] in result["argtop_lines"]
        assert lines[0] not in result["arg_lines"]
        assert lines[1] in result["from_lines"]
        assert lines[2] in result["copy_lines"]
        assert lines[3] in result["arg_lines"]


# ── TestReplaceSection ────────────────────────────


class TestReplaceSection:
    def test_replaces_content(self):
        template = (
            "before\n"
            "#APK__START\n"
            "old content\n"
            "#APK__END\n"
            "after\n"
        )
        result = replace_section(
            template, "APK", "new content\n",
        )
        assert "new content" in result
        assert "old content" not in result
        assert "before" in result
        assert "after" in result

    def test_preserves_other_sections(self):
        template = (
            "#APK__START\n"
            "apk stuff\n"
            "#APK__END\n"
            "#NPM__START\n"
            "npm stuff\n"
            "#NPM__END\n"
        )
        result = replace_section(
            template, "APK", "new apk\n",
        )
        assert "npm stuff" in result
        assert "new apk" in result

    def test_empty_replacement(self):
        template = (
            "#APK__START\n"
            "old content\n"
            "#APK__END\n"
        )
        result = replace_section(
            template, "APK", "",
        )
        assert "#APK__START" in result
        assert "#APK__END" in result
        assert "old content" not in result


# ── TestBuildApkSection ───────────────────────────


class TestBuildApkSection:
    def test_generates_command(self):
        result = build_apk_section(
            ["bash", "curl", "git"],
        )
        assert "apk add --no-cache" in result
        assert "bash" in result
        assert "curl" in result
        assert "git" in result

    def test_empty_list(self):
        result = build_apk_section([])
        assert "apk" not in result


# ── TestBuildPipvenvSection ───────────────────────


class TestBuildPipvenvSection:
    def test_generates_venv_commands(self):
        pip_installs = {
            "PYTHON_RUFF": [
                "ruff==${PIP_RUFF_VERSION}",
            ],
        }
        result = build_pipvenv_section(pip_installs)
        assert "/venvs/ruff" in result
        assert "uv venv" in result
        assert "uv pip install" in result
        assert "ruff==${PIP_RUFF_VERSION}" in result
        assert "ENV PATH=" in result

    def test_multiple_venvs(self):
        pip_installs = {
            "PYTHON_RUFF": [
                "ruff==${PIP_RUFF_VERSION}",
            ],
            "PYTHON_ISORT": [
                "isort==${PIP_ISORT_VERSION}",
            ],
        }
        result = build_pipvenv_section(pip_installs)
        assert "/venvs/ruff" in result
        assert "/venvs/isort" in result

    def test_linter_name_with_underscores(self):
        pip_installs = {
            "CLOUDFORMATION_CFN_LINT": [
                "cfn-lint==${PIP_CFN_LINT_VERSION}",
            ],
        }
        result = build_pipvenv_section(pip_installs)
        assert "/venvs/cfn-lint" in result


# ── TestBuildNpmSection ───────────────────────────


class TestBuildNpmSection:
    def test_generates_npm_install(self):
        result = build_npm_section(
            ["jscpd@${NPM_JSCPD_VERSION}"],
        )
        assert "npm" in result
        assert "jscpd@${NPM_JSCPD_VERSION}" in result
        assert "npm cache clean" in result

    def test_empty_list(self):
        result = build_npm_section([])
        assert "npm" not in result


# ── TestBuildGemSection ───────────────────────────


class TestBuildGemSection:
    def test_generates_gem_install(self):
        result = build_gem_section(
            ["rubocop:${GEM_RUBOCOP_VERSION}"],
        )
        assert "gem install" in result
        assert (
            "rubocop:${GEM_RUBOCOP_VERSION}" in result
        )

    def test_empty_list(self):
        result = build_gem_section([])
        assert "gem" not in result


# ── TestBuildCargoSection ─────────────────────────


class TestBuildCargoSection:
    def test_generates_cargo_install(self):
        result = build_cargo_section(
            ["clippy"],
        )
        assert "cargo" in result or "rust" in result

    def test_empty_list(self):
        result = build_cargo_section([])
        assert result == ""


# ── TestBuildFlavorSection ────────────────────────


class TestBuildFlavorSection:
    def test_sets_flavor_env(self):
        # Custom flavors always use MEGALINTER_FLAVOR=all because
        # MegaLinter only accepts all/none/official-18 at runtime.
        result = build_flavor_section("my-custom")
        assert "MEGALINTER_FLAVOR=all" in result
        assert "ENV" in result


# ── TestGenerateDockerfile ────────────────────────


MINIMAL_TEMPLATE = """\
# syntax=docker/dockerfile:1
#ARGTOP__START
#ARGTOP__END
#FROM__START
#FROM__END
FROM oxsecurity/megalinter:v9
#ARG__START
#ARG__END
#APK__START
#APK__END
#CARGO__START
#CARGO__END
#COPY__START
#COPY__END
#GEM__START
#GEM__END
#PIPVENV__START
#PIPVENV__END
#NPM__START
#NPM__END
#OTHER__START
#OTHER__END
#FLAVOR__START
ENV MEGALINTER_FLAVOR=all
#FLAVOR__END
#EXTRA_DOCKERFILE_LINES__START
ENTRYPOINT ["/bin/bash"]
#EXTRA_DOCKERFILE_LINES__END
"""


class TestGenerateDockerfile:
    def test_full_generation(self, tmp_path):
        template_file = tmp_path / "Dockerfile"
        template_file.write_text(
            MINIMAL_TEMPLATE, encoding="utf-8",
        )

        installs = {
            "apk": ["bash"],
            "npm": [],
            "pip": {
                "PYTHON_RUFF": [
                    "ruff==${PIP_RUFF_VERSION}",
                ],
            },
            "gem": [],
            "cargo": [],
            "dockerfile": [
                (
                    "# renovate: datasource=pypi"
                    " depName=ruff\n"
                    "ARG PIP_RUFF_VERSION=0.15.13"
                ),
            ],
        }

        result = generate_dockerfile(
            template_file, installs, "my-flavor",
        )
        assert "bash" in result
        assert "MEGALINTER_FLAVOR=all" in result
        assert "PIP_RUFF_VERSION" in result
        assert "ENTRYPOINT" in result

    def test_preserves_extra_lines(self, tmp_path):
        template_file = tmp_path / "Dockerfile"
        template_file.write_text(
            MINIMAL_TEMPLATE, encoding="utf-8",
        )

        installs = {
            "apk": [],
            "npm": [],
            "pip": {},
            "gem": [],
            "cargo": [],
            "dockerfile": [],
        }

        result = generate_dockerfile(
            template_file, installs, "test",
        )
        assert "ENTRYPOINT" in result


# ── TestInjectSarifFmt ────────────────────────────


class TestInjectSarifFmt:
    def test_injects_builder_stage(self):
        dockerfile = (
            "#FROM__START\n"
            "#FROM__END\n"
            "#COPY__START\n"
            "#COPY__END\n"
        )
        result = _inject_sarif_fmt(dockerfile)
        assert "FROM docker.io/rust:1-alpine" in result
        assert "sarif-fmt-builder" in result
        assert "cargo install sarif-fmt" in result
        assert f"--version {SARIF_FMT_VERSION}" in result

    def test_injects_copy_instruction(self):
        dockerfile = (
            "#FROM__START\n"
            "#FROM__END\n"
            "#COPY__START\n"
            "#COPY__END\n"
        )
        result = _inject_sarif_fmt(dockerfile)
        assert (
            "COPY --link --from=sarif-fmt-builder"
            in result
        )
        assert "/usr/bin/sarif-fmt" in result

    def test_preserves_existing_content(self):
        dockerfile = (
            "#FROM__START\n"
            "FROM koalaman/shellcheck AS shellcheck\n"
            "#FROM__END\n"
            "#COPY__START\n"
            "COPY --from=shellcheck /bin/sc /usr/bin/sc\n"
            "#COPY__END\n"
        )
        result = _inject_sarif_fmt(dockerfile)
        assert "koalaman/shellcheck" in result
        assert "sarif-fmt-builder" in result
        assert "/bin/sc" in result
        assert "/usr/bin/sarif-fmt" in result

    def test_full_generation_includes_sarif_fmt(
        self, tmp_path,
    ):
        template_file = tmp_path / "Dockerfile"
        template_file.write_text(
            MINIMAL_TEMPLATE, encoding="utf-8",
        )
        installs = {
            "apk": [],
            "npm": [],
            "pip": {},
            "gem": [],
            "cargo": [],
            "dockerfile": [],
        }
        result = generate_dockerfile(
            template_file, installs, "test",
        )
        assert "sarif-fmt-builder" in result
        assert "COPY --link --from=sarif-fmt-builder" in (
            result
        )
        # Builder stage must come before main FROM
        from_idx = result.index(
            "FROM docker.io/rust:1-alpine",
        )
        main_idx = result.index(
            "FROM docker.io/oxsecurity/megalinter",
        )
        assert from_idx < main_idx


# ── TestWriteFlavorConfig ─────────────────────────


class TestWriteFlavorConfig:
    def test_writes_config(self, tmp_path):
        output_dir = tmp_path / "output"
        output_dir.mkdir()
        write_flavor_config(
            output_dir,
            "my-flavor",
            ["BASH_SHELLCHECK", "PYTHON_RUFF"],
        )
        config_path = (
            output_dir / "mega-linter-flavor.yml"
        )
        assert config_path.exists()
        with config_path.open(encoding="utf-8") as f:
            data = yaml.safe_load(f)
        assert data["flavor"] == "my-flavor"
        assert "BASH_SHELLCHECK" in data["linters"]
        assert "PYTHON_RUFF" in data["linters"]

    def test_linter_count(self, tmp_path):
        output_dir = tmp_path / "output"
        output_dir.mkdir()
        linters = [
            "BASH_SHELLCHECK",
            "BASH_SHFMT",
            "PYTHON_RUFF",
        ]
        write_flavor_config(
            output_dir, "test-flavor", linters,
        )
        config_path = (
            output_dir / "mega-linter-flavor.yml"
        )
        with config_path.open(encoding="utf-8") as f:
            data = yaml.safe_load(f)
        assert len(data["linters"]) == 3  # noqa: PLR2004


# ── TestCLIEntryPoint ────────────────────────────


class TestCLIEntryPoint:
    def test_build_flavor_produces_output(
        self, tmp_path,
    ):
        # Set up descriptor dir
        desc_dir = tmp_path / "megalinter" / "descriptors"
        desc_dir.mkdir(parents=True)
        desc_file = (
            desc_dir
            / "bash.megalinter-descriptor.yml"
        )
        desc_file.write_text(
            yaml.dump(BASH_DESCRIPTOR),
            encoding="utf-8",
        )

        # Set up template
        template_file = tmp_path / "Dockerfile"
        template_file.write_text(
            MINIMAL_TEMPLATE, encoding="utf-8",
        )

        # Set up config
        config_file = tmp_path / ".mega-linter.yml"
        config_file.write_text(
            yaml.dump({
                "ENABLE_LINTERS": ["BASH_SHELLCHECK"],
            }),
            encoding="utf-8",
        )

        # Output dir
        output_dir = tmp_path / "flavor-output"

        result = build_flavor(
            config_path=str(config_file),
            megalinter_src=str(tmp_path),
            output_dir=str(output_dir),
            flavor_name="test-flavor",
        )

        assert output_dir.exists()
        assert (output_dir / "Dockerfile").exists()
        assert (
            output_dir / "mega-linter-flavor.yml"
        ).exists()
        assert result["flavor_name"] == "test-flavor"
        assert "BASH_SHELLCHECK" in result["linters"]

        # Verify Dockerfile content
        dockerfile_content = (
            output_dir / "Dockerfile"
        ).read_text(encoding="utf-8")
        assert (
            "MEGALINTER_FLAVOR=all"
            in dockerfile_content
        )


# ── TestDockerfileHardening ──────────────────────


class TestDockerfileHardening:
    """Tests for security hardening applied by
    generate_dockerfile: HEALTHCHECK, USER suppression,
    wget-to-curl replacement."""

    def _generate(self, tmp_path, installs=None):
        """Helper: write template and generate."""
        template_file = tmp_path / "Dockerfile"
        template_file.write_text(
            MINIMAL_TEMPLATE, encoding="utf-8",
        )
        if installs is None:
            installs = {
                "apk": ["bash"],
                "npm": [],
                "pip": {},
                "gem": [],
                "cargo": [],
                "dockerfile": [],
            }
        return generate_dockerfile(
            template_file, installs, "test",
        )

    def test_healthcheck_present(self, tmp_path):
        result = self._generate(tmp_path)
        assert "HEALTHCHECK CMD" in result

    def test_healthcheck_before_entrypoint(
        self, tmp_path,
    ):
        result = self._generate(tmp_path)
        hc_pos = result.index("HEALTHCHECK CMD")
        ep_pos = result.index("ENTRYPOINT")
        assert hc_pos < ep_pos

    def test_user_suppression_checkov(self, tmp_path):
        result = self._generate(tmp_path)
        assert "checkov:skip=CKV_DOCKER_3" in result

    def test_user_suppression_trivy(self, tmp_path):
        result = self._generate(tmp_path)
        assert "trivy:ignore:DS-0002" in result

    def test_wget_replaced_with_curl(self, tmp_path):
        """Test wget is replaced with curl and URL is preserved."""
        installs = {
            "apk": ["bash"],
            "npm": [],
            "pip": {},
            "gem": [],
            "cargo": [],
            "dockerfile": [
                (
                    "RUN wget --tries=5 -q -O -"
                    " https://example.com/install.sh"
                    " | sh -s -- -b /usr/local/bin"
                ),
            ],
        }
        result = self._generate(tmp_path, installs=installs)

        # Combined assertions from both tests
        assert "wget" not in result
        assert "curl" in result
        assert "https://example.com/install.sh" in result
