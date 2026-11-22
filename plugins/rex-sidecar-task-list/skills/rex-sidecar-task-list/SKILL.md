---
name: rex-sidecar-task-list
description: Keeps the user's task list (shown in the Rex sidecar's Google Tasks or Reminders tab) in step with the work done in this session. Use it when the user starts a piece of work with you (fix, build, investigate, write, review), to add the work to the task list or match it to a task already there, and when that work is finished, to report the task done for the user to confirm. Do not use it for quick questions.
---

# Rex sidecar task list

The user reviews their tasks in the Rex sidecar pane, in the **Google Tasks**
tab, the **Reminders** tab (Apple Reminders), or both. Three Rex actions reach
the lists of the tabs that are shown. Run them with Bash:

```sh
rex do tasks_list                                  # open tasks, as JSON, each list with its provider
rex do tasks_add title="A. Fix the CSV import (1h)" due=today   # rating and due are required
rex do tasks_report_done id=TASK_ID note="Import fixed; tests pass"
```

Each list from `tasks_list` has `provider`: `google` or `apple`. Each task
has its `rating`.

## When work starts

1. Run `rex do tasks_list`. If an open task already describes the work, use
   it. Do not add a duplicate.
2. Otherwise add one with `tasks_add`:
   - Title: a short imperative naming the outcome, such as "Fix the CSV
     import". Start it with a rating: `A. ` for work due today or tomorrow,
     `B. ` for longer-term work, `C. ` for low importance. The rating is
     required. End it with an estimate in parentheses, such as `(30m)` or
     `(1h30)`.
   - Always pass `due`: `today` when the work is being done now, otherwise
     the date the user wants it finished by, or your best estimate of it.
     The action rejects a task without a rating or a due date.
   - Where it goes: with one task tab shown, it goes there. With both, pass
     `list=<ID>` of the list that fits the work, from `tasks_list`; without
     it, the task goes to Google Tasks. In Reminders it goes to the list the
     user chose as default unless you pass `list`, and the rating becomes
     the reminder's Priority (A High, B Medium, C Low).
   - Work estimated above 2h, in Google Tasks: add a task for the whole and
     one step per part of at most 2h, each with `parent=<ID of the task>`.
     Reminders has no steps: add one task and keep its estimate.
3. Keep the task ID for the rest of the session. Tell the user in one line
   what was added, for example: "Added to your tasks: A. Fix the CSV import
   (1h)."

## When work ends

When the work is finished and verified, run `tasks_report_done` with the
task ID and a one-sentence note on the result. This does not complete the
task: the report waits in the Attention section of the task's tab, where the
user presses `y` to mark it done or `n` to keep it open. Tell the user in
one line that the report is waiting there.

Report only work that is finished. If the work stops part way, leave the
task open and say what remains.

## Errors

- "No task tab is shown" or "not set up": offer to set up a task tab with
  the rex-sidecar-tasks-setup skill.
- "Sign-in needed": ask the user to press `L` in the tab the error names. If
  the sign-in fails, use the rex-sidecar-tasks-setup skill.
- Any other error: tell the user in one line and continue the work; the task
  list must not block it.