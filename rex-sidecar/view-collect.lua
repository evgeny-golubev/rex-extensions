-- Writes the Search Panel's list for a Claude pane, from all of Claude's replies:
--   rex do view-collect.lua session=... claude=<block> out=<file>
-- A first line starting with "!" is a message to show instead of a list.
local dir = debug.getinfo(1, "S").source:match("^@?(.*/)") or "./"
local settings = dofile(dir .. "settings.lua")
local claude = dofile(dir .. "claude.lua")
local mentions = dofile(dir .. "mentions.lua")

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

local turns = mentions.turns(mentions.tail_lines(path, math.huge), math.huge)
local rules = mentions.rules_for(settings.link_patterns(dir), cwd)
local lists = {}
for i, text in ipairs(turns) do
	lists[i] = mentions.find({ text }, cwd, rules)
end
local groups = mentions.group(lists)
if #groups == 0 then
	write("!Nothing to open in Claude's replies yet.\n")
	return
end
write(mentions.tsv(groups))
