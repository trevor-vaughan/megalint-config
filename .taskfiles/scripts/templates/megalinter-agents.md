# MegaLinter Findings Remediation

This directory contains MegaLinter findings split by linter. Each markdown file contains all findings for one specific linter.

## How to Fix Issues

### Workflow

Each markdown file in this directory holds the findings for one linter and can be fixed independently. If your agent harness can spawn parallel workers — sub-agents, sub-tasks, background jobs, whatever your tool calls them — dispatch one per linter file so they run concurrently, each on a model tier suited to its difficulty. If it cannot, process the files sequentially; every other step below is identical.

1. **Dispatch one worker per linter file.** Map this to your harness's own primitive (sub-agent spawn, parallel job, or a manual pass per file). Give each worker a task equivalent to:

   > Fix all findings in `megalinter-reports/llm-sarif/<linter>.md` — e.g. `yamllint.md`. Follow the workflow in `AGENTS.md` in that directory. Review and validate your fixes, then commit real fixes only.

   Choose the worker's model by difficulty (see Model Selection below).

2. **Model Selection** — choose the appropriate model tier for the task:
   - **Small/fast models** (e.g., haiku, gpt-4o-mini, gemini-flash) — Simple mechanical fixes (trailing spaces, indentation, formatting, line length)
   - **Balanced models** (e.g., sonnet, gpt-4o, gemini-pro) — Complex logic issues (code smells, architectural problems, refactoring)
   - **Large/reasoning models** (e.g., opus, o1, gemini-ultra) — Critical security issues, complex architectural decisions

3. **Per-file workflow** (each worker follows this):
   - Read the assigned linter file
   - Triage each finding as a **real issue** or a **false positive** (see "Handling False Positives" below). When in doubt, treat it as real.
   - Fix all real findings in that file
   - Route every false positive through the suppression workflow — do **not** silently delete or ignore findings
   - Review your work for correctness by re-reading affected files and validating changes
   - Perform independent validation: verify each fix addresses the original finding without introducing new issues
   - Commit **real fixes only** with a clear description. Do **not** commit suppressions — leave them as working-tree changes for human validation.
   - Report completion with a summary of fixes applied **and** a separate, itemized list of every proposed suppression awaiting human sign-off

> **Commit serialization:** all workers share one git repository and index. Concurrent `git commit`/`git add` invocations race on the index lock and fail. Commit serially — retry on a transient `index.lock` error rather than aborting — or have the orchestrator commit on each worker's behalf after it reports.

### Project Constraints

- **YAML**: Follow `.yamllint.yml` configuration. Line length follows yamllint config, not the 99-char code rule.
- **Python**: Follow `ruff.toml` configuration. Use ruff for all Python linting.
- **Commits**: All commits MUST use Conventional Commits and the `Assisted-by` trailer.
- **Sync impact**: Config files and workflows sync to all org repos via `sync-config.yml`. Check before modifying to understand downstream impact.

### Handling False Positives

A real fix is always preferred. Suppression is a last resort, and **every suppression is a security-sensitive decision**: a wrongly-silenced finding can hide a genuine vulnerability or bug. Before suppressing anything:

1. **Prove the finding is 100% a false positive.** Re-read the flagged code and the linter's rule. Independently double-check your conclusion — verify the reasoning from scratch rather than rationalizing the easy path. If you cannot establish with certainty that it is benign, treat it as a real issue and fix it.
2. **Never suppress to save effort.** Difficulty fixing a finding is not evidence that it is a false positive.

There are exactly two suppression mechanisms. Pick by cause:

- **`.gitignore` — for false-positive *generators* only.** When the findings come from a file that is **not hand-maintained source** — generated code, build output, vendored dependencies, lockfiles, or test fixtures — add that file or directory to `.gitignore`. MegaLinter only lints git-listed files, so this removes the noise at its source. **Never add hand-written source to `.gitignore` to silence a finding** — that hides the file from version control, not just the linter.
- **Native inline suppression — for a single justified finding in real source.** Use the linter's own mechanism scoped to the exact line/finding (e.g. `# noqa: <CODE>`, `# nosec`, `# checkov:skip=<CKV_ID>:<reason>`, `//nolint:<linter>`), always with a comment naming the rule and stating why it is safe. **Never blanket-disable a rule** project-wide or for a whole file to dodge one finding.

**Human validation is mandatory.** Do not commit suppressions. Apply the `.gitignore` entry or inline comment as a working-tree change, then enumerate each one in your completion report — file, finding, mechanism, and the justification — so a human can review and approve before it merges.

### Auto-fixable Issues

Some findings are marked **Auto-fixable**. Fix these the same way as any other finding — edit the affected files directly. They are mechanical (formatting, whitespace, import order), so a small/fast model handles them well.

**Do not run `task megalint` (or any `task megalint:*` target) yourself.** Running the linter or its auto-fixer is reserved for the human operator. Your job is to edit source files and report; the human re-runs the linter to verify.
