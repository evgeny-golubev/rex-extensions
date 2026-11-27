-- Tells Rex how to resume a program that doesn't say so itself, with an
-- OSC 7577 report written to the program's terminal on its behalf. Rex then
-- runs the command at its next start if one of its trust rules allows it.
-- https://www.superlogical.com/rex/docs/build/program-resume.md
local M = {}

local b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.base64(s)
	local out = {}
	for i = 1, #s, 3 do
		local a, b, c = s:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local chars = 2 + (b and 1 or 0) + (c and 1 or 0)
		for j = 1, 4 do
			local k = math.floor(n / 64 ^ (4 - j)) % 64
			out[#out + 1] = j <= chars and b64:sub(k + 1, k + 1) or "="
		end
	end
	return table.concat(out)
end

--- The terminal device and OSC 7577 token of process pid, or nil. macOS
--- hides the environment of its own programs (/bin, /usr/bin), so those have
--- none here.
function M.terminal_of(pid)
	local r = rex.exec({ "/bin/ps", "-E", "-ww", "-o", "tty=,command=", "-p", tostring(pid) })
	local out = r and r.ok and r.stdout or ""
	local tty = out:match("^%s*(ttys%d+)")
	local token
	for t in out:gmatch("OSC7577_TOKEN=([%w_%-]+)") do
		token = t
	end
	if tty and token and #token >= 22 and #token <= 64 then
		return "/dev/" .. tty, token
	end
end

--- The signed report body: plain SHA-256 of the body, ":" and the token.
--- The token goes to shasum on stdin, so it never shows in the process list.
function M.body(pid, argv, cwd, token, now)
	local args = {}
	for i, a in ipairs(argv) do
		args[i] = M.base64(a)
	end
	local body = "pid=" .. pid .. ":time=" .. now .. ":argv=" .. table.concat(args, ",")
	if cwd then
		body = body .. ":cwd=" .. M.base64(cwd)
	end
	local r = rex.exec({ "/usr/bin/shasum", "-a", "256" }, { stdin = body .. ":" .. token })
	local mac = r and r.ok and r.stdout and r.stdout:match("^(%x+)")
	return mac and #mac == 64 and (body .. ":mac=" .. mac:lower()) or nil
end

--- Reports argv, run in cwd, as the way to resume process pid. Returns
--- whether a report was written; Rex may still ignore it.
function M.report(pid, argv, cwd)
	local tty, token = M.terminal_of(pid)
	if not tty then
		return false
	end
	local body = M.body(pid, argv, cwd, token, os.time())
	local f = body and io.open(tty, "w")
	if not f then
		return false
	end
	f:write("\27]7577;" .. body .. "\27\\")
	f:close()
	return true
end

return M
