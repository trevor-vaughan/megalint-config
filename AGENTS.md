# AGENTS.md

Guidance for AI coding agents working in this repository. Read this first.

## What this repo is

A shared [MegaLinter](https://megalinter.io/) configuration plus a
*linter runner* that points at any target directory. Configs live here;
target repos don't vendor anything. The artifacts that matter:

- `.mega-linter.yml` — the canonical linter profile. Changes here affect
  every target the runner is pointed at.
- `.mega-linter.d/` — drop-in directory for shared sub-configs
  (`.devskim.json`, `.jscpd.json`, `kics.config`, …). Anything here is
  auto-mounted at the target's workspace root.
- `Taskfile.yml` + `.taskfiles/megalint.yml` — Taskfile entrypoint.
- `.taskfiles/scripts/megalint-run.sh` — the runner. Two staging modes:
  - **Default (in-target):** copies shared configs directly into the
    target's workspace root, mounts the target (RO + nested RW reports,
    or fully RW for `APPLY_FIXES`), removes staged copies on exit. Fast,
    but staged files are briefly visible in the target and concurrent
    runs against the same target conflict.
  - **`MEGALINT_TMPDIR=<any non-empty>`:** hardlink-clones the target
    (excluding `.git/`) into a private `.megalint_<rand>_<target-basename>/`
    adjacent to the target (mode 0700), bind-mounts `<target>/.git` in
    read-only, persists reports back to the target on exit, and removes
    the staging dir. Target tree never modified; concurrent runs are
    safe. Requires `rsync`.
- `.taskfiles/scripts/megalinter-sarif-chunk.sh`,
  `.taskfiles/scripts/sarif-to-markdown.jq` — SARIF chunking pipeline.
- `.taskfiles/scripts/templates/` — agent-facing templates.
- `.github/workflows/megalinter.yml` — CI workflow.

See `README.md` for end-user documentation.

## Working principles

- **Verify before editing.** Read the file you're changing in full. Match
  surrounding style (section headers, comment density, quoting).
- **The `.mega-linter.yml` is a contract.** Anything you add or remove
  affects every target the runner is pointed at. When in doubt, ask
  before changing enabled linters, exclusion regexes, or shared arguments.
- **Adding a shared sub-config?** Drop the file into `.mega-linter.d/`.
  The runner auto-discovers everything there and overlays each file at
  the target's workspace root. No code or Taskfile changes required.
- **Don't enable a linter without checking its false-positive cost.** The
  `DISABLE_LINTERS:` block in `.mega-linter.yml` records why each disabled
  linter was disabled (e.g., 94 false positives, redundant with another
  tool). Re-enabling without addressing the cited reason is regression.
- **Don't introduce auto-fix in CI without explicit ask.** Local users opt
  into `APPLY_FIXES=all`; the CI workflow runs lint-only by design.

## Local workflow

```bash
task                                            # List available tasks
task megalint:run                               # Lint this repo
task megalint:changed                           # Lint only files changed vs. default branch
task megalint:run TARGET=/path/to/other/repo    # Lint a different repo
task megalint:run APPLY_FIXES=all               # Lint + apply auto-fixes
task megalint:sarif-chunk TARGET=...            # Split findings per linter
```

Container engine is auto-detected (Podman preferred, Docker fallback).
The single bind mount uses `:z` for SELinux relabel. Reports land at
`<target>/megalinter-reports/` — gitignored in this repo.

Target repos can override the shared config with a `.mega-linter.local.yml`
at their repo root that does `EXTENDS: .mega-linter.shared.yml`. See
README for the full override model.

## Fixing lint findings at scale

When the linter reports many findings:

1. Run `task megalint:sarif-chunk`. This splits the SARIF into one markdown
   file per linter under `megalinter-reports/megalinter-report-chunked/`.
2. The chunked output includes an `AGENTS.md` briefing tailored for
   sub-agent dispatch — see `.taskfiles/scripts/templates/megalinter-agents.md`
   for the template used to generate it.
3. Spawn one sub-agent per linter file. Mechanical fixes (formatting,
   whitespace) suit smaller/faster models; security or architectural
   findings warrant a larger model.
4. Re-run `task megalint:run` after fixes; iterate until clean.

## Editing the configuration

- `.mega-linter.yml` is organised into clearly delimited sections
  (`# ===== ... =====`). New settings go in the matching section; create a
  new section only when no existing one fits.
- Linter-specific arguments use the `<LINTER>_ARGUMENTS` or
  `<LINTER>_<KEY>` form documented at <https://megalinter.io/>.
- File exclusion regex uses `<DESCRIPTOR>_FILTER_REGEX_EXCLUDE` (e.g.,
  `MARKDOWN_FILTER_REGEX_EXCLUDE`). Anchor patterns with `(^|/)` to avoid
  partial-name false-positives.

## Verification before claiming done

Before reporting work complete:

1. `task megalint:run` — full lint pass against the working tree.
2. For workflow changes, run `actionlint` against `.github/workflows/*.yml`.
3. For changes to the `.mega-linter.yml` contract, state the downstream
   impact explicitly so a reviewer can weigh it.

## Files this linter ignores

`AGENTS.md` and `CLAUDE.md` are excluded from markdown linting via
`MARKDOWN_FILTER_REGEX_EXCLUDE` in `.mega-linter.yml`. They follow
agent-host conventions, not the markdown style enforced on human-facing
docs. If you need to extend that exclusion, update the regex — don't add
inline disable comments to the files themselves.
