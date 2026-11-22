# Rex View

**Let Claude show you things, not just tell you.** Screenshots, Markdown
reports and code open in a floating pane right over Claude's tab. Press `q`
to close it.

- **Just ask:** "show me that screenshot", or "open the README in a pane".
- **Or don't:** Claude opens one by itself when it wants to show you a
  picture, a report it wrote, or the line of code it's talking about.
- **Looks right:** pictures are scaled to fit, Markdown is formatted across
  the full width, and code gets line numbers and colours.

**Try it:**

```sh
claude plugin marketplace add evgeny-golubev/rex-extensions
claude plugin install rex-view@rex-extensions
```

Version 0.5.1. It's a Claude Code skill, so it needs no line in `init.lua`.

## What you see

| File | How it's shown |
| --- | --- |
| png, jpg, gif, webp | The picture, scaled to fit and redrawn when the float changes size. A gif shows its first frame |
| Markdown | Formatted by `glow`, with paragraphs filling the float's width, from the top. Asked for at a line, or without `glow`, it's shown like code |
| Code and other text | Line numbers and colours from `bat`, at a line if one is given |
| Binary files | A short notice instead |

## Keys

- `q` closes the float. On a picture, `Esc` closes it too.
- Text scrolls with the keys of `less` and the mouse wheel.
- Dragging selects text.

A new float replaces the one before it, and takes focus.

## Optional tools

| Tool | What it adds | Without it |
| --- | --- | --- |
| [`bat`](https://github.com/sharkdp/bat) (`brew install bat`) | Colours and line numbers | Plain text, with a note on how to install it |
| [`glow`](https://github.com/charmbracelet/glow) (`brew install glow`) | Formatted Markdown | Markdown shown like code, with no note |

`glow` uses its dark style. Set `GLAMOUR_STYLE`, for example to `light`, to
change it.

## Safety

Terminal codes inside a file are shown as text, so a file can't mess up the
screen. Pictures are drawn with the Kitty graphics protocol. Formats other
than PNG are converted to PNG first, with macOS's `sips`.

## Install and update

Install through this repository's plugin marketplace:

```sh
claude plugin marketplace add evgeny-golubev/rex-extensions
claude plugin install rex-view@rex-extensions
```

Then restart Claude Code, or run `/reload-plugins` in it.

To update:

```sh
claude plugin marketplace update rex-extensions
claude plugin update rex-view@rex-extensions
```

## Manual use

From a clone of this repository, show a file, or a file at a line:

```sh
plugins/rex-view/skills/rex-view/scripts/show docs/rex-sidecar.png
plugins/rex-view/skills/rex-view/scripts/show README.md 120
```

## Tests

```sh
rex do ~/.config/rex/extensions/plugins/rex-view/test.lua
```

The tests cover finding the tab and building the request. They open no panes.
