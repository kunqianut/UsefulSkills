---
name: summarize-session
argument-hint: "[session-id] [--project <name>]"
disable-model-invocation: true
---

# Summarize Session: Structured Summary with Thread Update

Generates a structured summary from a captured raw session using the thread-tracker agent, then updates the thread file for that project+branch.

## Configuration Defaults

```
VAULT_PATH = ~/ObsidianVaults/ClaudeCode
AUTO_UPDATE_THREAD = true
```

## Argument Parsing

Parse `$ARGUMENTS` as follows:
- If arguments contain `--project <name>`, use that as the project name filter. Remove the flag and value from remaining arguments.
- If arguments contain `--previous`, select the second-most-recent captured raw session file in the vault for the current project. Remove the flag.
- If any remaining argument looks like a UUID (contains dashes, 32+ hex chars), treat it as a session ID to look up.
- If no session ID is provided, default to the most recently captured raw session file in the vault for the current project.

Examples:
- `/summarize-session` -> summarize most recent captured session for current project
- `/summarize-session --previous` -> summarize the previously captured session
- `/summarize-session 9cae11ae-71e2-4a41-9bee-8a3b5e2b1170` -> summarize specific session
- `/summarize-session --project MyApp` -> summarize most recent captured session for MyApp

## Workflow

### Phase 1: LOCATE RAW SESSION

#### 1a. Find the raw session markdown

Expand the vault path and search for the raw session file:

```bash
VAULT="${VAULT_PATH/#\~/$HOME}"
PROJECT="<project_name>"  # from --project or basename of current directory
```

If a session ID was provided, search for a file matching `*-<first-8-chars-of-id>.md` in `${VAULT}/sessions/raw/${PROJECT}/`.

If `--previous` was set, list files in `${VAULT}/sessions/raw/${PROJECT}/` sorted by modification time and pick the second most recent.

Otherwise, pick the most recently modified file in `${VAULT}/sessions/raw/${PROJECT}/`.

#### 1b. Validate

If no raw session file is found:
- Check if the session exists as a JSONL file in `~/.claude/projects/`
- If yes, tell the user: "Session exists but hasn't been captured yet. Run `/capture-session` first."
- If no, report that no session was found

Read the raw session file content.

#### 1c. Check for existing summary

Check if a summary already exists at `${VAULT}/sessions/summaries/${PROJECT}/` with the same filename. If it does, ask the user whether to overwrite or skip.

### Phase 2: ANALYZE

Spawn the `thread-tracker` agent to analyze the raw session content.

Use the Agent tool with:
- `subagent_type`: `thread-tracker`
- `prompt`: Include the full raw session markdown content and request structured extraction:

```
Analyze this Claude Code session and extract structured information.

Return a JSON code block with these fields:
- summary: 2-3 sentence description of what was accomplished
- key_decisions: list of decisions made (include rationale)
- action_items: list of objects with "text" and "status" ("open" or "done")
- open_questions: list of unresolved issues
- files_touched: list of file paths from tool calls
- topics: 2-5 keyword tags (lowercase, hyphenated)
- status: one of "completed", "in-progress", "blocked", "stale"
- user_intent: what the user was trying to achieve

<session_content>
[INSERT FULL RAW SESSION MARKDOWN HERE]
</session_content>
```

Parse the JSON from the agent's response. If the agent returns malformed JSON, extract what fields you can and note the parsing issue.

### Phase 3: FORMAT AND WRITE SUMMARY

#### 3a. Build the summary markdown

Extract metadata from the raw session's YAML frontmatter (date, project, session_id, branch).

```yaml
---
date: <date>
project: <project>
session_id: <session_id>
branch: <branch>
type: session-summary
tags: [<extracted topics from agent>]
status: <status from agent>
decisions:
  - "<decision 1>"
  - "<decision 2>"
action_items:
  - text: "<item>"
    status: open
open_questions:
  - "<question>"
files_touched:
  - "<path>"
raw_session: "[[sessions/raw/<project>/<filename>]]"
---

# Summary: <project> / <branch> / <date>

**Status**: <status>
**Session**: [[sessions/raw/<project>/<filename>]]

## What Happened
<summary from agent>

## User Intent
<user_intent from agent>

## Key Decisions
- <decision 1>
- <decision 2>

## Action Items
- [ ] <open item 1>
- [x] <completed item>

## Open Questions
- <question 1>

## Files Touched
- `<path/to/file>`

## Topics
<topic1>, <topic2>, ...
```

#### 3b. Write the summary file

```bash
mkdir -p "${VAULT}/sessions/summaries/${PROJECT}"
```

Write to `${VAULT}/sessions/summaries/${PROJECT}/<same-filename-as-raw>.md`.

### Phase 4: UPDATE THREAD

If `AUTO_UPDATE_THREAD = true`:

#### 4a. Read or create thread file

The thread file lives at `${VAULT}/threads/${PROJECT}/<branch>.md`.

```bash
mkdir -p "${VAULT}/threads/${PROJECT}"
```

If the thread file does not exist, create it with this template:

```yaml
---
project: <project>
branch: <branch>
type: thread
created: <date>
last_updated: <date>
status: <latest status>
tags: [<union of all session topics>]
---

# Thread: <project> / <branch>

## Sessions
- [[sessions/summaries/<project>/<filename>]] — <date>: <one-line summary>
```

If the thread file already exists, read it.

#### 4b. Append session entry

Add a new line to the `## Sessions` section:
```
- [[sessions/summaries/<project>/<filename>]] — <date>: <one-line summary>
```

Update the frontmatter:
- `last_updated` to the current date
- `status` to the latest session's status
- `tags` to the union of existing tags and new session's topics

#### 4c. Confirm

Print:
```
Summary written: <summary_file_path>
Thread updated: <thread_file_path>

Status: <status>
Key decisions: N
Open action items: N
Topics: <topic list>
```

## Error Handling

- **Raw session not found**: Guide user to run `/capture-session` first
- **Agent returns malformed JSON**: Extract what fields are parseable, fill remaining with "unknown" or empty lists, note the issue in the output
- **Thread file has unexpected format**: Append the session entry at the end of the file rather than failing
- **Summary already exists**: Ask user whether to overwrite or skip
- **Vault path does not exist**: Create it, or report if permissions prevent creation

## Important Notes

- This skill depends on `/capture-session` having been run first — it reads from the vault, not from JSONL directly.
- The thread-tracker agent is spawned to do the analysis. If the agent is not installed, report the error and suggest copying `agents/thread-tracker.md` to `~/.claude/agents/`.
- Thread files accumulate session links over time, creating a longitudinal record of work on each branch.
- Obsidian wikilinks (`[[...]]`) enable navigation between raw sessions, summaries, and thread overviews.
- The summary file uses the same filename as the raw session file for easy correlation.
