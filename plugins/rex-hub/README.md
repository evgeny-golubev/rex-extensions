# Rex Hub Skill

Teaches coding agents (Claude Code, `agy`, etc.) to delegate tasks to other
coding agents through [`rex-hub`](../../rex-hub/README.md) (`rex do hub_run`,
`hub_send`, `hub_read`, `hub_stop`) instead of running blind shell commands.

## Install

### Claude Code

Through the marketplace:

```sh
claude plugin marketplace add evgeny-golubev/rex-extensions
claude plugin install rex-hub@rex-extensions
```

Or link directly from a clone:

```sh
mkdir -p ~/.claude/skills
ln -s ~/.config/rex/extensions/plugins/rex-hub/skills/rex-hub ~/.claude/skills/rex-hub
```

### Antigravity CLI (`agy`)

Link into `~/.gemini/config/skills/`:

```sh
mkdir -p ~/.gemini/config/skills
ln -s ~/.config/rex/extensions/plugins/rex-hub/skills/rex-hub ~/.gemini/config/skills/rex-hub
```
