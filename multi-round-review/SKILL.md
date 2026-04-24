---
name: multi-round-review
argument-hint: "[--rounds N] [PR# or description of changes to review]"
disable-model-invocation: true
---

# PR Review: Multi-Round Consolidated Review

## Configuration Defaults

```
REVIEW_ROUNDS = 3
REVIEWERS = code-reviewer, pr-test-analyzer, silent-failure-hunter
```

You may override REVIEW_ROUNDS per-invocation with `--rounds N` in the arguments.
You may customize the default REVIEWERS list by editing the values above.

## Argument Parsing

Parse `$ARGUMENTS` as follows:
- If arguments start with `--rounds N`, extract N as the number of review rounds and treat the rest as the target.
- Otherwise, use the default REVIEW_ROUNDS and treat all arguments as the target.
- If the remaining target is a number (e.g., `123`) or a GitHub PR URL, treat it as a GitHub PR to review.
- If the target is empty or a description, review the local uncommitted changes (`git diff HEAD`).

Examples:
- `/multi-round-review` -> rounds=3, review local uncommitted changes
- `/multi-round-review 42` -> rounds=3, review GitHub PR #42
- `/multi-round-review --rounds 2` -> rounds=2, review local uncommitted changes
- `/multi-round-review --rounds 2 42` -> rounds=2, review GitHub PR #42
- `/multi-round-review --rounds 1 https://github.com/org/repo/pull/42` -> rounds=1, review that PR

## Workflow

Execute these phases in order:

### Phase 1: CAPTURE

Obtain the diff to review:

**If reviewing a GitHub PR:**
1. Run `gh pr diff <PR#>` to get the full diff.
2. Run `gh pr diff <PR#> --name-only` to get the list of changed files.
3. Run `gh pr view <PR#> --json title,body,baseRefName,headRefName` to get PR metadata.
4. If any `gh` call fails, report the specific error and the command that failed, then stop.

**If reviewing local changes:**
1. Run `git diff HEAD` to get the full diff of all staged and unstaged changes.
   - If `git diff HEAD` fails (e.g., no commits yet), inform the user: "No commits found; falling back to staged changes." Then run `git diff --cached`.
   - If `git diff --cached` is also empty, inform the user: "No staged changes found; will list untracked files." Then run `git ls-files --others --exclude-standard` and read each listed file to construct a synthetic diff.
2. Run `git diff HEAD --name-only` (or the equivalent for the fallback used) to get the list of changed files.
3. If all methods produce no content, stop here and report to the user that there are no reviewable changes.

Store the diff output and changed file list for use in the review loop.

### Phase 2: REVIEW LOOP

For each round from 1 to REVIEW_ROUNDS:

#### 2a. REVIEW

Spawn ALL configured reviewers IN PARALLEL using the Agent tool. For each reviewer agent:

- Use `subagent_type` matching the reviewer name (e.g., `code-reviewer`, `pr-test-analyzer`, `silent-failure-hunter`)
- Pass the following in the prompt:
  - The full diff output (the actual diff content)
  - The list of changed files
  - The PR metadata (title, description) if reviewing a GitHub PR
  - If this is round 2+, include a summary of issues found in prior rounds so the reviewer can look for issues that were MISSED previously
  - Instruction (substitute `{current_round}` and `{total_rounds}` with actual values): "Review these changes. You have full repo access via Read, Grep, and Glob tools. Explore surrounding code, callers, tests, and CLAUDE.md for context. This is round {current_round} of {total_rounds} total review rounds. Focus on finding issues that a previous reviewer might miss. Classify each issue as either BLOCKING (must fix) or NIT (suggestion). End your review with a clear verdict: PASS (no blocking issues) or NEEDS_CHANGES (has blocking issues)."
- Launch all reviewer agents in a single message (parallel execution)

#### 2b. COLLECT

Gather all reviewer feedback. For each reviewer, record:
- BLOCKING issues (must fix before merge)
- NIT issues (non-blocking suggestions)
- Overall verdict: PASS or NEEDS_CHANGES
- If a reviewer's output has no clear verdict, treat it as NEEDS_CHANGES and mark it as "AMBIGUOUS" in the per-round report row. Include the first 200 characters of the reviewer's raw output so the user can diagnose whether the reviewer agent is broken.
- If the Agent tool errors for a reviewer, mark that reviewer as UNAVAILABLE (not PASS)

**Fallback: if ALL reviewers are UNAVAILABLE**

If every configured reviewer returned an Agent tool error (i.e., all are marked UNAVAILABLE), do not treat the round as all-PASS. Instead:

1. Note in the report that custom review agents are not installed. Include the agent tool error message so the user can distinguish transient failures (rate limits) from permanent misconfiguration (agents not installed).
2. Run the built-in `/review` command to perform a standard review of the changes.
3. Parse the `/review` output for BLOCKING issues and NITs using the same criteria (BLOCKING = must fix, NIT = suggestion).
4. Use the `/review` output as the sole reviewer result for this round, labelled as "built-in /review (fallback)".
5. If the fallback fired in the previous round as well, skip spawning agents for all remaining rounds. Reuse the previous round's `/review` output for each remaining round (do not re-run `/review`). In each reused round's report row, note "results shared from round N fallback". Add a prominent note at the top of the report: "All rounds used built-in /review fallback. For multi-perspective review, install custom agents (see setup instructions)."

If only SOME reviewers are UNAVAILABLE (but at least one ran successfully), treat the unavailable ones as ABSENT — they are neither PASS nor NEEDS_CHANGES and must not count toward the verdict. In the per-round report row, mark them as "UNAVAILABLE" (not PASS). Continue with the results from those that did run, and note in the report header how many of N reviewers actually ran.

#### 2c. PROCEED

ALWAYS proceed to the next round regardless of this round's outcome. Fresh agent instances in the next round provide fresh perspective and may catch different issues. When constructing prompts for the next round, include a summary of all issues found so far and instruct reviewers to look for NEW issues not yet identified.

### Phase 3: CONSOLIDATE

After all rounds complete, deduplicate and merge findings across all rounds:

1. **Deduplicate**: Merge issues that refer to the same code location and same problem (even if described differently across rounds). Keep the most detailed description.
2. **Confirm**: Issues found by multiple reviewers or in multiple rounds are higher confidence. Note which issues were independently found multiple times.
3. **Categorize**: Group all unique issues into:
   - BLOCKING: Issues that should be fixed before merge
   - NIT: Non-blocking suggestions for improvement
4. **Prioritize**: Within each category, order by how many reviewers/rounds flagged the issue (most-flagged first).

### Phase 4: REPORT

Present the consolidated review to the user:

```
## PR Review Summary

**Target**: [local changes | PR #N: title]
**Rounds**: N | **Reviewers per round**: code-reviewer, pr-test-analyzer, silent-failure-hunter

---

### BLOCKING Issues (must fix)

1. **[Issue title]** — `file/path.ts:L42`
   [Description of the issue]
   Found by: code-reviewer (round 1, 2), silent-failure-hunter (round 2)

2. ...

### NITs (suggestions)

1. **[Issue title]** — `file/path.ts:L10`
   [Description of the issue]
   Found by: code-reviewer (round 1)

2. ...

### Per-Round Details

#### Round 1 (N of N reviewers ran)
- code-reviewer: PASS/NEEDS_CHANGES/UNAVAILABLE/AMBIGUOUS — N blocking, N nits
- pr-test-analyzer: PASS/NEEDS_CHANGES/UNAVAILABLE/AMBIGUOUS — N blocking, N nits
- silent-failure-hunter: PASS/NEEDS_CHANGES/UNAVAILABLE/AMBIGUOUS — N blocking, N nits

#### Round 2
...

### Overall Verdict

PASS / NEEDS_CHANGES (N blocking issues, N nits across N rounds)
```

## Error Handling

- **No changes detected**: Stop early, report to user
- **GitHub PR not found**: Report error and stop
- **Reviewer output has no clear verdict**: Treat as NEEDS_CHANGES, mark as AMBIGUOUS in report with first 200 chars of raw output
- **Agent tool error (some reviewers)**: Treat unavailable reviewers as ABSENT (not PASS), mark as UNAVAILABLE in report, reduce the reviewer count denominator for that round
- **Agent tool error (ALL reviewers)**: Do not treat as PASS. Fall back to the built-in `/review` command as the sole reviewer for that round

## Important Notes

- This skill is REVIEW ONLY. It does not modify code or fix issues. It reports findings for the user to act on.
- Supports both local git changes and GitHub PRs.
- Each round uses completely fresh agent instances with no prior context, but the prompt includes a summary of prior findings to encourage fresh perspectives.
- Multiple rounds help catch issues that a single pass might miss — different agent instances approach the code differently.
- If custom reviewer agents are not installed, the skill automatically falls back to the built-in `/review` command. To get full multi-perspective review, copy the agent files from the repo's `agents/` directory to `~/.claude/agents/`.
