-- Writes the Rex View picker's list for a Claude pane:
--   rex do view-collect.lua session=... claude=<block> out=<file>
-- A first line starting with "!" is a message to show instead of a list.
local dir = debug.getinfo(1, "S").source:match("^@?(.*/)") or "./"
local settings = dofile(dir .. "settings.lua")
local claude = dofile(dir .. "claude.lua")
local mentions = dofile(dir .. "mentions.lua")

-- Enough for a few long turns; tool output fills most of a transcript.
local tail_bytes = 16 * 1048576

local function write(text)
	local f = assert(io.open(rex.args.out, "wb"))
	f:write(text)
	f:close()
end

local process = rex.block.call("com.superlogical.terminal", "process", { session_id = rex.args.session, block_id = rex.args.claude })
local pid = claude.pid(process)
local path, cwd
if pid then
	path, cwd = claude.transcript(pid)
end
if not path then
	write("!No Claude Code session found in this tab.\n")
	return
end

local n = settings.view_replies(dir)
local turns = mentions.turns(mentions.tail_lines(path, tail_bytes), n)
local rows = mentions.find(turns, cwd, mentions.rules_for(settings.link_patterns(dir), cwd))
if #rows == 0 then
	write("!Nothing to open in Claude's last " .. n .. (n == 1 and " reply" or " replies") .. ".\n")
	return
end
write(mentions.tsv(rows))
