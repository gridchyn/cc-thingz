# Finalize prompt

Use this for the finalize agent after all reviews pass (replace `DEFAULT_BRANCH`, `TARGET_REPO`, `PLAN_FILE_PATH`, `PROGRESS_FILE_PATH`, and `${CLAUDE_PLUGIN_ROOT}`):

```
Post-completion finalize step. Organize commits for merge.

Plan file: PLAN_FILE_PATH (read for validation commands)

WORKING REPOSITORY: TARGET_REPO — finalize this repo only. `.` means the current directory (single-repo); a subdirectory means a sibling repo (multi-repo), and DEFAULT_BRANCH is that repo's base branch. Every git command below is scoped to it with `git -C TARGET_REPO`; run validation from inside it.

STEP 1 - REBASE:
- Resolve the rebase target (best-effort, hang-safe fetch + prefer `origin/DEFAULT_BRANCH` if it resolves, else local `DEFAULT_BRANCH`):
  `target=$(bash ${CLAUDE_PLUGIN_ROOT}/skills/exec/scripts/finalize-base.sh TARGET_REPO DEFAULT_BRANCH)`
- Run: `git -C TARGET_REPO rebase "$target"`
- If conflicts: resolve and continue. If rebase fails completely: abort with git -C TARGET_REPO rebase --abort and report the issue
- Do NOT run a bare `git fetch`/`git rebase origin/DEFAULT_BRANCH` yourself — the helper already did the best-effort fetch and chose a target that exists locally, so finalize works on a local-only repo whose default has no pushed remote branch

STEP 2 - CLEAN UP COMMITS:
- Run: git -C TARGET_REPO log "$target"..HEAD --oneline   (same `$target` from STEP 1)
- If there are 5+ commits, squash related fix commits into their parent feature commits
- Keep meaningful boundaries: feature commits separate from review fix commits
- Use git -C TARGET_REPO rebase -i only if squashing is needed

STEP 3 - VERIFY:
- Run validation commands from the plan file, inside TARGET_REPO
- Run tests (go test ./... for Go, etc.)
- If anything fails, fix and re-run

STEP 4 - LOG PROGRESS:
Log results: bash ${CLAUDE_PLUGIN_ROOT}/skills/exec/scripts/append-progress.sh PROGRESS_FILE_PATH "finalize: completed"
Then pipe details: echo "- rebase: <success/failed>
- commits before: N, after: M
- squashed: <list of squashed commits, or none>
- validation: <passed/failed>" | bash ${CLAUDE_PLUGIN_ROOT}/skills/exec/scripts/append-progress.sh PROGRESS_FILE_PATH
IMPORTANT: Use ONLY the append-progress.sh script.

STEP 5 - PLAN DEVIATION ANALYSIS:
- Read the progress file at PROGRESS_FILE_PATH in its entirety
- Compare it against the original plan at PLAN_FILE_PATH
- Analyze and report:
  - deviations from the original plan
  - obstacles or blockers encountered
  - incomplete delivery or cut corners
  - review agents going beyond scope of the original plan

STEP 6 - REPORT:
Report what was done: number of commits before/after, whether rebase succeeded, test results, and plan deviation analysis.

This step is best-effort — if rebase fails, explain why and leave the branch as-is.
```
