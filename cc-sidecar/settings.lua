-- The extension's settings.json, and the file a palette action leaves for the
-- watcher: Rex has no way for an action to message a running script.
local M = {}

local function read_json(path)
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	local value = rex.json.decode(text)
	return type(value) == "table" and value or nil
end

--- Written whole and renamed into place, so a reader never sees half a file.
local function write_json(path, value)
	local tmp = path .. ".tmp"
	local f = assert(io.open(tmp, "w"))
	f:write(assert(rex.json.encode(value, { indent = true })), "\n")
	f:close()
	assert(os.rename(tmp, path))
end

function M.auto_show(base)
	local settings = read_json(base .. "settings.json") or {}
	return settings.auto_show ~= false
end

function M.set_auto_show(base, on)
	local settings = read_json(base .. "settings.json") or {}
	settings.auto_show = on
	write_json(base .. "settings.json", settings)
end

function M.tree(base)
	local settings = read_json(base .. "settings.json") or {}
	return settings.tree == true
end

function M.set_tree(base, on)
	local settings = read_json(base .. "settings.json") or {}
	settings.tree = on
	write_json(base .. "settings.json", settings)
end

--- Section name -> true, for the sections folded in the panel.
function M.folded(base)
	local settings = read_json(base .. "settings.json") or {}
	return type(settings.folded) == "table" and settings.folded or {}
end

--- Read again first: other panes change the same list.
function M.set_folded(base, name, on)
	local settings = read_json(base .. "settings.json") or {}
	settings.folded = type(settings.folded) == "table" and settings.folded or {}
	settings.folded[name] = on or nil
	write_json(base .. "settings.json", settings)
end

function M.request_show(base, session_id, block_id)
	write_json(base .. "show-request.json", { session_id = session_id, block_id = block_id })
end

function M.take_show_request(base)
	local path = base .. "show-request.json"
	local request = read_json(path)
	os.remove(path)
	return request
end

return M
