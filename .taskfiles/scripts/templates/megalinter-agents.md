# MegaLinter Findings Remediation

This directory contains MegaLinter findings split by linter. Each markdown file contains all findings for one specific linter.

## How to Fix Issues

### Workflow

**Use the Agent tool to spawn sub-agents for each linter file.** This allows parallel processing and appropriate model selection.

1. **Spawn sub-agents** — one per linter file using the Agent tool:
   ```
   Agent({
     description: "Fix yamllint findings",
     subagent_type: "general-purpose",
     model: "<choose-based-on-complexity>",  // See Model Selection below
     prompt: "Fix all yamllint issues in megalinter-reports/megalinter-report-chunked/yamllint.md. Follow the workflow in AGENTS.md in that directory. Review and validate your fixes, then commit."
   })
   ```

2. **Model Selection** — choose the appropriate model tier for the task:
   - **Small/fast models** (e.g., haiku, gpt-4o-mini, gemini-flash) — Simple mechanical fixes (trailing spaces, indentation, formatting, line length)
   - **Balanced models** (e.g., sonnet, gpt-4o, gemini-pro) — Complex logic issues (code smells, architectural problems, refactoring)
   - **Large/reasoning models** (e.g., opus, o1, gemini-ultra) — Critical security issues, complex architectural decisions

3. **Sub-agent workflow** (each agent follows this):
   - Read the assigned linter file
   - Fix all findings in that file
   - Review your work for correctness by re-reading affected files and validating changes
   - Perform independent validation: verify each fix addresses the original finding without introducing new issues
   - Commit fixes with clear description
   - Report completion with summary of fixes applied

### Project Constraints

- **YAML**: Follow `.yamllint.yml` configuration. Line length follows yamllint config, not the 99-char code rule.
- **Python**: Follow `ruff.toml` configuration. Use ruff for all Python linting.
- **Commits**: All commits MUST use Conventional Commits and the `Assisted-by` trailer.
- **Sync impact**: Config files and workflows sync to all org repos via `sync-config.yml`. Check before modifying to understand downstream impact.

### Auto-fixable Issues

Some findings are marked **Auto-fixable**. You can run:
```bash
task megalint:run APPLY_FIXES=all  # Auto-fix all fixable issues
```

Then review the changes before committing.
