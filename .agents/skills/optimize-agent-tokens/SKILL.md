---
name: optimize-agent-tokens
description: Reduce agent token use without lowering correctness by narrowing repository context, removing repeated prompt instructions, bounding tool output, and keeping responses outcome-focused. Use for token or context optimization, prompt and AGENTS.md audits, large-repository exploration, repeated tool-heavy work, or when a Codex task is consuming excessive context, reasoning, or output tokens.
---

# Optimize Agent Tokens

Minimize total input, reasoning, tool-output, and response tokens while preserving the task's success criteria, safety boundaries, and verification quality.

## Work from the smallest sufficient context

1. State the requested outcome, affected component, constraints, and completion evidence in one compact note.
2. For a large or unfamiliar tree, run `scripts/context-audit.sh [repo-path]` before opening files broadly.
3. Read the nearest applicable `AGENTS.md`, the relevant manifest, and only files connected to the requested behavior.
4. Search names and symbols with `rg` before opening files. Add tight globs and exclusions; cap exploratory output.
5. Avoid loading lockfiles, generated output, dependency trees, logs, binaries, snapshots, or entire directories unless the task specifically requires them.

For this repository, route first by component:

- `smartspoon/`: Flutter mobile app
- `ispoon-backend/`: Node.js backend
- `smartspoon-website/`: Next.js website; obey its nested `AGENTS.md`
- `Spoon firmware/`: embedded firmware

## Keep execution lean

- Batch independent read-only checks when their combined output stays bounded.
- Reuse existing results; do not repeat repository-wide listings, status checks, or unchanged test output.
- Prefer deterministic commands or existing scripts over explaining or regenerating routine transformations.
- Inspect focused diffs and run the narrowest relevant validation first. Expand only when risk or a failure justifies it.
- Preserve unrelated worktree changes. Do not spend context reviewing them unless they overlap the task.
- Do not trade away correctness, security checks, user approval boundaries, or necessary tests to save tokens.

## Optimize prompts and agent instructions

When auditing prompts, skills, or `AGENTS.md` files:

1. Establish a working baseline or representative examples.
2. Remove one repeated instruction, obsolete example, or irrelevant tool group at a time.
3. State each rule once. Prefer outcome, constraints, evidence, and stopping conditions over unnecessary step-by-step direction.
4. Keep true invariants and measured behavior fixes; move detailed optional material into directly linked references.
5. Re-run the same validation after each meaningful reduction. Count a reduction as successful only when output still meets the original quality bar.

## Return compact results

Lead with the outcome. Include changed files, decisive evidence, material caveats, and the next action if one remains. Omit repeated narration, generic reassurance, and background that did not affect the result.
