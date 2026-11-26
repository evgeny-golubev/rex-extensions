-- Shared helpers for rex-hub: agent command building, run metadata storage,
-- label detection, and reading child outputs. Pure Lua so it can be loaded by
-- rex-hub/init.lua, rex-sidecar/panel.lua, and unit tests.

local M = {}

local home = os.getenv("HOME") or ""

M.label_prefix = "Hub: "
M.supported_agents = { claude = true, codex = true, agy = true, pi = true, opencode = true }

function M.state_dir()
	return REX_HUB_STATE_DIR or (home .. "/.config/rex/state/hub")
end

function M.is_hub_label(label)
	return type(label) == "string" and label:sub(1, #M.label_prefix) == M.label_prefix
end

function M.hub_label(agent, task)
	local short = tostring(task or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
	local chars = {}
	for ch in short:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		chars[#chars + 1] = ch
	end
	if #chars > 36 then
		short = table.concat(chars, "", 1, 35) .. "…"
	end
	if short == "" then
		return M.label_prefix .. tostring(agent or "agent")
	end
	return M.label_prefix .. tostring(agent or "agent") .. " · " .. short
end

--- Strips ANSI escape sequences and carriage returns for clean agent consumption.
function M.strip_ansi(text)
	local s = tostring(text or "")
	s = s:gsub("\27%[[%d;?]*[A-Za-z]", "")
	s = s:gsub("\27%][^\7\27]*[\7]", "")
	s = s:gsub("\27%][^\27]*\27\\", "")
	s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
	return s
end

--- Builds the CLI argv for launching `agent` in `oneshot` or `interactive` mode.
function M.build_command(agent, mode, task, model)
	agent = tostring(agent or ""):lower()
	mode = mode or "oneshot"
	task = tostring(task or "")
	if not M.supported_agents[agent] then
		return nil, "unsupported agent: " .. agent .. " (expected claude, codex, agy, pi or opencode)"
	end
	if mode ~= "oneshot" and mode ~= "interactive" then
		return nil, "unsupported mode: " .. tostring(mode) .. " (expected oneshot or interactive)"
	end
	if mode == "oneshot" and task == "" then
		return nil, "task is required for oneshot mode"
	end
	if agent == "opencode" and mode == "interactive" and model and model ~= "" then
		return nil, "opencode takes no model in interactive mode (only opencode run does)"
	end
	-- A task starting with "-" would be read as an option, and with "@" as a
	-- file by pi; a leading space keeps it a plain prompt for every CLI.
	if task:match("^[%-@]") then
		task = " " .. task
	end

	local argv
	if agent == "claude" then
		argv = { "claude" }
		if model and model ~= "" then
			argv[#argv + 1] = "--model"
			argv[#argv + 1] = model
		end
		if mode == "oneshot" then
			argv[#argv + 1] = "-p"
			argv[#argv + 1] = task
		elseif task ~= "" then
			argv[#argv + 1] = task
		end
	elseif agent == "codex" then
		if mode == "oneshot" then
			argv = { "codex", "exec" }
		else
			argv = { "codex" }
		end
		if model and model ~= "" then
			argv[#argv + 1] = "-m"
			argv[#argv + 1] = model
		end
		if task ~= "" then
			argv[#argv + 1] = task
		end
	elseif agent == "agy" then
		argv = { "agy" }
		if model and model ~= "" then
			argv[#argv + 1] = "--model"
			argv[#argv + 1] = model
		end
		if mode == "oneshot" then
			argv[#argv + 1] = "-p"
			argv[#argv + 1] = task
		elseif task ~= "" then
			argv[#argv + 1] = "-i"
			argv[#argv + 1] = task
		end
	elseif agent == "pi" then
		argv = { "pi" }
		if model and model ~= "" then
			argv[#argv + 1] = "--model"
			argv[#argv + 1] = model
		end
		if mode == "oneshot" then
			argv[#argv + 1] = "-p"
			argv[#argv + 1] = task
		elseif task ~= "" then
			argv[#argv + 1] = task
		end
	elseif agent == "opencode" then
		if mode == "oneshot" then
			argv = { "opencode", "run" }
			if model and model ~= "" then
				argv[#argv + 1] = "-m"
				argv[#argv + 1] = model
			end
			argv[#argv + 1] = task
		else
			argv = { "opencode" }
			if task ~= "" then
				argv[#argv + 1] = "--prompt"
				argv[#argv + 1] = task
			end
		end
	end
	return argv
end

local function ensure_dir(path)
	if rex and rex.exec then
		rex.exec({ "/bin/mkdir", "-p", path }, { timeout = 5 })
	else
		os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
	end
end

--- Run IDs name files in the state folder, so nothing else is accepted.
function M.valid_id(id)
	return type(id) == "string" and id:match("^[%w_%-]+$") ~= nil
end

function M.run_path(dir, id)
	return dir .. "/" .. id .. ".json"
end

--- A oneshot run's answer, as Markdown.
function M.result_path(dir, id)
	return dir .. "/" .. id .. ".md"
end

--- A oneshot run's stderr.
function M.error_path(dir, id)
	return dir .. "/" .. id .. ".err"
end

--- Written once by run-wrapper.sh when the agent ends.
function M.exit_path(dir, id)
	return dir .. "/" .. id .. ".exit"
end

function M.new_id(agent, dir)
	dir = dir or M.state_dir()
	while true do
		local id = string.format("%s-%d-%d", tostring(agent or "run"), os.time(), math.random(100000, 999999))
		local f = io.open(M.run_path(dir, id), "r")
		if not f then
			return id
		end
		f:close()
	end
end

function M.save_run(dir, run)
	dir = dir or M.state_dir()
	if not M.valid_id(run.id) then
		return nil, "invalid run id"
	end
	ensure_dir(dir)
	local path = M.run_path(dir, run.id)
	local tmp = path .. ".tmp." .. tostring(math.random(10000, 99999))
	local f, err = io.open(tmp, "w")
	if not f then
		return nil, err
	end
	f:write(rex.json.encode(run))
	f:close()
	os.rename(tmp, path)
	return path
end

--- Loads a run, merged with its exit record: the exit only fills in a run
--- still marked "running", so hub_run's "timeout" and hub_stop's "stopped" stay.
function M.load_run(dir, id)
	dir = dir or M.state_dir()
	if not M.valid_id(id) then
		return nil
	end
	local f = io.open(M.run_path(dir, id), "r")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	local ok, data = pcall(rex.json.decode, text)
	if not ok or type(data) ~= "table" then
		return nil
	end
	local e = io.open(M.exit_path(dir, id), "r")
	if e then
		local status, code, finished = (e:read("*l") or ""):match("^(%a+) (%d+) (%d+)")
		e:close()
		if status then
			if data.status == "running" then
				data.status = status
				data.finished = tonumber(finished)
			end
			if data.exit_code == nil then
				data.exit_code = tonumber(code)
			end
			data.layer_state = "closed"
		end
	end
	return data
end

--- Deletes the files of runs that ended more than `days` days ago.
function M.prune(dir, days)
	dir = dir or M.state_dir()
	local cutoff = os.time() - days * 86400
	for _, run in ipairs(M.list_runs(dir)) do
		if run.status ~= "running" and (run.finished or run.started or 0) < cutoff then
			os.remove(M.run_path(dir, run.id))
			os.remove(M.result_path(dir, run.id))
			os.remove(M.error_path(dir, run.id))
			os.remove(M.exit_path(dir, run.id))
		end
	end
end

--- Lists saved runs in `dir`, optionally filtered by `filter` ({ parent_block_id, session_id, status }).
--- Sorted oldest first by `started`.
function M.list_runs(dir, filter)
	dir = dir or M.state_dir()
	local r = rex and rex.exec and rex.exec({ "/bin/ls", "-1", dir }, { timeout = 3 })
	if not r or not r.ok or not r.stdout or r.stdout == "" then
		return {}
	end
	local runs = {}
	for name in r.stdout:gmatch("[^\n]+") do
		local id = name:match("^(.+)%.json$")
		if id then
			local run = M.load_run(dir, id)
			if run then
				local keep = true
				if filter then
					if filter.parent_block_id and run.parent_block_id ~= filter.parent_block_id then
						keep = false
					end
					if filter.session_id and run.session_id ~= filter.session_id then
						keep = false
					end
					if filter.window_id and run.window_id ~= filter.window_id then
						keep = false
					end
					if filter.status and run.status ~= filter.status then
						keep = false
					end
				end
				if keep then
					runs[#runs + 1] = run
				end
			end
		end
	end
	table.sort(runs, function(a, b)
		if (a.started or 0) ~= (b.started or 0) then
			return (a.started or 0) < (b.started or 0)
		end
		return tostring(a.id) < tostring(b.id)
	end)
	return runs
end

--- Reads the saved output file of a oneshot run (ANSI-stripped and trimmed).
function M.read_output_file(path, max_bytes)
	if not path then
		return nil
	end
	local f = io.open(path, "r")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	if not text then
		return nil
	end
	text = M.strip_ansi(text):gsub("^%s+", ""):gsub("%s+$", "")
	if max_bytes and #text > max_bytes then
		text = "…(truncated)…\n" .. text:sub(-max_bytes):gsub("^[\128-\191]+", "")
	end
	return text
end

return M
