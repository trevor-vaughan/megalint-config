# MegaLinter Findings Remediation

This directory contains MegaLinter findings split by linter. Each markdown file holds all findings for one linter (e.g. `yamllint.md`) and can be remediated independently.

## The completeness contract

This is the rule everything else serves: **no finding is ever skipped, silently dropped, or deleted.** Every finding in every file must end in exactly one of three terminal states.

| State | Meaning | Committed? |
|-------|---------|------------|
| **Fixed** | You edited the source so the finding no longer applies, and validated it. | Yes — real fixes only. |
| **Suppression proposed** | Proven false positive, suppressed via an approved mechanism (see [Handling false positives](#handling-false-positives)). | No — working-tree change, pending human review. |
| **Blocked** | Needs a human decision you can't make yourself (see [Decisions that need a human](#decisions-that-need-a-human)). | No — left unresolved for a human. |

**Reconcile before you declare a file done.** Count the findings you drove to a terminal state and compare against the `**Total findings: N**` header at the top of that file. The counts must match. If they don't, you lost findings — stop and recount before reporting.

> Log-sourced files (headed `# Linter: <name> (from log)`) have no `Total findings` count. For those, reconcile against each distinct error described in the log body instead of a number.

## Track every finding

Do not hold the finding list in your head — that is how findings get dropped.

When you open a linter file, load **every** finding into your harness's task/todo/checklist primitive (TodoWrite, a task list, sub-tasks, whatever your tool provides) — one tracked item per finding, keyed by `file:line [ruleId]`. If your harness has no such primitive, keep a written checklist in your working notes.

Update each item to its terminal state (Fixed / Suppression proposed / Blocked) as you go. **Do not report the file complete while any tracked item is still open.** This checklist, reconciled against the header count, is what guarantees completeness.

## Workflow

The work has two roles. If you dispatch parallel workers, you play the orchestrator and each worker follows the per-file procedure. If you process files yourself one at a time, skip orchestration and run the per-file procedure per file — everything else is identical.

### Orchestration (only if you run parallel workers)

If your harness can spawn parallel workers — sub-agents, sub-tasks, background jobs, whatever your tool calls them — dispatch one per linter file so they run concurrently, each on a model tier suited to its difficulty.

1. **Dispatch one worker per linter file.** Map this to your harness's own primitive (sub-agent spawn, parallel job, or a manual pass per file). Give each worker a task equivalent to:

   > Fix all findings in `megalinter-reports/llm-sarif/<linter>.md` — e.g. `yamllint.md`. Follow the workflow in `AGENTS.md` in that directory. Track every finding, validate your fixes, reconcile against the header count, then commit real fixes only.

2. **Choose the worker's model by difficulty:**
   - **Small/fast models** (e.g. haiku, gpt-4o-mini, gemini-flash) — mechanical fixes (trailing spaces, indentation, formatting, line length).
   - **Balanced models** (e.g. sonnet, gpt-4o, gemini-pro) — logic issues (code smells, refactoring, non-trivial corrections).
   - **Large/reasoning models** (e.g. opus, o1, gemini-ultra) — security-sensitive findings and architectural decisions.

3. **Serialize commits.** All workers share one git repository and index. Concurrent `git commit`/`git add` invocations race on the index lock and fail. Either have workers commit serially — retrying on a transient `index.lock` error rather than aborting — or have the orchestrator commit on each worker's behalf after it reports.

### Per-file procedure (every worker)

1. **Enumerate.** Load every finding in the file into your tracker (see [Track every finding](#track-every-finding)).
2. **Triage** each finding as a **real issue** or a **false positive** (see [Handling false positives](#handling-false-positives)). When in doubt, treat it as real.
3. **Fix** every real finding by editing the affected source. Mark it **Fixed** in your tracker once done.
4. **Route false positives** through the suppression workflow — never silently delete or ignore a finding. Mark it **Suppression proposed**.
5. **Escalate decisions.** If a finding needs a call you can't make yourself, follow [Decisions that need a human](#decisions-that-need-a-human) and mark it **Blocked**.
6. **Validate.** Re-read every file you changed. Confirm each fix addresses its original finding and introduces no new problem. Verify your reasoning from scratch rather than trusting your first pass.
7. **Reconcile.** Confirm your tracked-item count equals the `**Total findings: N**` header. Resolve any mismatch before continuing.
8. **Commit real fixes only**, with a clear Conventional Commits message. Do **not** commit suppressions or blocked findings — leave them as working-tree changes for human review.
9. **Report.** Summarize the fixes applied, then give a separate itemized list of every proposed suppression and every blocked finding awaiting human sign-off.

## Decisions that need a human

Some findings are not yours to resolve alone. **Surface these to your operator and wait for an answer before acting.** Escalate when:

- A fix has **materially different valid outcomes** and picking wrong changes behavior (e.g. which of two APIs is correct, whether a value should be configurable).
- The finding is **security-sensitive** — every suppression qualifies (see below), as does any change touching auth, crypto, secrets, or input validation.
- The fix is a **behavioral or architectural change** rather than a local correction.
- You are **not 100% certain** the fix is correct and safe.

**If you can ask, ask and wait.** Do not proceed past the finding until the human responds.

**If you cannot ask** — an unattended or CI run with no interactive operator — do **not** guess. Mark the finding **Blocked** in your tracker, leave the source unchanged, and enumerate it in your completion report so a human can resolve it. A blocked finding is a complete, honest outcome; a guessed one is not.

## Handling false positives

A real fix is always preferred. Suppression is a last resort, and **every suppression is a security-sensitive decision** — a wrongly-silenced finding can hide a genuine vulnerability. A suppression is therefore always a [decision that needs a human](#decisions-that-need-a-human): you may prepare it, but never commit it. Before suppressing anything:

1. **Prove the finding is 100% a false positive.** Re-read the flagged code and the linter's rule. Independently double-check your conclusion — verify the reasoning from scratch rather than rationalizing the easy path. If you cannot establish with certainty that it is benign, treat it as a real issue and fix it.
2. **Never suppress to save effort.** Difficulty fixing a finding is not evidence that it is a false positive.

There are exactly two suppression mechanisms. Pick by cause:

- **`.gitignore` — for false-positive *generators* only.** When the findings come from a file that is **not hand-maintained source** — generated code, build output, vendored dependencies, lockfiles, or test fixtures — add that file or directory to `.gitignore`.
  MegaLinter only lints git-listed files, so this removes the noise at its source. **Never add hand-written source to `.gitignore` to silence a finding** — that hides the file from version control, not just the linter.
- **Native inline suppression — for a single justified finding in real source.** Use the linter's own mechanism scoped to the exact line/finding (e.g. `# noqa: <CODE>`, `# nosec`, `# checkov:skip=<CKV_ID>:<reason>`, `//nolint:<linter>`), always with a comment naming the rule and stating why it is safe. **Never blanket-disable a rule** project-wide or for a whole file to dodge one finding.

**Human validation is mandatory.** Do not commit suppressions. Apply the `.gitignore` entry or inline comment as a working-tree change, mark the finding **Suppression proposed**, then enumerate each one in your completion report — file, finding, mechanism, and justification — so a human can review and approve before it merges.

## Auto-fixable issues

Some findings are marked **Auto-fixable**. Fix these the same way as any other finding — edit the affected files directly. They are mechanical (formatting, whitespace, import order), so a small/fast model handles them well. They still count toward the completeness contract like every other finding.

## Project constraints

- **YAML**: Follow `.yamllint.yml` configuration. Line length follows yamllint config, not the 99-char code rule.
- **Python**: Follow `ruff.toml` configuration. Use ruff for all Python linting.
- **Commits**: All commits MUST use Conventional Commits and the `Assisted-by` trailer.
- **Sync impact**: Config files and workflows sync to all org repos via `sync-config.yml`. Check before modifying to understand downstream impact — a change here is a change everywhere.

## Do not run the linter yourself

**Do not run `task megalint` (or any `task megalint:*` target).** Running the linter or its auto-fixer is reserved for the human operator. Your job is to edit source files, track and reconcile findings, and report; the human re-runs the linter to verify.
