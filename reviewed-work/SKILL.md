---
name: reviewed-work
argument-hint: "[--light] [--rounds N] [task description]"
disable-model-invocation: true
---

# Reviewed Work: Multi-Round Review Workflow

## Configuration Defaults

```
REVIEW_ROUNDS = 2
REVIEWERS = code-reviewer, pr-test-analyzer, silent-failure-hunter
```

You may override REVIEW_ROUNDS per-invocation with `--rounds N` in the arguments.
You may customize the default REVIEWERS list by editing the values above.

## Argument Parsing

Parse `$ARGUMENTS` as follows:
- If arguments contain `--light`, enable light mode (see below) and remove the flag from the remaining arguments.
- If arguments contain `--rounds N`, extract N as the number of review rounds and treat the rest as the task description.
- Otherwise, use the default REVIEW_ROUNDS and treat all arguments as the task description.
- `--light` and `--rounds` can be combined, but `--light` overrides REVIEWERS to use only the built-in `/review`.

Examples:
- `/reviewed-work implement auth` -> rounds=2, full review, task="implement auth"
- `/reviewed-work --rounds 3 implement auth` -> rounds=3, full review, task="implement auth"
- `/reviewed-work --rounds 1 fix the login bug` -> rounds=1, full review, task="fix the login bug"
- `/reviewed-work --light implement auth` -> rounds=1, light review, task="implement auth"
- `/reviewed-work --light --rounds 2 implement auth` -> rounds=2, light review, task="implement auth"

### Light Mode

When `--light` is set:
- **REVIEW_ROUNDS** defaults to 1 (unless explicitly overridden with `--rounds N`)
- **Skip Phase 3a entirely** — do not spawn any subagent reviewers
- **Instead**, run the built-in `/review` command directly on the changes
- Parse the `/review` output for BLOCKING issues and NITs
- Continue to Phase 3c (FIX-VERIFY LOOP) — if `/review` found BLOCKING issues, fix them and re-run `/review` (not subagent reviewers) to verify (cap at 3 iterations)
- The Phase 4 report uses the following simplified format:

```
## Review Summary (Light Mode)

### Round 1
- built-in /review: PASS/NEEDS_CHANGES (N fix-verify iterations)

### Totals
- Rounds: N
- Fix-verify iterations: N total
- Remaining NITs: (list any non-blocking suggestions)
- Unresolved BLOCKING issues: (list any, if max iterations were hit)
```

## Workflow

Execute these phases in order:

### Phase 1: IMPLEMENT

Complete the coding task described by the task arguments. Write the code, create files, modify existing files - do whatever is needed to fully implement the requested work.

### Phase 2: CAPTURE

After implementation is complete, capture the current changes:

1. Run `git diff HEAD` to get the full diff of all staged and unstaged changes.
   - If `git diff HEAD` fails (e.g., no commits yet), fall back to `git diff --cached` or read new files directly.
2. Run `git diff HEAD --name-only` to get the list of changed files.
3. If no changes are detected, stop here and report to the user that there are no changes to review.

Store the diff output and changed file list for use in the review loop.

### Phase 3: REVIEW LOOP

For each round from 1 to REVIEW_ROUNDS:

#### 3a. REVIEW

Spawn ALL configured reviewers IN PARALLEL using the Agent tool. For each reviewer agent:

- Use `subagent_type` matching the reviewer name (e.g., `code-reviewer`, `pr-test-analyzer`, `silent-failure-hunter`)
- Pass the following in the prompt:
  - The full `git diff HEAD` output (the actual diff content)
  - The list of changed files
  - Instruction: "Review these changes. You have full repo access via Read, Grep, and Glob tools. Explore surrounding code, callers, tests, and CLAUDE.md for context. Classify each issue as either BLOCKING (must fix) or NIT (suggestion). End your review with a clear verdict: PASS (no blocking issues) or NEEDS_CHANGES (has blocking issues)."
- Launch all reviewer agents in a single message (parallel execution)

#### 3b. COLLECT

Gather all reviewer feedback. For each reviewer, record:
- BLOCKING issues (must fix before proceeding)
- NIT issues (non-blocking suggestions)
- Overall verdict: PASS or NEEDS_CHANGES
- If a reviewer's output has no clear verdict, treat it as NEEDS_CHANGES and mark it as "AMBIGUOUS" in the per-round report row. Include the first 200 characters of the reviewer's raw output so the user can diagnose whether the reviewer agent is broken.
- If the Agent tool errors for a reviewer, mark that reviewer as UNAVAILABLE (not PASS)

**Fallback: if ALL reviewers are UNAVAILABLE**

If every configured reviewer returned an Agent tool error (i.e., all are marked UNAVAILABLE), do not treat the round as all-PASS. Instead:

1. Note in the report that custom review agents are not installed.
2. Run the built-in `/review` command to perform a standard review of the changes.
3. Parse the `/review` output for BLOCKING issues and NITs using the same criteria (BLOCKING = must fix, NIT = suggestion).
4. Use the `/review` output as the sole reviewer result for this round, labelled as "built-in /review (fallback)".
5. Continue to Phase 3c (FIX-VERIFY LOOP) normally with the fallback verdict.

If only SOME reviewers are UNAVAILABLE (but at least one ran successfully), treat the unavailable ones as ABSENT — they are neither PASS nor NEEDS_CHANGES and must not count toward the verdict. In the per-round report row, mark them as "UNAVAILABLE" (not PASS). Continue with the results from those that did run, and note in the report header how many of N reviewers actually ran.

#### 3c. FIX-VERIFY LOOP

If ANY reviewer reported BLOCKING issues:

1. Address all BLOCKING issues by modifying the code
2. Re-capture the updated diff (`git diff HEAD` again)
3. Re-spawn the SAME set of reviewers in parallel with the updated diff to verify fixes
4. If new or remaining BLOCKING issues are found, fix and re-verify again
5. Cap at 3 fix-verify iterations per round to prevent infinite loops
6. If max iterations reached, note remaining issues and proceed to next round

#### 3d. PROCEED

ALWAYS proceed to the next round regardless of this round's outcome. Fresh agent instances in the next round provide fresh perspective and may catch different issues.

### Phase 4: REPORT

After all rounds complete, present a final summary to the user:

```
## Review Summary

### Round 1
- code-reviewer: PASS/NEEDS_CHANGES (N fix-verify iterations)
- pr-test-analyzer: PASS/NEEDS_CHANGES (N fix-verify iterations)
- silent-failure-hunter: PASS/NEEDS_CHANGES (N fix-verify iterations)

### Round 2
- code-reviewer: PASS/NEEDS_CHANGES (N fix-verify iterations)
- pr-test-analyzer: PASS/NEEDS_CHANGES (N fix-verify iterations)
- silent-failure-hunter: PASS/NEEDS_CHANGES (N fix-verify iterations)

### Totals
- Rounds: N
- Fix-verify iterations: N total
- Remaining NITs: (list any non-blocking suggestions)
- Unresolved BLOCKING issues: (list any, if max iterations were hit)
```

## Error Handling

- **No changes detected**: Stop early, report to user
- **Reviewer output has no clear verdict**: Treat as NEEDS_CHANGES, mark as AMBIGUOUS in report with first 200 chars of raw output
- **Agent tool error (some reviewers)**: Treat unavailable reviewers as ABSENT (not PASS), mark as UNAVAILABLE in report, reduce the reviewer count denominator for that round
- **Agent tool error (ALL reviewers)**: Do not treat as PASS. Fall back to the built-in `/review` command as the sole reviewer for this round
- **Fix-verify loop hits max iterations (3)**: Report remaining issues, proceed to next round
- **After final round**: Report any unresolved BLOCKING issues clearly to user

## Important Notes

- This workflow operates on LOCAL git diff, not GitHub PRs. It works in any git repo, even without a remote.
- Reviewers have full repo access (Read, Grep, Glob) and should explore beyond just the diff.
- Each round uses completely fresh agent instances with no prior context.
- The outer loop (rounds) always runs all configured rounds. The inner loop (fix-verify) ensures fixes are correct before moving on.
- If custom reviewer agents are not installed, the skill automatically falls back to the built-in `/review` command. To get full multi-perspective review, copy the agent files from the repo's `agents/` directory to `~/.claude/agents/`.
