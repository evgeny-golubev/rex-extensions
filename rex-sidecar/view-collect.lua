-- Writes the Search Panel's list for an agent's pane, from all of its replies:
--   rex do view-collect.lua session=... claude=<block> out=<file>
-- A first line starting with "!" is a message to show instead of a list.
local dir = debug.getinfo(1, "S").source:match("^@?(.*/)") or "./"
local settings = dofile(dir .. "settings.lua")
local agents = dofile(dir .. "../agents/init.lua")
local mentions = dofile(dir .. "mentions.lua")

local function write(text)
	local f = assert(io.open(rex.args.out, "wb"))
	f:write(text)
	f:close()
end

local process = rex.block.call("com.superlogical.terminal", "process", { session_id = rex.args.session, block_id = rex.args.claude })
local adapter, sess = agents.session(process, rex.args.session, rex.args.claude)
local path, cwd = sess and sess.transcript, sess and sess.cwd
if not path then
	write("!No " .. (adapter and adapter.name or "agent") .. " session found in this tab.\n")
	return
end

-- A parser's `turns` needs only mentions of the panel's helpers.
local parser = dofile(dir .. "parsers/" .. adapter.id .. ".lua")({ mentions = mentions })
local turns = parser.turns(mentions.tail_lines(path, math.huge), math.huge)
local rules = mentions.rules_for(settings.link_patterns(dir), cwd)
local lists = {}
for i, text in ipairs(turns) do
	lists[i] = mentions.find({ text }, cwd, rules)
end
local groups = mentions.group(lists)
if #groups == 0 then
	write("!Nothing to open in " .. adapter.name .. "'s replies yet.\n")
	return
end
write(mentions.tsv(groups))
