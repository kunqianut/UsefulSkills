---
name: briefing
argument-hint: "[branch-name] [--project <name>]"
disable-model-invocation: true
---

# Briefing: Thread Context Loader

Provides a deep context briefing for a specific development thread — what it's about, what you intended, decisions made, and where things stand. Use this when returning to a thread after a break.

## Configuration Defaults

```
VAULT_PATH = ~/ObsidianVaults/ClaudeCode
MAX_SESSIONS_TO_READ = 5
```

## Argument Parsing

Parse `$ARGUMENTS` as follows:
- If arguments contain `--project <name>`, use that as the project name. Remove the flag and value.
- If any remaining argument is provided, treat it as the branch name.
- If no branch name is provided, detect the current branch via `git branch --show-current`.
- If no `--project` is provided, use `basename $(pwd)` as the project name.

Examples:
- `/briefing` -> briefing for current branch in current project
- `/briefing add-light-mode` -> briefing for the add-light-mode branch
- `/briefing --project MyApp main` -> briefing for main branch in MyApp
- `/briefing --project MyApp` -> briefing for current branch in MyApp

## Workflow

### Phase 1: GATHER

#### 1a. Determine project and branch

```bash
BRANCH="${BRANCH_ARG:-$(git branch --show-current 2>/dev/null || echo 'unknown')}"
PROJECT="${PROJECT_ARG:-$(basename $(pwd))}"
VAULT="${VAULT_PATH/#\~/$HOME}"
```

#### 1b. Read thread file

Check for the thread file at `${VAULT}/threads/${PROJECT}/${BRANCH}.md`.

If it exists, read it to get the list of session links and thread-level metadata.

If it doesn't exist, fall back to scanning `${VAULT}/sessions/summaries/${PROJECT}/` for files whose frontmatter `branch` field matches.

#### 1c. Read session summaries

Find all session summary files for this project+branch combination. Sort by date (most recent first). Read up to MAX_SESSIONS_TO_READ of them.

For each summary, extract from frontmatter and body:
- date
- status
- summary text (from "## What Happened")
- user intent (from "## User Intent")
- key decisions (from "## Key Decisions")
- action items with status (from "## Action Items")
- open questions (from "## Open Questions")
- files touched (from "## Files Touched")

If no summaries are found, check if raw sessions exist. If raw sessions exist but no summaries, suggest running `/summarize-session`. If neither exists, report that no data is available for this thread.

### Phase 2: SYNTHESIZE AND DISPLAY

Present a structured briefing compiled from all gathered session summaries.

```markdown
## Thread Briefing: <project> / <branch>

**Last active**: <date> (<N days ago>)
**Status**: <most recent status>
**Sessions captured**: <count>

### What This Thread Is About
<Synthesize from the earliest sessions' summaries and user intents. 2-3 sentences describing the overall goal and scope of this thread.>

### Your Previous Intentions
<From user_intent fields across sessions. What were you trying to achieve? What was your approach?>

### Key Decisions Made
<Chronological list of all decisions across sessions>
- <date>: <decision 1>
- <date>: <decision 2>
- ...

### Where Things Stand Now
<Most recent session's summary — what was the last thing you worked on?>

### Open Action Items
<Aggregated from all sessions, deduplicated>
- [ ] <item 1> (from <date>)
- [ ] <item 2> (from <date>)
- [x] <completed item> (from <date>)

### Open Questions
<Aggregated from all sessions>
- <question 1> (raised <date>)
- <question 2> (raised <date>)

### Files Involved
<Union of all files_touched across sessions>
- `<path/to/file1>`
- `<path/to/file2>`

### Session History
<Reverse chronological list>
- <date>: <one-line summary> ([[session link]])
- <date>: <one-line summary> ([[session link]])
```

For the "What This Thread Is About" section, read the earliest session summaries to understand the original goal, then trace how it evolved through subsequent sessions.

For "Your Previous Intentions", focus on the user_intent fields to reconstruct what the user was thinking and planning.

## Error Handling

- **Branch not found in vault**: Report that no sessions have been captured for this branch. List available branches for the project.
- **Thread file missing but summaries exist**: Build the briefing from summaries alone (thread file is optional).
- **No summaries, only raw sessions**: Suggest running `/summarize-session` to generate summaries first.
- **No data at all**: Report clearly and suggest starting with `/capture-session`.
- **Cannot detect current branch**: Ask the user to specify the branch name.

## Important Notes

- This skill does not invoke any agent — it reads and synthesizes vault data directly.
- The quality of the briefing depends on having run `/capture-session` and `/summarize-session` for prior sessions.
- "Your Previous Intentions" is the most valuable section for context recovery — it captures what you were thinking, not just what you did.
- Use `/suggest-actions` after reviewing the briefing to get concrete next steps.
- Session history links use Obsidian wikilink format for easy navigation in the vault.
