# Rex View for Claude Code

Version 0.1.0. A Claude Code skill that shows a file in a floating pane over the tab Claude
is running in. Ask Claude to "show me that picture" or "open the README in a
pane".

| File | Shown as |
|---|---|
| png, jpg, gif, webp | The image, scaled to fit and redrawn on resize (Kitty graphics; other formats are converted to PNG with `sips`, and a gif shows its first frame) |
| Markdown, source code, other text | Line numbers and syntax colours from `bat`, at a given line if there is one |
| Binary | A short notice |

Without [`bat`](https://github.com/sharkdp/bat), text is shown plain, with a
notice to run `brew install bat`. Markdown is coloured source, not formatted.

A new float replaces the previous one. It takes focus; `q` closes it, or `Esc`
on an image. Text scrolls with the keys of `less` and the mouse wheel, and
dragging selects it. Terminal codes in a file are shown as text, so a file
can't disturb the screen.

## Install

Through this repository's plugin marketplace:

```sh
claude plugin marketplace add evgeny-golubev/rex-extensions
claude plugin install rex-view@rex-extensions
```

Then restart Claude Code, or run `/reload-plugins` in it. Unlike the
extensions, it needs no line in `init.lua`.

To update, run `claude plugin marketplace update rex-extensions`, then
`claude plugin update rex-view@rex-extensions`.

## Manual use

From a clone of this repository:

```sh
plugins/rex-view/skills/rex-view/scripts/show docs/cc-pane.png
plugins/rex-view/skills/rex-view/scripts/show README.md 120
```

## Tests

```sh
rex do ~/.config/rex/extensions/plugins/rex-view/test.lua
```

The tests cover finding the tab and building the request, with no live panes.
