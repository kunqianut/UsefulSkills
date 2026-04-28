---
name: threads
argument-hint: "[--project <name>] [--all] [--stale]"
disable-model-invocation: true
---

# Threads: Active Thread Dashboard

Scans all session summaries in the Obsidian vault and presents a dashboard of active development threads grouped by project and git branch.

## Configuration Defaults

```
VAULT_PATH = ~/ObsidianVaults/ClaudeCode
STALE_DAYS = 7
```

## Argument Parsing

Parse `$ARGUMENTS` as follows:
- If arguments contain `--project <name>`, filter threads to only that project. Remove the flag and value.
- If arguments contain `--all`, show all threads including completed and stale ones. Remove the flag.
- If arguments contain `--stale`, show only stale threads (no activity for > STALE_DAYS). Remove the flag.
- Default: show only active threads (status is not "completed", last activity within STALE_DAYS).

Examples:
- `/threads` -> show active threads for all projects
- `/threads --project UsefulSkills` -> show active threads for UsefulSkills only
- `/threads --all` -> show all threads including completed/stale
- `/threads --stale` -> show only stale threads

## Workflow

### Phase 1: SCAN

#### 1a. Find all summary files

```bash
VAULT="${VAULT_PATH/#\~/$HOME}"
find "${VAULT}/sessions/summaries" -name "*.md" -type f 2>/dev/null | sort
```

If no summary files exist, report that no sessions have been summarized yet and suggest running `/capture-session` followed by `/summarize-session`.

#### 1b. Extract metadata from each summary

Set the vault path as an environment variable and run python3 to parse YAML frontmatter from all summary files. Replace `<VAULT>` with the expanded vault path:

```bash
export _THREADS_VAULT_PATH="<VAULT>" && python3 << 'PYEOF'
import os, json, re

import sys

vault = os.environ.get("_THREADS_VAULT_PATH", "")
if not vault:
    print("Error: _THREADS_VAULT_PATH not set", file=sys.stderr)
    sys.exit(1)
summaries_dir = os.path.join(vault, "sessions", "summaries")

threads = {}

for root, dirs, files in os.walk(summaries_dir):
    for fname in sorted(files):
        if not fname.endswith(".md"):
            continue
        fpath = os.path.join(root, fname)
        project = os.path.basename(root)

        try:
            with open(fpath) as f:
                content = f.read()
        except OSError as e:
            sys.stderr.write(f"Warning: could not read {fpath}: {e}, skipping\n")
            continue

        # Parse YAML frontmatter
        fm_match = re.match(r'^---\n(.*?)\n---', content, re.DOTALL)
        if not fm_match:
            continue

        fm = fm_match.group(1)
        def get_val(key):
            m = re.search(rf'^{key}:\s*(.+)$', fm, re.MULTILINE)
            return m.group(1).strip().strip("'\"")
 if m else ""

        def get_list(key):
            m = re.search(rf'^{key}:\s*\[(.+?)\]', fm, re.MULTILINE)
            if m:
                return [x.strip().strip("'\"")
 for x in m.group(1).split(",")]
            items = []
            in_list = False
            for line in fm.split("\n"):
                if line.startswith(f"{key}:"):
                    in_list = True
                    continue
                if in_list:
                    if line.startswith("  - "):
                        items.append(line[4:].strip().strip("'\"")
)
                    elif not line.startswith("  "):
                        break
            return items

        date = get_val("date")
        branch = get_val("branch")
        status = get_val("status")
        topics = get_list("tags")

        # Count open action items
        action_items = []
        in_actions = False
        for line in content.split("\n"):
            if line.startswith("## Action Items"):
                in_actions = True
                continue
            if in_actions and line.startswith("## "):
                break
            if in_actions and line.startswith("- [ ] "):
                action_items.append(line[6:])

        # Extract summary line
        summary_line = ""
        in_summary = False
        for line in content.split("\n"):
            if line.startswith("## What Happened"):
                in_summary = True
                continue
            if in_summary and line.strip():
                summary_line = line.strip()[:100]
                break

        key = f"{project}/{branch}"
        if key not in threads:
            threads[key] = {
                "project": project,
                "branch": branch,
                "sessions": [],
                "all_topics": set(),
                "total_open_actions": 0,
                "latest_status": "",
                "latest_date": "",
                "latest_summary": ""
            }

        threads[key]["sessions"].append({"date": date, "file": fname})
        threads[key]["all_topics"].update(topics)
        threads[key]["total_open_actions"] += len(action_items)
        if not threads[key]["latest_date"] or date > threads[key]["latest_date"]:
            threads[key]["latest_date"] = date
            threads[key]["latest_status"] = status
            threads[key]["latest_summary"] = summary_line

# Convert sets to lists for JSON
for k in threads:
    threads[k]["all_topics"] = sorted(threads[k]["all_topics"])
    threads[k]["session_count"] = len(threads[k]["sessions"])

print(json.dumps(threads, indent=2))
PYEOF
```

### Phase 2: CLASSIFY

For each thread, determine its display category:

1. **Active**: status is "in-progress" or "blocked", and last activity within STALE_DAYS
2. **Stale**: last activity older than STALE_DAYS, status is not "completed"
3. **Completed**: status is "completed"

Calculate "days since last activity" from the latest session date.

### Phase 3: DISPLAY

Present the dashboard. Apply filters based on arguments (`--project`, `--all`, `--stale`).

```
## Active Threads

### <project>/<branch> (last active: <N>d ago)
**Status**: <status> | **Open actions**: <count> | **Sessions**: <count>
**Last session**: <summary snippet>
**Topics**: <topic1>, <topic2>

### <project>/<branch> (last active: <N>d ago)
...

---

## Blocked Threads

### <project>/<branch> (last active: <N>d ago)
**Status**: blocked | **Open actions**: <count>
**Last session**: <summary snippet>

---

## Stale Threads (no activity > <STALE_DAYS> days)

### <project>/<branch> (last active: <N>d ago)
**Status**: <status> | **Open actions**: <count>
**Last session**: <summary snippet>

---

## Suggested Focus
1. <thread with most recent activity and open actions> — <reason>
2. <blocked thread> — check if blocker is resolved
3. <stale thread with open actions> — resume or close out
```

The "Suggested Focus" section lists up to 3 threads prioritized by:
1. Threads with open action items and recent activity (quick wins)
2. Blocked threads (may have become unblocked)
3. Stale threads with open action items (need attention or closure)

## Error Handling

- **Vault not found**: Print setup instructions — suggest running `/capture-session` first to create the vault structure
- **No summary files**: Report that no sessions have been summarized; suggest the `/capture-session` then `/summarize-session` workflow
- **Malformed frontmatter in summary files**: Skip that file, note it in output
- **No threads match filters**: Report clearly (e.g., "No active threads found for project X")

## Important Notes

- Threads are identified by the combination of project name + git branch.
- The dashboard reads only from session summaries in the vault — it does not access JSONL files or Claude Code internals.
- "Days since last activity" is calculated from the `date` field in the most recent summary's frontmatter.
- The "Suggested Focus" section is a simple heuristic, not an LLM analysis. For deeper suggestions, use `/suggest-actions <branch>`.
