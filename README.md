# UsefulSkills
Reusable Claude Code skills and workflows

## Setup

```bash
# 1. Clone the repo
git clone git@github.com:kunqianut/UsefulSkills.git

# 2. Copy the skill
mkdir -p ~/.claude/skills/reviewed-work
cp UsefulSkills/reviewed-work/SKILL.md ~/.claude/skills/reviewed-work/SKILL.md

# 3. (Recommended) Install the custom review agents
cp UsefulSkills/agents/*.md ~/.claude/agents/
```

## Custom Review Agents

The `/reviewed-work` skill uses three specialized review agents that run in parallel:

- **code-reviewer** — Confidence-scored code review against project guidelines and bug detection (only reports issues with confidence >= 80)
- **pr-test-analyzer** — Test coverage analysis with criticality ratings, focused on behavioral coverage over line coverage
- **silent-failure-hunter** — Error handling audit with zero tolerance for silent failures and inadequate error messages

These agents are defined in the `agents/` directory. Copy them to `~/.claude/agents/` (step 3 above) to enable multi-perspective parallel review.

Without the agents installed, the skill still works — it falls back to the built-in `/review` command. However, you won't get the three-perspective parallel review that the skill is designed for.
