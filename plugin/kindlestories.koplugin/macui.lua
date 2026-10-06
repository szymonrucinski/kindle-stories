-- Vendored from kindle-ui b3d20bcdeb23d2c19b5fe707514dddb6503d2aa2:src/lib/macui.lua by scripts/sync-kit.sh; edit it there, not here.
--[[--
macui: Macintosh System 1 (1984) widgets for KOReader plugins.

The single implementation of docs/specs/2026-10-02-system1-design.md, shared by every plugin in
this repo so they all look alike. A plugin symlinks this file into its folder (deploy.sh copies
the real file) and loads it with:

    local macui = dofile(PLUGIN_DIR .. "macui.lua")

Geometry is written in "design px": Kindle Stories' 600x800 coordinates. macui.U converts them to
screen pixels as a whole number (3 on the 1860x2480 Scribe, 1 on a 600x800 Kindle), so every
stroke, stripe and font pixel lands on whole screen pixels and stays pure black and white.

An app is a macui.App: full screen desktop, menu bar with pull-down menus, a cascade of windows,
an optional button dialog at the bottom, and modal alerts / progress dialogs. Each window shows
one content object: macui.List, macui.Grid, macui.Text, or any table with
paint(bb, rect) and optional tap(pos, rect) / hold(pos, rect) / status() / pages() / setPage(n).
]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderImage = require("ui/renderimage")
local RenderText = require("ui/rendertext")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local Screen = Device.screen

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local M = { BLACK = BLACK, WHITE = WHITE }

M.AUTHOR = "Szymon Rucinski"

-- The one typeface (spec rule 2): change it here and every app follows.
-- grid: design size of a pixel font; sizes snap down to its multiples so each font pixel covers
-- whole screen pixels. ascii: the font has no typographic punctuation (quotes, dashes, ellipsis),
-- so text is folded to ASCII before drawing. Use { file = "X.ttf" } for an outline font.
-- The value lives in G_reader_settings "macui_font", shared with the main UI's font patch
-- (patches/2-macui-font.lua), so one setting switches every screen.
M.FONT = G_reader_settings and G_reader_settings:readSetting("macui_font") or { file = "ChicagoFLF-PL.ttf" }
-- The monospace companion (terminal, code), shared with the main UI's mono font slots.
M.MONO = G_reader_settings and G_reader_settings:readSetting("macui_font_mono")
    or { file = "AnonymousPro-Regular.ttf" }
-- The reading face for paragraphs (abstracts, summaries, articles): Chicago is a menu font and
-- tiring in long text; the original Mac set documents in New York, a serif. Bookerly is the
-- Kindle's own e-ink serif (on the device, not copied); Noto Serif ships with KOReader.
M.READ = G_reader_settings and G_reader_settings:readSetting("macui_font_read")
    or {
        file = "Bookerly-Regular.ttf",
        bold = "Bookerly-Bold.ttf",
        fallback = "NotoSerif-Regular.ttf",
        fallback_bold = "NotoSerif-Bold.ttf",
    }
M.SIZES = {
    menu = 17,
    title = 17,
    body = 19,
    small = 14,
    tiny = 12,
    big = 28,
    mono = 12,
    read = 16,
    read_bold = 16,
}

M.ICON_DIRS = { "/mnt/us/koreader/icons-mac/" }

-- Window chrome in design px (Kindle Stories' numbers), shared by M.window and M.App.
local TITLE_PX, STATUS_PX, SHADOW_PX = 34, 32, 4

--------------------------------------------------------------------------------------------------
-- Units
--------------------------------------------------------------------------------------------------

M.U = math.max(1, math.floor(math.min(Screen:getWidth(), Screen:getHeight()) / 600 + 0.1))
local U = M.U
local function u(n) return math.floor(n * U + 0.5) end
M.u = u

-- Design-px canvas size (620x826 on the Scribe).
M.W, M.H = Screen:getWidth() / U, Screen:getHeight() / U

-- Desktop dither cell in screen px: matches the physical grain of the 167 dpi original.
local CELL = math.max(1, math.floor((Device.display_dpi or Screen:getDPI()) / 167 + 0.5))
M.CELL = CELL

--------------------------------------------------------------------------------------------------
-- Type
--------------------------------------------------------------------------------------------------

local faces = {}

-- The face for a type role. KOReader's own cfont/infont is the last resort; if even that fails, this raises
-- here instead of returning nil to fail later in a paint.
---@return table
function M.face(role, scale)
    if scale and scale ~= 1 then
        return M.faceScaled(role, scale)
    end
    local face = faces[role]
    if face then
        return face
    end
    local font = role == "mono" and M.MONO or M.FONT
    if role == "read" or role == "read_bold" then
        local bold = role == "read_bold"
        font = {
            file = bold and M.READ.bold or M.READ.file,
            fallback = bold and M.READ.fallback_bold or M.READ.fallback,
        }
    end
    local px = (M.SIZES[role] or M.SIZES.body) * U
    local g = font.grid
    if g then
        px = math.max(g, math.floor(px / g) * g)
    end
    -- Font:getFace multiplies its size by scaleBySize (rounding up); divide first to get px exactly.
    local k = Screen:scaleBySize(1000000) / 1000000
    face = Font:getFace(font.file, (px - 0.5) / k)
        or (font.fallback and Font:getFace(font.fallback, (px - 0.5) / k))
        or assert(Font:getFace(role == "mono" and "infont" or "cfont", M.SIZES[role]), "no font for " .. role)
    faces[role] = face
    return face
end

-- A role's face at a different size (e.g. a reader's text-size setting), cached per scale.
---@return table
function M.faceScaled(role, scale)
    local key = role .. "@" .. scale
    if faces[key] then
        return faces[key]
    end
    local saved = M.SIZES[role]
    M.SIZES[role] = saved * scale
    local cached = faces[role]
    faces[role] = nil
    local f = M.face(role)
    faces[role] = cached
    M.SIZES[role] = saved
    faces[key] = f
    return f
end

-- Pixel fonts lack these; folding keeps every glyph in the one typeface.
local FOLD = {
    { " · ", "   " },
    { "·", "-" },
    { "“", '"' },
    { "”", '"' },
    { "‘", "'" },
    { "’", "'" },
    { "…", "..." },
    { "—", "--" },
    { "–", "-" },
    { "•", "*" },
    { "→", "->" },
    { "←", "<-" },
    { "×", "x" },
    { "✓", "" },
    { "◀", "<" },
    { "▶", ">" },
}

function M.fold(str)
    if not M.FONT.ascii or not str then
        return str
    end
    for _, p in ipairs(FOLD) do
        str = str:gsub(p[1], p[2])
    end
    return str
end

local function rawWidth(face, str) return RenderText:sizeUtf8Text(0, Screen:getWidth(), face, str, true).x end

function M.width(face, str) return rawWidth(face, M.fold(str)) end

-- Cuts str to max_w screen px, ending in "..." (the font may lack "…").
function M.truncate(face, str, max_w)
    str = M.fold(str)
    if rawWidth(face, str) <= max_w then
        return str
    end
    local chars = util.splitToChars(str)
    local ell = M.FONT.ascii and "..." or "…"
    local function cut(n) return table.concat(chars, "", 1, n):gsub("%s+$", "") .. ell end
    -- binary search for the longest prefix that fits: ~log2(n) measurements instead of n
    local lo, hi = 0, #chars - 1
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        if rawWidth(face, cut(mid)) <= max_w then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return lo > 0 and cut(lo) or ell
end

-- Word-wraps str into at most max_lines lines of max_w screen px; the last line is truncated.
function M.wrap(face, str, max_w, max_lines)
    str = M.fold(str)
    local lines, line = {}, ""
    for word in str:gmatch("%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if rawWidth(face, try) <= max_w or line == "" then
            line = try
        else
            if #lines == max_lines - 1 then
                break
            end
            table.insert(lines, line)
            line = word
        end
    end
    local used = table.concat(lines, " ") .. (line ~= "" and (" " .. line) or "")
    if #used:gsub("^%s+", "") < #str then
        line = line .. " " .. str:sub(#used:gsub("^%s+", "") + 1) -- force the cut on the last line
    end
    table.insert(lines, M.truncate(face, line, max_w))
    return lines
end

-- Baseline that vertically centres face's cap height in a box at y of height h (screen px).
function M.baseline(face, y, h)
    local fh, asc = face.ftsize:getHeightAndAscender()
    return y + math.floor((h - fh) / 2 + asc + 0.5)
end

-- Draws str at screen px x with its baseline at y.
-- opts: w (box width), align ("left" | "center" | "right"), color, max_w (truncate).
function M.text(bb, x, y, face, str, opts)
    opts = opts or {}
    local max_w = opts.max_w or opts.w
    str = max_w and M.truncate(face, str, max_w) or M.fold(str)
    if opts.w and opts.align and opts.align ~= "left" then
        local tw = rawWidth(face, str)
        x = x + (opts.align == "center" and math.floor((opts.w - tw) / 2) or (opts.w - tw))
    end
    RenderText:renderUtf8Text(bb, x, y, face, str, true, false, opts.color or BLACK)
end

--------------------------------------------------------------------------------------------------
-- Names: one parser for how documents are titled in every app
--------------------------------------------------------------------------------------------------

M.MONTHS = {
    "January",
    "February",
    "March",
    "April",
    "May",
    "June",
    "July",
    "August",
    "September",
    "October",
    "November",
    "December",
}
-- Magazine series, by folder name on pCloud and by the filename prefix of their issues.
M.SERIES = { AC = "American Cinematographer" }
local ACRONYMS = { ai = "AI", ml = "ML", llm = "LLM", llms = "LLMs", gpu = "GPU", cpu = "CPU", nlp = "NLP" }

-- Magazine issues are named <series>_<code>MMYY.pdf, e.g. ac_ac1125.pdf.
-- Returns { label = "November 2025", sort_key = 202511, series = "American Cinematographer"|nil }.
function M.issueOf(name)
    local code, mm, yy = name:match("^(%a+)_%a+(%d%d)(%d%d)%.pdf$")
    if not mm then
        return nil
    end
    local month, year = tonumber(mm), tonumber(yy)
    if month < 1 or month > 12 then
        return nil
    end
    year = year + (year < 70 and 2000 or 1900)
    return {
        label = M.MONTHS[month] .. " " .. year,
        sort_key = year * 100 + month,
        series = M.SERIES[code:upper()],
    }
end

-- "dokumen.pub_fundamentals-and-applications-of-colour-engineering-9781119827184-….epub"
-- -> "Fundamentals and applications of colour engineering"
function M.prettyTitle(name)
    local base = name:gsub("%.%w+$", "")
    base = base:gsub("^[%w%-]+%.%a+_", "") -- download-site prefixes: dokumen.pub_, pdfcoffee.com_
    base = base:gsub("%-pdf%-free$", "")
    base = base:gsub("[%-_]%d%d%d%d%d%d%d%d%d%d%d?%d?%d?", "") -- ISBNs
    base = base:gsub("[%-_]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    base = base:gsub("%w+", function(w) return ACRONYMS[w:lower()] end)
    base = base:gsub("^%l", string.upper)
    return base
end

-- Display name of a document: its metadata title, else a magazine issue ("November 2025", or
-- "American Cinematographer, November 2025" with opts.series), else a cleaned-up file name.
function M.title(path, doc_props, opts)
    local t = doc_props and doc_props.title
    if type(t) == "string" and t:match("%S") then
        return (t:gsub("^%s+", ""):gsub("%s+$", ""))
    end
    local base = (path or ""):match("([^/]*)$") or ""
    local issue = M.issueOf(base)
    if issue then
        return (opts and opts.series and issue.series) and (issue.series .. ", " .. issue.label)
            or issue.label
    end
    local pretty = M.prettyTitle(base)
    return pretty ~= "" and pretty or base
end

--------------------------------------------------------------------------------------------------
-- 1-bit drawing (screen px)
--------------------------------------------------------------------------------------------------

local pattern_bb

-- 50% checker, screen sized, built once; dither() copies regions of it so patterns line up.
local function pattern()
    local w, h = Screen:getWidth(), Screen:getHeight()
    if pattern_bb and pattern_bb:getWidth() == w and pattern_bb:getHeight() == h then
        return pattern_bb
    end
    if pattern_bb then
        pattern_bb:free() -- the screen rotated: rebuild at the new size
    end
    local bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    bb:fill(WHITE)
    for y = 0, 2 * CELL - 1 do
        for x = 0, w - 1 do
            if (math.floor(x / CELL) + math.floor(y / CELL)) % 2 == 0 then
                bb:setPixel(x, y, BLACK)
            end
        end
    end
    for y = 2 * CELL, h - 1, 2 * CELL do
        bb:blitFrom(bb, 0, y, 0, 0, w, math.min(2 * CELL, h - y))
    end
    pattern_bb = bb
    return bb
end

function M.dither(bb, x, y, w, h) bb:blitFrom(pattern(), x, y, x, y, w, h) end

-- System 1 "disabled": knocks out half the black pixels of a region, so ink reads as gray.
function M.grayOut(bb, x, y, w, h)
    for yy = y, y + h - 1 do
        local row = math.floor(yy / CELL)
        for xx = x + ((row + math.floor(x / CELL)) % 2 == 0 and CELL or 0), x + w - 1, 2 * CELL do
            bb:paintRect(xx, yy, math.min(CELL, x + w - xx), 1, WHITE)
        end
    end
end

-- White box with a black frame and a solid drop shadow (spec rule 4). Screen px.
function M.box(bb, x, y, w, h, opts)
    opts = opts or {}
    local shadow = opts.shadow or 0
    if shadow > 0 then
        bb:paintRect(x + shadow, y + shadow, w, h, BLACK)
    end
    bb:paintRect(x, y, w, h, opts.fill or WHITE)
    bb:paintBorder(x, y, w, h, opts.border or u(2), BLACK)
end

-- Rounded push button. opts: default (extra ring), pressed (inverted), disabled (gray label).
function M.button(bb, g, label, opts)
    opts = opts or {}
    if opts.default then
        bb:paintBorder(g.x - u(5), g.y - u(5), g.w + u(10), g.h + u(10), u(3), BLACK, u(16))
    end
    bb:paintRoundedRect(g.x, g.y, g.w, g.h, opts.pressed and BLACK or WHITE, u(10))
    bb:paintBorder(g.x, g.y, g.w, g.h, u(2), BLACK, u(10))
    local face = M.face("menu")
    M.text(
        bb,
        g.x + u(6),
        M.baseline(face, g.y, g.h),
        face,
        label,
        { w = g.w - u(12), align = "center", color = opts.pressed and WHITE or BLACK }
    )
    if opts.disabled then
        M.grayOut(bb, g.x + u(6), g.y + u(4), g.w - u(12), g.h - u(8))
    end
end

--------------------------------------------------------------------------------------------------
-- Bitmaps: tiny ASCII-art glyphs the typeface lacks ('#' = black, '.' = white)
--------------------------------------------------------------------------------------------------

M.GLYPHS = {
    apple = {
        ".......##....",
        "......##.....",
        "......#......",
        "..####.####..",
        ".###########.",
        "############.",
        "###########..",
        "###########..",
        "###########..",
        "############.",
        ".############",
        ".###########.",
        "..#########..",
        "...##...##...",
    },
    check = {
        "..........##",
        ".........##.",
        "........##..",
        "##.....##...",
        ".##...##....",
        "..##.##.....",
        "...###......",
        "....#.......",
    },
    up = {
        ".......##.......",
        "......#..#......",
        ".....#....#.....",
        "....#......#....",
        "...#........#...",
        "..#..........#..",
        ".#............#.",
        "#####......#####",
        "....#......#....",
        "....#......#....",
        "....#......#....",
        "....########....",
    },
    left = {
        "....##",
        "...##.",
        "..##..",
        ".##...",
        "##....",
        ".##...",
        "..##..",
        "...##.",
        "....##",
    },
    note = { -- System 1 "Note" alert: a face with a speech balloon
        "..................##########....",
        "................##..........##..",
        "...............#..............#.",
        "..............#................#",
        "..............#....######......#",
        "..............#...##....##.....#",
        ".....#####....#........##......#",
        "...##.....##..#.......##.......#",
        "..#.........#.#.......##.......#",
        ".#...........#.#...............#",
        ".#...##.##...#..#.....##......#.",
        "#.....................##.....#..",
        "#.............#...#........##...",
        "#......#......#....#.######.....",
        "#......#......#.....##..........",
        "#.....##......#.................",
        ".#...........#..................",
        ".#...#####...#..................",
        "..#.........#...................",
        "...##.....##....................",
        ".....#####......................",
        ".....#...#......................",
        "...###...###....................",
        "..#.........#...................",
        ".#...........#..................",
        "#.............#.................",
    },
    caution = {
        "...............##...............",
        "..............####..............",
        ".............##..##.............",
        ".............#....#.............",
        "............##....##............",
        "............#......#............",
        "...........##..##..##...........",
        "...........#..####..#...........",
        "..........##..####..##..........",
        "..........#...####...#..........",
        ".........##...####...##.........",
        ".........#....####....#.........",
        "........##....####....##........",
        "........#.....####.....#........",
        ".......##.....####.....##.......",
        ".......#......####......#.......",
        "......##.......##.......##......",
        "......#........##........#......",
        ".....##..................##.....",
        ".....#........####........#.....",
        "....##.......######.......##....",
        "....#........######........#....",
        "...##.........####.........##...",
        "...#........................#...",
        "..##........................##..",
        "..############################..",
    },
    stop = {
        "..........############..........",
        ".........#............#.........",
        "........#..############.#.......",
        ".......#..#............#.#......",
        "......#..#..............#.#.....",
        ".....#..#....##..##..##..#.#....",
        "....#..#.....##..##..##...#.#...",
        "...#..#..##..##..##..##....#.#..",
        "..#..#...##..##..##..##.....#.#.",
        ".#..#....##..##..##..##......#.#",
        "#..#.....##..##..##..##.......##",
        "#.#......##..##..##..##........#",
        "#.#......##############..##....#",
        "#.#......###############.##....#",
        "#.#......##############.##.....#",
        "#.#......#############.##......#",
        "#.#.......############.#.......#",
        "#.#.......###########.##.......#",
        "#.#........#########.##........#",
        "#.#.........########.#.........#",
        ".#.#.........#######..........#.",
        "..#.#..........................#",
        "...#.#........................#.",
        "....#.#......................#..",
        ".....#.#....................#...",
        "......#.####################....",
    },
}

local glyph_cache = {}

-- Renders an ASCII glyph at an integer scale k into a BB8 (cached). flip = "v" mirrors vertically.
function M.glyph(name, k, flip)
    local key = name .. k .. (flip or "")
    if glyph_cache[key] then
        return glyph_cache[key]
    end
    local art = M.GLYPHS[name]
    local h, w = #art, #art[1]
    local bb = Blitbuffer.new(w * k, h * k, Blitbuffer.TYPE_BB8)
    bb:fill(WHITE)
    for r = 1, h do
        local line = art[flip == "v" and (h - r + 1) or r]
        for c = 1, w do
            local ch = line:sub(flip == "h" and (w - c + 1) or c, flip == "h" and (w - c + 1) or c)
            if ch == "#" then
                bb:paintRect((c - 1) * k, (r - 1) * k, k, k, BLACK)
            end
        end
    end
    glyph_cache[key] = bb
    return bb
end

-- Paints a glyph with only its black pixels (so it works on inverted or dithered backgrounds).
-- color: BLACK or WHITE ink.
function M.paintGlyph(bb, name, x, y, k, color, flip)
    local g = M.glyph(name, k, flip)
    local w, h = g:getWidth(), g:getHeight()
    local ink = color or BLACK
    local art = M.GLYPHS[name]
    local aw = #art[1]
    for r = 1, #art do
        local line = art[flip == "v" and (#art - r + 1) or r]
        for c = 1, aw do
            local idx = flip == "h" and (aw - c + 1) or c
            if line:sub(idx, idx) == "#" then
                bb:paintRect(x + (c - 1) * k, y + (r - 1) * k, k, k, ink)
            end
        end
    end
    return w, h
end

--------------------------------------------------------------------------------------------------
-- Icons: icons-mac/*.svg (32x32 grid), rendered at whole multiples of 32 and thresholded to 1-bit
--------------------------------------------------------------------------------------------------

local icon_cache = {}

function M.addIconDir(dir) table.insert(M.ICON_DIRS, 1, dir) end

local function findIcon(name)
    for _, d in ipairs(M.ICON_DIRS) do
        local p = d .. name .. ".svg"
        if lfs.attributes(p, "mode") == "file" then
            return p
        end
    end
end

-- Returns a 1-bit BB8 icon of px x px (px should be a multiple of 32), or nil if missing.
-- variant: nil, "dim" (System 1 gray: not on this Kindle / unavailable).
function M.icon(name, px, variant)
    local key = name .. px .. (variant or "")
    if icon_cache[key] ~= nil then
        return icon_cache[key] or nil
    end
    local path = findIcon(name)
    local src = path and RenderImage:renderSVGImageFile(path, px, px)
    if not src then
        logger.warn("macui: no icon", name)
        icon_cache[key] = false
        return nil
    end
    local bb = Blitbuffer.new(px, px, Blitbuffer.TYPE_BB8)
    bb:fill(WHITE)
    for y = 0, math.min(px, src:getHeight()) - 1 do
        for x = 0, math.min(px, src:getWidth()) - 1 do
            local c = src:getPixel(x, y):getColorRGB32()
            -- transparent counts as white; dark opaque pixels are ink
            if c.alpha >= 128 and (c.r + c.g + c.b) < 384 then
                bb:setPixel(x, y, BLACK)
            end
        end
    end
    src:free()
    if variant == "dim" then
        M.grayOut(bb, 0, 0, px, px)
    end
    icon_cache[key] = bb
    return bb
end

-- Icon with transparency (BB8A): outside the silhouette stays see-through, so icons can sit on
-- the dithered desktop. variant: nil, "dim" (half the ink knocked out to paper), or "selected"
-- (the Finder's selected icon: inverted inside the silhouette, transparent outside).
function M.iconA(name, px, variant)
    local key = "A" .. name .. px .. (variant or "")
    if icon_cache[key] ~= nil then
        return icon_cache[key] or nil
    end
    local path = findIcon(name)
    local src = path and RenderImage:renderSVGImageFile(path, px, px)
    if not src then
        icon_cache[key] = false
        return nil
    end
    local ink, paper = 0, 255
    if variant == "selected" then
        ink, paper = 255, 0
    end
    -- new buffers are zeroed, i.e. fully transparent (fill() would force alpha to 255)
    local bb = Blitbuffer.new(px, px, Blitbuffer.TYPE_BB8A)
    for y = 0, math.min(px, src:getHeight()) - 1 do
        for x = 0, math.min(px, src:getWidth()) - 1 do
            local c = src:getPixel(x, y):getColorRGB32()
            if c.alpha >= 128 then
                local dark = (c.r + c.g + c.b) < 384
                if dark and variant == "dim" and (math.floor(x / CELL) + math.floor(y / CELL)) % 2 == 1 then
                    dark = false
                end
                bb:setPixel(x, y, Blitbuffer.Color8A(dark and ink or paper, 255))
            end
        end
    end
    src:free()
    icon_cache[key] = bb
    return bb
end

-- Paints an icon with its transparency at screen px (x, y); px should be a multiple of 32.
function M.paintIcon(bb, name, x, y, px, variant)
    local ib = M.iconA(name, px, variant)
    if ib then
        bb:alphablitFrom(ib, x, y, 0, 0, px, px)
    end
    return ib ~= nil
end

--------------------------------------------------------------------------------------------------
-- Images: Atkinson dithering (the MacPaint algorithm) turns photos into 1-bit
--------------------------------------------------------------------------------------------------

-- Returns a new 1-bit BB8 of w x h from any blitbuffer (scaled smoothly first unless it is
-- already w x h). gamma < 1 lifts midtones before dithering, so dark photos keep their shadows.
function M.atkinson(src, w, h, gamma)
    local scaled = src
    if src:getWidth() ~= w or src:getHeight() ~= h then
        scaled = RenderImage:scaleBlitBuffer(src, w, h, false)
    end
    local lut = {}
    gamma = gamma or 0.85
    for v = 0, 255 do
        lut[v] = math.floor(255 * (v / 255) ^ gamma + 0.5)
    end
    local buf = ffi.new("int16_t[?]", w * h)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            buf[y * w + x] = lut[scaled:getPixel(x, y):getColor8().a]
        end
    end
    if scaled ~= src then
        scaled:free()
    end
    local out = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    out:fill(WHITE)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local i = y * w + x
            local old = buf[i]
            local err
            if old < 128 then
                out:paintRect(x, y, 1, 1, BLACK)
                err = old
            else
                err = old - 255
            end
            -- 1/8 of the error to six neighbours; the 2/8 that is dropped keeps highlights clean.
            err = math.floor(err / 8)
            if err ~= 0 then
                if x + 1 < w then
                    buf[i + 1] = buf[i + 1] + err
                end
                if x + 2 < w then
                    buf[i + 2] = buf[i + 2] + err
                end
                if y + 1 < h then
                    if x > 0 then
                        buf[i + w - 1] = buf[i + w - 1] + err
                    end
                    buf[i + w] = buf[i + w] + err
                    if x + 1 < w then
                        buf[i + w + 1] = buf[i + w + 1] + err
                    end
                    if y + 2 < h then
                        buf[i + 2 * w] = buf[i + 2 * w] + err
                    end
                end
            end
        end
    end
    return out
end

-- First page (PDF, DjVu, CBZ) or embedded cover (EPUB) of a document as a 1-bit w x h image,
-- filling the box and cropped to its centre. Results are cached as PNGs keyed by path, size and
-- dimensions, so each cover is computed once. Returns a BB8 the caller must free, or nil.
function M.cover(path, w, h)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" then
        return nil
    end
    local DataStorage = require("datastorage")
    local dir = DataStorage:getDataDir() .. "/cache/macui-covers"
    local bit = require("bit")
    local hash = 2166136261 -- FNV-1a over the full path: distinct paths get distinct names
    for i = 1, #path do
        hash = bit.tobit(bit.bxor(hash, path:byte(i)) * 16777619)
    end
    local cached = string.format(
        "%s/%s-%08x-%d-%d-%dx%d.png",
        dir,
        (path:match("([^/]*)$") or ""):gsub("[^%w]", "_"):sub(1, 40),
        bit.band(hash, 0xffffffff) % 0x100000000,
        attr.size,
        attr.modification,
        w,
        h
    )
    if lfs.attributes(cached, "mode") == "file" then
        local bb = RenderImage:renderImageFile(cached, false)
        if bb then
            return bb
        end
    end
    local DocumentRegistry = require("document/documentregistry")
    local doc = DocumentRegistry:openDocument(path)
    if not doc then
        return nil
    end
    local ok, src = pcall(function()
        if doc.info and doc.info.has_pages then
            -- render page 1 just large enough to fill the box: far faster than a full-screen render
            local native = doc:getNativePageDimensions(1)
            local zoom = math.max(w / native.w, h / native.h)
            local tile = doc:renderPage(1, nil, zoom, 0, 1.0, 1.0, false)
            return tile and tile.bb:copy()
        end
        return doc:getCoverPageImage()
    end)
    doc:close()
    if not ok or not src then
        logger.warn("macui: no cover for", path, src)
        return nil
    end
    -- scale to fill (keeping proportions), then crop the centre
    local sw, sh = src:getWidth(), src:getHeight()
    local k = math.max(w / sw, h / sh)
    local fw, fh = math.max(w, math.floor(sw * k + 0.5)), math.max(h, math.floor(sh * k + 0.5))
    local filled = (fw == sw and fh == sh) and src or RenderImage:scaleBlitBuffer(src, fw, fh, false)
    local crop = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    crop:blitFrom(filled, 0, 0, math.floor((fw - w) / 2), math.floor((fh - h) / 2), w, h)
    if filled ~= src then
        filled:free()
    end
    src:free()
    local out = M.atkinson(crop, w, h)
    crop:free()
    util.makePath(dir)
    pcall(out.writePNG, out, cached)
    return out
end

-- 1-bit progress bar (screen px): a 1 px frame filled black to fraction 0..1.
function M.progress(bb, x, y, w, h, fraction)
    bb:paintRect(x, y, w, h, WHITE)
    bb:paintBorder(x, y, w, h, u(1), BLACK)
    bb:paintRect(x, y, math.floor(w * math.max(0, math.min(1, fraction or 0))), h, BLACK)
end

-- System 1 check box (screen px): a square with an X when checked. Returns its rect.
function M.checkbox(bb, x, y, size, checked)
    bb:paintRect(x, y, size, size, WHITE)
    bb:paintBorder(x, y, size, size, u(1), BLACK)
    if checked then
        local inset, t = u(3), math.max(1, U)
        local n = size - 2 * inset
        for i = 0, n - t do
            bb:paintRect(x + inset + i, y + inset + i, t, t, BLACK)
            bb:paintRect(x + inset + n - t - i, y + inset + i, t, t, BLACK)
        end
    end
    return Geom:new { x = x, y = y, w = size, h = size }
end

-- System 1 radio button (screen px): a circle with a dot when on. Returns its rect.
function M.radio(bb, x, y, size, on)
    bb:paintRoundedRect(x, y, size, size, WHITE, math.floor(size / 2))
    bb:paintBorder(x, y, size, size, u(1), BLACK, math.floor(size / 2))
    if on then
        local d = math.floor(size / 2)
        bb:paintRoundedRect(
            x + math.floor((size - d) / 2),
            y + math.floor((size - d) / 2),
            d,
            d,
            BLACK,
            math.floor(d / 2)
        )
    end
    return Geom:new { x = x, y = y, w = size, h = size }
end

-- System 1 Control Panel slider (screen px): a track with tick marks and a box thumb at
-- fraction 0..1. Returns the track rect (map a tap to a value with (p.x - r.x) / r.w).
function M.slider(bb, x, y, w, h, fraction)
    local cy = y + math.floor(h / 2)
    bb:paintRect(x, y, w, h, WHITE)
    bb:paintRect(x, cy - u(1), w, u(2), BLACK)
    for i = 0, 8 do
        local tx = x + math.floor((w - u(1)) * i / 8)
        bb:paintRect(tx, cy + u(4), u(1), u(5), BLACK)
    end
    local tw = u(12)
    local tx = x + math.floor((w - tw) * math.max(0, math.min(1, fraction or 0)))
    bb:paintRect(tx, y + u(2), tw, h - u(4), WHITE)
    bb:paintBorder(tx, y + u(2), tw, h - u(4), u(2), BLACK)
    return Geom:new { x = x, y = y, w = w, h = h }
end

-- A System 1 window frame drawn directly (screen px), for screens that place fixed windows
-- themselves (e.g. the Home desktop) instead of using App's cascade. Returns the content rect
-- and the close-box rect (nil when opts.close == false).
-- opts: active (default true: stripes and close box), close (default true), left / right
-- (status strip texts; no strip when both are nil), shadow (default true).
function M.window(bb, r, title, opts)
    opts = opts or {}
    local active = opts.active ~= false
    M.box(bb, r.x, r.y, r.w, r.h, { shadow = opts.shadow ~= false and u(SHADOW_PX) or 0 })
    local th = u(TITLE_PX)
    local close
    if active then
        for ly = r.y + u(7), r.y + th - u(8), u(4) do
            bb:paintRect(r.x + u(4), ly, r.w - u(8), u(2), BLACK)
        end
        if opts.close ~= false then
            local box = Geom:new { x = r.x + u(14), y = r.y + u(8), w = u(18), h = u(18) }
            bb:paintRect(box.x - u(4), box.y - u(2), box.w + u(8), box.h + u(4), WHITE)
            bb:paintBorder(box.x, box.y, box.w, box.h, u(2), BLACK)
            -- returned for hit tests: the same fingertip-sized zone as App windows use
            close = Geom:new { x = r.x, y = r.y, w = math.max(u(70), math.floor(r.w / 4)), h = th }
        end
    end
    bb:paintRect(r.x, r.y + th - u(2), r.w, u(2), BLACK)
    local face = M.face("title")
    local t = M.truncate(face, title or "", r.w - u(120))
    local tw = M.width(face, t)
    local tx = r.x + math.floor((r.w - tw) / 2)
    bb:paintRect(tx - u(10), r.y + u(4), tw + u(20), th - u(8), WHITE)
    M.text(bb, tx, M.baseline(face, r.y, th - u(2)), face, t)
    local bottom = r.y + r.h
    if opts.left or opts.right then
        local sh = u(STATUS_PX)
        local sy = bottom - sh
        bb:paintRect(r.x, sy, r.w, u(2), BLACK)
        local small = M.face("small")
        local base = M.baseline(small, sy + u(2), sh - u(2))
        local rw = opts.right and M.width(small, opts.right) or 0
        if rw > 0 then
            M.text(bb, r.x + r.w - rw - u(12), base, small, opts.right)
        end
        M.text(bb, r.x + u(12), base, small, opts.left or "", { max_w = r.w - rw - u(40) })
        bottom = sy
    end
    return Geom:new { x = r.x + u(2), y = r.y + th, w = r.w - u(4), h = bottom - r.y - th }, close
end

--------------------------------------------------------------------------------------------------
-- App: desktop, menu bar, window cascade, button dialog, modals
--------------------------------------------------------------------------------------------------

-- Design-px layout (Kindle Stories' numbers on the taller canvas).
local MENU_H, TITLE_H, STATUS_H = 34, 34, 32
local MARGIN, SHADOW = 22, 4
local DLG_H, BTN_W, BTN_H = 104, 136, 44
local CASCADE_X, CASCADE_Y = 12, 30
local SCROLL_W = 20

M.App = InputContainer:extend {
    covers_fullscreen = true,
    -- menus: { { title = "File", items = function(app) return { {text, callback, enabled, checked} | "-" } end } }
    menus = nil,
    buttons = nil, -- { { label, callback, enabled = function(app) end, default = bool|function } }; nil = no dialog
    -- A window may carry its own `buttons` list; it replaces the app's while that window is on top.
    dialog = nil, -- true: reserve the button dialog area even when the app has no buttons of its own
    -- overlay = true: float over other screens (no desktop pattern, KOReader repaints what is
    -- underneath); a tap outside the menu bar, menus and windows closes it. Used for a Mac menu
    -- bar over KOReader's own screens.
    overlay = nil,
    author = nil, -- defaults to M.AUTHOR
}

function M.App:init()
    if self.overlay then
        self.covers_fullscreen = false
    end
    -- pass dimen = Geom{ x = 0, y = 0, w, h } to share the screen (e.g. above a tab bar)
    self.dimen = self.dimen or Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.windows = {}
    self.menus = self.menus or {}
    -- every app gets the shell's Apple menu (registered by the main UI) unless it has its own
    local shell = package.loaded["macui.status"]
    local has_apple = false
    for _, m in ipairs(self.menus) do
        if m.glyph == "apple" then
            has_apple = true
        end
    end
    if not has_apple and type(shell) == "table" and shell.apple then
        table.insert(self.menus, 1, {
            glyph = "apple",
            title = "Apple",
            items = function(app)
                local ok, items = pcall(shell.apple, app)
                return ok and items or {}
            end,
        })
    end
    local range = self.dimen
    self.ges_events = {
        Tap = { GestureRange:new { ges = "tap", range = range } },
        Hold = { GestureRange:new { ges = "hold", range = range } },
        HoldRelease = { GestureRange:new { ges = "hold_release", range = range } },
        Swipe = { GestureRange:new { ges = "swipe", range = range } },
    }
    self.key_events = { Close = { { "Back" } } }
    self:layout()
end

-- The button set in force: the top window's own, else the app's.
function M.App:activeButtons()
    local top = self.windows and self.windows[#self.windows]
    return (top and top.buttons) or self.buttons
end

function M.App:setButtons(list)
    self.buttons = list
    self:layout()
    self:refresh()
end

function M.App:layout()
    local W, H = self.dimen.w / U, self.dimen.h / U
    local reserve = self.buttons ~= nil or self.dialog
    local dlg_top = reserve and (H - MARGIN - DLG_H) or H
    self.win_area = { x = MARGIN, y = MENU_H + 24, w = W - 2 * MARGIN, h = dlg_top - 22 - (MENU_H + 24) }
    if not reserve then
        self.win_area.h = H - MARGIN - (MENU_H + 24)
    end
    local btns = self:activeButtons()
    self.dlg = nil
    if reserve and btns and #btns > 0 then
        local n = #btns
        local bw = math.min(BTN_W + 24, (W - 2 * MARGIN - 40 - (n + 1) * 16) / n)
        local dw = n * bw + (n + 1) * 32
        self.dlg = { x = math.floor((W - dw) / 2), y = dlg_top, w = dw, h = DLG_H }
        local gap = (dw - n * bw) / (n + 1)
        for i, b in ipairs(btns) do
            b.g = Geom:new {
                x = u(self.dlg.x + gap * i + bw * (i - 1)),
                y = u(dlg_top + (DLG_H - BTN_H) / 2),
                w = u(bw),
                h = u(BTN_H),
            }
        end
    end
end

-- Screen-px geometry of window i of n in the cascade (later windows sit lower right, smaller).
function M.App:windowRect(i)
    local a = self.win_area
    local d = math.min(i - 1, 4)
    local x, y = a.x + d * CASCADE_X, a.y + d * CASCADE_Y
    return Geom:new {
        x = u(x),
        y = u(y),
        w = u(a.w - d * CASCADE_X - SHADOW),
        h = u(a.h - d * CASCADE_Y - SHADOW),
    }
end

local function inRect(p, r) return r and p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h end
M.inRect = inRect

-- Window parts in screen px, for painting and hit tests.
function M.App:parts(i)
    local r = self:windowRect(i)
    local win = self.windows[i]
    local th, sh = u(TITLE_H), u(STATUS_H)
    local p = { frame = r }
    p.title = Geom:new { x = r.x, y = r.y, w = r.w, h = th }
    p.close = Geom:new { x = r.x + u(14), y = r.y + u(8), w = u(18), h = u(18) }
    p.status = Geom:new { x = r.x, y = r.y + r.h - sh, w = r.w, h = sh }
    local sw = (win and win.content.pages) and u(SCROLL_W) or 0
    p.content = Geom:new { x = r.x + u(2), y = r.y + th, w = r.w - u(4) - sw, h = r.h - th - sh }
    if sw > 0 then
        p.scroll = Geom:new { x = r.x + r.w - u(2) - sw, y = r.y + th, w = sw, h = r.h - th - sh }
        p.up = Geom:new { x = p.scroll.x, y = p.scroll.y, w = sw, h = sw }
        p.down = Geom:new { x = p.scroll.x, y = p.scroll.y + p.scroll.h - sw, w = sw, h = sw }
    end
    return p
end

---- windows

-- win = { title = "…", content = <content> }
function M.App:pushWindow(win)
    table.insert(self.windows, win)
    self:layout()
    self:transition()
end

function M.App:popWindow()
    local win = table.remove(self.windows)
    if win and win.content.free then
        win.content:free()
    end
    if win and win.onClose then
        win.onClose()
    end
    self:layout()
    self:transition()
end

function M.App:topWindow() return self.windows[#self.windows] end

---- painting

function M.App:paintMenuBar(bb)
    local sw, mh = self.dimen.w, u(MENU_H)
    bb:paintRect(0, 0, sw, mh, WHITE)
    -- rounded screen corners, as on the original 9" CRT
    local cr = u(8)
    bb:paintRect(0, 0, cr, cr, BLACK)
    bb:paintRect(sw - cr, 0, cr, cr, BLACK)
    bb:paintRoundedRect(0, 0, sw, cr * 2, WHITE, cr)
    bb:paintRect(0, mh - u(2), sw, u(2), BLACK)
    local face = M.face("menu")
    local base = M.baseline(face, 0, mh - u(2))
    local x = u(20)
    self.menu_hits = {}
    for i, m in ipairs(self.menus) do
        local art = m.glyph and M.GLYPHS[m.glyph]
        local mw = art and (#art[1] * U) or M.width(face, m.title)
        local hit = Geom:new { x = x - u(10), y = 0, w = mw + u(20), h = mh }
        self.menu_hits[i] = hit
        local ink = self.open_menu == i and WHITE or BLACK
        if self.open_menu == i then
            bb:paintRect(hit.x, 0, hit.w, mh - u(2), BLACK)
        end
        if art then
            M.paintGlyph(bb, m.glyph, x, math.floor((mh - u(2) - #art * U) / 2), U, ink)
        else
            M.text(bb, x, base, face, m.title, { color = ink })
        end
        x = x + mw + u(30)
    end
    -- the shell's status area (Wi-Fi, battery, clock; tap = Control Panel), when the main UI has
    -- registered it, so every app's menu bar matches; else the author's name as in Kindle Stories
    self.status_hit = nil
    local status = package.loaded["macui.status"]
    if type(status) == "table" and status.paint then
        local box_x = x + u(10)
        local ok, used = pcall(status.paint, bb, box_x, 0, sw - box_x - u(12), mh - u(2))
        if ok and type(used) == "number" and used > 0 then
            self.status_hit = Geom:new { x = sw - u(12) - used - u(10), y = 0, w = used + u(22), h = mh }
            return
        end
    end
    local small = M.face("small")
    local author = self.author or M.AUTHOR
    M.text(bb, sw - M.width(small, author) - u(18), M.baseline(small, 0, mh - u(2)), small, author)
end

-- Opens pull-down i (or closes the open one with nil), refreshing only the menu region.
function M.App:openMenu(i)
    self.open_menu = i
    self:refresh("ui", self:menuRegion())
end

function M.App:menuItems(i)
    local m = self.menus[i]
    local items = type(m.items) == "function" and m.items(self) or m.items
    return items or {}
end

-- The open pull-down: white box, 1 px frame, shadow, a check column, dotted separators.
function M.App:paintMenu(bb)
    local i = self.open_menu
    local items = self:menuItems(i)
    local face = M.face("menu")
    local row, sep = u(32), u(12)
    local w = 0
    for _, it in ipairs(items) do
        if it ~= "-" then
            w = math.max(w, M.width(face, it.text))
        end
    end
    w = w + u(26) + u(30)
    local h = u(6)
    for _, it in ipairs(items) do
        h = h + (it == "-" and sep or row)
    end
    local x = self.menu_hits[i].x
    x = math.min(x, self.dimen.w - w - u(6))
    local y = u(MENU_H) - u(2)
    M.box(bb, x, y, w, h, { border = u(1), shadow = u(2) })
    self.menu_rows = {}
    local yy = y + u(3)
    for k, it in ipairs(items) do
        if it == "-" then
            local ly = yy + math.floor(sep / 2)
            for lx = x + u(1), x + w - u(2), 2 * U do
                bb:paintRect(lx, ly, U, U, BLACK)
            end
            yy = yy + sep
        else
            local g = Geom:new { x = x + u(1), y = yy, w = w - u(2), h = row }
            local enabled = it.enabled ~= false
            local hot = self.flash_menu_row == k
            if hot then
                bb:paintRect(g.x, g.y, g.w, g.h, BLACK)
            end
            local ink = hot and WHITE or BLACK
            if it.checked then
                local gk = U
                local gw, gh = #M.GLYPHS.check[1] * gk, #M.GLYPHS.check * gk
                M.paintGlyph(bb, "check", x + u(8), yy + math.floor((row - gh) / 2), gk, ink)
                local _ = gw
            end
            M.text(bb, x + u(26), M.baseline(face, yy, row), face, it.text, { color = ink })
            if not enabled then
                M.grayOut(bb, g.x, g.y, g.w, g.h)
            end
            self.menu_rows[k] = { g = g, item = it, enabled = enabled }
            yy = yy + row
        end
    end
    self.menu_box = Geom:new { x = x, y = y, w = w + u(2), h = h + u(2) }
end

function M.App:paintScrollBar(bb, p, content)
    local s = p.scroll
    local page, pages = content:pages()
    bb:paintRect(s.x, s.y, u(2), s.h, BLACK)
    if pages <= 1 then
        return -- inactive scroll bar: plain white, no arrows (as System 1)
    end
    local k = math.max(1, math.floor((s.w - u(4)) / 16))
    for _, part in ipairs { { p.up, nil }, { p.down, "v" } } do
        local g = part[1]
        bb:paintRect(g.x, g.y + (part[2] and 0 or g.h - u(2)), g.w, u(2), BLACK)
        local gw, gh = 16 * k, 12 * k
        M.paintGlyph(
            bb,
            "up",
            g.x + math.floor((g.w - gw) / 2) + u(1),
            g.y + math.floor((g.h - gh) / 2),
            k,
            BLACK,
            part[2]
        )
    end
    local tx, ty, tw, th = s.x + u(2), p.up.y + p.up.h, s.w - u(2), p.down.y - (p.up.y + p.up.h)
    M.dither(bb, tx, ty, tw, th)
    local thumb = s.w - u(2)
    local ypos = ty + math.floor((th - thumb) * (page - 1) / math.max(1, pages - 1))
    bb:paintRect(tx, ypos, tw, thumb, WHITE)
    bb:paintRect(tx, ypos, tw, u(2), BLACK)
    bb:paintRect(tx, ypos + thumb - u(2), tw, u(2), BLACK)
end

function M.App:paintWindow(bb, i)
    local win = self.windows[i]
    local active = i == #self.windows
    local p = self:parts(i)
    local r = p.frame
    M.box(bb, r.x, r.y, r.w, r.h, { shadow = u(SHADOW) })
    local th = u(TITLE_H)
    if active then
        for ly = r.y + u(7), r.y + th - u(8), u(4) do
            bb:paintRect(r.x + u(4), ly, r.w - u(8), u(2), BLACK)
        end
        local c = p.close
        bb:paintRect(c.x - u(4), c.y - u(2), c.w + u(8), c.h + u(4), WHITE)
        bb:paintBorder(c.x, c.y, c.w, c.h, u(2), BLACK)
        if self.flash_close then
            bb:paintRect(c.x, c.y, c.w, c.h, BLACK)
        end
    end
    bb:paintRect(r.x, r.y + th - u(2), r.w, u(2), BLACK)
    local face = M.face("title")
    local title = M.truncate(face, win.title or "", r.w - u(120))
    local tw = M.width(face, title)
    local tx = r.x + math.floor((r.w - tw) / 2)
    bb:paintRect(tx - u(10), r.y + u(4), tw + u(20), th - u(8), WHITE)
    M.text(bb, tx, M.baseline(face, r.y, th - u(2)), face, title)
    if not active then
        return -- background windows show only frame and title; the top one covers the rest
    end
    local content = win.content
    local cr = p.content
    bb:paintRect(cr.x, cr.y, cr.w + (p.scroll and p.scroll.w or 0), cr.h, WHITE)
    content:paint(bb, cr, self)
    if p.scroll then
        self:paintScrollBar(bb, p, content)
    end
    -- status strip, like the Finder's "7 items   152K in disk" bar
    local s = p.status
    bb:paintRect(s.x, s.y, s.w, u(2), BLACK)
    local small = M.face("small")
    local left, right
    if content.status then
        left, right = content:status()
    end
    self.pager = nil
    local base = M.baseline(small, s.y + u(2), s.h - u(2))
    local rx = s.x + s.w - u(12)
    if content.pages and not right then
        local page, pages = content:pages()
        if pages > 1 then
            -- "◀  2 of 5  ▶": the arrows are tap targets (glyphs: the font may lack ◀ ▶)
            local k = math.max(1, math.floor(u(14) / 9))
            local gw, gh = 6 * k, 9 * k
            local gy = s.y + u(2) + math.floor((s.h - u(2) - gh) / 2)
            local txt = page .. " of " .. pages
            local txt_w = M.width(small, txt)
            rx = rx - gw
            M.paintGlyph(bb, "left", rx, gy, k, BLACK, "h")
            local next_hit = Geom:new { x = rx - u(10), y = s.y, w = gw + u(22), h = s.h }
            rx = rx - u(14) - txt_w
            M.text(bb, rx, base, small, txt)
            rx = rx - u(14) - gw
            M.paintGlyph(bb, "left", rx, gy, k, BLACK)
            local prev_hit = Geom:new { x = rx - u(12), y = s.y, w = gw + u(22), h = s.h }
            self.pager = { prev = prev_hit, next = next_hit }
            rx = rx - u(12)
        end
    elseif right and right ~= "" then
        rx = rx - M.width(small, right)
        M.text(bb, rx, base, small, right)
    end
    M.text(bb, s.x + u(12), base, small, left or "", { max_w = rx - s.x - u(40) })
end

function M.App:paintDialog(bb)
    local d = self.dlg
    if not d then
        return
    end
    local x, y, w, h = u(d.x), u(d.y), u(d.w), u(d.h)
    bb:paintRect(x, y, w, h, WHITE)
    bb:paintBorder(x, y, w, h, u(2), BLACK)
    bb:paintBorder(x + u(5), y + u(5), w - u(10), h - u(10), u(3), BLACK)
    for i, b in ipairs(self:activeButtons()) do
        local enabled = b.enabled == nil or b.enabled(self)
        local default = b.default
        if type(default) == "function" then
            default = default(self)
        end
        M.button(
            bb,
            b.g,
            b.label,
            { default = default and enabled, pressed = self.flash_button == i, disabled = not enabled }
        )
    end
end

function M.App:paintTo(bb, x, y)
    -- the cached desktop pattern is the background; everything else is painted over it
    if not self.overlay then
        bb:blitFrom(pattern(), x, y, 0, 0, self.dimen.w, self.dimen.h)
    end
    for i = 1, #self.windows do
        self:paintWindow(bb, i)
    end
    self:paintDialog(bb)
    self:paintMenuBar(bb)
    if self.open_menu then
        self:paintMenu(bb)
    end
    if self.modal then
        self.modal:paint(bb, self)
    end
end

---- refresh and feedback

-- E-ink updates take longer the more area they cover, so changes refresh only their region.

-- The menu bar plus room for the tallest pull-down: covers opening, closing and switching menus.
function M.App:menuRegion()
    local maxh = 0
    for i = 1, #self.menus do
        local h = u(6)
        for _, it in ipairs(self:menuItems(i)) do
            h = h + (it == "-" and u(12) or u(32))
        end
        maxh = math.max(maxh, h)
    end
    return Geom:new { x = 0, y = 0, w = self.dimen.w, h = math.min(self.dimen.h, u(MENU_H) + maxh + u(6)) }
end

-- A full flash ("full") makes KOReader wait for the panel: measured 400-580 ms on the Scribe,
-- against ~47 ms for "ui". So windows open and close with a non-flashing "ui" refresh of the
-- window area, and every TRANSITION_FLASH-th change flashes ("flashui") to clear ghosting.
local TRANSITION_FLASH = 6

function M.App:windowsRegion()
    local a = self.win_area
    return Geom:new { x = u(a.x), y = u(a.y), w = u(a.w) + u(SHADOW), h = u(a.h) + u(SHADOW) }
end

function M.App:transition()
    self.changes = (self.changes or 0) + 1
    local r = self:windowsRegion()
    if self.dlg then
        -- a window with its own buttons changes the button dialog too: cover it in the same refresh
        local bottom = u(self.dlg.y + self.dlg.h)
        r = Geom:new { x = 0, y = r.y, w = self.dimen.w, h = math.max(r.y + r.h, bottom) - r.y }
    end
    self:refresh(self.changes % TRANSITION_FLASH == 0 and "flashui" or "ui", r)
end

-- The top window including its drop shadow.
function M.App:topRegion()
    if #self.windows == 0 then
        return self.dimen
    end
    local r = self:windowRect(#self.windows)
    return Geom:new { x = r.x, y = r.y, w = r.w + u(SHADOW), h = r.h + u(SHADOW) }
end

-- mode: "ui" (default: keeps anti-aliased text edges), "fast" (A2, black and white only: used for
-- the brief inverted tap feedback), "flashui" (flashes the region: periodic ghosting cleanup).
function M.App:refresh(mode, rect)
    -- an overlay paints no background, so the screens under it must repaint too, or a closed
    -- menu or alert would leave its old pixels behind
    UIManager:setDirty(self.overlay and "all" or self, function() return mode or "ui", rect or self.dimen end)
end

-- Streaming repaints, coalesced (macterm's due-time policy as one kit knob): a burst of calls becomes
-- one refresh at min(last + quiet, first + max_wait), never sooner than min_gap after the previous
-- one. Flushes use `mode` (A2: black and white, no flash); every cleanup-th flush, and once the burst
-- has been quiet for `settle` s, a "ui" refresh brings the anti-aliased text edges back.
M.REFRESH = { quiet = 0.15, max_wait = 0.6, min_gap = 0.5, mode = "fast", cleanup = 6, settle = 1.0 }
M.clock = function() return time.to_s(time.now()) end -- specs replace it

---@param rect table|nil Geom in screen px (default: the whole app)
function M.App:refreshSoon(rect)
    local R, now = M.REFRESH, M.clock()
    local s = self.soon
    if not s then
        s = { flushed = -math.huge, n = 0 }
        s.flush_fn = function() self:flushSoon() end
        s.settle_fn = function()
            if s.ghost and not self.closed then
                self:refresh("ui", s.ghost)
            end
            s.ghost = nil
        end
        self.soon = s
    end
    rect = rect or self.dimen
    s.rect = s.rect and s.rect:combine(rect) or rect
    s.first = s.first or now
    s.last = now
    local due = math.max(math.min(s.last + R.quiet, s.first + R.max_wait), s.flushed + R.min_gap)
    UIManager:unschedule(s.flush_fn)
    UIManager:unschedule(s.settle_fn)
    UIManager:scheduleIn(math.max(0, due - now), s.flush_fn)
end

-- The pending refreshSoon now (also what its timer runs).
function M.App:flushSoon()
    local s = self.soon
    if not (s and s.rect) or self.closed then
        return
    end
    local R = M.REFRESH
    local rect = s.rect
    s.rect, s.first, s.flushed, s.n = nil, nil, M.clock(), s.n + 1
    local mode = s.n % R.cleanup == 0 and "ui" or R.mode
    self:refresh(mode, rect)
    if mode == "ui" then
        s.ghost = nil
    else
        s.ghost = s.ghost and s.ghost:combine(rect) or rect
        UIManager:unschedule(s.settle_fn)
        UIManager:scheduleIn(R.settle, s.settle_fn)
    end
end

-- Shows a pressed state (set by `set`) for a moment, then runs fn: tap feedback on e-ink.
function M.App:flash(set, clear, rect, fn)
    set()
    UIManager:setDirty(self.overlay and "all" or self, function() return "fast", rect end)
    UIManager:forceRePaint()
    UIManager:scheduleIn(0.12, function()
        clear()
        if not self.closed then
            fn()
        end
    end)
end

---- gestures

function M.App:onTap(_, ges)
    local p = ges.pos
    if self.modal then
        self.modal:tap(p, self)
        return true
    end
    if self.open_menu then
        if inRect(p, self.menu_box) then
            for k, row in pairs(self.menu_rows) do
                if inRect(p, row.g) and row.enabled then
                    self:flash(
                        function() self.flash_menu_row = k end,
                        function()
                            self.flash_menu_row = nil
                            self.open_menu = nil
                        end,
                        self.menu_box,
                        function()
                            self:refresh("ui", self:menuRegion())
                            if row.item.callback then
                                row.item.callback(self)
                            end
                        end
                    )
                    return true
                end
            end
            return true
        end
        local was = self.open_menu
        self.open_menu = nil
        local on_bar = false
        for i, hit in ipairs(self.menu_hits or {}) do
            if inRect(p, hit) then
                on_bar = true
                if i ~= was then
                    self.open_menu = i
                end
            end
        end
        if self.overlay and not on_bar and #self.windows == 0 then
            self:quit() -- one tap outside dismisses a floating menu bar
            return true
        end
        self:refresh("ui", self:menuRegion())
        return true
    end
    for i, hit in ipairs(self.menu_hits or {}) do
        if inRect(p, hit) then
            self.open_menu = i
            self:refresh("ui", self:menuRegion())
            return true
        end
    end
    if self.status_hit and inRect(p, self.status_hit) then
        local status = package.loaded["macui.status"]
        if status and status.tap then
            pcall(status.tap, self)
        end
        return true
    end
    if self.dlg then
        for i, b in ipairs(self:activeButtons()) do
            if inRect(p, b.g) then
                if b.enabled == nil or b.enabled(self) then
                    self:flash(
                        function() self.flash_button = i end,
                        function() self.flash_button = nil end,
                        b.g,
                        function()
                            self:refresh("ui", b.g)
                            b.callback(self)
                        end
                    )
                end
                return true
            end
        end
    end
    local n = #self.windows
    if n == 0 then
        if self.overlay then
            self:quit()
        end
        return true
    end
    local top = self:parts(n)
    local close_hit = Geom:new {
        x = top.frame.x,
        y = top.frame.y,
        w = math.max(u(70), math.floor(top.frame.w / 4)),
        h = top.title.h,
    }
    if inRect(p, close_hit) then
        self:flash(
            function() self.flash_close = true end,
            function() self.flash_close = false end,
            top.close,
            function() self:closeWindow() end
        )
        return true
    end
    local content = self.windows[n].content
    if self.pager and content.pages then
        local page, pages = content:pages()
        local to = inRect(p, self.pager.prev) and page - 1 or (inRect(p, self.pager.next) and page + 1)
        if to then
            if to >= 1 and to <= pages then
                content:setPage(to)
                self:refresh("ui", self:topRegion())
            end
            return true
        end
    end
    if top.scroll and content.pages then
        local page, pages = content:pages()
        if
            inRect(p, top.up)
            or (inRect(p, top.scroll) and p.y < top.scroll.y + top.scroll.h / 2 and not inRect(p, top.down))
        then
            if page > 1 then
                content:setPage(page - 1)
                self:refresh("ui", self:topRegion())
            end
            return true
        elseif inRect(p, top.scroll) then
            if page < pages then
                content:setPage(page + 1)
                self:refresh("ui", self:topRegion())
            end
            return true
        end
    end
    if inRect(p, top.content) then
        if content.tap then
            content:tap(p, top.content, self)
        end
        return true
    end
    -- a tap on a window further back goes back to it, as clicking a background window did
    for i = n - 1, 1, -1 do
        if inRect(p, self:windowRect(i)) and not inRect(p, top.frame) then
            while #self.windows > i do
                local win = table.remove(self.windows)
                if win.content.free then
                    win.content:free()
                end
                if win.onClose then
                    win.onClose()
                end
            end
            self:layout()
            self:transition()
            return true
        end
    end
    if self.overlay and not inRect(p, top.frame) then
        self:quit()
    end
    return true
end

function M.App:onHold(_, ges)
    if self.modal or self.open_menu or #self.windows == 0 then
        return true
    end
    local top = self:parts(#self.windows)
    local content = self.windows[#self.windows].content
    if inRect(ges.pos, top.content) and content.hold then
        content:hold(ges.pos, top.content, self)
    end
    return true
end

-- The finger lifting after a hold (ends a text selection, a drag...): content:holdRelease(pos, rect, app).
function M.App:onHoldRelease(_, ges)
    if self.modal or self.open_menu or #self.windows == 0 then
        return true
    end
    local top = self:parts(#self.windows)
    local content = self.windows[#self.windows].content
    if content.holdRelease then
        content:holdRelease(ges.pos, top.content, self)
    end
    return true
end

function M.App:onSwipe(_, ges)
    if self.modal or self.open_menu or #self.windows == 0 then
        return true
    end
    local content = self.windows[#self.windows].content
    if not content.pages then
        return true
    end
    local page, pages = content:pages()
    local d = ges.direction
    local next_page = (d == "west" or d == "north") and page + 1
        or ((d == "east" or d == "south") and page - 1 or page)
    if next_page >= 1 and next_page <= pages and next_page ~= page then
        content:setPage(next_page)
        self:refresh("ui", self:topRegion())
    end
    return true
end

-- Close box / Back: close the top window; closing the last one quits.
function M.App:closeWindow()
    if #self.windows <= 1 then
        self:quit()
    else
        self:popWindow()
    end
end

function M.App:onClose()
    if self.modal then
        if self.modal.cancel then
            self.modal:cancel(self)
        end
        return true
    end
    if self.open_menu then
        self.open_menu = nil
        self:refresh("ui", self:menuRegion())
        return true
    end
    self:closeWindow()
    return true
end

function M.App:quit() UIManager:close(self, "ui") end

function M.App:onShow() self:refresh("ui") end

-- A moment after wake the Kindle framework paints its own status bar (a 12-hour clock) over
-- the top of the screen; repaint the menu-bar strip at 1.5 s and 4 s to wipe it.
function M.App:onResume()
    self:cancelWakeRepaint()
    local strip = Geom:new { x = 0, y = 0, w = self.dimen.w, h = u(MENU_H) }
    self.wake_fns = {}
    for _, delay in ipairs { 1.5, 4 } do
        local fn = function()
            if not self.closed then
                self:refresh("ui", strip)
            end
        end
        table.insert(self.wake_fns, fn)
        UIManager:scheduleIn(delay, fn)
    end
end

function M.App:cancelWakeRepaint()
    for _, fn in ipairs(self.wake_fns or {}) do
        UIManager:unschedule(fn)
    end
    self.wake_fns = nil
end

function M.App:onCloseWidget()
    self:cancelWakeRepaint()
    if self.soon then
        UIManager:unschedule(self.soon.flush_fn)
        UIManager:unschedule(self.soon.settle_fn)
    end
    self.closed = true
    if self.modal then
        self.modal:free()
        self.modal = nil
    end
    for _, win in ipairs(self.windows) do
        if win.content.free then
            win.content:free()
        end
    end
    self.windows = {}
    if self.onQuit then
        self.onQuit()
    end
end

--------------------------------------------------------------------------------------------------
-- Modals: alert and progress (System 1 double-bordered dialogs)
--------------------------------------------------------------------------------------------------

local Modal = {}
Modal.__index = Modal

-- spec: { icon = "note"|"caution"|"stop"|nil, title = "…" (bold first line), text = "…",
--         buttons = { { label, callback, default } }, cancel = fn (Back key), progress = 0..1|nil, detail = "…" }
local function newModal(spec) return setmetatable(spec, Modal) end

function Modal:layout(app)
    local W = app.dimen.w
    local w = math.min(W - u(2 * 60), u(500))
    local need = u(2 * 20)
    for _, b in ipairs(self.buttons or {}) do
        need = need + math.max(u(110), M.width(M.face("menu"), b.label) + u(40)) + u(26)
    end
    w = math.max(w, math.min(W - u(2 * 24), need))
    local pad = u(20)
    local icon_w = self.icon and u(32 + 18) or 0
    local face = M.face("body")
    local tw = w - 2 * pad - icon_w
    if not self.textbox or self.textbox_w ~= tw then
        if self.textbox then
            self.textbox:free()
        end
        local text = M.fold((self.title and (self.title .. "\n\n") or "") .. (self.text or ""))
        self.textbox = TextBoxWidget:new { text = text, face = face, width = tw }
        self.textbox_w = tw
    end
    local text_h = self.textbox:getSize().h
    local icon_h = self.icon and u(32) or 0
    local bar_h = self.progress and u(28 + 30) or 0
    local btn_h = (self.buttons and #self.buttons > 0) and u(BTN_H + 26) or 0
    local h = pad + math.max(text_h, icon_h) + bar_h + btn_h + pad
    self.g = Geom:new { x = math.floor((W - w) / 2), y = math.floor((app.dimen.h - h) / 2.4), w = w, h = h }
    self.text_pos = { x = self.g.x + pad + icon_w, y = self.g.y + pad }
    self.icon_pos = { x = self.g.x + pad, y = self.g.y + pad }
    self.bar = self.progress
        and Geom:new {
            x = self.g.x + pad,
            y = self.g.y + pad + math.max(text_h, icon_h) + u(18),
            w = w - 2 * pad,
            h = u(24),
        }
    local by = self.g.y + h - pad - u(BTN_H)
    local bx = self.g.x + w - pad
    for i = #(self.buttons or {}), 1, -1 do
        local b = self.buttons[i]
        local bw = math.max(u(110), M.width(M.face("menu"), b.label) + u(40))
        bx = bx - bw
        b.g = Geom:new { x = bx, y = by, w = bw, h = u(BTN_H) }
        bx = bx - u(26)
    end
end

function Modal:paint(bb, app)
    self:layout(app)
    local g = self.g
    M.box(bb, g.x, g.y, g.w, g.h, { border = u(2), shadow = u(SHADOW) })
    bb:paintBorder(g.x + u(5), g.y + u(5), g.w - u(10), g.h - u(10), u(3), BLACK)
    if self.icon then
        local k = U
        M.paintGlyph(bb, self.icon, self.icon_pos.x, self.icon_pos.y, k)
    end
    self.textbox:paintTo(bb, self.text_pos.x, self.text_pos.y)
    if self.bar then
        local b = self.bar
        bb:paintBorder(b.x, b.y, b.w, b.h, u(2), BLACK)
        local fill = math.floor((b.w - u(4)) * math.max(0, math.min(1, self.progress)))
        bb:paintRect(b.x + u(2), b.y + u(2), fill, b.h - u(4), BLACK)
        if self.detail then
            local small = M.face("small")
            M.text(bb, b.x, b.y + b.h + u(22), small, self.detail, { max_w = b.w })
        end
    end
    for i, b in ipairs(self.buttons or {}) do
        M.button(bb, b.g, b.label, { default = b.default, pressed = self.pressed == i })
    end
end

function Modal:tap(p, app)
    for i, b in ipairs(self.buttons or {}) do
        if b.g and inRect(p, b.g) then
            app:flash(function() self.pressed = i end, function() self.pressed = nil end, b.g, function()
                if app.modal ~= self then
                    return -- this alert was replaced or closed meanwhile
                end
                if b.keep_open then
                    app:refresh("ui", self.g)
                else
                    app:closeModal()
                end
                if b.callback then
                    b.callback(app)
                end
            end)
            return
        end
    end
end

-- The alert box with its shadow, in screen px.
function Modal:region()
    local g = self.g
    return Geom:new { x = g.x, y = g.y, w = g.w + u(SHADOW), h = g.h + u(SHADOW) }
end

function Modal:cancel(app)
    app:closeModal()
    if self.on_cancel then
        self.on_cancel(app)
    end
end

function Modal:free()
    if self.textbox then
        self.textbox:free()
        self.textbox = nil
    end
end

-- Shows an alert. Returns the modal (call app:closeModal() to dismiss it yourself).
function M.App:alert(spec)
    if self.modal then
        self.modal:free()
    end
    self.modal = newModal(spec)
    self.modal:layout(self)
    self:refresh("ui", self.modal:region())
    return self.modal
end

-- Progress dialog: returns a handle with :update(fraction, detail) and :close().
-- spec: { text = "Copying “X”…", cancel = function() end }
function M.App:progress(spec)
    local app = self
    local m = self:alert {
        icon = spec.icon,
        text = spec.text,
        progress = 0,
        detail = spec.detail,
        buttons = spec.cancel and { { label = "Cancel", callback = spec.cancel } } or nil,
        on_cancel = spec.cancel,
    }
    return {
        update = function(_, fraction, detail)
            if app.modal ~= m then
                return
            end
            m.progress = fraction
            m.detail = detail
            app:refresh("ui", m.g)
        end,
        close = function()
            if app.modal == m then
                app:closeModal()
            end
        end,
    }
end

-- Text entry (the composer). spec: { title, text (initial), hint, ok_label = "OK", password = bool,
-- lines = n (a multi-line field n lines tall: Return types a new line), quote = "…" (shown read-only
-- above the field, e.g. the highlighted passage), ok = function(value, app) }. The Notebooks pen pad
-- joins its keyboard by itself (it hooks every VirtualKeyboard). Returns the dialog.
-- ponytail: wraps KOReader's InputDialog and keyboard for now; restyle here once, every app follows.
function M.App:prompt(spec)
    local InputDialog = require("ui/widget/inputdialog")
    local lines = spec.lines and spec.lines > 1 and spec.lines or nil
    local text_height
    if lines then
        local probe = TextBoxWidget:new { text = "X", face = InputDialog.input_face, width = u(100) }
        text_height = lines * probe:getLineHeight()
        probe:free()
    end
    local dlg
    dlg = InputDialog:new {
        title = M.fold(spec.title or ""),
        description = spec.quote and M.fold(spec.quote),
        input = spec.text or "",
        input_hint = spec.hint,
        text_type = spec.password and "password" or nil,
        allow_newline = lines ~= nil,
        text_height = text_height,
        buttons = {
            {
                { text = "Cancel", id = "close", callback = function() UIManager:close(dlg) end },
                {
                    text = spec.ok_label or "OK",
                    is_enter_default = not lines,
                    callback = function()
                        local v = dlg:getInputText()
                        UIManager:close(dlg)
                        if spec.ok then
                            spec.ok(v, self)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
    return dlg
end

function M.App:closeModal()
    if self.modal then
        local region = self.modal.g and self.modal:region()
        self.modal:free()
        self.modal = nil
        self:refresh("ui", region)
    end
end

--------------------------------------------------------------------------------------------------
-- KOReader menus as Mac menus
--------------------------------------------------------------------------------------------------

local function try(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local ok, v = pcall(fn, ...)
    if ok then
        return v
    end
    logger.warn("macui: menu item function failed:", v)
end

-- KOReader menu items carry no icons, so list windows pick one from the item's text: the first
-- rule with a matching keyword (lower case, Lua patterns) wins. Extend the list for new entries.
M.ICON_RULES = {
    { "wifi", { "wi%-fi", "wifi", "network", "internet", "proxy", "ssh" } },
    { "frontlight", { "frontlight", "brightness", "dimmer", "backlight" } },
    { "night", { "night", "warmth", "dark mode", "invert" } },
    { "rotate", { "rotation", "orientation", "rotate" } },
    { "screen", { "screen", "e%-ink", "refresh", "dpi", "display", "screenshot" } },
    { "gestures", { "gesture", "taps", "swipe", "touch", "corner" } },
    { "keyboard", { "keyboard", "input" } },
    { "navigation", { "navigation", "page turn", "keys", "button", "scroll" } },
    { "language", { "language", "translat", "hyphenat" } },
    { "document", { "document", "font", "text", "style", "typograph", "margin", "reader" } },
    { "home", { "home", "start with" } },
    {
        "history",
        {
            "history",
            "recent",
            "last file",
            "time",
            "date",
            "clock",
            "auto%-save",
            "sleep",
            "suspend",
            "standby",
            "timeout",
        },
    },
    { "power", { "power", "battery", "shutdown", "restart", "reboot" } },
    { "device", { "device", "storage", "usb", "developer", "debug" } },
    { "stats", { "statistic", "progress", "reading time" } },
    { "bookmark", { "bookmark", "highlight", "annotation", "note" } },
    { "search", { "search", "find", "dictionary", "wikipedia", "lookup" } },
    { "folder", { "file", "folder", "browser", "collection", "favorite" } },
    { "plugin", { "plugin", "patch", "updat" } },
    { "alert-note", { "notification", "message", "help", "about", "info" } },
    { "settings", { "setting", "advanced", "more", "option" } },
}

function M.iconFor(text)
    local t = (text or ""):lower()
    for _, rule in ipairs(M.ICON_RULES) do
        for _, pat in ipairs(rule[2]) do
            if t:find(pat) then
                return rule[1]
            end
        end
    end
end

-- A stand-in for KOReader's TouchMenu, which item callbacks receive (they call updateItems()
-- after toggling a setting, or closeMenu()).
local function touchmenuShim(app)
    return {
        updateItems = function() app:refresh() end,
        closeMenu = function() app:quit() end,
        item_table = {},
    }
end

-- Converts KOReader menu items (TouchMenu style: text/text_func, enabled_func, checked_func,
-- callback(touchmenu), sub_item_table/sub_item_table_func, separator, keep_menu_open) into macui
-- menu items. Entries with a sub-menu get the Mac "…" and open as a list window (System 1 had no
-- hierarchical menus). Every KOReader function is pcall-guarded.
function M.fromKOReader(items)
    local out = {}
    for _, it in ipairs(items or {}) do
        local text = it.text_func and try(it.text_func) or it.text
        if type(text) == "string" and text ~= "" then
            local has_sub = it.sub_item_table ~= nil or it.sub_item_table_func ~= nil
            local entry = {
                toggle = (it.checked_func ~= nil or it.checked ~= nil) and not it.radio,
                radio = it.radio and true or nil,
                icon = it.macui_icon or M.iconFor(text),
                text = text
                    .. ((has_sub and not text:find("…$") and not text:find("%.%.%.$")) and "…" or ""),
                enabled = it.enabled ~= false and ((not it.enabled_func) or try(it.enabled_func) ~= false),
                checked = (it.checked_func and try(it.checked_func)) or (it.checked and true) or nil,
            }
            entry.callback = function(app) app:runKOReaderItem(it, text) end
            out[#out + 1] = entry
            if it.separator then
                out[#out + 1] = "-"
            end
        end
    end
    if out[#out] == "-" then
        out[#out] = nil
    end
    return out
end

-- Runs a KOReader menu item: a sub-menu opens as a list window; an action closes an overlay
-- first (so the dialogs it opens appear over the screen), unless the item keeps the menu open.
function M.App:runKOReaderItem(it, title)
    local sub = it.sub_item_table or (it.sub_item_table_func and try(it.sub_item_table_func))
    if sub then
        -- converted on every paint, so text_func / checked_func results follow setting changes
        self:openList(title, function() return M.fromKOReader(sub) end)
        return
    end
    if not it.callback then
        return
    end
    local shim = touchmenuShim(self)
    if self.overlay and not it.keep_menu_open then
        self:quit()
    end
    try(it.callback, shim)
    if it.keep_menu_open then
        self:refresh()
    end
end

-- A window listing menu items (a sub-menu, or any list of commands).
local MenuList = {}
MenuList.__index = MenuList

-- items: a list, or a function returning one (re-evaluated on every paint).
function M.App:openList(title, items)
    local list = setmetatable({
        source = type(items) == "function" and items or nil,
        items = type(items) == "table" and items or {},
        page = 1,
    }, MenuList)
    self:pushWindow { title = title, content = list }
end

function MenuList:paint(bb, r, app)
    if self.source then
        self.items = self.source() or {}
    end
    local face = M.face("menu")
    local with_icons = false
    for _, it in ipairs(self.items) do
        if it ~= "-" and it.icon then
            with_icons = true
        end
    end
    local row = with_icons and u(40) or u(36)
    local ip = math.floor(u(24) / 32) * 32 -- icon size: a whole multiple of the 32-px grid
    local text_x = r.x + u(30) + (with_icons and (ip + u(12)) or 0)
    self.per_page = math.max(1, math.floor((r.h - u(8)) / row))
    local pages = math.max(1, math.ceil(#self.items / self.per_page))
    self.page = math.min(self.page, pages)
    self.rows = {}
    local first = (self.page - 1) * self.per_page + 1
    local y = r.y + u(4)
    for k = first, math.min(#self.items, first + self.per_page - 1) do
        local it = self.items[k]
        if it == "-" then
            for lx = r.x + u(8), r.x + r.w - u(8), 2 * U do
                bb:paintRect(lx, y + math.floor(row / 2), U, U, BLACK)
            end
        else
            local g = Geom:new { x = r.x, y = y, w = r.w, h = row }
            local hot = self.flash == k
            if hot then
                bb:paintRect(g.x, g.y, g.w, g.h, BLACK)
            end
            local ink = hot and WHITE or BLACK
            local cs = u(14)
            local cy = y + math.floor((row - cs) / 2)
            if it.radio then
                M.radio(bb, r.x + u(9), cy, cs, it.checked)
            elseif it.toggle then
                M.checkbox(bb, r.x + u(9), cy, cs, it.checked)
            elseif it.checked then
                M.paintGlyph(bb, "check", r.x + u(10), y + math.floor((row - 8 * U) / 2), U, ink)
            end
            if hot and (it.radio or it.toggle) then
                bb:invertRect(r.x + u(9), cy, cs, cs)
            end
            if with_icons and it.icon then
                local ix, iy = r.x + u(30), y + math.floor((row - ip) / 2)
                M.paintIcon(bb, it.icon, ix, iy, ip)
                if hot then
                    bb:invertRect(ix, iy, ip, ip) -- keep the icon readable on the black pressed row
                end
            end
            M.text(
                bb,
                text_x,
                M.baseline(face, y, row),
                face,
                it.text,
                { color = ink, max_w = r.x + r.w - text_x - u(10) }
            )
            if it.enabled == false then
                M.grayOut(bb, g.x, g.y, g.w, g.h)
            end
            self.rows[#self.rows + 1] = { g = g, item = it, k = k }
        end
        y = y + row
    end
end

function MenuList:pages()
    local pages = math.max(1, math.ceil(#self.items / (self.per_page or #self.items)))
    return math.min(self.page, pages), pages
end

function MenuList:setPage(n) self.page = n end

function MenuList:tap(p, _, app)
    for _, row in ipairs(self.rows or {}) do
        if inRect(p, row.g) and row.item.enabled ~= false then
            app:flash(function() self.flash = row.k end, function() self.flash = nil end, row.g, function()
                if row.item.callback then
                    row.item.callback(app)
                end
                -- radio-style items move their checkmark to another row: refresh the whole list
                if not app.closed then
                    app:refresh("ui", app:topRegion())
                end
            end)
            return
        end
    end
end

function MenuList:status()
    local n = 0
    for _, it in ipairs(self.items) do
        if it ~= "-" then
            n = n + 1
        end
    end
    return n .. (n == 1 and " item" or " items")
end

--------------------------------------------------------------------------------------------------
-- Contents
--------------------------------------------------------------------------------------------------

-- Finder list view. items: { { name, icon = "folder", dim = bool, ...column keys } }
-- columns: { { key = "kind", title = "Kind", w = 110 (design px), align = "left"|"right" } } after Name.
M.List = {}
M.List.__index = M.List

function M.List:new(o)
    o = setmetatable(o or {}, self)
    o.items = o.items or {}
    o.columns = o.columns or {}
    o.page = 1
    o.row_h = o.row_h or 38
    o.per_page = 1
    return o
end

function M.List:geometry(r)
    local head = u(26)
    local row = u(self.row_h)
    self.per_page = math.max(1, math.floor((r.h - head - u(4)) / row))
    return head, row
end

function M.List:pages() return self.page, math.max(1, math.ceil(#self.items / self.per_page)) end

function M.List:setPage(n) self.page = n end

function M.List:setItems(items)
    self.items = items
    self.page = 1
end

function M.List:paint(bb, r)
    local head, row = self:geometry(r)
    local small, face = M.face("small"), M.face("body")
    local pad = u(12)
    -- column header, underlined as in the Finder's "by Name" view
    local cols_w = 0
    for _, c in ipairs(self.columns) do
        cols_w = cols_w + u(c.w)
    end
    local name_x = r.x + pad + u(32) + u(12)
    local hb = M.baseline(small, r.y, head)
    M.text(bb, name_x, hb, small, self.name_title or "Name")
    local cx = r.x + r.w - pad - cols_w
    for _, c in ipairs(self.columns) do
        M.text(bb, cx, hb, small, c.title, { w = u(c.w) - u(8), align = c.align })
        cx = cx + u(c.w)
    end
    bb:paintRect(r.x, r.y + head - u(1), r.w, u(1), BLACK)
    self.rows = {}
    if #self.items == 0 then
        M.text(
            bb,
            r.x,
            M.baseline(face, r.y + head + u(40), u(40)),
            face,
            self.empty or "This folder is empty.",
            { w = r.w, align = "center" }
        )
        return
    end
    self.page = math.min(self.page, select(2, self:pages()))
    local first = (self.page - 1) * self.per_page + 1
    for k = first, math.min(#self.items, first + self.per_page - 1) do
        local it = self.items[k]
        local y = r.y + head + (k - first) * row
        local g = Geom:new { x = r.x, y = y, w = r.w, h = row }
        self.rows[#self.rows + 1] = { g = g, item = it }
        local ip = u(32)
        ip = math.floor(ip / 32) * 32 -- whole multiple of the 32-px icon grid
        local ib = it.icon and M.icon(it.icon, ip, it.dim and "dim" or nil)
        if ib then
            bb:blitFrom(
                ib,
                r.x + pad + math.floor((u(32) - ip) / 2),
                y + math.floor((row - ip) / 2),
                0,
                0,
                ip,
                ip
            )
        end
        local name_w = r.x + r.w - pad - cols_w - name_x - u(10)
        if it.sub or (self.title_lines or 1) > 1 then
            -- the name (word-wrapped to title_lines), then a detail line in the small face
            local names = M.wrap(face, it.name, name_w, self.title_lines or 1)
            local fh = face.ftsize:getHeightAndAscender()
            local sh = it.sub and small.ftsize:getHeightAndAscender() or 0
            local block = #names * fh + sh
            local ty = y + math.floor((row - block) / 2)
            for li, ln in ipairs(names) do
                M.text(bb, name_x, M.baseline(face, ty + (li - 1) * fh, fh), face, ln)
            end
            if it.sub then
                M.text(bb, name_x, M.baseline(small, ty + #names * fh, sh), small, it.sub, { max_w = name_w })
            end
        else
            M.text(bb, name_x, M.baseline(face, y, row), face, it.name, { max_w = name_w })
        end
        local x = r.x + r.w - pad - cols_w
        local sb = M.baseline(small, y, row)
        for _, c in ipairs(self.columns) do
            local v = it[c.key]
            if c.bar then
                -- a fraction (0..1) drawn as a small progress bar; nil draws nothing
                if type(v) == "number" then
                    local bw, bh = u(c.w) - u(16), u(10)
                    local by = y + math.floor((row - bh) / 2)
                    bb:paintBorder(x, by, bw, bh, u(1), BLACK)
                    bb:paintRect(x, by, math.floor(bw * math.max(0, math.min(1, v))), bh, BLACK)
                end
            elseif v and v ~= "" then
                M.text(bb, x, sb, small, tostring(v), { w = u(c.w) - u(8), align = c.align })
            end
            x = x + u(c.w)
        end
        if self.selected == it then
            bb:invertRect(g.x, g.y, g.w, g.h)
        end
    end
end

function M.List:hit(p)
    for _, row in ipairs(self.rows or {}) do
        if inRect(p, row.g) then
            return row
        end
    end
end

-- Tap: invert the row briefly (System 1 selection), then open it.
function M.List:tap(p, _, app)
    local row = self:hit(p)
    if not row then
        return
    end
    app:flash(function() self.selected = row.item end, function() self.selected = nil end, row.g, function()
        app:refresh("ui", row.g)
        if self.onOpen then
            self.onOpen(row.item, app)
        end
    end)
end

function M.List:hold(p, _, app)
    local row = self:hit(p)
    if row and self.onHold then
        self.onHold(row.item, app)
    end
end

function M.List:status()
    if self.statusText then
        return self.statusText(self)
    end
    local n = #self.items
    return n .. (n == 1 and " item" or " items")
end

-- Finder icon view. items: { { name, sub = "…", icon = "folder", dim = bool, image = bb|nil } }.
-- cols x rows cells; an item's image (e.g. a dithered cover) replaces its icon.
M.Grid = {}
M.Grid.__index = M.Grid

function M.Grid:new(o)
    o = setmetatable(o or {}, self)
    o.items = o.items or {}
    o.cols = o.cols or 3
    o.rows_n = o.rows or 3
    o.page = 1
    return o
end

function M.Grid:perPage() return self.cols * self.rows_n end

function M.Grid:pages() return self.page, math.max(1, math.ceil(#self.items / self:perPage())) end

function M.Grid:setPage(n) self.page = n end

function M.Grid:setItems(items)
    self.items = items
    self.page = 1
end

-- Screen-px image size for this grid in rect r (cover proportions 0.77, like a magazine).
function M.Grid:imageSize(r)
    local cw = math.floor((r.w - u(24)) / self.cols)
    local ch = math.floor((r.h - u(12)) / self.rows_n)
    local label_h = u(46)
    local ih = ch - label_h - u(20)
    local iw = math.floor(ih * (self.aspect or 0.77))
    if iw > cw - u(30) then
        iw = cw - u(30)
        ih = math.floor(iw / (self.aspect or 0.77))
    end
    return iw, ih, cw, ch, label_h
end

function M.Grid:paint(bb, r)
    local iw, ih, cw, ch, label_h = self:imageSize(r)
    -- icon labels use the small face, as the Finder did (Geneva 9 under Chicago 12 menus)
    local face, small = M.face("small"), M.face("tiny")
    self.cells = {}
    self.page = math.min(self.page, select(2, self:pages()))
    if #self.items == 0 then
        M.text(
            bb,
            r.x,
            M.baseline(face, r.y + u(60), u(40)),
            face,
            self.empty or "This folder is empty.",
            { w = r.w, align = "center" }
        )
        return
    end
    local first = (self.page - 1) * self:perPage() + 1
    for k = first, math.min(#self.items, first + self:perPage() - 1) do
        local it = self.items[k]
        local idx = k - first
        local col, row = idx % self.cols, math.floor(idx / self.cols)
        local cx = r.x + u(12) + col * cw
        local cy = r.y + u(12) + row * ch
        local g = Geom:new { x = cx, y = cy, w = cw, h = ch }
        self.cells[#self.cells + 1] = { g = g, item = it }
        local ix = cx + math.floor((cw - iw) / 2)
        local iy = cy + u(10)
        local img = it.image
        if img then
            -- a cover: 1-bit image in a frame with a drop shadow, like a document on the desk
            bb:paintRect(ix + u(SHADOW), iy + u(SHADOW), iw, ih, BLACK)
            bb:blitFrom(img, ix, iy, 0, 0, math.min(iw, img:getWidth()), math.min(ih, img:getHeight()))
            bb:paintBorder(ix, iy, iw, ih, u(1), BLACK)
        else
            local ip = math.max(32, math.floor(math.min(iw, ih, u(64)) / 32) * 32)
            if it.placeholder then
                -- not on this Kindle yet: a dimmed page with the icon in the middle
                M.box(bb, ix, iy, iw, ih, { border = u(1), shadow = u(3) })
                M.grayOut(bb, ix, iy, iw, ih)
            end
            local ib = it.icon and M.icon(it.icon, ip, it.dim and "dim" or nil)
            if ib then
                bb:blitFrom(ib, ix + math.floor((iw - ip) / 2), iy + math.floor((ih - ip) / 2), 0, 0, ip, ip)
            end
        end
        if it.progress and it.progress > 0 then
            local by = iy + ih + u(6)
            bb:paintBorder(ix, by, iw, u(5), u(1), BLACK)
            bb:paintRect(ix, by, math.floor(iw * math.min(1, it.progress)), u(5), BLACK)
        end
        local ly = iy + ih + u(14)
        local name = M.truncate(face, it.name, cw - u(10))
        local nw = M.width(face, name)
        local nx = cx + math.floor((cw - nw) / 2)
        local sel = self.selected == it
        -- the Finder draws the selected icon's name inverted
        if sel then
            bb:paintRect(nx - u(4), ly, nw + u(8), u(24), BLACK)
        end
        M.text(bb, nx, M.baseline(face, ly, u(24)), face, name, { color = sel and WHITE or BLACK })
        if it.sub then
            M.text(bb, cx, M.baseline(small, ly + u(24), u(20)), small, it.sub, { w = cw, align = "center" })
        end
        local _ = label_h
        if sel and img then
            bb:invertRect(ix, iy, iw, ih)
        end
    end
end

function M.Grid:hit(p)
    for _, c in ipairs(self.cells or {}) do
        if inRect(p, c.g) then
            return c
        end
    end
end

M.Grid.tap = function(self, p, _, app)
    local c = self:hit(p)
    if not c then
        return
    end
    app:flash(function() self.selected = c.item end, function() self.selected = nil end, c.g, function()
        app:refresh("ui", c.g)
        if self.onOpen then
            self.onOpen(c.item, app)
        end
    end)
end

M.Grid.hold = function(self, p, _, app)
    local c = self:hit(p)
    if c and self.onHold then
        self.onHold(c.item, app)
    end
end

M.Grid.status = M.List.status

function M.Grid:free()
    for _, it in ipairs(self.items) do
        if it.image and it.free_image ~= false then
            it.image:free()
            it.image = nil
        end
    end
end

-- Paged document for reading: blocks { kind = "h" | "p" | "li" | "rule" | "code" | "quote" | "note" | "busy",
-- text } (code: monospace, lines verbatim; quote: indented under a bar; note: a small Chicago line;
-- busy: an indeterminate 1-bit bar after its text), plus
-- { kind = "img", image = <blitbuffer> | path = "<image file>", caption = "…" } for pictures in the
-- flow (Atkinson-dithered to 1-bit, fit to the text width, never split across pages).
-- o.scale (e.g. 0.85 .. 1.4) sets the reading text size. Headings use the
-- Chicago title face, paragraphs and list items the reading serif (M.READ) with open leading;
-- pages break between lines, never leave a heading alone at a page bottom, and list items get a
-- square bullet. Use it for abstracts, summaries and articles instead of macui.Text.
M.Doc = {}
M.Doc.__index = M.Doc

function M.Doc:new(o)
    o = setmetatable(o or {}, self)
    o.blocks = o.blocks or {}
    o.page = 1
    return o
end

-- Blocks changed in place (or replaced): repaginate at the next paint. Each text block keeps its
-- measurement (b.m) while its text and width stay, so only new or changed blocks are measured again.
function M.Doc:invalidate() self.laid_w = nil end

local DOC = {
    pad_x = 26,
    pad_y = 18,
    gap_h = 18,
    gap_p = 12,
    gap_li = 5,
    indent = 22,
    rule = 18,
    busy = 30,
    code_scale = 1.25,
}

function M.Doc:layout(r)
    if self.laid_w == r.w and self.laid_h == r.h then
        return
    end
    self:freeBoxes()
    for _, img in ipairs(self.images or {}) do
        img:free()
    end
    self.images = nil
    self.laid_w, self.laid_h = r.w, r.h
    local w = r.w - 2 * u(DOC.pad_x)
    local H = r.h - 2 * u(DOC.pad_y)
    local pages = { {} }
    local y = 0
    local function newPage()
        pages[#pages + 1] = {}
        y = 0
    end
    for _, b in ipairs(self.blocks) do
        if b.kind == "rule" then
            if y > 0 and y + u(DOC.rule) > H then
                newPage()
            end
            table.insert(pages[#pages], { rule = true, y = y + math.floor(u(DOC.rule) / 2) })
            y = y + u(DOC.rule)
        elseif b.kind == "img" then
            local src = b.image or (b.path and RenderImage:renderImageFile(b.path, false))
            if src then
                local sw, sh = src:getWidth(), src:getHeight()
                local cap_h = b.caption and u(30) or 0
                local k = math.min(w / sw, (H - cap_h) / sh, 1.5)
                local iw, ih = math.max(1, math.floor(sw * k)), math.max(1, math.floor(sh * k))
                if y > 0 and y + u(DOC.gap_p) + ih + cap_h > H then
                    newPage()
                elseif y > 0 then
                    y = y + u(DOC.gap_p)
                end
                local img = M.atkinson(src, iw, ih)
                if not b.image then
                    src:free()
                end
                self.images = self.images or {}
                table.insert(self.images, img)
                table.insert(
                    pages[#pages],
                    { img = img, x = math.floor((w - iw) / 2), y = y, caption = b.caption, ih = ih }
                )
                y = y + ih + cap_h
            end
        elseif b.kind == "busy" then
            if y > 0 and y + u(DOC.gap_p + DOC.busy) > H then
                newPage()
            elseif y > 0 then
                y = y + u(DOC.gap_p)
            end
            table.insert(pages[#pages], { busy = b.text or "", y = y })
            y = y + u(DOC.busy)
        elseif b.text and b.text:match("%S") then
            local kind = b.kind
            local heading = kind == "h"
            local chicago = heading or kind == "note"
            local face = heading and M.face("title")
                or kind == "note" and M.face("small")
                or kind == "code" and M.face("mono", (self.scale or 1) * DOC.code_scale)
                or M.face("read", self.scale)
            local indent = (kind == "li" or kind == "quote" or kind == "code") and u(DOC.indent) or 0
            local text = chicago and M.fold(b.text) or b.text
            local lh_k = chicago and 0.1 or (kind == "code" and 0.2 or 0.35)
            local m = b.m
            if not (m and m.w == w - indent and m.face == face and m.text == text) then
                local box =
                    TextBoxWidget:new { text = text, face = face, width = w - indent, line_height = lh_k }
                m = {
                    w = w - indent,
                    face = face,
                    text = text,
                    lh = box.line_height_px,
                    total = box:getAllLineCount(),
                }
                box:free()
                b.m = m
            end
            local lh, total = m.lh, m.total
            if y > 0 then
                y = y + u(heading and DOC.gap_h or (kind == "li" and DOC.gap_li or DOC.gap_p))
            end
            local first = 1
            while first <= total do
                local avail = math.floor((H - y) / lh)
                -- a heading needs room for itself and two lines of what follows
                if avail < 1 or (heading and avail < total + 2) then
                    newPage()
                    avail = math.max(1, math.floor(H / lh))
                end
                local n = math.min(avail, total - first + 1)
                table.insert(pages[#pages], {
                    text = text,
                    face = face,
                    width = w - indent,
                    indent = indent,
                    heading = heading,
                    lh_k = lh_k,
                    bar = kind == "quote",
                    first = first,
                    n = n,
                    y = y,
                    lh = lh,
                    bullet = b.kind == "li" and first == 1,
                })
                y = y + n * lh
                first = first + n
                if first <= total then
                    newPage()
                end
            end
        end
    end
    if #pages > 1 and #pages[#pages] == 0 then
        pages[#pages] = nil
    end
    self.pages_list = pages
    self.page = math.min(self.page, #pages)
end

function M.Doc:freeBoxes()
    for _, b in ipairs(self.boxes or {}) do
        b:free()
    end
    self.boxes = {}
end

function M.Doc:paint(bb, r)
    self:layout(r)
    self:freeBoxes()
    local x0, y0 = r.x + u(DOC.pad_x), r.y + u(DOC.pad_y)
    for _, seg in ipairs(self.pages_list[self.page] or {}) do
        if seg.rule then
            bb:paintRect(x0, y0 + seg.y, r.w - 2 * u(DOC.pad_x), u(1), BLACK)
        elseif seg.img then
            bb:blitFrom(seg.img, x0 + seg.x, y0 + seg.y, 0, 0, seg.img:getWidth(), seg.img:getHeight())
            if seg.caption then
                local small = M.face("small")
                M.text(
                    bb,
                    x0,
                    M.baseline(small, y0 + seg.y + seg.ih, u(30)),
                    small,
                    seg.caption,
                    { w = r.w - 2 * u(DOC.pad_x), align = "center" }
                )
            end
        elseif seg.busy then
            -- indeterminate wait, 1-bit: the label, then a framed bar of the 50% dither
            local small = M.face("small")
            local h = u(DOC.busy)
            M.text(bb, x0, M.baseline(small, y0 + seg.y, h), small, seg.busy)
            local bx = x0 + M.width(small, seg.busy) + u(14)
            local bw = math.min(u(160), r.w - 2 * u(DOC.pad_x) - (bx - x0))
            if bw > u(20) then
                local by, bh = y0 + seg.y + u(9), h - u(18)
                bb:paintRect(bx, by, bw, bh, WHITE)
                M.dither(bb, bx + u(2), by + u(2), bw - u(4), bh - u(4))
                bb:paintBorder(bx, by, bw, bh, u(2), BLACK)
            end
        else
            local box = TextBoxWidget:new {
                text = seg.text,
                face = seg.face,
                width = seg.width,
                height = seg.n * seg.lh,
                line_height = seg.lh_k,
            }
            if seg.first > 1 then
                box:scrollLines(seg.first - 1)
            end
            box:paintTo(bb, x0 + seg.indent, y0 + seg.y)
            self.boxes[#self.boxes + 1] = box
            if seg.bar then
                bb:paintRect(x0 + u(6), y0 + seg.y, u(2), seg.n * seg.lh, BLACK)
            end
            if seg.bullet then
                local d = u(6)
                bb:paintRect(x0 + u(6), y0 + seg.y + math.floor((seg.lh - d) / 2), d, d, BLACK)
            end
        end
    end
end

function M.Doc:pages() return self.page, self.pages_list and #self.pages_list or 1 end

function M.Doc:setPage(n) self.page = n end

function M.Doc:free()
    self:freeBoxes()
    for _, img in ipairs(self.images or {}) do
        img:free()
    end
    self.images = nil
end

--------------------------------------------------------------------------------------------------
-- Chat: a conversation laid out by macui.Doc (questions in Chicago, answers in the reading serif)
--------------------------------------------------------------------------------------------------

---@class macui.ChatTurn
---@field role "user"|"assistant"|"note"
---@field text string markdown (assistant), plain (user, note)
---@field error boolean|nil an answer that failed: shown as a note

---@class macui.Chat
---@field turns macui.ChatTurn[]
---@field empty string|nil shown while there are no turns
---@field status_text string|fun(chat:macui.Chat):string|nil left text of the status strip (new{status=})
---@field busy string|nil the "thinking..." line, see setBusy
---@field follow boolean the page follows the end of the conversation (false once paged back)
M.Chat = {}
M.Chat.__index = M.Chat

-- Laid-out text is bounded: the newest turns up to `keep` bytes; older ones fold into one note.
M.CHAT = { keep = 48 * 1024 }

---@param o {turns:macui.ChatTurn[]|nil, empty:string|nil, status:string|function|nil}|nil
---@return macui.Chat
function M.Chat:new(o)
    o = setmetatable(o or {}, self)
    o.turns = o.turns or {}
    o.status_text, o.status = rawget(o, "status"), nil -- the field would hide the status() method
    o.doc = M.Doc:new {}
    o.follow = true
    o.dirty = true
    return o
end

-- Something changed: repaginate at the next paint and ask the app for a coalesced repaint.
function M.Chat:changed()
    self.dirty = true
    local app, rect = self.app, self.rect
    if app and not app.closed and rect then
        app:refreshSoon(rect)
    end
end

---@param role "user"|"assistant"|"note"
---@param text string|nil
---@return macui.ChatTurn
function M.Chat:add(role, text)
    local turn = { role = role, text = text or "" }
    self.turns[#self.turns + 1] = turn
    self.follow = true
    self:changed()
    return turn
end

-- Streaming: appends delta to turn's text. Only that turn is parsed again, and only its changed
-- blocks are measured again; repaints are coalesced (App:refreshSoon).
---@param turn macui.ChatTurn
---@param delta string|nil
function M.Chat:append(turn, delta)
    if delta and delta ~= "" then
        turn.text = turn.text .. delta
        self:changed()
    end
end

-- text: show an indeterminate wait line at the end ("Thinking..."); nil: remove it.
---@param text string|nil
function M.Chat:setBusy(text)
    if self.busy ~= text then
        self.busy = text
        self:changed()
    end
end

-- The newest answer that did not fail (for Copy).
---@return string|nil
function M.Chat:lastAnswer()
    for i = #self.turns, 1, -1 do
        local t = self.turns[i]
        if t.role == "assistant" and not t.error and t.text:match("%S") then
            return t.text
        end
    end
end

function M.Chat:clear()
    self.turns = {}
    self.busy = nil
    self.follow = true
    self.doc.page = 1
    self:changed()
end

-- A turn's Doc blocks, cached on the turn while its text stays. Unchanged blocks keep their old
-- tables, and with them Doc's measurements.
local function turnBlocks(turn, Markdown)
    if turn.blocks and turn.blocks_of == turn.text and turn.blocks_err == turn.error then
        return turn.blocks
    end
    local new
    if turn.role == "user" then
        new = { { kind = "h", text = "You: " .. (Markdown.plain(turn.text) or "") } }
    elseif turn.role == "note" or turn.error then
        new = {
            { kind = "note", text = (turn.error and "Error: " or "") .. (Markdown.plain(turn.text) or "") },
        }
    else
        new = Markdown.blocks(turn.text)
    end
    local old = turn.blocks or {}
    for i, b in ipairs(new) do
        local o = old[i]
        if o and o.kind == b.kind and o.text == b.text then
            new[i] = o
        end
    end
    turn.blocks, turn.blocks_of, turn.blocks_err = new, turn.text, turn.error
    return new
end

function M.Chat:build()
    local Markdown = require("markdown")
    local blocks, from, size = {}, 1, 0
    for i = #self.turns, 1, -1 do
        size = size + #self.turns[i].text
        if size > M.CHAT.keep and i < #self.turns then
            from = i + 1
            break
        end
    end
    for i = 1, from - 1 do
        self.turns[i].blocks = nil -- folded away: free its blocks and measurements
    end
    if from > 1 then
        local n = from - 1
        blocks[1] = { kind = "note", text = n == 1 and "1 earlier message" or (n .. " earlier messages") }
    end
    for i = from, #self.turns do
        local turn = self.turns[i]
        if turn.role == "user" and #blocks > 0 then
            blocks[#blocks + 1] = { kind = "rule" }
        end
        for _, b in ipairs(turnBlocks(turn, Markdown)) do
            blocks[#blocks + 1] = b
        end
    end
    if self.busy then
        blocks[#blocks + 1] = { kind = "busy", text = self.busy }
    end
    if #blocks == 0 and self.empty then
        blocks[1] = { kind = "note", text = self.empty }
    end
    self.doc.blocks = blocks
    self.doc:invalidate()
    self.dirty = false
end

function M.Chat:paint(bb, r, app)
    self.app = app
    -- what a streaming repaint covers: the content, scroll bar and status strip (they track pages)
    local p = app
        and app.windows[#app.windows]
        and app.windows[#app.windows].content == self
        and app:parts(#app.windows)
    self.rect = p and Geom:new { x = p.frame.x, y = r.y, w = p.frame.w, h = p.frame.y + p.frame.h - r.y } or r
    if self.dirty then
        self:build()
    end
    self.doc:layout(r)
    if self.follow then
        self.doc.page = #self.doc.pages_list
    end
    self.doc:paint(bb, r)
end

function M.Chat:pages() return self.doc:pages() end

function M.Chat:setPage(n)
    self.doc:setPage(n)
    local _, last = self.doc:pages()
    self.follow = n >= last
end

function M.Chat:status()
    local s = self.status_text
    if type(s) == "function" then
        return s(self)
    end
    return s
end

function M.Chat:free() self.doc:free() end

---@class macui.ChatCtx one question being answered, handed to send()
---@field chat macui.Chat
---@field app table macui.App
---@field turn macui.ChatTurn|nil the answer, created by the first append
---@field append fun(delta:string) streams text into the answer; ignored once stopped
---@field done fun(err:string|nil) the answer is complete (err: shown as an error note)
---@field stopped boolean|nil set when the user pressed Stop or closed the window

---@class macui.ChatSpec
---@field title string window title
---@field chat macui.Chat
---@field send fun(text:string, ctx:macui.ChatCtx):(fun()|nil) start answering; may return a cancel function
---@field buttons_extra table[]|nil more { label, callback, enabled } buttons, placed before Back
---@field ask {title:string|nil, quote:string|nil, hint:string|nil, lines:integer|nil, ok_label:string|nil}|nil

-- A chat window with its own buttons: Ask... (the composer; Stop while an answer runs), Copy (the
-- last answer), any buttons_extra, Back. The app supplies send() only; this owns the busy state.
-- Returns the window; win.ask(text) asks without the composer (e.g. a first question).
---@param spec macui.ChatSpec
---@return table window
function M.App:openChat(spec)
    local chat = spec.chat
    local run -- the answer in progress: its ctx
    local first = { label = "Ask..." }
    local function setRun(ctx)
        run = ctx
        first.label = ctx and "Stop" or "Ask..."
        local d = self.dlg
        if d then
            self:refresh("ui", Geom:new { x = u(d.x), y = u(d.y), w = u(d.w), h = u(d.h) })
        end
    end
    local function finish(ctx, err)
        if run ~= ctx then
            return
        end
        setRun(nil)
        chat:setBusy(nil)
        if err then
            chat:add("note", err).error = true
        end
    end
    -- Stop: cancel the engine, then ignore anything it still sends. quiet: the window is closing.
    local function stop(quiet)
        local ctx = run
        if not ctx then
            return
        end
        ctx.stopped = true
        if ctx.cancel then
            pcall(ctx.cancel)
        end
        if quiet then
            run = nil
            return
        end
        finish(ctx, nil)
        chat:add("note", "Stopped.")
    end
    local function ask(text)
        if not text or not text:match("%S") then
            return
        end
        chat:add("user", text)
        local ctx = { chat = chat, app = self }
        function ctx.append(delta)
            if run ~= ctx then
                return
            end
            if not ctx.turn then
                chat:setBusy(nil) -- the answer itself shows progress now; Stop stays until done
                ctx.turn = chat:add("assistant", "")
            end
            chat:append(ctx.turn, delta)
        end
        function ctx.done(err) finish(ctx, err) end
        setRun(ctx)
        chat:setBusy("Thinking...")
        local ok, cancel = pcall(spec.send, text, ctx)
        if not ok then
            logger.warn("macui.openChat: send failed:", cancel)
            finish(ctx, tostring(cancel))
        elseif run == ctx then
            ctx.cancel = type(cancel) == "function" and cancel or nil
        end
    end
    first.default = function() return run == nil end
    first.callback = function()
        if run then
            stop()
        else
            local o = spec.ask or {}
            self:prompt {
                title = o.title or spec.title,
                quote = o.quote,
                hint = o.hint,
                lines = o.lines or 4,
                ok_label = o.ok_label or "Ask",
                ok = function(v) ask(v) end,
            }
        end
    end
    local buttons = {
        first,
        {
            label = "Copy",
            enabled = function() return chat:lastAnswer() ~= nil end,
            callback = function() Device.input.setClipboardText(chat:lastAnswer() or "") end,
        },
    }
    for _, b in ipairs(spec.buttons_extra or {}) do
        buttons[#buttons + 1] = b
    end
    buttons[#buttons + 1] = { label = "Back", callback = function() self:closeWindow() end }
    local win = { title = spec.title, content = chat, buttons = buttons, onClose = function() stop(true) end }
    self:pushWindow(win)
    win.ask = ask -- for apps (and tools/ko) that start a question themselves
    return win
end

-- Paged text (about boxes, short notes). o.text, o.role ("body"). For reading, use M.Doc.
M.Text = {}
M.Text.__index = M.Text

function M.Text:new(o)
    o = setmetatable(o or {}, self)
    o.page = 1
    return o
end

function M.Text:ensure(r)
    local w, h = r.w - u(2 * 20), r.h - u(2 * 16)
    if self.box and self.box_w == w and self.box_h == h then
        return
    end
    if self.box then
        self.box:free()
    end
    self.box = TextBoxWidget:new {
        text = M.fold(self.text or ""),
        face = M.face(self.role or "body"),
        width = w,
        height = h,
        line_height = 0.2,
    }
    self.box_w, self.box_h = w, h
    self.npages = math.max(1, math.ceil(self.box:getAllLineCount() / math.max(1, self.box:getVisLineCount())))
    self.box:scrollToTop()
    for _ = 2, self.page do
        self.box:scrollDown()
    end
end

function M.Text:paint(bb, r)
    self:ensure(r)
    self.box:paintTo(bb, r.x + u(20), r.y + u(16))
end

function M.Text:pages() return self.page, self.npages or 1 end

function M.Text:setPage(n)
    if not self.box then
        self.page = n
        return
    end
    while self.page < n do
        self.box:scrollDown()
        self.page = self.page + 1
    end
    while self.page > n do
        self.box:scrollUp()
        self.page = self.page - 1
    end
end

function M.Text:free()
    if self.box then
        self.box:free()
        self.box = nil
    end
end

return M
