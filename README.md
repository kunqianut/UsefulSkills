# UsefulSkills
Reusable Claude Code skills and workflows

## Skills

| Skill | Description |
|-------|-------------|
| `/reviewed-work` | Implement a task, then review the changes through multiple rounds of parallel review with automatic fix-verify loops |
| `/multi-round-review` | Review-only: run multiple rounds of parallel review on local changes or a GitHub PR, then consolidate findings |
| `/capture-session` | Capture a Claude Code session's raw conversation data to your Obsidian vault |
| `/summarize-session` | Generate a structured summary from a captured session with decisions, action items, and topic tags |
| `/threads` | Dashboard of all active development threads grouped by project and branch |
| `/briefing` | Deep context briefing for a specific thread — what it's about, your intentions, and where things stand |
| `/suggest-actions` | Suggested next steps, unresolved questions, and blockers for a thread |

## Setup

```bash
# 1. Clone the repo
git clone git@github.com:kunqianut/UsefulSkills.git

# 2. Copy the skills
for skill in reviewed-work multi-round-review capture-session summarize-session threads briefing suggest-actions; do
  mkdir -p ~/.claude/skills/$skill
  cp UsefulSkills/$skill/SKILL.md ~/.claude/skills/$skill/SKILL.md
done

# 3. Install the agents
cp UsefulSkills/agents/*.md ~/.claude/agents/

# 4. (Optional) Install the auto-capture hook
mkdir -p ~/.claude/hooks
cp UsefulSkills/hooks/auto-capture-session.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/auto-capture-session.sh

# 5. (Optional) Install the nightly cron script
cp UsefulSkills/hooks/nightly-capture-and-summarize.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/nightly-capture-and-summarize.sh
```

### Hook Configuration

To auto-capture the current session whenever you close Claude Code, add this to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionEnd": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash ~/.claude/hooks/auto-capture-session.sh"
          }
        ]
      }
    ]
  }
}
```

### Nightly Cron Setup (Optional)

For long-running sessions that stay open overnight, set up a nightly cron job that captures and summarizes active sessions at 3 AM:

```bash
crontab -e
# Add this line:
0 3 * * * bash ~/.claude/hooks/nightly-capture-and-summarize.sh >> ~/ObsidianVaults/ClaudeCode/_logs/nightly-cron.log 2>&1
```

The nightly job scans all projects for sessions modified in the last 24 hours, captures any new or updated sessions, and runs `claude -p` headlessly to generate summaries. Logs are saved to `~/ObsidianVaults/ClaudeCode/_logs/`.

### Cross-Project Portability

All skills, agents, and hooks are installed at the user level (`~/.claude/`), so they work across **all** Claude Code sessions regardless of which project you're in:

- Skills in `~/.claude/skills/` are available in every session
- Agents in `~/.claude/agents/` are available in every session
- Hooks in `~/.claude/settings.json` fire for every session
- The vault path (`~/ObsidianVaults/ClaudeCode/`) organizes data by project name automatically

### Obsidian Vault Setup

The thread tracking skills write to an Obsidian vault. By default this is `~/ObsidianVaults/ClaudeCode/`. The vault is created automatically on first use.

To use a different path, edit the `VAULT_PATH` in the Configuration Defaults section of each skill's SKILL.md, and set the `CLAUDE_VAULT_PATH` environment variable for the hook:

```bash
export CLAUDE_VAULT_PATH="$HOME/path/to/your/vault"
```

To use the vault with Obsidian, open it as a vault in Obsidian (`Open folder as vault` → select `~/ObsidianVaults/ClaudeCode`).

## Review Skills

### `/reviewed-work`

Implement a coding task, then automatically review the changes through multiple rounds of parallel review. Includes fix-verify loops that address blocking issues and re-review until clean.

```
/reviewed-work implement auth          # 2 rounds (default)
/reviewed-work --rounds 3 fix login    # 3 rounds
/reviewed-work --light implement auth  # single-round with built-in /review
```

### `/multi-round-review`

Review-only skill — no code modifications. Runs multiple rounds of parallel review on existing changes and consolidates all findings into a deduplicated, prioritized report. Supports both local git changes and GitHub PRs.

```
/multi-round-review                    # 3 rounds on local changes (default)
/multi-round-review 42                 # 3 rounds on GitHub PR #42
/multi-round-review --rounds 2         # 2 rounds on local changes
/multi-round-review --rounds 2 42      # 2 rounds on GitHub PR #42
```

## Thread Tracking Skills

A pipeline for capturing, organizing, and navigating Claude Code conversation history across multiple development threads.

### Workflow

```
1. /capture-session     → saves raw conversation to Obsidian vault
2. /summarize-session   → generates structured summary with decisions/actions
3. /threads             → shows dashboard of all active threads
4. /briefing            → loads context for a specific thread
5. /suggest-actions     → suggests next steps for a thread
```

With the auto-capture hook installed, step 1 happens automatically when you close a session. With the nightly cron, both steps 1 and 2 happen automatically for long-running sessions.

### `/capture-session`

Captures raw conversation data from a Claude Code session JSONL file and writes it as structured markdown to your Obsidian vault.

```
/capture-session                       # capture most recent session
/capture-session --previous            # capture the previous session
/capture-session <session-id>          # capture a specific session
/capture-session --project MyApp       # capture from a specific project
```

### `/summarize-session`

Generates a structured summary from a captured session using the thread-tracker agent. Supports **incremental updates** — if a summary already exists, only new conversation turns since the last summarization are analyzed and merged. Tracks summarization coverage with timestamps.

```
/summarize-session                     # summarize (or incrementally update) most recent capture
/summarize-session --previous          # summarize the previous capture
/summarize-session --fresh             # force full re-summarization from scratch
/summarize-session <session-id>        # summarize a specific session
```

### `/threads`

Dashboard showing all active development threads grouped by project and branch. Shows status, open action items, last activity, and suggested focus areas.

```
/threads                               # show active threads
/threads --project MyApp               # filter to one project
/threads --all                         # include completed/stale threads
/threads --stale                       # show only stale threads
```

### `/briefing`

Deep context briefing for a specific thread. Shows what the thread is about, your previous intentions, key decisions, current status, and open items. Use when returning to a thread after a break.

```
/briefing                              # briefing for current branch
/briefing add-light-mode               # briefing for a specific branch
/briefing --project MyApp main         # briefing for a specific project/branch
```

### `/suggest-actions`

Analyzes session history and current git state to suggest concrete next steps, surface unresolved questions, and identify blockers. Uses the thread-tracker agent for intelligent analysis.

```
/suggest-actions                       # suggestions for current branch
/suggest-actions add-light-mode        # suggestions for a specific branch
/suggest-actions --project MyApp main  # suggestions for a specific project/branch
```

## Agents

Both skill groups use specialized agents that run as subagents:

### Review Agents

- **code-reviewer** — Confidence-scored code review against project guidelines and bug detection (only reports issues with confidence >= 80)
- **pr-test-analyzer** — Test coverage analysis with criticality ratings, focused on behavioral coverage over line coverage
- **silent-failure-hunter** — Error handling audit with zero tolerance for silent failures and inadequate error messages

### Thread Tracking Agent

- **thread-tracker** — Session analysis agent that extracts structured information (summaries, decisions, action items, topics) from conversation logs. Used by `/summarize-session` and `/suggest-actions`.

These agents are defined in the `agents/` directory. Copy them to `~/.claude/agents/` (step 3 above) to enable full functionality.

Without the review agents installed, review skills fall back to the built-in `/review` command. Without the thread-tracker agent, `/summarize-session` and `/suggest-actions` will report an error.

## Obsidian Vault Structure

```
~/ObsidianVaults/ClaudeCode/
├── sessions/
│   ├── raw/                        # Full conversation captures
│   │   └── <project>/
│   │       └── YYYY-MM-DD-<short-id>.md
│   └── summaries/                  # Structured summaries
│       └── <project>/
│           └── YYYY-MM-DD-<short-id>.md
└── threads/                        # Per-branch thread overviews
    └── <project>/
        └── <branch>.md
```

Each file uses YAML frontmatter compatible with Obsidian's Dataview plugin and wikilinks for cross-referencing between raw sessions, summaries, and thread overviews.
