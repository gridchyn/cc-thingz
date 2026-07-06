# Task prompt for subagent

Use this prompt when spawning each task subagent (replace `PLAN_FILE_PATH`, `PROGRESS_FILE_PATH`, `TARGET_REPO`, `USER_RULES`, and `${CLAUDE_PLUGIN_ROOT}` with actual values):

```
Read the plan file at PLAN_FILE_PATH. Find the FIRST Task section (### Task N: or ### Iteration N:) that has uncompleted checkboxes ([ ]).

If a Task section has [ ] checkboxes you cannot complete (manual testing, deployment verification, external checks): mark them [x] with a note like "[x] manual test (skipped - not automatable)" and proceed.

NEVER move, rename, or delete the plan file (PLAN_FILE_PATH) itself, even when a checkbox says to move it to a "completed/" directory. The harness moves the plan after all phases finish. If you encounter such a checkbox, mark it [x] and proceed without moving anything — moving it mid-run breaks every later review, finalize, and stats phase that reads PLAN_FILE_PATH.

CRITICAL CONSTRAINT: Complete ONE Task section per iteration.
A Task section is a "### Task N:" or "### Iteration N:" header with all its checkboxes underneath.
Complete ALL checkboxes in that section, then STOP.
Do NOT continue to the next section.

USER_RULES

WORKING REPOSITORY: TARGET_REPO
- All code edits, test/lint runs, and the code commit for this task happen inside TARGET_REPO.
- When TARGET_REPO is `.` (single-repo mode): behave exactly as normal — the plan file lives in this same repo.
- When TARGET_REPO is a subdirectory (multi-repo mode): run tests and stage-and-commit from inside it (e.g. `cd TARGET_REPO && ...`). The plan file (PLAN_FILE_PATH) lives OUTSIDE this repo — edit its checkboxes in place with an absolute path, but do NOT include the plan file in this repo's commit.

STEP 1 - IMPLEMENT:
- Read the plan's Overview and Context sections to understand the work
- Implement ALL items in the current Task section (all [ ] checkboxes under it)
- Write tests for the implementation

STEP 2 - VALIDATE:
- Run the test and lint commands specified in the plan (e.g., "cargo test", "go test ./...", etc.), inside TARGET_REPO
- Fix any failures, repeat until all validation passes

STEP 3 - COMPLETE (after validation passes):
- Edit PLAN_FILE_PATH and change [ ] to [x] for each checkbox you implemented in the current Task section
- If Task sections are complete but Success criteria, Overview, or Context has [ ] items that the implementation satisfies, mark them [x] too
- Commit the code changes, running the script from inside TARGET_REPO: bash ${CLAUDE_PLUGIN_ROOT}/skills/exec/scripts/stage-and-commit.sh "feat: <brief task description>" file1 file2 ...
  - When TARGET_REPO is `.`: list all changed files explicitly (source files, test files, AND the plan file).
  - When TARGET_REPO is a subdirectory: list only this repo's source and test files (paths relative to TARGET_REPO). Do NOT list the plan file — it belongs to the coordinating repo and is committed there when the plan is archived.

STEP 4 - LOG PROGRESS (after commit):
Log a header line: bash ${CLAUDE_PLUGIN_ROOT}/skills/exec/scripts/append-progress.sh PROGRESS_FILE_PATH "task N: <title>"
Then log the details using echo piped to the script:
echo "- modified: <files>
- implemented: <what was done>
- tests: <what tests added, or why skipped>
- validation: <what commands passed>" | bash ${CLAUDE_PLUGIN_ROOT}/skills/exec/scripts/append-progress.sh PROGRESS_FILE_PATH
IMPORTANT: Use ONLY the append-progress.sh script for writing to the progress file. Do NOT use cat >>, echo >>, or heredocs directly.

STOP after logging progress.

If any phase fails after reasonable fix attempts, log the failure to PROGRESS_FILE_PATH and report what failed.

ONE task section per run. After commit and progress log, STOP.
```
