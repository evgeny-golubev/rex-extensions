-- Opens the viewer in a floating pane in the tab that holds this terminal.
local M = {}
local label_prefix = "View: "

--- The window that holds a block, from a session view.
function M.window_of(view, block_id)
	for _, w in ipairs(view.windows or {}) do
		for _, l in ipairs(w.layers or {}) do
			for _, b in ipairs(l.blocks or {}) do
				if b.block_id == block_id then
					return w
				end
			end
		end
	end
end

--- The floats an earlier show left in a window.
function M.old_layers(window)
	local found = {}
	for _, l in ipairs(window.layers or {}) do
		if l.kind ~= "tiled" then
			for _, b in ipairs(l.blocks or {}) do
				if (b.label or ""):sub(1, #label_prefix) == label_prefix then
					found[#found + 1] = l.layer_id
					break
				end
			end
		end
	end
	return found
end

function M.request(session_id, window_id, viewer, path, line)
	local command = { viewer, path }
	if line and line ~= "" then
		command[3] = tostring(line)
	end
	return {
		session_id = session_id,
		window_id = window_id,
		bounds = { 0.1, 0.075, 0.8, 0.85 },
		focus = true,
		layout = {
			block = {
				flavor = "com.superlogical.terminal.shell",
				label = label_prefix .. path:match("[^/]+$"),
				options = { command = command, cwd = path:match("^(.*)/[^/]*$") or "/" },
			},
		},
	}
end

if REX_VIEW_TEST then
	return M
end

local session_id, block_id = os.getenv("REX_SESSION"), os.getenv("REX_BLOCK")
local attached, err = rex.call("session.attach", { session_id = session_id })
if err ~= nil then
	error("rex-view: " .. tostring(err), 0)
end
local window = M.window_of(attached.view, block_id)
if not window then
	error("rex-view: this terminal's tab wasn't found in the session", 0)
end
for _, id in ipairs(M.old_layers(window)) do
	rex.call("session.close_layer", { session_id = session_id, layer_id = id })
end
local _, opened = rex.call("session.new_layer", M.request(session_id, window.window_id, rex.args.viewer, rex.args.path, rex.args.line))
if opened ~= nil then
	error("rex-view: " .. tostring(opened), 0)
end
return "opened " .. rex.args.path
