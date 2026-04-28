#!/bin/bash
# Nightly cron script: capture and summarize active Claude Code sessions.
# Scans all project directories for JSONL files modified in the last 24 hours,
# captures any that are new or have new content, then summarizes via claude -p.
#
# Install:
#   cp hooks/nightly-capture-and-summarize.sh ~/.claude/hooks/
#   chmod +x ~/.claude/hooks/nightly-capture-and-summarize.sh
#   crontab -e  # add the following line:
#   0 3 * * * bash ~/.claude/hooks/nightly-capture-and-summarize.sh >> ~/ObsidianVaults/ClaudeCode/_logs/nightly-cron.log 2>&1

VAULT="${CLAUDE_VAULT_PATH:-$HOME/ObsidianVaults/ClaudeCode}"
PROJECTS_DIR="$HOME/.claude/projects"
LOG_DIR="${VAULT}/_logs"
TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

mkdir -p "$LOG_DIR" || { echo "Error: could not create log dir $LOG_DIR" >&2; exit 1; }

echo "========================================="
echo "Nightly capture started: $TIMESTAMP"
echo "========================================="

if ! command -v python3 &>/dev/null; then
    echo "Error: python3 not found." >&2
    exit 1
fi

if [ ! -d "$PROJECTS_DIR" ]; then
    echo "No projects directory found at $PROJECTS_DIR"
    exit 0
fi

CAPTURED_COUNT=0
SUMMARIZED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0

for proj_dir in "$PROJECTS_DIR"/*/; do
    [ ! -d "$proj_dir" ] && continue

    proj_encoded=$(basename "$proj_dir")

    while IFS= read -r jsonl_file; do
        [ -z "$jsonl_file" ] && continue

        session_id=$(basename "$jsonl_file" .jsonl)
        short_id="${session_id:0:8}"

        # Skip files held open by a running Claude process (active sessions)
        if lsof "$jsonl_file" 2>/dev/null | grep -qi "claude"; then
            echo "  Skipping active session: $short_id"
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            continue
        fi

        # Decode project name from the first record's cwd
        export _PROBE_JSONL="$jsonl_file"
        project_name=$(python3 -c "
import json, os
fpath = os.environ['_PROBE_JSONL']
with open(fpath) as f:
    for line in f:
        line = line.strip()
        if not line: continue
        try:
            r = json.loads(line)
            if r.get('cwd'):
                print(os.path.basename(r['cwd']))
                break
        except json.JSONDecodeError: pass
" 2>/dev/null)
        unset _PROBE_JSONL

        [ -z "$project_name" ] && project_name="unknown"

        raw_dir="${VAULT}/sessions/raw/${project_name}"
        existing=$(find "$raw_dir" -name "*-${short_id}.md" 2>/dev/null | head -1)

        needs_capture=false
        if [ -z "$existing" ]; then
            needs_capture=true
        elif [ "$jsonl_file" -nt "$existing" ]; then
            needs_capture=true
        fi

        if [ "$needs_capture" = false ]; then
            SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
            continue
        fi

        echo ""
        echo "Capturing: $project_name ($short_id...)"

        export _CAPTURE_JSONL_PATH="$jsonl_file"
        export _CAPTURE_VAULT="$VAULT"

        CAPTURE_RESULT=$(python3 << 'PYEOF'
import json, os, sys
from collections import Counter
from datetime import datetime

fpath = os.environ["_CAPTURE_JSONL_PATH"]
vault = os.environ["_CAPTURE_VAULT"]

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
    sys.stderr.write(f"Error: could not read {fpath}: {e}\n")
    sys.exit(1)

if skipped > 0:
    sys.stderr.write(f"Warning: {skipped} malformed lines skipped in {fpath}\n")

if not records:
    sys.stderr.write(f"No valid records in {fpath}\n")
    sys.exit(1)

session_id = ""
timestamps = []
branches = Counter()
cwd_val = ""
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
    if r.get("type") == "pr-link" and r.get("prUrl"):
        pr_links.append(r["prUrl"])

project_name = os.path.basename(cwd_val) if cwd_val else "unknown"
primary_branch = branches.most_common(1)[0][0] if branches else "unknown"

def parse_ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None

if timestamps:
    parsed = [(ts, parse_ts(ts)) for ts in timestamps]
    valid = [(ts, dt) for ts, dt in parsed if dt is not None]
    if valid:
        valid.sort(key=lambda x: x[1])
        start_time, end_time = valid[0][0], valid[-1][0]
    else:
        start_time, end_time = timestamps[0], timestamps[-1]
else:
    start_time, end_time = "", ""

date = start_time[:10] if start_time else datetime.now().strftime("%Y-%m-%d")
title = custom_title or agent_name or "Untitled"

duration_minutes = 0
if start_time and end_time:
    try:
        t1 = parse_ts(start_time)
        t2 = parse_ts(end_time)
        if t1 and t2:
            duration_minutes = int((t2 - t1).total_seconds() / 60)
    except (ValueError, TypeError) as e:
        sys.stderr.write(f"Warning: could not parse timestamps for duration: {e}\n")
        duration_minutes = 0

lines = []
lines.append("---")
lines.append(f"date: {date}")
lines.append(f"project: {json.dumps(project_name)}")
lines.append(f"session_id: {json.dumps(session_id)}")
lines.append(f"branch: {json.dumps(primary_branch)}")
lines.append(f"all_branches: {json.dumps(sorted(branches.keys()))}")
lines.append("type: session-raw")
lines.append(f"tags: {json.dumps(['claude-code', project_name])}")
lines.append(f"start_time: {json.dumps(start_time)}")
lines.append(f"end_time: {json.dumps(end_time)}")
lines.append(f"duration_minutes: {duration_minutes}")
lines.append(f"title: {json.dumps(title)}")
lines.append("---")
lines.append("")
lines.append(f"# Session: {project_name} / {primary_branch} / {date}")
lines.append("")
lines.append("## Metadata")
lines.append(f"- **Project**: {project_name} (`{cwd_val}`)")
lines.append(f"- **Branch**: {primary_branch}")
lines.append(f"- **Duration**: {start_time} → {end_time} (~{duration_minutes} minutes)")
lines.append(f"- **Session ID**: `{session_id}`")
lines.append(f"- **Title**: {title}")
if pr_links:
    lines.append(f"- **PR Links**: {', '.join(pr_links)}")
lines.append("")
lines.append("## Conversation")
lines.append("")

turn_num = 0
for r in records:
    if r.get("type") == "user":
        content = (r.get("message") or {}).get("content", "")
        if isinstance(content, str) and content.strip():
            turn_num += 1
            ts = r.get("timestamp", "")
            lines.append(f"### Turn {turn_num} — {ts}")
            lines.append("")
            lines.append("**User:**")
            lines.append(content.strip())
            lines.append("")
        elif isinstance(content, list):
            text_parts = [c.get("text", "") for c in content if isinstance(c, dict) and c.get("type") == "text" and c.get("text", "").strip()]
            if text_parts:
                turn_num += 1
                ts = r.get("timestamp", "")
                lines.append(f"### Turn {turn_num} — {ts}")
                lines.append("")
                lines.append("**User:**")
                lines.append("\n".join(text_parts))
                lines.append("")
    elif r.get("type") == "assistant":
        texts = []
        tool_calls = []
        for c in (r.get("message") or {}).get("content", []):
            if not isinstance(c, dict):
                continue
            if c.get("type") == "text" and c.get("text", "").strip():
                texts.append(c["text"].strip())
            elif c.get("type") == "tool_use":
                name = c.get("name", "")
                inp = c.get("input") or {}
                if name == "Bash":
                    summary = inp.get("command", "")[:150]
                elif name in ("Read", "Write", "Edit"):
                    summary = inp.get("file_path", "")[:150]
                elif name == "Agent":
                    summary = inp.get("description", "")[:150]
                else:
                    keys = list(inp.keys())[:3]
                    summary = ", ".join(f"{k}={str(inp[k])[:50]}" for k in keys)
                tool_calls.append(f"- `{name}`: `{summary}`")
        if texts or tool_calls:
            lines.append("**Claude:**")
            for t in texts:
                lines.append(t)
                lines.append("")
            if tool_calls:
                lines.append("**Tool Calls:**")
                lines.extend(tool_calls)
                lines.append("")
            lines.append("---")
            lines.append("")

tool_counts = Counter()
for r in records:
    if r.get("type") == "assistant":
        for c in (r.get("message") or {}).get("content", []):
            if isinstance(c, dict) and c.get("type") == "tool_use":
                tool_counts[c.get("name", "unknown")] += 1

if tool_counts:
    lines.append("## Tool Usage Summary")
    lines.append("")
    lines.append("| Tool | Count |")
    lines.append("|------|-------|")
    for tool, count in tool_counts.most_common():
        lines.append(f"| {tool} | {count} |")
    lines.append("")

output = "\n".join(lines)

out_dir = os.path.join(vault, "sessions", "raw", project_name)
try:
    os.makedirs(out_dir, exist_ok=True)
    short_id = (session_id or os.path.basename(fpath).replace(".jsonl", ""))[:8]
    out_path = os.path.join(out_dir, f"{date}-{short_id}.md")
    with open(out_path, "w") as f:
        f.write(output)
except OSError as e:
    sys.stderr.write(f"Error writing to {out_dir}: {e}\n")
    sys.exit(2)

print(json.dumps({
    "path": out_path,
    "project": project_name,
    "branch": primary_branch,
    "date": date,
    "turns": turn_num,
    "session_id": session_id
}))
PYEOF
)

        PYTHON_EXIT=$?
        unset _CAPTURE_JSONL_PATH _CAPTURE_VAULT

        if [ $PYTHON_EXIT -ne 0 ] || [ -z "$CAPTURE_RESULT" ]; then
            echo "  FAILED: capture error for $short_id ($jsonl_file)"
            FAILED_COUNT=$((FAILED_COUNT + 1))
            continue
        fi

        CAPTURED_COUNT=$((CAPTURED_COUNT + 1))
        CAP_PROJECT=$(echo "$CAPTURE_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('project',''))" 2>/dev/null)
        CAP_PATH=$(echo "$CAPTURE_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('path',''))" 2>/dev/null)
        echo "  Captured: $CAP_PATH"

        # Summarize via headless claude
        if command -v claude &>/dev/null; then
            echo "  Summarizing via claude -p..."
            SUMMARIZE_PROMPT=$(printf 'Run /summarize-session for the session file at the path %s in project %s. Read the raw session file and generate a structured summary.' "$CAP_PATH" "$CAP_PROJECT")
            SUMMARIZE_OUTPUT=$(claude -p "$SUMMARIZE_PROMPT" 2>&1)
            CLAUDE_EXIT=$?

            if [ $CLAUDE_EXIT -eq 0 ]; then
                SUMMARIZED_COUNT=$((SUMMARIZED_COUNT + 1))
                echo "  Summarized successfully"
            else
                echo "  Summarization failed (exit $CLAUDE_EXIT): $(echo "$SUMMARIZE_OUTPUT" | head -3)"
            fi
        else
            echo "  Skipping summarization: claude CLI not found. Run /summarize-session manually."
        fi

    done < <(find "$proj_dir" -maxdepth 1 -name "*.jsonl" -mtime -2 2>/dev/null)
done

echo ""
echo "========================================="
echo "Nightly capture complete: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "  Captured:   $CAPTURED_COUNT"
echo "  Summarized: $SUMMARIZED_COUNT"
echo "  Skipped:    $SKIPPED_COUNT (already up to date)"
echo "  Failed:     $FAILED_COUNT"
echo "========================================="
