---
name: summarize-session
argument-hint: "[session-id] [--project <name>] [--fresh]"
disable-model-invocation: true
---

# Summarize Session: Incremental Structured Summary with Thread Update

Generates or updates a structured summary from a captured raw session using the thread-tracker agent. Supports incremental updates — if a summary already exists, only new conversation turns are analyzed and the summary is updated in place.

## Configuration Defaults

```
VAULT_PATH = ~/ObsidianVaults/ClaudeCode
AUTO_UPDATE_THREAD = true
```

## Argument Parsing

Parse `$ARGUMENTS` as follows:
- If arguments contain `--project <name>`, use that as the project name filter. Remove the flag and value from remaining arguments.
- If arguments contain `--previous`, select the second-most-recent captured raw session file in the vault for the current project. Remove the flag.
- If arguments contain `--fresh`, force a full re-summarization even if an existing summary exists (ignore incremental logic). Remove the flag.
- If any remaining argument looks like a UUID (contains dashes, 32+ hex chars), treat it as a session ID to look up.
- If no session ID is provided, default to the most recently captured raw session file in the vault for the current project.

Examples:
- `/summarize-session` -> summarize (or incrementally update) most recent captured session
- `/summarize-session --previous` -> summarize the previously captured session
- `/summarize-session --fresh` -> force full re-summarization from scratch
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

### Phase 2: CHECK EXISTING SUMMARY

Check if a summary already exists at `${VAULT}/sessions/summaries/${PROJECT}/` with the same filename.

#### 2a. If summary exists AND `--fresh` was NOT set (incremental mode)

Read the existing summary file.

First, check if the frontmatter contains `parse_error: true`. If so, warn the user: "Existing summary has a parse error from a previous run. Consider using `--fresh` to regenerate from scratch." Then fall through to fresh mode (2b) unless the user confirms they want to proceed incrementally.

Extract the `summarized_through` timestamp from the YAML frontmatter.

If `summarized_through` is missing or empty (e.g., an older summary created before this field was added), warn the user: "Existing summary has no `summarized_through` timestamp. Falling back to full re-analysis." Then fall through to fresh mode (2b).

Parse the raw session markdown to find all conversation turns. Each turn has a timestamp in its heading (`### Turn N — <timestamp>`). Collect only turns whose timestamp is AFTER the `summarized_through` value (string comparison works for ISO 8601 UTC timestamps ending in Z).

If no new turns exist after `summarized_through`:
- Report: "Summary is up to date (last summarized through <timestamp>). Use `--fresh` to force re-summarization."
- Stop here.

If new turns exist, collect them as the `new_turns` content for Phase 3.

Also read the existing summary's body content (everything after the YAML frontmatter) for use as context in Phase 3.

#### 2b. If no summary exists OR `--fresh` was set (fresh mode)

Proceed with the full raw session content. No existing summary context.

### Phase 3: ANALYZE

Spawn the `thread-tracker` agent to analyze the session content.

Use the Agent tool with:
- `subagent_type`: `thread-tracker`

#### 3a. Fresh summarization prompt (no existing summary)

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

#### 3b. Incremental update prompt (existing summary + new turns)

```
Here is the EXISTING summary for this Claude Code session:

<existing_summary>
[INSERT EXISTING SUMMARY BODY HERE]
</existing_summary>

Here are NEW conversation turns that happened AFTER the last summarization:

<new_turns>
[INSERT ONLY THE NEW TURNS HERE]
</new_turns>

Update the summary by:
1. Revising the "summary" to include the new work
2. Adding any new decisions to "key_decisions" (keep existing ones)
3. Updating "action_items" — mark completed ones as "done", add new ones as "open"
4. Adding new "open_questions", removing any that were resolved in the new turns
5. Adding new "files_touched" (merge with existing, no duplicates)
6. Updating "topics" if new topics emerged
7. Updating "status" based on the latest state
8. Updating "user_intent" if it evolved

Return the COMPLETE updated JSON (all fields, not just changes).

<json_fields>
- summary, key_decisions, action_items (with text+status), open_questions, files_touched, topics, status, user_intent
</json_fields>
```

Parse the JSON from the agent's response. If the agent returns malformed JSON, extract what fields you can, set `parse_error: true` in the frontmatter, and include a warning at the top of the body.

### Phase 4: FORMAT AND WRITE SUMMARY

#### 4a. Build the summary markdown

Extract metadata from the raw session's YAML frontmatter (date, project, session_id, branch).

Determine the `summarized_through` timestamp: find the latest turn timestamp in the raw session markdown.

```yaml
---
date: <date>
project: <project>
session_id: <session_id>
branch: <branch>
type: session-summary
tags: [<extracted topics from agent>]
status: <status from agent>
last_summarized_at: <current ISO timestamp>
summarized_through: <latest turn timestamp in raw session>
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
**Last summarized**: <last_summarized_at>
**Covers through**: <summarized_through>

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

#### 4b. Write the summary file

```bash
mkdir -p "${VAULT}/sessions/summaries/${PROJECT}"
```

Write to `${VAULT}/sessions/summaries/${PROJECT}/<same-filename-as-raw>.md`.

If overwriting an existing summary (incremental or --fresh), overwrite without prompting.

### Phase 5: UPDATE THREAD

If `AUTO_UPDATE_THREAD = true`:

#### 5a. Read or create thread file

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

#### 5b. Update thread file

Check if a session entry for this session already exists in the `## Sessions` section (matching the wikilink path). If it does, update that line with the new summary. If not, append a new line.

Update the frontmatter:
- `last_updated` to the current date
- `status` to the latest session's status
- `tags` to the union of existing tags and new session's topics

#### 5c. Confirm

Print:
```
Summary written: <summary_file_path>
  Mode: <fresh|incremental>
  Summarized through: <timestamp>
Thread updated: <thread_file_path>

Status: <status>
Key decisions: N
Open action items: N
Topics: <topic list>
```

## Error Handling

- **Raw session not found**: Guide user to run `/capture-session` first
- **Agent returns malformed JSON**: Extract what fields are parseable, set `parse_error: true` in frontmatter, include bold warning at top of body, fill remaining with "unknown" or empty lists
- **Thread file has unexpected format**: Append the session entry at the end, warn the user
- **Vault path does not exist**: Create it, or report if permissions prevent creation
- **No new turns since last summarization**: Report "Summary is up to date" with the `summarized_through` timestamp, suggest `--fresh` to force

## Important Notes

- This skill depends on `/capture-session` having been run first — it reads from the vault, not from JSONL directly.
- The thread-tracker agent is spawned to do the analysis. If the agent is not installed, report the error and suggest copying `agents/thread-tracker.md` to `~/.claude/agents/`.
- **Incremental mode** is the default: if a summary exists, only new turns are analyzed. Use `--fresh` to force a full re-analysis.
- The `summarized_through` timestamp tracks exactly which conversation turns have been included in the summary. This enables reliable incremental updates even for long-running sessions that are captured multiple times.
- Thread files accumulate session links over time. When a session is re-summarized incrementally, the existing thread entry is updated in place rather than duplicated.
- Obsidian wikilinks (`[[...]]`) enable navigation between raw sessions, summaries, and thread overviews.
