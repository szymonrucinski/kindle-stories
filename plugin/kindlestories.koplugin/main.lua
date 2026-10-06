--[[--
Kindle Stories: small language models running on the Kindle CPU, dressed up as Macintosh System 1.

@module koplugin.KindleStories
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local RenderText = require("ui/rendertext")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local time = require("ui/time")
local _ = require("gettext")
local Screen = Device.screen

local PLUGIN_DIR = debug.getinfo(1, "S").source:match("^@(.*/)")
local parse = dofile(PLUGIN_DIR .. "parse.lua")

local LLM_DIR = "/mnt/us/llm"
local OUT = "/tmp/kindlestories.out"
local PID = "/tmp/kindlestories.pid"
local POLL_S = 0.5
-- If present at startup: open the desk; non-empty content = prompt to start with (used by KUAL).
local AUTOSTART = "/tmp/kindlestories.autostart"

local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local OPENERS = {
    "Once upon a time",
    "One day, a little Kindle",
    "Lily found a shiny key",
    "Tom and his dog went to the park",
    "There was a tiny robot who wanted to read",
    "In a big forest lived a sleepy owl",
}

local AUTHOR = "Szymon Rucinski"

-- cmd is run from LLM_DIR as: <cmd> -n <steps> -i <prompt>. Chat models print only the answer
-- and open in the kit's Chat window instead of the desk.
local MODELS = {
    {
        id = "tinystories",
        name = "TinyStories 15M",
        params = "15M",
        cmd = "./runq-fast stories15M_q80.bin",
        label = "stories15M · int8 NEON",
        steps = 256,
        title = "Kindle Stories",
        presets = OPENERS,
        ask = { title = "Begin a story", input = "Once upon a time, ", ok = "Write" },
        intro = "Tap New Story. A 15-million parameter neural network will write it, token by token, right here on this Kindle's 1 GHz Cortex-A9. No cloud.\n\nBuilt by Szymon Rucinski.",
    },
    {
        id = "smollm",
        name = "SmolLM2 135M Chat",
        params = "135M",
        chat = true,
        cmd = "./smollm/smol smollm/SmolLM2-135M-Instruct-Q4_0.gguf",
        label = "SmolLM2-135M · Q4_0",
        steps = 200,
        title = "SmolLM2 Chat",
        -- Vetted: at 135M, "What is a transformer in AI?" gets the electrical kind.
        presets = {
            "Why is the sky blue?",
            "Write a haiku about e-ink.",
            "What is machine learning?",
            "Give me 3 tips to sleep better.",
            "What is edge AI?",
        },
        ask = { title = "Ask a question" },
        intro = "Tap Ask... to ask a question, or pick one from the Questions menu. SmolLM2, a 135-million parameter chat model, answers token by token on this Kindle's 1 GHz Cortex-A9. No cloud. Each question is answered on its own.",
    },
}

local function findModel(id)
    for _, m in ipairs(MODELS) do
        if m.id == id then
            return m
        end
    end
    return MODELS[1]
end

local show -- (model, prompt): opens the desk, or the Chat window for a chat model

-- Layout in pixels for the 600x800 panel (Kindle 4/5/Touch/PW1-class).
local W = 600
local MENU_H = 34
local WIN = { x = 22, y = 58, w = 556, h = 590 }
local TITLE_H = 34
local STATUS_H = 32
local DLG = { x = 60, y = 670, w = 480, h = 104 }
local BTN_W, BTN_H = 136, 44

local MacDesk = InputContainer:extend {
    covers_fullscreen = true,
}

function MacDesk:init()
    self.dimen = Geom:new { x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.face_menu = Font:getFace("ChicagoFLF.ttf", 17)
    self.face_title = Font:getFace("ChicagoFLF.ttf", 17)
    self.face_story = Font:getFace("ChicagoFLF.ttf", 19)
    self.face_status = Font:getFace("ChicagoFLF.ttf", 14)
    self.model = self.model or MODELS[1]
    self.status = self:idleStatus()
    local pad = 16
    self.story_box = Geom:new {
        x = WIN.x + pad,
        y = WIN.y + TITLE_H + pad,
        w = WIN.w - 2 * pad,
        h = WIN.h - TITLE_H - STATUS_H - 2 * pad,
    }
    self.textbox = TextBoxWidget:new {
        text = _(self.model.intro),
        face = self.face_story,
        width = self.story_box.w,
        height = self.story_box.h,
        line_height = 0.25,
    }
    local by = DLG.y + (DLG.h - BTN_H) / 2
    local gap = (DLG.w - 3 * BTN_W) / 4
    self.buttons = {
        {
            label = _("New Story"),
            default = true,
            g = Geom:new { x = DLG.x + gap, y = by, w = BTN_W, h = BTN_H },
            cb = function()
                local p = self.model.presets
                self:generate(p[math.random(#p)])
            end,
        },
        {
            label = _("Prompt…"),
            g = Geom:new { x = DLG.x + 2 * gap + BTN_W, y = by, w = BTN_W, h = BTN_H },
            cb = function()
                self:askPrompt()
            end,
        },
        {
            label = _("Quit"),
            quit = true,
            g = Geom:new { x = DLG.x + 3 * gap + 2 * BTN_W, y = by, w = BTN_W, h = BTN_H },
            cb = function()
                self:quit()
            end,
        },
    }
    self.close_box = Geom:new { x = WIN.x + 14, y = WIN.y + 8, w = 18, h = 18 }
    self.ges_events.Tap = { GestureRange:new { ges = "tap", range = self.dimen } }
end

-- Classic 50% gray desktop, rendered once: two dithered rows, then blitted down the screen.
function MacDesk:desktop()
    if self.desk_bb then
        return self.desk_bb
    end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local bb = Blitbuffer.new(sw, sh, Blitbuffer.TYPE_BB8)
    bb:fill(WHITE)
    for x = 0, sw - 1, 2 do
        bb:setPixel(x, 0, BLACK)
        bb:setPixel(x + 1, 1, BLACK)
    end
    for y = 2, sh - 1, 2 do
        bb:blitFrom(bb, 0, y, 0, 0, sw, 2)
    end
    self.desk_bb = bb
    return bb
end

function MacDesk:text(bb, x, baseline, face, str, center_w)
    if center_w then
        local tw = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, str, true).x
        x = x + math.floor((center_w - tw) / 2)
    end
    RenderText:renderUtf8Text(bb, x, baseline, face, str, true, false, BLACK)
end

function MacDesk:paintMenuBar(bb)
    local sw, mh = W, MENU_H
    bb:paintRect(0, 0, sw, mh, WHITE)
    bb:paintRect(0, mh - 2, sw, 2, BLACK)
    -- Rounded screen corners, as on the original 9" CRT.
    for _, c in ipairs { { 0, 0 }, { sw - 8, 0 } } do
        bb:paintRect(c[1], c[2], 8, 8, BLACK)
    end
    bb:paintRoundedRect(0, 0, sw, 16, WHITE, 8)
    bb:paintRect(0, 8, sw, mh - 10, WHITE)
    local base = math.floor(mh * 0.72)
    local x = 20
    for _, m in ipairs { "File", "Edit", "View", "Story", "Special" } do
        local mw = RenderText:sizeUtf8Text(0, sw, self.face_menu, m, true).x
        self:text(bb, x, base, self.face_menu, m)
        if m == "Story" then
            self.story_menu = Geom:new { x = x - 10, y = 0, w = mw + 20, h = mh }
        end
        if m == "Special" then
            self.special_menu = Geom:new { x = x - 10, y = 0, w = mw + 20, h = mh }
        end
        x = x + mw + 30
    end
    local aw = RenderText:sizeUtf8Text(0, sw, self.face_status, AUTHOR, true).x
    self:text(bb, sw - aw - 18, base, self.face_status, AUTHOR)
end

-- Window with drop shadow, striped title bar and close box.
function MacDesk:paintWindow(bb)
    local x, y, w, h = WIN.x, WIN.y, WIN.w, WIN.h
    bb:paintRect(x + 4, y + 4, w, h, BLACK) -- shadow
    bb:paintRect(x, y, w, h, WHITE)
    bb:paintBorder(x, y, w, h, 2, BLACK)
    local th = TITLE_H
    for ly = y + 7, y + th - 8, 4 do
        bb:paintRect(x + 4, ly, w - 8, 2, BLACK)
    end
    bb:paintRect(x, y + th - 2, w, 2, BLACK)
    local cb = self.close_box
    bb:paintRect(cb.x - 4, cb.y - 2, cb.w + 8, cb.h + 4, WHITE)
    bb:paintBorder(cb.x, cb.y, cb.w, cb.h, 2, BLACK)
    local title = self.model.title .. (self.running and " — thinking…" or "")
    local tw = RenderText:sizeUtf8Text(0, w, self.face_title, title, true).x
    local tx = x + math.floor((w - tw) / 2)
    bb:paintRect(tx - 10, y + 4, tw + 20, th - 8, WHITE)
    self:text(bb, tx, y + math.floor(th * 0.7), self.face_title, title)
    -- Status strip, like the Finder's "items / in disk" bar.
    local sy = y + h - STATUS_H
    bb:paintRect(x, sy, w, 2, BLACK)
    self:text(bb, x + 12, sy + math.floor(STATUS_H * 0.7), self.face_status, self.status)
    self.textbox:paintTo(bb, self.story_box.x, self.story_box.y)
end

-- Modal-dialog style box holding the buttons (double border, as in System 1 alerts).
function MacDesk:paintDialog(bb)
    local x, y, w, h = DLG.x, DLG.y, DLG.w, DLG.h
    bb:paintRect(x, y, w, h, WHITE)
    bb:paintBorder(x, y, w, h, 2, BLACK)
    bb:paintBorder(x + 5, y + 5, w - 10, h - 10, 3, BLACK)
    for _, b in ipairs(self.buttons) do
        local g = b.g
        if b.default then
            bb:paintBorder(g.x - 5, g.y - 5, g.w + 10, g.h + 10, 3, BLACK, 16)
        end
        bb:paintBorder(g.x, g.y, g.w, g.h, 2, BLACK, 10)
        local dim = self.running and not b.quit
        self:text(bb, g.x, g.y + math.floor(g.h * 0.66), self.face_menu, dim and "···" or b.label, g.w)
    end
end

function MacDesk:paintTo(bb, x, y)
    bb:blitFrom(self:desktop(), x, y, 0, 0, self.dimen.w, self.dimen.h)
    self:paintMenuBar(bb)
    self:paintWindow(bb)
    self:paintDialog(bb)
end

function MacDesk:refreshStory(mode)
    local x, y, w, h = WIN.x, WIN.y, WIN.w, WIN.h
    UIManager:setDirty(self, mode or "fast", Geom:new { x = x, y = y, w = w, h = h })
end

function MacDesk:setStory(text)
    self.textbox:setText(text)
    self.textbox:scrollToBottom()
end

function MacDesk:onTap(_, ges)
    local p = ges.pos
    if p:intersectWith(self.close_box) then
        self:quit()
        return true
    end
    if self.story_menu and p:intersectWith(self.story_menu) then
        self:showStoryMenu()
        return true
    end
    if self.special_menu and p:intersectWith(self.special_menu) then
        self:showModelMenu()
        return true
    end
    for _, b in ipairs(self.buttons) do
        if p:intersectWith(b.g) then
            b.cb()
            return true
        end
    end
    return true
end

function MacDesk:showStoryMenu()
    local rows = {}
    for _, o in ipairs(self.model.presets) do
        table.insert(rows, {
            {
                text = o .. "…",
                callback = function()
                    UIManager:close(self.menu_dialog)
                    self:generate(o)
                end,
            },
        })
    end
    self.menu_dialog = ButtonDialog:new { title = _("Story"), buttons = rows }
    UIManager:show(self.menu_dialog)
end

function MacDesk:idleStatus()
    return self.model.label .. " · " .. self.model.params .. " params · on this Kindle"
end

function MacDesk:showModelMenu()
    local rows = {}
    for _k, m in ipairs(MODELS) do -- not `_`: that would shadow gettext inside the callback
        table.insert(rows, {
            {
                text = m.name .. (m == self.model and "  ✓" or ""),
                callback = function()
                    UIManager:close(self.menu_dialog)
                    self:stop()
                    G_reader_settings:saveSetting("kindlestories_model", m.id)
                    G_reader_settings:flush()
                    if m.chat then
                        self:quit()
                        show(m)
                        return
                    end
                    self.model = m
                    self:setStory(_(m.intro)) -- also resets the scroll left by a long answer
                    self.status = self:idleStatus()
                    UIManager:setDirty(self, "ui")
                end,
            },
        })
    end
    self.menu_dialog = ButtonDialog:new { title = _("Model"), buttons = rows }
    UIManager:show(self.menu_dialog)
end

function MacDesk:askPrompt()
    if self.running then
        return
    end
    local dlg
    dlg = InputDialog:new {
        title = _(self.model.ask.title),
        input = self.model.ask.input,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dlg)
                    end,
                },
                {
                    text = _(self.model.ask.ok),
                    is_enter_default = true,
                    callback = function()
                        local t = dlg:getInputText()
                        UIManager:close(dlg)
                        if t:match("%S") then
                            self:generate(t)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

local function shq(s)
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

local function pidAlive(pid)
    return pid and lfs.attributes("/proc/" .. pid) ~= nil
end

local function readPid()
    local f = io.open(PID)
    if not f then
        return nil
    end
    local pid = f:read("*n")
    f:close()
    return pid
end

-- One model process at a time (they share OUT and PID): its stop function, while it runs.
local stopModel = function() end

-- Runs model m on prompt in the background and polls its output every POLL_S:
-- on_update(text, secs, changed) while it runs, then once on_end(text, tps, secs) (tps nil: it
-- died first). text only grows (parse.settled). Returns a stop function, or nil and an error.
local function runModel(m, prompt, on_update, on_end)
    stopModel()
    if not lfs.attributes(LLM_DIR .. "/" .. m.cmd:match("^%./(%S+)")) then
        return nil, _("Model binary not found in ") .. LLM_DIR
    end
    os.remove(OUT)
    os.execute(
        string.format(
            "cd %s && (%s -n %d -i %s > %s 2>&1 & echo $! > %s)",
            LLM_DIR,
            m.cmd,
            m.steps,
            shq(prompt),
            OUT,
            PID
        )
    )
    local t0, last_len, poll = time.now(), -1, nil
    local function stop()
        UIManager:unschedule(poll)
        stopModel = function() end
        local pid = readPid()
        if pidAlive(pid) then
            os.execute("kill " .. pid)
        end
    end
    poll = function()
        local f = io.open(OUT)
        local out = f and f:read("*a") or ""
        if f then
            f:close()
        end
        local text, tps = parse.settled(out)
        local secs = time.to_s(time.since(t0))
        if tps or (not pidAlive(readPid()) and secs > 3) then
            stopModel = function() end
            on_end(text, tps, secs)
            return
        end
        on_update(text, secs, #out ~= last_len)
        last_len = #out
        UIManager:scheduleIn(POLL_S, poll)
    end
    UIManager:scheduleIn(POLL_S, poll)
    stopModel = stop
    return stop
end

function MacDesk:generate(prompt)
    if self.running then
        return
    end
    local m = self.model
    local label = m.label
    local stop, err = runModel(m, prompt, function(story, secs, changed)
        if changed then
            self:setStory(story .. " █")
        end
        self.status = string.format("%s · %d chars · %.0fs", label, #story, secs)
        self:refreshStory("fast")
    end, function(story, tps, secs)
        self.running = false
        if tps then
            self:setStory(story)
            self.status = string.format("%s · %.1f tok/s · %.0fs · done", label, tps, secs)
        else
            self:setStory(story ~= "" and story or _("(the model stopped before writing anything)"))
            self.status = label .. " · stopped"
        end
        UIManager:setDirty(self, "ui")
    end)
    if not stop then
        UIManager:show(InfoMessage:new { text = err })
        return
    end
    self.running = true
    -- llama2.c echoes the prompt, so the story starts with it.
    self:setStory(prompt .. " █")
    self.status = label .. " · starting…"
    UIManager:setDirty(self, "ui")
end

function MacDesk:stop()
    if self.running then
        stopModel()
    end
    self.running = false
end

function MacDesk:quit()
    UIManager:close(self, "full")
end

function MacDesk:onCloseWidget()
    self:stop()
    self.textbox:free()
    if self.desk_bb then
        self.desk_bb:free()
        self.desk_bb = nil
    end
end

function MacDesk:onShow()
    UIManager:setDirty(self, "full")
end

local macui -- the kit, loaded with the first Chat window: the desk does not use it

local function loadKit()
    if not macui then
        -- Chat requires "markdown": this folder's copy, unless another plugin already provides one.
        package.preload.markdown = package.preload.markdown
            or function()
                return dofile(PLUGIN_DIR .. "markdown.lua")
            end
        macui = dofile(PLUGIN_DIR .. "macui.lua")
        if not macui.FONT.fallback then
            -- kindle-ui installs a Polish Chicago; deploy.sh installs the plain one.
            macui.FONT = setmetatable({ fallback = "ChicagoFLF.ttf" }, { __index = macui.FONT })
        end
    end
    return macui
end

-- A chat model in the kit's Chat window (the same one as kindle-ui's Mac Assistant). Each
-- question is answered on its own (the model has a 512-token context); the window keeps the turns.
local function openChat(m, prompt)
    local kit = loadKit()
    local idle = m.label .. " · " .. m.params .. " params · on this Kindle"
    local status, running = idle, false
    local chat = kit.Chat:new {
        empty = m.intro,
        status = function()
            return status
        end,
    }
    local app, win
    local function setStatus(s)
        status = s
        chat:changed() -- repaints the status strip with the conversation
    end
    local function send(text, ctx)
        local shown = ""
        local stop, err = runModel(m, text, function(out, secs, changed)
            if changed and #out > #shown then
                ctx.append(out:sub(#shown + 1))
                shown = out
            end
            status = string.format("%s · %d chars · %.0fs", m.label, #shown, secs)
        end, function(out, tps, secs)
            running = false
            if #out > #shown then
                ctx.append(out:sub(#shown + 1))
                shown = out
            end
            if tps then
                setStatus(string.format("%s · %.1f tok/s · %.0fs · done", m.label, tps, secs))
                ctx.done()
            else
                setStatus(m.label .. " · stopped")
                ctx.done(
                    shown:match("%S") and "the model stopped early"
                        or "the model stopped before writing anything"
                )
            end
        end)
        if not stop then
            error(err, 0) -- openChat shows it as an error note
        end
        running = true
        setStatus(m.label .. " · starting…")
        return function()
            running = false
            stop()
            setStatus(idle)
        end
    end
    local function switchTo(other)
        G_reader_settings:saveSetting("kindlestories_model", other.id)
        G_reader_settings:flush()
        app:quit()
        show(other)
    end
    app = kit.App:new {
        dialog = true,
        onQuit = function()
            stopModel()
        end,
        menus = {
            {
                title = "File",
                items = function()
                    return {
                        {
                            text = "Quit",
                            callback = function()
                                app:quit()
                            end,
                        },
                    }
                end,
            },
            {
                title = "Questions",
                items = function()
                    local items = {}
                    for _k, q in ipairs(m.presets) do
                        items[#items + 1] = {
                            text = q,
                            enabled = not running,
                            callback = function()
                                win.ask(q)
                            end,
                        }
                    end
                    return items
                end,
            },
            {
                title = "Special",
                items = function()
                    local items = {}
                    for _k, other in ipairs(MODELS) do
                        items[#items + 1] = {
                            text = other.name,
                            checked = other == m,
                            callback = function()
                                if other ~= m then
                                    switchTo(other)
                                end
                            end,
                        }
                    end
                    return items
                end,
            },
        },
    }
    UIManager:show(app)
    win = app:openChat {
        title = m.title,
        chat = chat,
        send = send,
        ask = { title = m.ask.title, hint = m.presets[1] },
    }
    if prompt and prompt ~= "" then
        win.ask(prompt)
    end
    return app, win
end

function show(m, prompt)
    if m.chat then
        return openChat(m, prompt)
    end
    local desk = MacDesk:new { model = m }
    UIManager:show(desk)
    if prompt and prompt ~= "" then
        desk:generate(prompt)
    end
    return desk
end

local KindleStories = WidgetContainer:extend {
    name = "kindlestories",
    is_doc_only = false,
}

function KindleStories:init()
    Dispatcher:registerAction(
        "kindlestories_show",
        { category = "none", event = "ShowKindleStories", title = _("Kindle Stories"), general = true }
    )
    self.ui.menu:registerToMainMenu(self)
    local f = io.open(AUTOSTART)
    if f then
        local prompt = f:read("*a"):gsub("%s+$", "")
        f:close()
        os.remove(AUTOSTART)
        UIManager:nextTick(function()
            show(findModel(G_reader_settings:readSetting("kindlestories_model")), prompt)
        end)
    end
end

function KindleStories:addToMainMenu(menu_items)
    menu_items.kindlestories = {
        text = _("Kindle Stories"),
        sorting_hint = "more_tools",
        callback = function()
            self:onShowKindleStories()
        end,
    }
end

function KindleStories:onShowKindleStories()
    show(findModel(G_reader_settings:readSetting("kindlestories_model")))
    return true
end

return KindleStories
