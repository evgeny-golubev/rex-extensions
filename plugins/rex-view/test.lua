-- Run: rex do ~/.config/rex/extensions/plugins/rex-view/test.lua
local dir = debug.getinfo(1, "S").source:match("^@?(.*/)")
REX_VIEW_TEST = true
local M = dofile(dir .. "skills/rex-view/scripts/show.lua")
REX_VIEW_TEST = nil

local function equal(actual, expected, what)
	if actual ~= expected then
		error(what .. ": " .. tostring(actual) .. " ~= " .. tostring(expected), 2)
	end
end

local mine = {
	window_id = "window:2",
	layers = {
		{ layer_id = "layer:t", kind = "tiled", blocks = { { block_id = "block:me", label = "shell" } } },
		{ layer_id = "layer:v", kind = "floating", blocks = { { block_id = "block:v", label = "View: a.md" } } },
		{ layer_id = "layer:o", kind = "floating", blocks = { { block_id = "block:o", label = "scratch" } } },
	},
}
local view = { windows = { { window_id = "window:1", layers = { { kind = "tiled", blocks = { { block_id = "block:x" } } } } }, mine } }

equal(M.window_of(view, "block:me"), mine, "this terminal's tab, not the first one")
equal(M.window_of(view, "block:none"), nil, "unknown block")

local old = M.old_layers(mine)
equal(#old, 1, "only earlier viewer floats are replaced")
equal(old[1], "layer:v", "the viewer float")

local r = M.request("session:1", "window:2", "/s/viewer", "/src/my app/a.lua", "12")
equal(r.window_id, "window:2", "opens in this tab")
equal(r.focus, true, "takes focus")
local b = r.layout.block
equal(b.label, "View: a.lua", "label")
equal(b.options.cwd, "/src/my app", "cwd")
equal(b.options.command[2], "/src/my app/a.lua", "path")
equal(b.options.command[3], "12", "line")
equal(M.request("s", "w", "/v", "/a.md", "").layout.block.options.command[3], nil, "no line")
equal(M.request("s", "w", "/v", "/a.md", 3).layout.block.options.command[3], "3", "a line that rex do made a number")
equal(r.bounds[1] + r.bounds[3] <= 1 and r.bounds[2] + r.bounds[4] <= 1, true, "fits the tab")

local u = M.request("s", "w", "/v", "https://example.com/a/?q=1", "").layout.block
equal(u.label, "View: example.com", "a URL's label is its host")
equal(u.options.command[2], "https://example.com/a/?q=1", "the whole URL")
equal(u.options.cwd, nil, "a URL has no folder")
equal(M.label("https://example.com/"), "View: example.com", "a URL ending in a slash")
equal(M.label("localhost:3000/app"), "View: localhost:3000", "localhost")
equal(M.label("/src/report.html"), "View: report.html", "an HTML file")
return "rex-view: all tests passed"
