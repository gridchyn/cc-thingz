# Planning Plugin Usage

The planning plugin has three components: make (plan creation), exec (autonomous execution), and plan-review (quality review agent).

## Make — `/planning:make`

### Triggers
- `/planning:make <description>` — create an implementation plan
- invoked automatically by brainstorm when user picks "Write plan"

### Workflow
1. **Step 0** — parses intent (feature, bug fix, refactor, migration) and explores codebase for context
2. **Step 1** — asks focused questions one at a time: goal, scope, constraints, testing approach, title
3. **Step 1.5** — proposes 2-3 implementation approaches with trade-offs (skipped if obvious)
4. **Step 2** — creates plan file at `docs/plans/yyyymmdd-<task-name>.md`
5. **Step 3** — offers next steps: interactive review, auto review, implement, or done

### Examples
```
/planning:make add user authentication
/planning:make fix the race condition in the connection pool
/planning:make refactor the middleware stack
/planning:make add my Go testing rules to user-level planning rules
```

### Plan File Structure
- Overview, Context, Development Approach, Testing Strategy
- Implementation Steps with `### Task N:` sections
- Each task has `**Files:**` block and `[ ]` checkboxes
- Progress tracking with `[x]`, `➕`, `⚠️` markers
- **Multi-repo (optional):** a `## Repos` manifest plus a `**Repo:** <dir>` line per task turn the plan into a cross-repo coordinating plan (see [Multi-repo mode](#multi-repo-mode)). Omit both for an ordinary single-repo plan.

## Exec — `/planning:exec`

### Triggers
- `/planning:exec [plan-file]` — execute a plan autonomously
- "exec", "execute plan", "run plan"

### Workflow
1. Resolves plan file (from argument or picks from `docs/plans/`)
2. Asks about worktree isolation (worktree vs current directory)
3. Creates a feature branch
4. Executes tasks sequentially — one subagent per task, commits after each
5. Runs multi-phase review: comprehensive (iteration 1) then critical re-check loop → code smells → external (codex) → critical-only
6. Optional finalize: rebase and squash commits
7. Stats summary: aggregate per-phase tokens/duration + git diff stats and report

Exec auto-detects **multi-repo mode** from the plan (a `## Repos` manifest or per-task `**Repo:**` fields). In that mode it skips the worktree question, branches each sibling repo in place, runs tasks in plan order against their target repo, reviews/finalizes each touched repo against its own base branch, and prints a per-repo PR summary. A plan with no repo targeting behaves exactly as before. See [Multi-repo mode](#multi-repo-mode).

### Configuration
Set via `userConfig` in plugin.json (prompted at install):

| Key | Default | Description |
|-----|---------|-------------|
| `external_review_cmd` | *(auto-detect codex)* | external review tool command |
| `task_retries` | `1` | retries for failed tasks |
| `review_iterations` | `5` | max fix-and-recheck cycles |
| `external_review_iterations` | `10` | max external review iterations |
| `finalize_enabled` | `true` | run rebase + squash phase |
| `plans_dir` | `docs/plans` | directory for plan files |
| `workspace_root` | `.` | root for resolving multi-repo target dirs (relative to cwd); only used in multi-repo mode |

### Customization
Prompts and agent definitions use a three-layer override chain:
1. Project: `.claude/exec-plan/prompts/` and `.claude/exec-plan/agents/`
2. User: `$CLAUDE_PLUGIN_DATA/prompts/` and `$CLAUDE_PLUGIN_DATA/agents/`
3. Bundled defaults

A `SessionStart` hook (`skills/exec/scripts/seed-data.sh`) copies bundled defaults to `$CLAUDE_PLUGIN_DATA` on first run — edit the copies to customize. The seeder is **version-aware**: on a plugin version bump it refreshes seeded files you have *not* edited (tracked via a checksum manifest) and leaves your edits untouched. Project overrides in `.claude/exec-plan/` always win regardless. (See [Consumer handoff](#consumer-handoff-using-this-fork) for the one-time clear needed when upgrading *onto* the version-aware seeder.)

### Customization patterns

- *Route review fanout to named specialists.* Override `prompts/review.md` to launch named subagents (`qa-expert`, `code-quality`, `go-test-expert`, `implementation-reviewer`, `documentation`) instead of `general-purpose`.
- *Delegate to an existing skill.* Override a prompt or agent file to read another skill's `SKILL.md` and follow it inline. Examples: `agents/smells.txt` → `/smells` skill; `prompts/finalizer.md` → `/rebase-commits` skill.

### Subagent constraint

Subagents in current Claude Code do not have the Agent tool — they cannot spawn other subagents. `prompts/review.md` is therefore read by the main session orchestrator (as a playbook), not given to a subagent. The 5-specialist fanout runs directly from the main session. Leaf-work prompts (`task.md`, `fixer.md`, `finalizer.md`, `codex-review.md`, `agents/smells.txt`) can be subagent prompts because they don't need to spawn further. Any custom override needing parallel fanout must follow the same playbook pattern.

## Plan-Review — agent

### Triggers
- launched by make's "Auto review" option
- usable as `subagent_type: "plan-review"` in Agent tool calls

### What It Checks
- problem definition and solution correctness
- scope creep and over-engineering
- testing requirements and coverage
- task granularity and ordering
- convention adherence (via CLAUDE.md and custom rules)

### Output
Structured report with severity-rated findings:
- Critical Issues, Important Issues, Minor Issues
- Over-Engineering Concerns
- Testing Coverage Assessment
- Verdict: APPROVE or NEEDS REVISION

## Interactive Review

After creating a plan, make offers interactive review via:
- **revdiff** (if installed) — TUI with syntax highlighting and line-level annotations
- **plan-annotate.py** (fallback) — opens plan in `$EDITOR` via terminal overlay

Both loop until the user quits without annotations.

## Multi-repo mode

A single coordinating plan can drive a change that spans several sibling repositories (e.g. a schema migration that must land in one repo before dependent code in another). Exec detects multi-repo mode automatically and keeps single-repo behavior 100% unchanged when no repo targeting is present.

### Plan schema

Two additions to an ordinary plan switch it into multi-repo mode:

1. A `## Repos` manifest (place it right after `## Context (from discovery)`):

   ```markdown
   ## Repos

   Branch: `feature/DPB-6042`

   - `pgw-config-service`
   - `pgw-core-service` — base: `develop`
   - `pgw-workflow-service` — branch: `feature/DPB-6042-wf`
   ```

   - Directories are relative to `workspace_root` (default `.`).
   - `Branch:` is the default feature branch for all repos; omit it to derive the branch from the plan filename.
   - Per-repo `base:` overrides the auto-detected base branch; per-repo `branch:` overrides the feature branch.

2. A `**Repo:** <dir>` line under each `### Task N:` header (before its `**Files:**` block). The value must be one of the repos in `## Repos`.

A plan with **neither** runs as a normal single-repo plan. `/planning:make` emits these only when you tell it the change is cross-repo.

### Behavior

- **Branching (in place, no worktrees):** exec pre-flights every target repo read-only (exists, is git, clean tree, not on a foreign feature branch) and only then creates/switches each repo's feature branch. If any repo fails pre-flight it stops before branching any — never a half-branched set. The workspace-root repo (holding the plan) gets no code branch.
- **Tasks run in plan order** (not grouped by repo), each against its `**Repo:**`, committing that repo's code on its feature branch. Order cross-repo dependencies deliberately.
- **Review + finalize run per touched repo** (a repo with commits on its feature branch), each scoped to that repo's diff and base branch. Stats aggregate churn across repos.
- **One PR per touched repo.** Exec archives the coordinating plan to `docs/plans/completed/` in the root repo, prints a per-repo summary (repo → branch → commits → status), and never pushes.
- **git-only.** Multi-repo mode requires git for every target repo (single-repo hg is unaffected).

### Constraints

- Run exec from the workspace root (where the coordinating plan lives). Sibling repos must be checked out beside it (resolved via `workspace_root`).
- Each repo may have a different default branch — exec detects per repo, never hardcodes.

## Consumer handoff (using this fork)

To use this fork's planning plugin from your own Claude Code:

1. **Point your marketplace at the fork.** Add it to `extraKnownMarketplaces` in your Claude Code settings (or `/plugin marketplace add <owner>/<repo>`), then install/enable the `planning` plugin from it.
2. **Clear stale seeded prompts once (only when upgrading onto the version-aware seeder).** Existing installs seeded prompts/agents into the plugin data dir with the old copy-if-absent hook, which never refreshed them. The new seeder can't tell those pre-existing copies from user edits (no checksum manifest yet), so it leaves them in place on the first run — meaning the new multi-repo prompts would be shadowed. Clear them once so the new bundled prompts take effect:

   ```bash
   rm -rf "$HOME/.claude/plugins/data/<plugin-id>/prompts" \
          "$HOME/.claude/plugins/data/<plugin-id>/agents" \
          "$HOME/.claude/plugins/data/<plugin-id>/.seed-version" \
          "$HOME/.claude/plugins/data/<plugin-id>/.seed-manifest"
   ```

   (`<plugin-id>` is the planning plugin's data directory under `~/.claude/plugins/data/`.) The next session re-seeds fresh copies and writes a manifest. **After this one-time clear, future upgrades refresh automatically** and preserve any edits you make to the seeded copies.
3. **Prefer project-level overrides** for customization: files in `.claude/exec-plan/prompts/` and `.claude/exec-plan/agents/` always win at resolve time and are never touched by the seeder — no clearing needed.
