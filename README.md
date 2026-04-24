# UsefulSkills
Reusable Claude Code skills and workflows

## Skills

| Skill | Description |
|-------|-------------|
| `/reviewed-work` | Implement a task, then review the changes through multiple rounds of parallel review with automatic fix-verify loops |
| `/multi-round-review` | Review-only: run multiple rounds of parallel review on local changes or a GitHub PR, then consolidate findings |

## Setup

```bash
# 1. Clone the repo
git clone git@github.com:kunqianut/UsefulSkills.git

# 2. Copy the skills
mkdir -p ~/.claude/skills/reviewed-work ~/.claude/skills/multi-round-review
cp UsefulSkills/reviewed-work/SKILL.md ~/.claude/skills/reviewed-work/SKILL.md
cp UsefulSkills/multi-round-review/SKILL.md ~/.claude/skills/multi-round-review/SKILL.md

# 3. (Recommended) Install the custom review agents
cp UsefulSkills/agents/*.md ~/.claude/agents/
```

## `/reviewed-work`

Implement a coding task, then automatically review the changes through multiple rounds of parallel review. Includes fix-verify loops that address blocking issues and re-review until clean.

```
/reviewed-work implement auth          # 2 rounds (default)
/reviewed-work --rounds 3 fix login    # 3 rounds
```

## `/multi-round-review`

Review-only skill — no code modifications. Runs multiple rounds of parallel review on existing changes and consolidates all findings into a deduplicated, prioritized report. Supports both local git changes and GitHub PRs.

```
/multi-round-review                    # 3 rounds on local changes (default)
/multi-round-review 42                 # 3 rounds on GitHub PR #42
/multi-round-review --rounds 2         # 2 rounds on local changes
/multi-round-review --rounds 2 42      # 2 rounds on GitHub PR #42
```

## Custom Review Agents

Both skills use three specialized review agents that run in parallel:

- **code-reviewer** — Confidence-scored code review against project guidelines and bug detection (only reports issues with confidence >= 80)
- **pr-test-analyzer** — Test coverage analysis with criticality ratings, focused on behavioral coverage over line coverage
- **silent-failure-hunter** — Error handling audit with zero tolerance for silent failures and inadequate error messages

These agents are defined in the `agents/` directory. Copy them to `~/.claude/agents/` (step 3 above) to enable multi-perspective parallel review.

Without the agents installed, both skills still work — they fall back to the built-in `/review` command. However, you won't get the three-perspective parallel review that the skills are designed for.
