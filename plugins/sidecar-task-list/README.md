# Sidecar Task List

**Your to-do list, kept up to date by the agent doing the work.** Start
something with Claude and it lands on your list; finish it and Claude reports
it done, for you to confirm with one key.

- **No bookkeeping:** new work is added to your Google Tasks or Apple
  Reminders, or matched to a task already there.
- **You stay in charge:** Claude only reports a task done. You press `y` to
  confirm or `n` to keep it open, in the rex-sidecar
  [Tasks tab](../../rex-sidecar/README.md#tasks).
- **Guided setup:** ask Claude "set up the sidecar Tasks tab", and it walks you
  through it one step at a time. It never asks you to paste a secret into the
  chat.

**Try it:** `claude plugin install sidecar-task-list@rex-extensions`, then ask
Claude "set up the sidecar Tasks tab". [Details →](#install)

Version 0.1.0: two Claude Code skills, for setup and for keeping the list.

## Setup

Ask Claude "set up the sidecar Tasks tab". The sidecar-tasks-setup skill checks
what is done already: the extension, the tab, the task source, and for Google
Tasks the stored client and the sign-in. It then walks you through the rest one
step at a time, with the exact Google Cloud pages and values, and waits for you
after each step. It finds the downloaded client file, stores it in the Keychain,
deletes the download, signs you in and checks that your lists load. It never
asks you to paste a secret into the chat. Apple Reminders needs no setup, and
the skill offers it too.

## Task list

The sidecar-task-list skill keeps your task list in step with the
work you do with Claude. When you start a piece of work, Claude adds it to the
list, or matches it to a task already there. When the work is finished, Claude
reports the task done. The report waits in the Attention section of the
rex-sidecar [Tasks tab](../../rex-sidecar/README.md#tasks), where `y` marks the
task done and `n` keeps it open. Claude never completes a task itself.

It uses the rex-sidecar [task actions](../../rex-sidecar/README.md#task-actions),
`tasks_list`, `tasks_add` and `tasks_report_done`, so it needs the rex-sidecar
extension loaded and a task source chosen in the Tasks tab.

## Install

Through this repository's plugin marketplace:

```sh
claude plugin marketplace add evgeny-golubev/rex-extensions
claude plugin install sidecar-task-list@rex-extensions
```

Then restart Claude Code, or run `/reload-plugins` in it.

To use the copy in a clone of this repository instead, link the skill folders:

```sh
ln -s ~/.config/rex/extensions/plugins/sidecar-task-list/skills/sidecar-task-list ~/.claude/skills/sidecar-task-list
ln -s ~/.config/rex/extensions/plugins/sidecar-task-list/skills/sidecar-tasks-setup ~/.claude/skills/sidecar-tasks-setup
```
