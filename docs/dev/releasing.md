# Releasing

How the release machinery works and why it is built this way. For how to _cut_ a release, see the README.

## Components

| Path                                          | Role                              |
| --------------------------------------------- | --------------------------------- |
| `.taskfiles/release.yml`                      | `release:bump`, `release:current` |
| `.taskfiles/scripts/release-bump.sh`          | Every release invariant           |
| `.taskfiles/scripts/changelog-section.sh`     | One release's notes, for CI       |
| `cliff.toml`                                  | git-cliff configuration           |
| `.github/workflows/custom-flavor-release.yml` | Build, sign, publish              |

`release:bump` is a thin `interactive: true` shim over the script. The guards are not duplicated as Task `preconditions`, because two copies of a rule drift apart.

## Invariants

`release-bump.sh` enforces all of these before it writes anything:

- `uv` and git-cliff are reachable.
- `cliff.toml` and `pyproject.toml` exist.
- The working tree has no uncommitted or staged changes.
- The requested version is valid semver, and `uv` can represent it as a plain release or an alpha/beta/rc pre-release.
- The requested version has strictly higher precedence than the current one.
- The target tag does not already exist.

Nothing is pushed. `custom-flavor-release.yml` re-checks that the pushed tag matches the committed version, so a hand-cut tag that skipped `release:bump` fails before the image builds.

## Three things that look wrong but are not

### `sort -V` is not used to compare versions

It is not a semver comparator:

```console
$ printf '1.0.0-alpha\n1.0.0\n1.0.0-rc1\n1.0.0-rc.1\n' | sort -V
1.0.0            <- semver §11 requires this LAST
1.0.0-alpha
1.0.0-rc1        <- semver §11 requires rc.1 before rc1
1.0.0-rc.1
```

`semver_cmp` in `release-bump.sh` implements §11 precedence directly and is covered by `tests/semver-cmp.bats`, including the orderings above. Do not replace it with `sort -V`.

### The tag and the project version differ for pre-releases

PEP 440 has no `-` separator, so `uv version 0.6.0-rc1` stores `0.6.0rc1`. The tag must stay `v0.6.0-rc1`, because `scripts/compute-release-version.sh` requires that form.

Everything comparing the two normalises first, via `uv version --dry-run --short --frozen`, which writes nothing and lets uv own PEP 440 instead of reimplementing it in bash:

```console
$ uv version --dry-run --short --frozen 0.6.0-RC1
0.6.0rc1
```

`release-bump.sh` accepts anything uv normalises into a plain release or an `a`/`b`/`rc` pre-release, and refuses the rest. `0.6.0-post1` normalises to `0.6.0.post1`, which has no semver equivalent and no meaning for this project's tags, so it is rejected rather than mistranslated.

### `tag_pattern = "v[0-9]*"` in `cliff.toml` is load-bearing

This repository carries `riotbox-checkpoint/*` tags. Without the pattern git-cliff tries to parse them as semver and aborts:

```text
Semver error: unexpected character 'r' while parsing major version number
```

## Commit bodies contribute entries

A squash-merged branch arrives as one commit, so its individual changes live in the commit body rather than in a commit each. `cliff.toml` harvests them, and this is the convention it expects:

```text
feat(release): add release:bump task for cutting releases

Prose explaining why. This is not harvested.

- feat(release): add changelog-section.sh to extract one release's notes
  - Lives in a script rather than inline in the workflow so the bats
    suite exercises the same extraction CI runs.
- ci(release): fail the release when the tag and committed version differ
```

Each top-level bullet that is itself a Conventional Commit becomes its own changelog entry, grouped by _its own_ type — so the `ci(release):` bullet above lands under Miscellaneous Tasks, not under Features with its parent. Indented bullets beneath it become nested detail lines. An entry ends at the first blank line or at the next bullet indented no further than itself.

Everything else is dropped: prose paragraphs, bullets that are not Conventional Commits, and trailers such as `Assisted-By:`. Merge commits are skipped whole, because their body repeats the branch's own subjects and would list every change twice.

Hard wraps are undone, so a bullet may be wrapped freely. A word broken across a wrap is rejoined without a space, which is why `multiprocessing-` at the end of a line joins to `logging` on the next as `multiprocessing-logging`.

Two consequences worth knowing:

- Body bullets feed version selection too. A `feat!:` bullet inside a `fix:` commit makes `git-cliff --bumped-version` suggest a minor bump, not a patch.
- A `chore(release):` bullet is skipped, because the rule that keeps the release commit out of the next release's notes matches on the message and cannot tell the two apart.

The mechanism is `split_commits` plus the `commit_preprocessors` chain in `cliff.toml`, which is commented step by step. It runs before splitting, which is what makes splitting on newlines safe.

## Changelog regeneration is idempotent

`release-bump.sh` regenerates `CHANGELOG.md` in full rather than prepending. `cliff.toml` skips `^chore\(release\)` commits, so the release commit never appears in the next release's notes and a later full regeneration reproduces the same file. A prepend would drift the moment history is rewritten or the configuration changes.

Sections only cover commits reachable from the current branch. `v0.1.1` has no section because its tagged commit is not an ancestor of `main` — it was rebased away — so it is absent from the history the changelog renders.

## Pre-releases and thin stable notes

Cutting `v0.6.0-rc1` gives it its own `## [0.6.0-rc1]` section, so the later `## [0.6.0]` section holds only the commits made after the rc. Stable release notes can therefore read thin, with the detail in the section directly above.

The alternative — excluding rc tags from the changelog — would leave pre-releases with no notes at all. This is the better failure.

## Tests

`tests/semver-cmp.bats`, `tests/release-bump.bats`, `tests/changelog-section.bats`, and `tests/changelog-body-bullets.bats`, all run by `task dev:test:runner`.

The bump tests build throwaway repositories with a stub git-cliff, so they touch neither the real checkout nor the network, and they pin `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` to `/dev/null` so the caller's git identity cannot leak in.

`tests/changelog-body-bullets.bats` is the exception: the behaviour under test _is_ `cliff.toml`, which a stub cannot exercise, so it runs the real git-cliff against throwaway repositories. Override the command with `GIT_CLIFF` if `uvx git-cliff@2.13.1` is not how this machine reaches it.

Every negative case asserts the working tree is unmodified afterwards — a guard that aborts after a partial write is worse than no guard.

Note for anyone extending `tests/changelog-section.bats`: bats collapses blank entries out of the `lines` array, so section structure is asserted against `"$output"` as a whole.
