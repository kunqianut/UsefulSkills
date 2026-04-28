---
name: capture-session
argument-hint: "[session-id] [--project <name>] [--previous]"
disable-model-invocation: true
---

# Capture Session: Raw Conversation to Obsidian

Captures a Claude Code session's raw conversation data from JSONL and writes it as a structured markdown file to your Obsidian vault.

## Configuration Defaults

```
VAULT_PATH = ~/ObsidianVaults/ClaudeCode
```

You may customize VAULT_PATH to point to your Obsidian vault directory.

## Argument Parsing

Parse `$ARGUMENTS` as follows:
- If arguments contain `--previous`, select the second-most-recent session (useful when auto-triggered at session start). Remove the flag from remaining arguments.
- If arguments contain `--project <name>`, use that as the project name override. Remove the flag and value from remaining arguments.
- If any remaining argument looks like a UUID (contains dashes, 32+ hex chars), treat it as a session ID.
- If no session ID is provided, default to the most recently modified JSONL file for the current project.
- If no `--project` is provided, derive the project from the current working directory.

Examples:
- `/capture-session` -> capture most recent session for current project
- `/capture-session --previous` -> capture the second-most-recent session
- `/capture-session 9cae11ae-71e2-4a41-9bee-8a3b5e2b1170` -> capture specific session
- `/capture-session --project MyApp` -> capture most recent session for MyApp
- `/capture-session --previous --project MyApp` -> capture previous session for MyApp

## Workflow

### Phase 1: LOCATE

Find the JSONL session file.

#### 1a. Determine project directory

The Claude Code projects directory is `~/.claude/projects/`. Each project subdirectory is named by encoding the absolute working directory path: replace every `/` with `-`.

If `--project` was specified, search all project directories for one whose decoded path ends with the given project name (case-insensitive). If multiple match, list them and ask the user to be more specific.

If no `--project`, encode the current working directory:
```bash
ENCODED_CWD=$(pwd | sed 's|/|-|g')
PROJ_DIR="$HOME/.claude/projects/${ENCODED_CWD}"
```

If the project directory does not exist, report an error listing available project directories.

#### 1b. Find the JSONL file

If a session ID was provided:
```bash
JSONL_PATH="${PROJ_DIR}/${SESSION_ID}.jsonl"
```

If `--previous` was set:
```bash
JSONL_PATH=$(ls -t "${PROJ_DIR}"/*.jsonl 2>/dev/null | head -2 | tail -1)
```

Otherwise (most recent):
```bash
JSONL_PATH=$(ls -t "${PROJ_DIR}"/*.jsonl 2>/dev/null | head -1)
```

If no JSONL file is found, report the error and list all available sessions in the project directory with their modification times.

### Phase 2: EXTRACT

Extract conversation data from the JSONL file using a streaming python3 script. This handles large files (up to 26MB+) safely.

Set the JSONL path as an environment variable and run via the Bash tool. Replace `<JSONL_PATH>` with the actual path found in Phase 1:

```bash
export _CAPTURE_JSONL_PATH="<JSONL_PATH>" && python3 << 'PYEOF'
import json, sys, os
from collections import Counter
from datetime import datetime

fpath = os.environ.get("_CAPTURE_JSONL_PATH", "")
if not fpath:
    print("Error: _CAPTURE_JSONL_PATH not set", file=sys.stderr)
    sys.exit(1)

skipped = 0
records = []
try:
    with open(fpath) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError:
                skipped += 1
except OSError as e:
    print(f"Error: could not read {fpath}: {e}", file=sys.stderr)
    sys.exit(1)

if skipped > 0:
    print(f"Warning: {skipped} malformed lines skipped in {fpath}", file=sys.stderr)

session_id = ""
timestamps = []
branches = Counter()
cwd_val = ""
project_name = ""
custom_title = ""
agent_name = ""
pr_links = []

for r in records:
    if r.get("sessionId") and not session_id:
        session_id = r["sessionId"]
    if r.get("timestamp"):
        timestamps.append(r["timestamp"])
    if r.get("gitBranch"):
        branches[r["gitBranch"]] += 1
    if r.get("cwd") and not cwd_val:
        cwd_val = r["cwd"]
    if r.get("type") == "custom-title":
        custom_title = r.get("customTitle", "")
    if r.get("type") == "agent-name":
        agent_name = r.get("agentName", "")
    if r.get("type") == "pr-link":
        pr_links.append({"url": r.get("prUrl", ""), "number": r.get("prNumber", "")})

project_name = os.path.basename(cwd_val) if cwd_val else "unknown"
primary_branch = branches.most_common(1)[0][0] if branches else "unknown"

turns = []
for r in records:
    if r.get("type") == "user":
        content = (r.get("message") or {}).get("content", "")
        if isinstance(content, str) and content.strip():
            turns.append({"role": "user", "ts": r.get("timestamp", ""), "text": content})
    elif r.get("type") == "assistant":
        texts = []
        tool_calls = []
        for c in (r.get("message") or {}).get("content", []):
            if c.get("type") == "text" and c.get("text", "").strip():
                texts.append(c["text"])
            elif c.get("type") == "tool_use":
                tc = {"name": c.get("name", ""), "input_summary": ""}
                inp = c.get("input") or {}
                if c.get("name") == "Bash":
                    tc["input_summary"] = inp.get("command", "")[:200]
                elif c.get("name") in ("Read", "Write", "Edit"):
                    tc["input_summary"] = inp.get("file_path", "")
                elif c.get("name") == "Agent":
                    tc["input_summary"] = inp.get("description", "")[:200]
                else:
                    keys = list(inp.keys())[:3]
                    tc["input_summary"] = ", ".join(f"{k}={str(inp[k])[:50]}" for k in keys)
                tool_calls.append(tc)
        if texts or tool_calls:
            turns.append({
                "role": "assistant",
                "ts": r.get("timestamp", ""),
                "texts": texts,
                "tool_calls": tool_calls
            })

tool_counts = Counter()
for r in records:
    if r.get("type") == "assistant":
        for c in (r.get("message") or {}).get("content", []):
            if c.get("type") == "tool_use":
                tool_counts[c.get("name", "unknown")] += 1

start_time = min(timestamps) if timestamps else ""
end_time = max(timestamps) if timestamps else ""

duration_minutes = 0
if start_time and end_time:
    try:
        t1 = datetime.fromisoformat(start_time.replace("Z", "+00:00"))
        t2 = datetime.fromisoformat(end_time.replace("Z", "+00:00"))
        duration_minutes = int((t2 - t1).total_seconds() / 60)
    except (ValueError, TypeError):
        pass

result = {
    "session_id": session_id,
    "project": project_name,
    "cwd": cwd_val,
    "primary_branch": primary_branch,
    "all_branches": dict(branches),
    "start_time": start_time,
    "end_time": end_time,
    "date": start_time[:10] if start_time else "",
    "duration_minutes": duration_minutes,
    "custom_title": custom_title,
    "agent_name": agent_name,
    "turns": turns,
    "tool_stats": dict(tool_counts),
    "pr_links": pr_links,
    "total_turns": len(turns)
}

print(json.dumps(result, indent=2))
PYEOF
```

Store the output JSON for use in Phase 3.

### Phase 3: FORMAT

Convert the extracted JSON into a markdown file.

#### 3a. Build YAML frontmatter

```yaml
---
date: <date from extraction>
project: <project name>
session_id: <full UUID>
branch: <primary_branch>
all_branches: [<all branches seen>]
type: session-raw
tags: [claude-code, <project name>]
start_time: <ISO timestamp>
end_time: <ISO timestamp>
duration_minutes: <computed>
title: <custom_title or agent_name or "Untitled">
tool_stats:
  <tool_name>: <count>
---
```

#### 3b. Build markdown body

```markdown
# Session: <project> / <branch> / <date>

## Metadata
- **Project**: <project> (`<cwd>`)
- **Branch**: <primary_branch>
- **Duration**: <start_time> → <end_time> (~N minutes)
- **Session ID**: `<session_id>`
- **Title**: <custom_title or agent_name>
<if pr_links>- **PR Links**: <pr URLs></if>

## Conversation

### Turn 1 — <timestamp>

**User:**
<user content>

---

**Claude:**
<assistant text content>

**Tool Calls:**
- `<tool_name>`: `<input_summary>`

---

### Turn 2 — <timestamp>
...

## Tool Usage Summary

| Tool | Count |
|------|-------|
| <tool> | <count> |
| ... | ... |
```

Format each turn sequentially. For user turns, include the full message text. For assistant turns, include all text blocks and a summary of tool calls.

### Phase 4: WRITE

#### 4a. Create vault directories

```bash
VAULT="${VAULT_PATH/#\~/$HOME}"
PROJECT="<project_name>"
mkdir -p "${VAULT}/sessions/raw/${PROJECT}"
```

#### 4b. Write the file

Write the formatted markdown to:
```
${VAULT}/sessions/raw/${PROJECT}/${DATE}-${SHORT_ID}.md
```

Where `SHORT_ID` is the first 8 characters of the session UUID.

#### 4c. Confirm

Print a confirmation message:
```
Session captured: <file_path>
  Project: <project>
  Branch: <branch>
  Duration: ~N minutes
  Turns: N conversation turns
  Tools used: <tool summary>

Run /summarize-session to generate a structured summary.
```

## Error Handling

- **Project directory not found**: List available project directories under `~/.claude/projects/` and suggest the correct one
- **No JSONL files found**: Report that no sessions exist for this project
- **JSONL file empty or corrupt**: Report partial extraction with what was recovered
- **Vault directory not writable**: Report the exact permission error
- **No previous session (--previous with only 1 session)**: Report clearly, suggest using the most recent instead
- **Multiple projects match --project name**: List all matches and ask user to be more specific

## Important Notes

- This skill does NOT invoke any LLM agent — it is pure data transformation using python3 via Bash.
- Large session files (26MB+) are handled via line-by-line streaming in python3.
- The raw capture preserves all conversation content for future knowledge base construction.
- Tool call inputs are truncated to keep the file readable. Full tool results are not included by default.
- The vault path can be customized in the Configuration Defaults section above.
- Run `/summarize-session` after capture to generate a structured summary with extracted decisions and action items.
