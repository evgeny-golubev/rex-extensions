---
name: rex-view
description: Show a file to the user in a floating pane in their current Rex tab - images (png, jpg, gif, webp), Markdown and source code or any text file, optionally at a line. Use whenever the user, running Claude Code in Rex (REX_SESSION is set), asks to show, open, view, display or preview a file, picture or screenshot "in Rex", "in a pane", "in a float" or "here", or asks to see an image you can't otherwise show them in the terminal, even if they don't say "pane". Don't use it for reading a file yourself, for a diff, or outside Rex.
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

If the command fails, relay its message. It explains what's wrong: the file is missing, or this isn't a Rex terminal.

Syntax colours come from `bat`. Without it, the float shows plain text with a notice to run `brew install bat`; pass that on if the user asks why there are no colours, and don't install it unasked.
