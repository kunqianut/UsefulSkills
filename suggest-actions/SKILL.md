---
name: suggest-actions
argument-hint: "[branch-name] [--project <name>]"
disable-model-invocation: true
---

# Suggest Actions: Next Steps and Questions for a Thread

Analyzes a thread's session history and current git state to suggest concrete next steps, surface unresolved questions, and identify potential blockers.

## Configuration Defaults

```
VAULT_PATH = ~/ObsidianVaults/ClaudeCode
MAX_SESSIONS_TO_READ = 3
```

## Argument Parsing

Parse `$ARGUMENTS` as follows:
- If arguments contain `--project <name>`, use that as the project name. Remove the flag and value.
- If any remaining argument is provided, treat it as the branch name.
- If no branch name is provided, detect the current branch via `git branch --show-current`.
- If no `--project` is provided, use `basename $(pwd)` as the project name.

Examples:
- `/suggest-actions` -> suggestions for current branch in current project
- `/suggest-actions add-light-mode` -> suggestions for the add-light-mode branch
- `/suggest-actions --project MyApp main` -> suggestions for main branch in MyApp

## Workflow

### Phase 1: GATHER

#### 1a. Determine project and branch

```bash
BRANCH="${BRANCH_ARG:-$(git branch --show-current 2>/dev/null || echo 'unknown')}"
PROJECT="${PROJECT_ARG:-$(basename $(pwd))}"
VAULT="${VAULT_PATH/#\~/$HOME}"
```

#### 1b. Read session summaries

Find session summary files for this project+branch in `${VAULT}/sessions/summaries/${PROJECT}/`. Filter to files whose frontmatter `branch` field matches. Sort by date, read up to MAX_SESSIONS_TO_READ most recent ones.

If no summaries are found, report that no session history is available and suggest running `/capture-session` then `/summarize-session`.

#### 1c. Gather current git state

Run these commands via Bash to capture the current state of the branch:

```bash
git status --short 2>/dev/null || echo "not a git repo"
git log --oneline -10 2>/dev/null || echo "no commits"
git diff --stat HEAD 2>/dev/null || echo "no diff"
git branch --show-current 2>/dev/null || echo "unknown branch"
```

### Phase 2: ANALYZE

Spawn the `thread-tracker` agent to analyze session history and current state.

Use the Agent tool with:
- `subagent_type`: `thread-tracker`
- `prompt`:

```
You are helping a developer return to a thread after a break. Analyze the session history and current git state to suggest next steps.

**Thread**: <project>/<branch>

**Current git state**:
```
<git status output>
```

**Recent git commits**:
```
<git log output>
```

**Uncommitted changes**:
```
<git diff --stat output>
```

**Session summaries (most recent first)**:

---
<summary 1 full content>
---
<summary 2 full content>
---
<summary 3 full content>
---

Based on this context, provide your analysis as a JSON code block with these fields:

- immediate_action: the single most important thing to do right now (specific and actionable)
- follow_up_actions: 2-4 actions to do after the immediate one (ordered by priority)
- unresolved_questions: questions that need answering before progress can continue
- blockers_and_risks: potential issues that could slow progress
- related_threads: any mentions of other branches, projects, or dependencies in the session history
- context_notes: anything the developer should know before resuming (gotchas, things that were tried and failed, etc.)
```

Parse the JSON from the agent's response.

### Phase 3: DISPLAY

Present the analysis in a structured format:

```markdown
## Suggested Actions: <project> / <branch>

### Immediate Next Step
<immediate_action — specific, actionable, references actual files/tasks>

### Follow-up Actions
1. <action 1>
2. <action 2>
3. <action 3>

### Unresolved Questions
- <question 1>
- <question 2>

### Potential Blockers
- <blocker/risk 1>
- <blocker/risk 2>

### Context Notes
<Things to know before resuming — gotchas, failed approaches, etc.>

### Related Threads
- <project/branch> — <how it's related>
```

If the agent returns no blockers or related threads, omit those sections rather than showing empty ones.

## Error Handling

- **No session summaries found**: Report that no history is available. Suggest running `/capture-session` then `/summarize-session`. Optionally still show git state and provide basic suggestions based on uncommitted changes and recent commits alone.
- **Agent not installed**: Report that the thread-tracker agent is not installed. Suggest copying `agents/thread-tracker.md` to `~/.claude/agents/`. Fall back to presenting raw session summaries and git state without LLM analysis.
- **Agent returns malformed JSON**: Extract what fields are parseable, present them, note the parsing issue.
- **Not in a git repo**: Skip git state gathering, analyze only from session summaries.
- **No uncommitted changes**: Note this in the output — the branch may be in a clean state ready for new work.

## Important Notes

- This skill combines session history (from the vault) with live git state for the most accurate recommendations.
- The thread-tracker agent is required for analysis. Without it, the skill can only present raw data.
- Suggestions are specific and actionable — they reference actual files, tasks, and decisions from session history.
- Use `/briefing` first if you want a full historical overview before seeing action suggestions.
- The "Context Notes" section is especially valuable — it captures things that were tried and failed, saving you from repeating mistakes.
