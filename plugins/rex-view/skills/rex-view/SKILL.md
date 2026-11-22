---
name: rex-view
description: Show a file to the user in a floating pane in their current Rex tab - images (png, jpg, gif, webp, svg), Markdown, PDF and other documents, and source code or any text file, optionally at a line. Use whenever the user, running Claude Code in Rex (REX_SESSION is set), asks to show, open, view, display or preview a file, picture or screenshot "in Rex", "in a pane", "in a float" or "here", or asks to see an image you can't otherwise show them in the terminal, even if they don't say "pane". Also use it on your own initiative, unasked, whenever you want to show the user something that exists as a file - a picture or screenshot, a report or document you wrote, a place in the code you're pointing at. Don't use it for reading a file yourself, for a diff, or outside Rex.
---

# rex-view

Show the file with one command:

```sh
"${CLAUDE_SKILL_DIR}/scripts/show" <path> [line]
```

- `line` opens a text file at that line, highlighted. Pass it when pointing the user at a specific place.
- The float opens over the tab this conversation is in, takes keyboard focus and replaces an earlier rex-view float in that tab. Show one file at a time, so run it again for the next file.
- The user closes it with `q`. Tell them that, and name the file you opened.
- You can't see what the float draws. Don't claim how it looks; to check an image yourself, use the Read tool.

## Show things without being asked

When you want the user to see something and it exists as a file, open it instead of describing it or pasting it into the conversation:

- a picture, chart or screenshot, which the conversation can't display
- a report, plan or other long Markdown you wrote for them to read
- the place in the code your answer is about, with `line`

Save it to a file first if that's the natural way to show it. Skip the float when a few lines in the conversation say it just as well, or for work the user didn't need to look at. Because it takes keyboard focus, open it once your answer is ready, and don't open several in a row.

## How files are shown

Markdown, pictures, PDF, EPUB, HTML and Office files open in leaf, a terminal reader, when it's installed. Code and other text, and any file shown at a `line`, open with `bat` at that line, because leaf can't open at a line.

If `show` prints that leaf isn't installed, the file still opens, in the basic viewer. Tell the user, and ask whether to install leaf with `brew install deepanshumishraa/tap/leaf`. Install it only if they say yes, and ask once per conversation.

Without leaf, Markdown is formatted by `glow` if it's installed. Syntax colours come from `bat`; without it, the float shows plain text with a notice to run `brew install bat`. Pass that on if the user asks why there are no colours, and don't install it unasked.

## If it fails

If the command fails, relay its message. It explains what's wrong: the file is missing, or this isn't a Rex terminal.
