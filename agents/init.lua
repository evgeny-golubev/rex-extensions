-- The coding agents the extensions know, behind one interface, so cc-sidecar
-- and cc-crab-pond work the same for each. Load with
--   local agents = dofile(<repo> .. "agents/init.lua")
--
-- Every adapter has:
--   id, name                 "claude", "Claude"
--   matches(p)               whether a process from Rex's `process` call is it
--   session(pane)            the pane's session, or nil; `pane` has pid, cwd,
--                            session_id and block_id
--   subagents(sess, now)     the session's subagents, oldest first
--
-- A session has id, pid, transcript (a JSONL path), cwd, and when known name,
-- started (seconds since 1970), working, model, model_label, effort and
-- status = { window = context tokens, limits = { { label, used, resets_at } } }.
-- A subagent has id, transcript, type, description, finished, running, and
-- when known model, started and updated.
--
-- The transcript readers for the sidecar panel are in cc-sidecar/parsers/,
-- one per adapter ID.
local dir = debug.getinfo(1, "S").source:match("^@?(.*/)") or "./"

local A = {}
A.util = dofile(dir .. "util.lua")
A.claude = dofile(dir .. "claude.lua")(A.util)
A.codex = dofile(dir .. "codex.lua")(A.util)
A.list = { A.claude, A.codex }
A.by_id = { claude = A.claude, codex = A.codex }

--- The agent a process is, or nil.
function A.of(p)
	for _, adapter in ipairs(A.list) do
		if adapter.matches(p) then
			return adapter
		end
	end
end

--- The agent running in a pane, from its foreground program or one it runs
--- under, and that program's process.
function A.find(foreground, ancestors)
	local adapter = A.of(foreground)
	if adapter then
		return adapter, foreground
	end
	for _, p in ipairs(ancestors or {}) do
		adapter = A.of(p)
		if adapter then
			return adapter, p
		end
	end
end

--- The agent in a `process` call's result, its process, and that process's ID.
function A.in_process(process)
	if not process then
		return nil
	end
	local adapter, p = A.find(process.foreground, process.ancestors)
	return adapter, p, p and p.pid
end

--- A pane's agent and its session, from a `process` call's result.
function A.session(process, session_id, block_id)
	local adapter, p = A.in_process(process)
	if not adapter or not p.pid then
		return adapter
	end
	local fg = process.foreground or {}
	local sess = adapter.session({ pid = p.pid, cwd = p.cwd or fg.cwd, session_id = session_id, block_id = block_id })
	if sess then
		sess.agent = adapter
	end
	return adapter, sess
end

return A
