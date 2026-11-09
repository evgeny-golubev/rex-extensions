-- What Claude's last replies mention, for the Rex View picker: files that
-- exist, images, links, and text that a link pattern turns into a link.
local M = {}

local home = os.getenv("HOME") or ""
local max_rows = 100
local images = { png = true, jpg = true, jpeg = true, gif = true, webp = true }

local function decode(line)
	local ok, value = pcall(rex.json.decode, line)
	return ok and type(value) == "table" and value or nil
end

--- A prompt starts a turn; tool results come back as user records too.
local function is_prompt(record)
	if record.type ~= "user" or record.isMeta or record.isSidechain or record.isCompactSummary then
		return false
	end
	local content = (record.message or {}).content
	if type(content) == "string" then
		return true
	end
	if type(content) ~= "table" then
		return false
	end
	local text = false
	for _, item in ipairs(content) do
		if type(item) == "table" and item.type == "tool_result" then
			return false
		end
		text = text or (type(item) == "table" and item.type == "text")
	end
	return text
end

local function texts_of(record)
	if record.type ~= "assistant" or record.isSidechain then
		return {}
	end
	local out = {}
	for _, item in ipairs((record.message or {}).content or {}) do
		if type(item) == "table" and item.type == "text" and type(item.text) == "string" then
			out[#out + 1] = item.text
		end
	end
	return out
end

--- Claude's final message in each of the last n turns, newest first, from
--- transcript lines in file order: its last text before the next prompt, as the
--- Log tab's Responses. Only lines that can hold a prompt or a reply are
--- decoded, as tool output fills most of a transcript.
function M.turns(lines, n)
	local turns, current = {}, nil
	local function close()
		if current then
			turns[#turns + 1] = current
		end
		current = nil
	end
	for i = #lines, 1, -1 do
		local line = lines[i]
		local assistant = line:find('"type":"assistant"', 1, true)
		local user = not assistant and line:find('"type":"user"', 1, true)
		local record = (assistant or user) and decode(line)
		if record then
			local texts = texts_of(record)
			for j = #texts, 1, -1 do
				if not current and texts[j]:match("%S") then
					current = texts[j]
				end
			end
			if is_prompt(record) then
				close()
				if #turns >= n then
					break
				end
			end
		end
	end
	close()
	while #turns > n do
		turns[#turns] = nil
	end
	return turns
end

--- The lines of the last `limit` bytes of a file, without a cut first line.
function M.tail_lines(path, limit)
	local f = io.open(path, "rb")
	if not f then
		return {}
	end
	local size = f:seek("end")
	local start = math.max(0, size - limit)
	f:seek("set", start)
	local text = f:read("*a") or ""
	f:close()
	-- A plain find: this Lua gives up on patterns over megabytes of text.
	local lines, pos = {}, 1
	while pos <= #text do
		local nl = text:find("\n", pos, true) or (#text + 1)
		if nl > pos then
			lines[#lines + 1] = text:sub(pos, nl - 1)
		end
		pos = nl + 1
	end
	if start > 0 then
		table.remove(lines, 1)
	end
	return lines
end

--- "file", "dir" or nil. Reading a folder fails with an error, while an empty
--- file just ends.
function M.kind(path)
	local f = io.open(path, "rb")
	if not f then
		return nil
	end
	local data, err = f:read(1)
	f:close()
	if data == nil and err then
		return "dir"
	end
	return "file"
end

local function shorten(path, cwd)
	if cwd and path:sub(1, #cwd + 1) == cwd .. "/" then
		return path:sub(#cwd + 2)
	end
	if home ~= "" and path:sub(1, #home + 1) == home .. "/" then
		return "~/" .. path:sub(#home + 2)
	end
	return path
end

--- A word that may name a file, as a path and an optional line.
function M.path_token(word)
	local t = word:gsub("^[%(%[{\"'<*_`]+", ""):gsub("[%)%]}\"'>*_`,;!?.:]+$", "")
	if t == "" or #t > 1024 or t:find("://", 1, true) or t:find("[%c]") then
		return nil
	end
	local path, line = t:match("^(.-):(%d+):%d+$")
	if not path then
		path, line = t:match("^(.-):(%d+)$")
	end
	path = path or t
	if not (path:find("/", 1, true) or path:match("%.%w+$")) then
		return nil
	end
	return path, line
end

local function resolve(path, cwd)
	if path:sub(1, 2) == "~/" then
		return home .. path:sub(2)
	elseif path:sub(1, 1) == "/" then
		return path
	end
	return ((cwd or "") .. "/" .. path:gsub("^%./", ""))
end

local function words(text)
	local out = {}
	for span in text:gmatch("`([^`\n]+)`") do
		out[#out + 1] = span
	end
	for target in text:gmatch("%]%(([^%)%s]+)%)") do
		out[#out + 1] = target
	end
	for word in text:gmatch("%S+") do
		out[#out + 1] = word
	end
	return out
end

local function urls(text)
	local out = {}
	for url in text:gmatch("https?://[^%s<>\"'`%)%]]+") do
		out[#out + 1] = (url:gsub("[.,;:!?]+$", ""))
	end
	return out
end

--- A directory as settings.json keeps it: absolute, with ~ expanded and no
--- trailing slash.
function M.dir_key(dir)
	if dir == "~" then
		dir = home
	elseif dir:sub(1, 2) == "~/" then
		dir = home .. dir:sub(2)
	end
	dir = dir:gsub("/+$", "")
	return dir == "" and "/" or dir
end

--- The link rules for a directory, nearest first: its own patterns, then its
--- parent's, up to "/", which holds the ones for every project. A pattern set
--- nearer wins. A pattern saved without a directory counts as one for "/".
function M.rules_for(link_patterns, cwd)
	local by_dir = { ["/"] = {} }
	for key, value in pairs(link_patterns or {}) do
		if type(value) == "table" then
			local d = M.dir_key(key)
			by_dir[d] = by_dir[d] or {}
			for pattern, basis in pairs(value) do
				by_dir[d][pattern] = basis
			end
		elseif type(value) == "string" then
			by_dir["/"][key] = value
		end
	end
	local rules, taken = {}, {}
	local d = M.dir_key(cwd or "/")
	while true do
		local list = {}
		for pattern, basis in pairs(by_dir[d] or {}) do
			if type(pattern) == "string" and pattern ~= "" and not taken[pattern]
				and type(basis) == "string" and basis:match("^https?://") then
				list[#list + 1] = { pattern = pattern, basis = basis, dir = d }
			end
		end
		table.sort(list, function(x, y)
			return x.pattern < y.pattern
		end)
		for _, rule in ipairs(list) do
			taken[rule.pattern] = true
			rules[#rules + 1] = rule
		end
		if d == "/" then
			break
		end
		d = d:match("^(.*)/[^/]*$")
		d = (d == nil or d == "") and "/" or d
	end
	return rules
end

--- Each match of a Lua pattern, as the text and the part a capture took, if
--- any. A pattern that doesn't compile matches nothing. Rex's Lua has no %f, so
--- a pattern needs a non-letter before a key with %W; the text is padded with
--- line breaks so that also works at its start and end.
local function matches(text, pattern)
	text = "\n" .. text .. "\n"
	local out, init = {}, 1
	while init <= #text and #out < max_rows do
		local ok, s, e, capture = pcall(string.find, text, pattern, init)
		if not ok or not s then
			break
		end
		if e >= s then
			local found = text:sub(s, e):gsub("^[%s%(%[{\"'<]+", ""):gsub("%s+$", "")
			out[#out + 1] = { text = found, value = type(capture) == "string" and capture or found }
		end
		init = math.max(e, s) + 1
	end
	return out
end

--- The rows for the picker, from the newest turn to the oldest. `rules` comes
--- from M.rules_for. `kind` tells files from folders, and is M.kind outside the
--- tests.
function M.find(turns, cwd, rules, kind)
	kind = kind or M.kind
	local rows, seen = {}, {}
	local function add(row, key)
		if not seen[key] and #rows < max_rows then
			seen[key] = true
			rows[#rows + 1] = row
		end
	end
	rules = rules or {}
	for _, text in ipairs(turns) do
		for _, word in ipairs(words(text)) do
			local path, line = M.path_token(word)
			local full = path and resolve(path, cwd)
			if full and kind(full) == "file" then
				local ext = (full:match("%.(%w+)$") or ""):lower()
				local is_image = images[ext]
				local shown = shorten(full, cwd)
				add({
					kind = is_image and "image" or "text",
					label = shown .. ((line and not is_image) and (":" .. line) or ""),
					target = full,
					line = (not is_image) and line or nil,
				}, full .. ":" .. (line or ""))
			end
		end
		for _, url in ipairs(urls(text)) do
			add({ kind = "link", label = url:gsub("^https?://", ""), target = url }, url)
		end
		for _, rule in ipairs(rules) do
			for _, m in ipairs(matches(text, rule.pattern)) do
				local link = rule.basis .. m.value
				add({ kind = "link", label = m.text, target = link, note = rule.basis:match("^https?://([^/]+)") }, link)
			end
		end
	end
	return rows
end

local function clean(s)
	return (tostring(s or ""):gsub("[%c]", " "))
end

--- The picker's list: what's shown, then the target, line and kind, split by
--- tabs.
function M.tsv(rows)
	local out = {}
	for _, r in ipairs(rows) do
		local note = r.note or r.kind
		local shown = clean(r.label) .. "  \27[2m" .. clean(note) .. "\27[0m"
		out[#out + 1] = table.concat({ shown, clean(r.target), clean(r.line), r.kind }, "\t")
	end
	return table.concat(out, "\n") .. (#out > 0 and "\n" or "")
end

return M
