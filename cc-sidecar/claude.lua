-- Finds a pane's Claude and its transcript, for panel.lua and the Rex View
-- picker. Works in `rex do` scripts and in the config, which both have rex.exec.
local M = {}

local home = os.getenv("HOME") or ""

local function read_json(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	local ok, value = pcall(rex.json.decode, text)
	return ok and value or nil
end

local function is_claude(p)
	return p ~= nil and p.argv0 ~= nil and p.argv0:match("[^/]*$") == "claude"
end

--- Claude's process ID from a terminal block's `process` call: the foreground
--- program, or the one it runs under.
function M.pid(process)
	if not process then
		return nil
	end
	if is_claude(process.foreground) then
		return process.foreground.pid
	end
	for _, p in ipairs(process.ancestors or {}) do
		if is_claude(p) then
			return p.pid
		end
	end
end

--- Claude Code keeps a project's transcripts in a folder named after its
--- directory, with every character but letters and digits made a dash.
function M.project_dir(cwd)
	return (cwd:gsub("[^%w]", "-"))
end

local found = {}

--- The transcript and current directory of the Claude with this process ID,
--- from the session file Claude Code writes for each running Claude. /cd
--- changes the directory there, and moves the transcript with it.
function M.transcript(pid)
	local dirs = { os.getenv("CLAUDE_CONFIG_DIR"), home .. "/.claude" }
	for _, dir in pairs(dirs) do
		local s = read_json(dir .. "/sessions/" .. pid .. ".json")
		if s and s.sessionId then
			local path = s.cwd and (dir .. "/projects/" .. M.project_dir(s.cwd) .. "/" .. s.sessionId .. ".jsonl")
			local f = path and io.open(path, "rb")
			if f then
				f:close()
				return path, s.cwd
			end
			if found[s.sessionId] == nil then
				local ok, r = pcall(rex.exec, { "/usr/bin/find", dir .. "/projects", "-maxdepth", "2", "-name", s.sessionId .. ".jsonl" }, { timeout = 5 })
				found[s.sessionId] = ok and r and r.ok and r.stdout:match("[^\n]+") or false
			end
			return found[s.sessionId] or nil, s.cwd
		end
	end
end

return M
