---
name: rex-view
description: Show a file or web page to the user in their current Rex tab - images (png, jpg, gif, webp), Markdown, source code or any text file, optionally at a line, plus rendered HTML files and http, https or localhost URLs. Use whenever the user, running Claude Code in Rex (REX_SESSION is set), asks to show, open, view, display or preview a file, picture, screenshot, HTML page or URL "in Rex", "in a pane", "in a float" or "here", or asks to see an image you can't otherwise show them in the terminal, even if they don't say "pane". Also use it on your own initiative, unasked, whenever you want to show the user something that exists as a file - a picture or screenshot, a report or document you wrote, a place in the code you're pointing at. Don't use it for reading a file yourself, for a diff, or outside Rex.
---

# rex-view

Show the file with one command:

```sh
"${CLAUDE_SKILL_DIR}/scripts/show" <path> [line]
```

- `line` opens a text file at that line, highlighted. Pass it when pointing the user at a specific place.
- The float opens over the tab this conversation is in, takes keyboard focus and replaces an earlier rex-view float in that tab. Show one file at a time, so run it again for the next file.
- The user closes it with `q` (or `Esc` on an image). Tell them that, and name the file you opened.
- You can't see what the float draws. Don't claim how it looks; to check an image yourself, use the Read tool.

## HTML files and URLs

To show a web page or render an HTML file:

1. If the `mcp__terminal-browser__open` tool is available, call it with the URL. For a local file, pass a `file://` URL with an absolute, percent-encoded path. The page opens in the plugin's browser pane beside the conversation; `mcp__terminal-browser__close` or `/browser close` closes it.
2. If the tool isn't available, or it fails, run `show` with the URL or HTML file. The page opens in a float and takes the keys, so `Cmd+W` closes it, not `q`. Tell the user that.

URLs must start with `http://`, `https://`, `localhost` or `127.0.0.1`. To show an HTML file's source instead, pass `show` a `line`.

## Show things without being asked

When you want the user to see something and it exists as a file, open it instead of describing it or pasting it into the conversation:

- a picture, chart or screenshot, which the conversation can't display
- a report, plan or other long Markdown you wrote for them to read
- the place in the code your answer is about, with `line`

Save it to a file first if that's the natural way to show it. Skip the float when a few lines in the conversation say it just as well, or for work the user didn't need to look at. Because it takes keyboard focus, open it once your answer is ready, and don't open several in a row.

## If it fails

If the command fails, relay its message. It explains what's wrong: the file is missing, or this isn't a Rex terminal.

Markdown is formatted by `glow` if it's installed, otherwise it's shown like any other text. Passing a `line` skips formatting, because formatted lines don't match the file's.

Syntax colours come from `bat`. Without it, the float shows plain text with a notice to run `brew install bat`; pass that on if the user asks why there are no colours, and don't install it unasked.
