-- Helpers the agent adapters share. Works in `rex do` scripts and in the
-- config, which both have rex.exec.
local U = {}

U.home = os.getenv("HOME") or ""

function U.read_json(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	local ok, value = pcall(rex.json.decode, text)
	return ok and value or nil
end

--- A path's last part.
function U.basename(path)
	return (tostring(path or ""):match("[^/]*$"))
end

--- Runs a command and returns rex.exec's result, or nil. The sidecar panel
--- replaces this with a runner that doesn't block its key reads.
function U.exec(argv)
	local ok, r = pcall(rex.exec, argv, { timeout = 5 })
	return ok and r or nil
end

--- Seconds from ps's etime: [[dd-]hh:]mm:ss.
function U.etime(text)
	local d, rest = tostring(text or ""):match("^(%d+)%-(.+)$")
	rest = rest or tostring(text or "")
	local seconds = 0
	for n in rest:gmatch("%d+") do
		seconds = seconds * 60 + tonumber(n)
	end
	return seconds + (tonumber(d) or 0) * 86400
end

--- A process's full command line, or nil. Rex reports only argv[0].
function U.args(pid)
	local r = pid and U.exec({ "/bin/ps", "-ww", "-o", "args=", "-p", tostring(pid) })
	local args = r and r.ok and r.stdout:gsub("%s+$", "") or ""
	return args ~= "" and args or nil
end

--- When a process started, in seconds since 1970, or nil.
function U.started(pid, now)
	local r = pid and U.exec({ "/bin/ps", "-o", "etime=", "-p", tostring(pid) })
	local etime = r and r.ok and r.stdout:match("%S+")
	return etime and ((now or os.time()) - U.etime(etime)) or nil
end

--- A string as an SQL literal.
function U.quote(s)
	return "'" .. tostring(s):gsub("'", "''") .. "'"
end

--- The rows of a read-only query, as tables, or nil when sqlite3 fails.
function U.sqlite(db, query)
	local r = U.exec({ "/usr/bin/sqlite3", "-readonly", "-json", db, query })
	if not (r and r.ok) then
		return nil
	end
	if not r.stdout:match("%S") then
		return {}
	end
	local ok, rows = pcall(rex.json.decode, r.stdout)
	return ok and type(rows) == "table" and rows or nil
end

return U
