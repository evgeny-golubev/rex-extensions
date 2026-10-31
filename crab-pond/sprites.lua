-- Pixel crabs for pond.lua: a Clawd-style crab (Claude Code's mascot, by
-- Anthropic) after crab-band's (https://github.com/MaxHarfen/crab-band, MIT),
-- redrawn at half its size. Drawn with octants (2 x 4 pixels a cell), a crab
-- is 7 columns by 3 rows.
--
-- A crab is 14 x 12 pixels. Rows 0-3 hold its hat, rows 4-9 its body and
-- arms, rows 10-11 its legs, and columns 12-13 what it holds. In a picture
-- '.' is empty and every other character is a colour from its legend ("body"
-- is the crab's own). An outfit part with `frames` swaps pictures as the crab
-- animates, and one with `fixed` stays put while the body bobs. When a pane
-- is too short, a crab gives up its pixel rows in `drop_order`.

local M = {}

M.width, M.height = 14, 12
M.drop_order = { 9, 8, 11, 0, 3, 7, 2, 1 }
M.eye = "#1F1E1D"

M.body = {
	y = 4,
	rows = {
		"..cccccccc..",
		"..ckcccckc..",
		"..cccccccc..",
		"..cccccccc..",
		"..cccccccc..",
		"..cccccccc..",
	},
}
M.arms = { left = 0, right = 10, y = 6, size = 2 }
--- Leg columns, in the two pairs that step in turn, and the legs' top row.
M.legs = { { 2, 7 }, { 4, 9 } }
M.leg_top = 10

M.outfits = {}

M.outfits.wizard = {
	{ x = 0, y = 0, rows = {
		"......t.....",
		".....ttt....",
		"....tYttt...",
		".BBBBBBBBBB.",
	}, legend = { t = "#8E7CE8", Y = "#F5C542", B = "#4E46A8" } },
	{ x = 12, y = 1, frames = {
		{ ".Y", "..", ".n", "n.", "n." },
		{ "..", "..", ".n", "n.", "n." },
	}, legend = { Y = "#F5C542", n = "#8A5A33" } },
}

M.outfits.scientist = {
	{ x = 0, y = 4, rows = { "..GWGGGGWG.." }, legend = { G = "#6B6B6B", W = "#E8F4FF" } },
	{ x = 12, y = 1, frames = {
		{ ".o", "..", "..", ".g", "gg", "LL", "LL" },
		{ "..", "o.", "..", ".g", "gg", "LL", "LL" },
		{ "..", "..", ".o", ".g", "gg", "LL", "LL" },
	}, legend = { o = "#A8F0A8", g = "#CFE8F0", L = "#5BD15B" } },
}

M.outfits.painter = {
	{ x = 0, y = 1, rows = {
		"......N.....",
		"....NNNNN...",
		"...NNNNNNN..",
	}, legend = { N = "#2F3E66" } },
	{ x = 12, y = 2, frames = {
		{ ".r", ".h", "h.", "h." },
		{ ".b", ".h", "h.", "h." },
		{ ".y", ".h", "h.", "h." },
		{ ".g", ".h", "h.", "h." },
	}, legend = { r = "#E5484D", b = "#3D7DD8", y = "#F5C542", g = "#46A758", h = "#C9A26B" } },
}

M.outfits.royal = {
	{ x = 0, y = 2, rows = {
		"...Y.YY.Y...",
		"...YYRRYY...",
	}, legend = { Y = "#F5C542", R = "#E5484D" } },
	{ x = 11, y = 1, fixed = true, frames = { { "W" }, { "." }, { "." } }, legend = { W = "#FFFFFF" } },
}

M.outfits.cowboy = {
	{ x = 0, y = 1, rows = {
		"....HHHH....",
		"....BBBB....",
		".HHHHHHHHHH.",
	}, legend = { H = "#8A5A33", B = "#3D7DD8" } },
	{ x = 11, y = 0, frames = {
		{ ".rr", "r.r", ".r.", ".r.", ".r." },
		{ "rr.", "r.r", "rr.", ".r.", ".r." },
	}, legend = { r = "#D9B26B" } },
}

M.outfits.ninja = {
	{ x = 0, y = 4, rows = { "..GGGGGGGG.." }, legend = { G = "#2FA36B" } },
	{ x = 10, y = 3, frames = {
		{ ".G", "G." },
		{ "..", "GG" },
	}, legend = { G = "#2FA36B" } },
	{ x = 12, y = 6, fixed = true, frames = { { "s" }, { "." } }, legend = { s = "#D0D6DC" } },
}

M.outfits.musician = {
	{ x = 0, y = 2, rows = {
		"...GGGGGG...",
		"..G......G..",
		".P........P.",
		".P........P.",
	}, legend = { G = "#8C8C8C", P = "#E05AA8" } },
	{ x = 12, y = 0, fixed = true, frames = {
		{ ".n", "n.", "..", ".." },
		{ "..", ".n", "n.", ".." },
		{ "..", "..", ".n", "n." },
	}, legend = { n = "#B57CF0" } },
}

M.outfits.gardener = {
	{ x = 0, y = 1, rows = {
		"....SSSS....",
		"....GGGG....",
		"..SSSSSSSS..",
	}, legend = { S = "#E8C86A", G = "#46A758" } },
	{ x = 12, y = 2, frames = {
		{ ".d", "..", ".C", "CC", "CC" },
		{ "..", ".d", ".C", "CC", "CC" },
	}, legend = { d = "#5AB0F0", C = "#3FA34D" } },
}

M.outfits.explorer = {
	{ x = 0, y = 2, rows = {
		"....HHHH....",
		".HHBBBBBBHH.",
	}, legend = { H = "#D8C9A0", B = "#8A7A50" } },
	{ x = 12, y = 5, frames = {
		{ "rW", "WW" },
		{ "WW", "Wr" },
	}, legend = { W = "#F0F0F0", r = "#E5484D" } },
}

M.outfits.planner = {
	{ x = 12, y = 3, rows = { "BB", "WW", "Wk", "WW", "kW" }, legend = { B = "#A47A4A", W = "#F0F0F0", k = "#6B6B6B" } },
}

M.outfits.lookout = {
	{ x = 11, y = 2, fixed = true, frames = {
		{ ".GG", "GWG", "GLG", ".GG", "h..", "h.." },
		{ ".GG", "GLG", "GWG", ".GG", "h..", "h.." },
	}, legend = { G = "#5B6EAE", W = "#E8F4FF", L = "#9CC8F0", h = "#8A5A33" } },
}

M.outfits.builder = {
	{ x = 0, y = 2, rows = {
		"...YYYYYY...",
		".YYYYYYYYYY.",
	}, legend = { Y = "#F2D13A" } },
	{ x = 12, y = 2, frames = {
		{ "WW", ".W", ".W", ".W" },
		{ "..", "WW", ".W", ".W" },
	}, legend = { W = "#8FA3B0" } },
}

M.outfits.coder = {
	{ x = 0, y = 5, rows = { "..cKKKKKKc.." }, legend = { K = "#1F1E1D", c = "body" } },
	{ x = 11, y = 1, fixed = true, frames = {
		{ "BBB", "BgB", "B.B", "BBB" },
		{ "BBB", "BgB", "BgB", "BBB" },
		{ "BBB", "B.B", "BgB", "BBB" },
	}, legend = { B = "#2D4FA8", g = "#4FD16B" } },
}

M.outfits.git = {
	{ x = 10, y = 0, fixed = true, frames = {
		{ "rrp", "r.p", "..p", "..p", "..p", "..p" },
		{ ".rp", "rrp", "..p", "..p", "..p", "..p" },
	}, legend = { r = "#F05033", p = "#9A9A9A" } },
}

M.outfits.server = {
	{ x = 12, y = 2, fixed = true, frames = {
		{ "VV", "Vl", "VV", "V.", "VV", "Vl", "VV", "VV" },
		{ "VV", "V.", "VV", "Vl", "VV", "V.", "VV", "VV" },
	}, legend = { V = "#6A5ACD", l = "#7CFC00" } },
}

M.outfits.diver = {
	{ x = 0, y = 5, rows = { "..MkMMMMkM.." }, legend = { M = "#5AD0E6", k = "#1F1E1D" } },
	{ x = 10, y = 0, frames = {
		{ ".o", "..", "y.", "y.", "y.", "y." },
		{ "o.", ".o", "y.", "y.", "y.", "y." },
	}, legend = { o = "#BDEFFA", y = "#F5C542" } },
}

M.outfits.sleeper = {
	{ x = 0, y = 1, rows = {
		"........CC..",
		"...CCCCC..W.",
		"..WWWWWWWW..",
	}, legend = { C = "#5B6EAE", W = "#F0F0F0" } },
}

M.outfits.robot = {
	{ x = 0, y = 1, frames = {
		{ "......t.....", "......a.....", "......a....." },
		{ "............", "......a.....", "......a....." },
	}, legend = { t = "#E5484D", a = "#9A9A9A" } },
}

M.outfits.fire = {
	{ x = 0, y = 0, frames = {
		{ "...o..y.....", "..oyo.oo.o..", "..ooyooyooo." },
		{ "....o...o...", "...oyo.oyo..", "..oyoooyoo.." },
	}, legend = { o = "#F2701A", y = "#F5C542" } },
}

M.outfits.plain = {}

return M
