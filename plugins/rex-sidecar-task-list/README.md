# Rex Sidecar Task List

**Your to-do list, kept up to date by the agent doing the work.** Start
something with Claude and it lands on your list. Finish it, and Claude
reports it done for you to confirm with one key.

- **No bookkeeping:** new work goes to your Google Tasks or Apple Reminders,
  or is matched to a task that's already there.
- **You stay in charge:** Claude only reports a task done. You press `y` to
  confirm or `n` to keep it open.
- **Guided setup:** ask Claude "set up the sidecar Tasks tab", and it walks you
  through it one step at a time. It never asks you to paste a secret into the
  chat.

**Try it:**

```sh
claude plugin install rex-sidecar-task-list@rex-extensions
```

Then ask Claude "set up the sidecar Tasks tab".

Version 0.2.0. It has two Claude Code skills, one for setup and one for
keeping the list. It works with the rex-sidecar extension's
[Google Tasks and Reminders tabs](../../rex-sidecar/README.md#task-tabs).

## Setup

Ask Claude "set up the sidecar Tasks tab". The `rex-sidecar-tasks-setup`
skill first checks what's already done:

- the rex-sidecar extension and its task actions;
- which of the two task tabs is shown;
- for Google Tasks, the stored client and the sign-in.

Then it walks you through the rest, one step at a time, and waits for you
after each step.

- **Reminders** needs no setup. You show the tab and allow macOS access to
  Reminders once.
- **Google Tasks** takes about 10 minutes, once. The skill gives you the exact
  Google Cloud pages and values. It finds the downloaded client file, stores
  it in the macOS Keychain, deletes the download, signs you in and checks
  that your lists load.

You can show both tabs at once.

## Keeping the list

The `rex-sidecar-task-list` skill keeps your tasks in step with the work you
do with Claude.

1. **Work starts.** Claude looks for an open task that already describes it.
   If there's none, it adds one, with a rating (`A`, `B` or `C`), an estimate
   and a due date.
2. **Work ends.** Claude reports the task done, with a one-line note. The
   report waits in the Attention section of the task's tab. Press `y` to
   mark the task done, or `n` to keep it open. Claude never completes a task
   itself.

Where a new task goes:

- With one task tab shown, it goes there.
- With both shown, Claude picks the list that fits the work. Without a list,
  it goes to Google Tasks.
- In Reminders, it goes to the list you chose as default with `l` in the tab.
  The rating becomes the reminder's Priority: A is High, B Medium, C Low.
- Work over 2 hours gets steps in Google Tasks. Reminders has no steps, so it
  stays one task with its estimate.

The skill uses three Rex actions from rex-sidecar,
[`tasks_list`, `tasks_add` and `tasks_report_done`](../../rex-sidecar/README.md#task-actions).
They only use the providers of the tabs you've shown, so the rex-sidecar
extension must be loaded and at least one task tab shown.

## Install

Through this repository's plugin marketplace:

```sh
claude plugin marketplace add evgeny-golubev/rex-extensions
claude plugin install rex-sidecar-task-list@rex-extensions
```

Then restart Claude Code, or run `/reload-plugins` in it.

### Upgrading from sidecar-task-list

The plugin used to be called `sidecar-task-list`. Remove the old one, then
install the new one:

```sh
claude plugin uninstall sidecar-task-list@rex-extensions
claude plugin marketplace update rex-extensions
claude plugin install rex-sidecar-task-list@rex-extensions
```

### From a clone, without the marketplace

Link the two skill folders into Claude Code's skills folder:

```sh
ln -s ~/.config/rex/extensions/plugins/rex-sidecar-task-list/skills/rex-sidecar-task-list ~/.claude/skills/rex-sidecar-task-list
ln -s ~/.config/rex/extensions/plugins/rex-sidecar-task-list/skills/rex-sidecar-tasks-setup ~/.claude/skills/rex-sidecar-tasks-setup
```
