-- The Artifacts tab: the documents, PRs, Jira issues and links that Claude's
-- replies mention. Loaded as a tab plugin; see the README.
local sidecar = ...
local panel = sidecar.panel
local mentions = dofile(sidecar.dir .. "mentions.lua")
local width, clip = sidecar.width, sidecar.clip
local colours = sidecar.colours
local reset, bold, dim, red, teal = colours.reset, colours.bold, colours.dim, colours.red, colours.teal
local viewer = sidecar.dir .. "viewer"

local A = { name = "Artifacts", interval = 2 }

--- The categories, from every reply; see refresh_artifacts.
local artifacts = nil
--- A PR's link -> its title, or false when it couldn't be looked up.
local titles = {}

--- The Artifacts tab: the Search Panel link, pinned, then a section for each
--- category of what Claude's replies mention. `groups` comes from
--- mentions.group; a click on a row opens it as the Search Panel's Enter does.


--- `titles` maps a PR's link to its title, when it's known; `who` names the
--- agent, Claude by default.
function A.artifacts_view(groups, cols, folded, focus, notice, titles, who)
	titles = titles or {}
	who = who or "Claude"
	local out = sidecar.new_lines(folded, focus)
	local link = "Search Panel"
	local built = {
		lines = out,
		pinned = { bold .. teal .. link .. reset .. dim .. "  ↗ all of " .. who .. "'s replies" .. reset, notice and (red .. notice .. reset) or "" },
		hits = { { { from = 1, to = width(link), action = { kind = "view_panel" } } } },
		rows = {},
	}
	if #groups == 0 then
		out[1] = dim .. "Nothing in " .. who .. "'s replies yet." .. reset
	end
	for _, g in ipairs(groups) do
		local n = cols
		local function row(label, note, target)
			if note == "" then
				out[#out + 1] = clip(label, n)
			else
				local room = math.max(1, n - width(note) - 2)
				out[#out + 1] = clip(label, room) .. "  " .. dim .. note .. reset
			end
			out.actions[#out] = { kind = "mention", row = target }
		end
		local style = mentions.styles[g.name] or mentions.styles.Other
		sidecar.section(out, cols, g.name, { colour = style.colour, icon = style.icon, right = tostring(#g.rows) }, function(inner)
			n = inner
			for i, r in ipairs(g.rows) do
				if i > 10 then
					out[#out + 1] = dim .. "+" .. (#g.rows - 10) .. " more · Search Panel" .. reset
					out.actions[#out] = { kind = "view_panel" }
					break
				end
				if r.kind == "pr" then
					local title = titles[r.target]
					title = title and (dim .. (r.name:match("#%d+$") or r.name) .. reset .. " " .. title)
					local own = { kind = "link", target = r.target }
					if #r.rows + (r.direct and 1 or 0) <= 1 then
						local sub = r.rows[1]
						row(title or r.name, sub and sub.sub or "", sub or own)
					else
						row(title or r.name, "", own)
						for _, sub in ipairs(r.rows) do
							row("  " .. sub.sub, "", sub)
						end
					end
				elseif r.title then
					local key = r.target:match("/browse/(%u[%u%d]*%-%d+)") or r.label
					row(dim .. key .. reset .. " " .. r.title, "", r)
				else
					row(r.label, r.note or r.kind, r)
				end
			end
		end)
	end
	built.actions, built.sections = out.actions, out.sections
	return built
end

--- The Artifacts tab's categories. Each reply is read once, as replies don't
--- change once Claude has moved on; all are read again when the transcript,
--- Claude's directory or the link patterns change.
local function refresh_artifacts()
	local patterns = sidecar.settings.link_patterns(sidecar.settings_dir)
	local ok, encoded = pcall(rex.json.encode, patterns)
	local key = (panel.cwd or "") .. "\0" .. (ok and encoded or "")
	local a = artifacts
	if not (a and a.key == key and a.state == panel.state) then
		a = { key = key, state = panel.state, per = {}, groups = {}, total = 0, rules = mentions.rules_for(patterns, panel.cwd) }
		artifacts = a
		a.changed = true
	end
	local responses = panel.state.responses
	local lists = {}
	for i = #responses, 1, -1 do
		local r, done = responses[i], a.per[i]
		if not (done and done.seq == r.seq) then
			done = { seq = r.seq, rows = mentions.find({ r.text }, panel.cwd, a.rules) }
			a.per[i] = done
			a.changed = true
			if coroutine.running() and i % 20 == 0 then
				coroutine.yield()
			end
		end
		lists[#lists + 1] = done.rows
	end
	if a.changed or a.count ~= #responses then
		a.changed, a.count = false, #responses
		a.groups, a.total = mentions.group(lists)
	end
end

--- Looks up the titles of the PRs, from GitHub through `gh`, at most 4 at a
--- time. A title is looked up once while the panel runs, and a failed lookup
--- isn't tried again.
local looking = 0
local function pr_titles(groups)
	for _, g in ipairs(groups) do
		for _, r in ipairs(g.rows) do
			if looking >= 4 then
				return
			end
			local url = r.target
			if r.kind == "pr" and titles[url] == nil and sidecar.spawn("title " .. url, function()
				local res = sidecar.run({ "/bin/sh", "-c", 'export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"; exec gh pr view "$1" --json title --jq .title', "sh", url })
				local title = res and res.ok and res.stdout:gsub("%s+$", "") or ""
				titles[url] = title ~= "" and title or false
				looking = looking - 1
			end) then
				looking = looking + 1
			end
		end
	end
end

--- Reads the replies that are new, and looks up PR titles while the tab is open.
function A.refresh()
	refresh_artifacts()
	if panel.tab == A.name then
		pr_titles(artifacts.groups)
	end
end

function A.activate()
	if artifacts then
		pr_titles(artifacts.groups)
	end
end

function A.badge()
	return artifacts and artifacts.total > 0 and artifacts.total or nil
end

function A.view(cols)
	if not panel.gathered then
		return { lines = { dim .. "Reading the session…" .. reset }, pinned = {} }
	elseif not panel.state.path then
		return { lines = { dim .. "No " .. sidecar.agent_name() .. " session found for this pane." .. reset }, pinned = {} }
	end
	local a = artifacts or { groups = {} }
	return A.artifacts_view(a.groups, cols, panel.folded, panel.focus[A.name], panel.notice, titles, sidecar.agent_name())
end

--- What a click on a row does: the Search Panel's Enter. A link opens in the
--- background.
local function open_mention(row)
	if row.kind == "link" then
		if row.target:match("^https?://") then
			sidecar.spawn("open " .. row.target, function()
				sidecar.run({ "/usr/bin/open", row.target })
			end)
		end
		return
	end
	local f = io.open(viewer, "rb")
	local command = { viewer, row.target, row.line }
	if f then
		f:close()
	else
		command = { "/usr/bin/less", "-R", "--", row.target }
	end
	return sidecar.open_float(sidecar.view_label .. (row.target:match("[^/]+$") or row.target), command, row.target:match("^(.*)/[^/]*$"))
end

local function open_view_panel()
	if not panel.claude then
		return "No agent pane for this sidecar."
	end
	return sidecar.open_float(sidecar.view_label .. "Search Panel", { sidecar.dir .. "view-picker", sidecar.rex_binary, panel.session_id, panel.claude }, panel.cwd)
end

function A.act(action)
	if action.kind == "mention" then
		panel.notice = open_mention(action.row)
	elseif action.kind == "view_panel" then
		panel.notice = open_view_panel()
	end
end

return A
