# Sidecar task list for Claude Code

Version 0.1.0. A Claude Code skill that keeps your task list in step with the
work you do with Claude. When you start a piece of work, Claude adds it to the
list, or matches it to a task already there. When the work is finished, Claude
reports the task done. The report waits in the Attention section of the
cc-sidecar [Tasks tab](../../cc-sidecar/README.md#tasks), where `y` marks the
task done and `n` keeps it open. Claude never completes a task itself.

It uses the cc-sidecar [task actions](../../cc-sidecar/README.md#task-actions),
`tasks_list`, `tasks_add` and `tasks_report_done`, so it needs the cc-sidecar
extension loaded and a task source chosen in the Tasks tab.

## Install

Through this repository's plugin marketplace:

```sh
claude plugin marketplace add evgeny-golubev/rex-extensions
claude plugin install sidecar-task-list@rex-extensions
```

Then restart Claude Code, or run `/reload-plugins` in it.

To use the copy in a clone of this repository instead, link the skill folder:

```sh
ln -s ~/.config/rex/extensions/plugins/sidecar-task-list/skills/sidecar-task-list ~/.claude/skills/sidecar-task-list
```
