-- Command-line client for the Google Tasks API, run by Rex's Lua runtime. It
-- needs only programs that come with macOS: curl, security, nc and openssl.
--
-- Run it through the google-tasks script beside it, which passes the
-- arguments, or as: rex do google-tasks.lua "argv=<arguments, each ended by
-- the byte 0x1F>".
--
-- Credentials are kept in the macOS Keychain under the service name
-- "google-tasks-client": the OAuth client configuration (account "client") and
-- the refresh token (account "refresh_token").
--
-- Commands:
--   import-client PATH          Store an OAuth client JSON file in the Keychain.
--   login                       Sign in through the browser and store the refresh token.
--   tasks [--completed-since DATE]
--                               Print the open tasks of every list as JSON. With
--                               --completed-since, the tasks completed on or after DATE
--                               (YYYY-MM-DD) follow, hidden ones included, each with the
--                               local date of completion.
--   add LIST_ID [--due DATE] [--notes TEXT] [--parent TASK_ID] [--previous TASK_ID] TITLE
--                               Create a task, as a subtask of --parent if given, after
--                               --previous if given, and print its ID as JSON.
--   update LIST_ID TASK_ID [--title TEXT] [--due DATE] [--notes TEXT] [--status STATUS]
--                               Change the given fields of a task. An empty DATE clears
--                               the due date. STATUS is needsAction or completed.
-- A missing or expired sign-in prints {"error": "auth_required"} and exits with code 3.
-- Without a stored OAuth client it prints {"error": "setup_required"} and exits with
-- code 4; standard error names the next step.

local SERVICE = "google-tasks-client"
local SCOPE = "https://www.googleapis.com/auth/tasks"
local API = "https://tasks.googleapis.com/tasks/v1"
local TOKEN_URL = "https://oauth2.googleapis.com/token"
local AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
--- The console page where test users are added.
local AUDIENCE_URL = "https://console.cloud.google.com/auth/audience"

--- Stands for JSON null in a request body; rex.json has no null of its own.
local NULL = "@@json-null@@"

local function encode(value)
	return (rex.json.encode(value):gsub('"@@json%-null@@"', "null"))
end

--- Stops with a message on standard error and the given exit code.
local function fail(message, code)
	io.stderr:write(message, "\n")
	os.exit(code or 1)
end

local function auth_required(detail)
	io.write(rex.json.encode({ error = "auth_required", detail = detail }), "\n")
	os.exit(3)
end

local function setup_required()
	io.write(rex.json.encode({ error = "setup_required" }), "\n")
	fail('Google Tasks is not set up yet: no OAuth client is stored. Ask Claude Code "set up the sidecar Tasks tab",'
		.. " or follow the Google Tasks steps in rex-sidecar/README.md.", 4)
end

local function exec(argv, stdin, timeout)
	local r = rex.exec(argv, { timeout = timeout or 30, stdin = stdin })
	return r or fail("No answer from " .. argv[1])
end

local function keychain_read(account)
	local r = exec({ "/usr/bin/security", "find-generic-password", "-s", SERVICE, "-a", account, "-w" })
	return r.ok and (r.stdout:gsub("%s+$", "")) or nil
end

local function keychain_write(account, value)
	local r = exec({ "/usr/bin/security", "add-generic-password", "-U", "-s", SERVICE, "-a", account, "-w", value })
	if not r.ok then
		fail("Keychain write failed: " .. (r.stderr or ""))
	end
end

local function client_config()
	local raw = keychain_read("client") or setup_required()
	local data = rex.json.decode(raw)
	return data.installed or data.web
end

local function url_encode(s)
	return (tostring(s):gsub("[^%w%-%._~]", function(ch)
		return string.format("%%%02X", ch:byte())
	end))
end

local function form(fields)
	local parts = {}
	for key, value in pairs(fields) do
		parts[#parts + 1] = url_encode(key) .. "=" .. url_encode(value)
	end
	table.sort(parts)
	return table.concat(parts, "&")
end

--- A value quoted for a curl configuration file.
local function quoted(s)
	return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t") .. '"'
end

--- Sends a request with curl, which reads its configuration from standard
--- input, so tokens and secrets stay out of the process list. Returns the
--- HTTP status and the body.
local function request(method, url, headers, body)
	local config = { "request = " .. quoted(method), "url = " .. quoted(url) }
	for _, header in ipairs(headers or {}) do
		config[#config + 1] = "header = " .. quoted(header)
	end
	if body then
		config[#config + 1] = "data-binary = " .. quoted(body)
	end
	local r = exec({ "/usr/bin/curl", "-sS", "-K", "-", "-w", "\n%{http_code}" }, table.concat(config, "\n") .. "\n")
	if not r.ok then
		fail("Request failed: " .. ((r.stderr or "") ~= "" and r.stderr or r.stdout))
	end
	local text, status = r.stdout:match("^(.*)\n(%d+)$")
	return tonumber(status), text or ""
end

local function post_form(url, fields)
	return request("POST", url, { "Content-Type: application/x-www-form-urlencoded" }, form(fields))
end

local function access_token()
	local client = client_config()
	local refresh = keychain_read("refresh_token") or auth_required("not signed in")
	local status, text = post_form(TOKEN_URL, {
		client_id = client.client_id,
		client_secret = client.client_secret,
		refresh_token = refresh,
		grant_type = "refresh_token",
	})
	if status == 400 or status == 401 then
		auth_required("sign-in expired")
	elseif status ~= 200 then
		fail("Token request failed with HTTP " .. tostring(status) .. ": " .. text)
	end
	return rex.json.decode(text).access_token
end

local function api(method, path, token, payload, query)
	local url = API .. path .. (query and next(query) and ("?" .. form(query)) or "")
	local headers = { "Authorization: Bearer " .. token }
	local body
	if payload then
		headers[#headers + 1] = "Content-Type: application/json"
		body = encode(payload)
	end
	local status, text = request(method, url, headers, body)
	if status < 200 or status >= 300 then
		fail("Google Tasks answered HTTP " .. status .. ": " .. (text:gsub("%s+", " ")))
	end
	return text ~= "" and rex.json.decode(text) or {}
end

local function paged(path, token, key, query)
	local items, page = {}, nil
	repeat
		local params = {}
		for k, v in pairs(query) do
			params[k] = v
		end
		params.pageToken = page
		local result = api("GET", path, token, nil, params)
		for _, item in ipairs(result[key] or {}) do
			items[#items + 1] = item
		end
		page = result.nextPageToken
	until not page
	return items
end

--- Splits arguments into the values of the named options and the rest.
local function options(args, names)
	local values, rest, i = {}, {}, 1
	while i <= #args do
		local name = args[i]:match("^%-%-(.+)$")
		if name and names[name] then
			if i + 1 > #args then
				fail("Missing value for --" .. name)
			end
			values[name] = args[i + 1]
			i = i + 2
		else
			rest[#rest + 1] = args[i]
			i = i + 1
		end
	end
	return values, rest
end

--- The API form of a YYYY-MM-DD date; an empty one clears the date.
local function due_value(date)
	return date ~= "" and (date .. "T00:00:00.000Z") or NULL
end

local utc_offset = os.time() - os.time(os.date("!*t"))

--- The local calendar date of an RFC 3339 timestamp in UTC.
local function local_date(timestamp)
	local y, mo, d, h, mi, s = timestamp:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = tonumber(h), min = tonumber(mi), sec = tonumber(s) })
	return os.date("%Y-%m-%d", t + utc_offset)
end

local function task_fields(task)
	return {
		id = task.id, title = task.title or "", due = (task.due or ""):sub(1, 10), notes = task.notes or "",
		parent = task.parent, status = task.status or "needsAction",
	}
end

local function command_tasks(args)
	local values = options(args, { ["completed-since"] = true })
	local token = access_token()
	local output = {}
	for _, list in ipairs(paged("/users/@me/lists", token, "items", { maxResults = 100 })) do
		local path = "/lists/" .. list.id .. "/tasks"
		local open = paged(path, token, "items", { showCompleted = "false", showHidden = "false", maxResults = 100 })
		table.sort(open, function(a, b)
			return (a.position or "") < (b.position or "")
		end)
		local tasks = {}
		for i, t in ipairs(open) do
			tasks[i] = task_fields(t)
		end
		if values["completed-since"] then
			-- The completedMin filter also removes open tasks, so completed tasks need a request of their own.
			local done = paged(path, token, "items", { showCompleted = "true", showHidden = "true", maxResults = 100,
				completedMin = values["completed-since"] .. "T00:00:00.000Z" })
			for _, t in ipairs(done) do
				if t.status == "completed" and t.completed then
					local fields = task_fields(t)
					fields.completed = local_date(t.completed)
					tasks[#tasks + 1] = fields
				end
			end
		end
		output[#output + 1] = { id = list.id, title = list.title, tasks = tasks }
	end
	return output
end

local function command_add(args)
	local values, words = options({ unpack(args, 2) }, { due = true, notes = true, parent = true, previous = true })
	local body = { title = table.concat(words, " ") }
	if (values.due or "") ~= "" then
		body.due = due_value(values.due)
	end
	body.notes = values.notes
	local query = { parent = values.parent, previous = values.previous }
	local task = api("POST", "/lists/" .. args[1] .. "/tasks", access_token(), body, query)
	return { id = task.id }
end

local function command_update(args)
	local values, rest = options({ unpack(args, 3) }, { title = true, due = true, notes = true, status = true })
	if #rest > 0 or not next(values) then
		fail("Usage: update LIST_ID TASK_ID [--title TEXT] [--due DATE] [--notes TEXT] [--status STATUS]")
	end
	local body = { title = values.title, notes = values.notes, status = values.status }
	if values.due then
		body.due = due_value(values.due)
	end
	if values.status == "needsAction" then
		body.completed = NULL
	end
	api("PATCH", "/lists/" .. args[1] .. "/tasks/" .. args[2], access_token(), body)
	return "updated"
end

local function command_import_client(path)
	local f = io.open(path or "", "rb") or fail("Cannot read " .. tostring(path))
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(rex.json.decode, content)
	if ok and type(data) == "table" and data.web then
		fail("This file is for a Web application client. Create a client of type Desktop app and download its JSON file.")
	elseif not (ok and type(data) == "table" and data.installed) then
		fail("This file is not an OAuth client's JSON file. Download it from Clients: https://console.cloud.google.com/auth/clients")
	end
	keychain_write("client", content)
	return "client stored"
end

--- Random URL-safe text of about n bytes of entropy.
local function random_text(n)
	local r = exec({ "/usr/bin/openssl", "rand", "-base64", tostring(n) })
	return (r.stdout:gsub("%s", ""):gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

--- The PKCE challenge of a verifier: SHA-256, base64 without padding, URL-safe.
local function challenge_of(verifier)
	local r = exec({ "/bin/sh", "-c", "/usr/bin/openssl dgst -sha256 -binary | /usr/bin/openssl base64 -A" }, verifier)
	return (r.stdout:gsub("%s", ""):gsub("%+", "-"):gsub("/", "_"):gsub("=", ""))
end

local function url_decode(s)
	return (s:gsub("%+", " "):gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

--- Waits for the browser's redirect on a local port with nc, answers it, and
--- returns the query parameters of the first request that carries them.
local function receive_redirect(port)
	local reply = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n"
		.. "Sign-in complete. This window can be closed.\r\n"
	for _ = 1, 10 do
		-- nc prints the request; head keeps its first line and ends nc.
		local r = exec({ "/bin/sh", "-c", "/usr/bin/nc -l 127.0.0.1 \"$1\" | /usr/bin/head -1", "sh", tostring(port) }, reply, 300)
		local query = r.stdout:match("^GET [^?]*%?(%S+)")
		if query then
			local params = {}
			for key, value in query:gmatch("([^&=]+)=([^&]*)") do
				params[url_decode(key)] = url_decode(value)
			end
			if params.code or params.error then
				return params
			end
		elseif r.stdout == "" then
			return {}
		end
	end
	return {}
end

local function command_login()
	local client = client_config()
	local verifier = random_text(48)
	local state = random_text(12)
	math.randomseed(os.time())
	local port = math.random(49152, 65000)
	local redirect = "http://127.0.0.1:" .. port .. "/"
	local url = AUTH_URL .. "?" .. form({
		client_id = client.client_id,
		redirect_uri = redirect,
		response_type = "code",
		scope = SCOPE,
		access_type = "offline",
		prompt = "select_account consent",
		code_challenge = challenge_of(verifier),
		code_challenge_method = "S256",
		state = state,
	})
	exec({ "/usr/bin/open", url })
	io.write("Browser opened for sign-in. Waiting up to 5 minutes.\n")
	local received = receive_redirect(port)
	if received.error == "access_denied" then
		fail("Sign-in failed: access denied. Add your Google account under Test users at " .. AUDIENCE_URL .. ", then sign in again.")
	elseif not received.error and not received.code then
		fail('Sign-in failed: no answer from the browser within 5 minutes. If Google showed "Error 403: access_denied",'
			.. " add your Google account under Test users at " .. AUDIENCE_URL .. ".")
	elseif received.state ~= state or not received.code then
		fail("Sign-in failed: " .. (received.error or "the answer did not match the request"))
	end
	local status, text = post_form(TOKEN_URL, {
		client_id = client.client_id,
		client_secret = client.client_secret,
		code = received.code,
		code_verifier = verifier,
		redirect_uri = redirect,
		grant_type = "authorization_code",
	})
	if status ~= 200 then
		fail("Sign-in failed with HTTP " .. tostring(status) .. ": " .. text)
	end
	keychain_write("refresh_token", rex.json.decode(text).refresh_token)
	return "signed in"
end

local argv = {}
for word in ((rex.args or {}).argv or ""):gmatch("([^\31]*)\31") do
	argv[#argv + 1] = word
end
local command, args = argv[1], { unpack(argv, 2) }
local result
if command == "import-client" then
	result = command_import_client(args[1])
elseif command == "login" then
	result = command_login()
elseif command == "tasks" then
	result = command_tasks(args)
elseif command == "add" then
	result = command_add(args)
elseif command == "update" then
	result = command_update(args)
else
	fail("Commands: import-client, login, tasks, add, update. See the head of google-tasks.lua.", 2)
end
io.write(type(result) == "table" and rex.json.encode(result) or result, "\n")
os.exit(0)