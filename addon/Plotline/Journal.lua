-- SPDX-License-Identifier: GPL-3.0-or-later
-- Plotline: the Journal window (docs/DESIGN.md). Tabs: Chains (next), Timeline, Compendium.
--   Compendium: people, places, factions and items you've come across, built only from what this
--   character did (Record.lua): when you met them, which quests, which chains, the text you saw.
--   Links: names you know become links in Plotline's windows and in the game's quest text; an NPC
--   you've met gets a line in their tooltip.

local _, ns = ...
local C, R = ns.chains, ns.record
local J = {}
ns.journal = J

local KINDS = {
    { key = "npc", label = "People" },
    { key = "place", label = "Places" },
    { key = "faction", label = "Factions" },
    { key = "item", label = "Items" },
}
local KIND_LABEL = { npc = "Person", place = "Place", faction = "Faction", item = "Item" }
local LINK_INK = "ff8a3a12"    -- links on parchment: one rust-brown ink for every kind
local LINK_GOLD = "ffffd100"   -- links on dark backgrounds
local LINK_HOVER = "ffd2571c"  -- a link under the mouse: brighter than the ink
local ROW_H = 24

local function font(fs, ...)
    for i = 1, select("#", ...) do
        local obj = _G[select(i, ...)]
        if obj then fs:SetFontObject(obj) return end
    end
end

local function newFrame(kind, parent, template, fallback)
    local ok, frame = pcall(CreateFrame, kind, nil, parent, template)
    if ok then return frame end
    return CreateFrame(kind, nil, parent, fallback)
end

local function date(t) return t and _G.date("%d %b %Y", t) or "?" end

-- ------------------------------------------------------------------ links
-- |Hplotline:<kind>:<key>|h<name>|h  and  |Hquest:<id>|h<title>|h
function J.Link(kind, key, name, dark)
    local color = dark and LINK_GOLD or LINK_INK
    return ("|c%s|Hplotline:%s:%s|h%s|h|r"):format(color, kind, tostring(key), name)
end

function J.QuestLink(q, dark)
    local t = C.Title(q) or ("Quest " .. q)
    return ("|c%s|Hquest:%d|h%s|h|r"):format(dark and LINK_GOLD or LINK_INK, q, t)
end

-- Names this character knows, longest first, for linking inside text.
local names, namesDirty = {}, true
function J.Dirty() namesDirty = true end
local function knownNames()
    if not namesDirty then return names end
    wipe(names)
    for _, k in ipairs(KINDS) do
        for key, e in R.Each(k.key) do
            if e.name and #e.name >= 4 then names[#names + 1] = { name = e.name, kind = k.key, key = key } end
        end
    end
    table.sort(names, function(a, b) return #a.name > #b.name end)
    namesDirty = false
    return names
end

local function escape(s) return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")) end

-- Turn known names in `text` into links. Longest names first; a name already inside a link (or
-- part of a longer name) isn't linked again. `skip`: a key not to link (the entry being shown).
function J.Linkify(text, dark, skip)
    if not text or text == "" then return text end
    local slots = {}
    for _, n in ipairs(knownNames()) do
        if n.key ~= skip and text:find(n.name, 1, true) then
            local pat = "%f[%w]" .. escape(n.name) .. "%f[%W]"
            text = text:gsub(pat, function(m)
                slots[#slots + 1] = J.Link(n.kind, n.key, m, dark)
                return "\001" .. #slots .. "\002"
            end)
        end
    end
    return (text:gsub("\001(%d+)\002", function(i) return slots[tonumber(i)] end))
end

local unhighlight   -- defined with the hover colour code below

local function onLink(_, link, text, button)
    unhighlight()
    if link == "plotline:back:0" then
        J.Back()
        return
    end
    local chain = link:match("^plotline:chain:(.+)$")
    if chain then
        J.OpenChain(chain)
        return
    end
    local kind, key = link:match("^plotline:(%a+):(.+)$")
    if kind then
        J.Open(kind, (kind == "place" or kind == "item") and tonumber(key) or key)   -- subzones: by name
        return
    end
    if link:match("^item:") then
        if HandleModifiedItemClick then HandleModifiedItemClick(text) end
        return
    end
    local q = tonumber(link:match("^quest:(%d+)"))
    if q then
        if IsModifiedClick and IsModifiedClick("CHATLINK") then ns.hints.LinkQuest(q) else J.OpenQuest(q) end
    end
end

-- Hover colour: redraw the line with the hovered link in LINK_HOVER (its inner colours removed;
-- icons kept), and put the line back when the mouse leaves.
local hovered   -- { fs = FontString, text = original text, shown = text while hovered }
local function highlightLink(fs, link)
    if not fs or not fs.GetText then return end
    local text = fs:GetText()
    if not text then return end
    local open = "|H" .. link .. "|h"
    local s1, e1 = text:find(open, 1, true)
    if not s1 then return end
    local s2, e2 = text:find("|h", e1 + 1, true)
    if not s2 then return end
    local inner = text:sub(e1 + 1, s2 - 1):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local before, after = text:sub(1, s1 - 1), text:sub(e2 + 1)
    before = before:gsub("|c%x%x%x%x%x%x%x%x$", "")   -- the link's own colour
    after = after:gsub("^|r", "")
    local shown = before .. "|c" .. LINK_HOVER .. open .. inner .. "|h|r" .. after
    fs:SetText(shown)
    hovered = { fs = fs, text = text, shown = shown }
end

function unhighlight()
    if hovered and hovered.fs:GetText() == hovered.shown then hovered.fs:SetText(hovered.text) end
    hovered = nil
end

local function onLinkEnter(self, link, text, region)
    unhighlight()
    highlightLink(region, link)
    if link:match("^item:") then
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
        return
    end
    local kind, key = link:match("^plotline:(%a+):(.+)$")
    if not kind or kind == "back" or kind == "chain" then return end
    if kind == "place" or kind == "item" then key = tonumber(key) or key end   -- subzones: by name
    local e = R.Entry(kind, key)
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:AddLine(e.name or "?")
    GameTooltip:AddLine(J.Summary(kind, e), 1, 1, 1, true)
    GameTooltip:AddLine("Click to open in the Compendium", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function onLinkLeave()
    unhighlight()
    GameTooltip:Hide()
end

function J.EnableLinks(frame)
    if not frame or frame.plotlineLinks then return end
    frame.plotlineLinks = true
    frame:EnableMouse(true)   -- hyperlinks only report hovers and clicks on a frame that takes the mouse
    if frame.SetHyperlinksEnabled then frame:SetHyperlinksEnabled(true) end
    frame:HookScript("OnHyperlinkClick", onLink)
    frame:HookScript("OnHyperlinkEnter", onLinkEnter)
    frame:HookScript("OnHyperlinkLeave", onLinkLeave)
end

-- ------------------------------------------------------------------ summaries
local function countQuests(e)
    local n = 0
    for _ in pairs(e.q or {}) do n = n + 1 end
    return n
end

function J.Summary(kind, e)
    local n = countQuests(e)
    local quests = n == 1 and "1 quest" or (n .. " quests")
    if kind == "npc" then
        return ("Met %s, last seen %s. %s."):format(date(e.first), date(e.last), quests)
    elseif kind == "place" then
        return ("First visited %s, last %s. %s."):format(date(e.first), date(e.last), quests)
    elseif kind == "faction" then
        return ("Standing gained since %s. %s."):format(date(e.first), quests)
    end
    return ("First seen %s. %s."):format(date(e.first), quests)
end

local ROLE = { g = "gave you", e = "took", a = "accepted here", d = "completed here", n = "needed", r = "reward" }

-- ------------------------------------------------------------------ window
local win
local state = { tab = "chains", kind = "npc", key = nil, offset = 0, search = "", open = {} }

-- A slim vertical scroll bar: dark track and the game's scroll knob. Hidden when nothing scrolls.
local function scrollBar(parent, onChange)
    local bar = CreateFrame("Slider", nil, parent)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(10)
    bar.track = bar:CreateTexture(nil, "BACKGROUND")
    bar.track:SetPoint("TOPLEFT", 3, 0)
    bar.track:SetPoint("BOTTOMRIGHT", -3, 0)
    bar.track:SetColorTexture(0.55, 0.45, 0.3, 0.35)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.85, 0.68, 0.32, 0.95)
    thumb:SetSize(6, 36)
    bar:SetThumbTexture(thumb)
    bar:SetScript("OnEnter", function() thumb:SetColorTexture(1, 0.85, 0.45, 1) end)
    bar:SetScript("OnLeave", function() thumb:SetColorTexture(0.85, 0.68, 0.32, 0.95) end)
    bar:SetValueStep(1)
    if bar.SetObeyStepOnDrag then bar:SetObeyStepOnDrag(true) end
    bar:SetScript("OnValueChanged", function(self, value)
        if not self.updating then onChange(value) end
    end)
    function bar:SetRange(max, value)
        self.updating = true
        self:SetMinMaxValues(0, math.max(0, max))
        self:SetValue(value or 0)
        self.updating = false
        self:SetShown(max > 0)
    end
    bar:Hide()
    return bar
end

local function scrollArea(parent)
    local sf = CreateFrame("ScrollFrame", nil, parent)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(1, 1)
    sf:SetScrollChild(child)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, child:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * 40)))
        if self.bar then self.bar:SetRange(max, self:GetVerticalScroll()) end
    end)
    sf.child = child
    return sf
end

local function parchment(tex)
    local details = QuestMapFrame and QuestMapFrame.QuestsFrame and QuestMapFrame.QuestsFrame.DetailsFrame
    local src = details and details.Bg
    local atlas = src and src.GetAtlas and src:GetAtlas()
    if atlas then tex:SetAtlas(atlas) return end
    local file = src and src.GetTexture and src:GetTexture()
    if file then tex:SetTexture(file) tex:SetTexCoord(src:GetTexCoord()) return end
    tex:SetColorTexture(0.87, 0.78, 0.6, 1)
end

local function makeWindow()
    win = newFrame("Frame", UIParent, "ButtonFrameTemplate", "BackdropTemplate")
    win:SetSize(760, 520)
    win:SetPoint("CENTER")
    win:SetFrameStrata("HIGH")
    win:SetMovable(true)
    win:EnableMouse(true)
    win:RegisterForDrag("LeftButton")
    win:SetScript("OnDragStart", win.StartMoving)
    win:SetScript("OnDragStop", win.StopMovingOrSizing)
    win:SetClampedToScreen(true)
    win:Hide()
    _G.PlotlineJournalFrame = win
    tinsert(UISpecialFrames, "PlotlineJournalFrame")   -- Escape closes it
    if ButtonFrameTemplate_HidePortrait and (win.PortraitContainer or win.portrait) then
        ButtonFrameTemplate_HidePortrait(win)
    end
    if ButtonFrameTemplate_HideButtonBar and win.Inset then ButtonFrameTemplate_HideButtonBar(win) end
    if win.Inset then win.Inset:Hide() end
    if not win.Inset and win.SetBackdrop then
        win:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 24,
            insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    end
    local title = win.TitleText or (win.TitleContainer and win.TitleContainer.TitleText)
    if title then title:SetText("Plotline Journal") end

    -- left: search + list
    win.search = newFrame("EditBox", win, "SearchBoxTemplate", "InputBoxTemplate")
    win.search:SetSize(226, 20)
    win.search:SetPoint("TOPLEFT", 16, -30)
    win.search:SetAutoFocus(false)
    win.search:SetScript("OnTextChanged", function(self)
        if SearchBoxTemplate_OnTextChanged then pcall(SearchBoxTemplate_OnTextChanged, self) end
        state.search = (self:GetText() or ""):lower()
        state.offset = 0
        J.Refresh()
    end)
    win.list = CreateFrame("Frame", nil, win)
    win.list:SetPoint("TOPLEFT", 10, -56)
    win.list:SetPoint("BOTTOMLEFT", 10, 34)
    win.list:SetWidth(240)
    win.list:EnableMouseWheel(true)
    win.list:SetScript("OnMouseWheel", function(_, delta)
        state.offset = math.max(0, state.offset - delta * 3)
        if win.items then J.FillList(win.items) end
    end)
    win.listBar = scrollBar(win.list, function(value)
        state.offset = math.floor(value + 0.5)
        if win.items then J.FillList(win.items) end
    end)
    win.listBar:SetPoint("TOPRIGHT", win.list, "TOPRIGHT", 0, 0)
    win.listBar:SetPoint("BOTTOMRIGHT", win.list, "BOTTOMRIGHT", 0, 0)
    win.rows = {}

    -- right: parchment page with the entry
    local page = CreateFrame("Frame", nil, win)
    page:SetPoint("TOPLEFT", win.list, "TOPRIGHT", 8, 26)
    page:SetPoint("BOTTOMRIGHT", -10, 34)
    page.bg = page:CreateTexture(nil, "BACKGROUND")
    page.bg:SetAllPoints()
    parchment(page.bg)
    win.page = page
    win.scroll = scrollArea(page)
    win.scroll:SetPoint("TOPLEFT", 14, -12)
    win.scroll:SetPoint("BOTTOMRIGHT", -22, 12)
    win.scroll.bar = scrollBar(page, function(value) win.scroll:SetVerticalScroll(value) end)
    win.scroll.bar:SetPoint("TOPRIGHT", page, "TOPRIGHT", -6, -12)
    win.scroll.bar:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -6, 12)
    local body = win.scroll.child
    body:SetWidth(452)
    J.EnableLinks(body)
    win.body = body
    win.lines = {}

    -- tabs
    win.tabs = {}
    local tabs = { { "chains", "Chains" }, { "timeline", "Timeline" }, { "compendium", "Compendium" } }
    for i, t in ipairs(tabs) do
        local b = newFrame("Button", win, "PanelTabButtonTemplate", "UIPanelButtonTemplate")
        if not b.Text and b.SetSize then b:SetSize(100, 22) end
        b:SetText(t[2])
        b:SetID(i)
        if i == 1 then b:SetPoint("TOPLEFT", win, "BOTTOMLEFT", 12, 2)
        else b:SetPoint("LEFT", win.tabs[i - 1], "RIGHT", 3, 0) end
        b:SetScript("OnClick", function()
            state.tab = t[1]
            state.offset, state.quest, state.back = 0, nil, nil
            J.Refresh()
        end)
        if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, b, 0, 110) end
        win.tabs[i] = b
        b.key = t[1]
    end
    win.Tabs = win.tabs
    if PanelTemplates_SetNumTabs then pcall(PanelTemplates_SetNumTabs, win, #tabs) end
end

-- ------------------------------------------------------------------ list (left)
local function listRow(i)
    local r = win.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, win.list)
    r:SetHeight(ROW_H)
    r:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    r:SetPoint("RIGHT", win.list, "RIGHT", -14, 0)   -- room for the scroll bar
    r.text = r:CreateFontString(nil, "OVERLAY")
    font(r.text, "GameFontHighlight")
    r.right = r:CreateFontString(nil, "OVERLAY")
    font(r.right, "GameFontHighlight")
    r.right:SetPoint("RIGHT", -4, 0)
    r.text:SetPoint("LEFT", 4, 0)
    r.text:SetPoint("RIGHT", r.right, "LEFT", -4, 0)
    r.text:SetJustifyH("LEFT")
    r.text:SetWordWrap(false)
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints()
    r.sel:SetColorTexture(0.2, 0.35, 0.6, 0.6)
    r.band = r:CreateTexture(nil, "BACKGROUND", nil, -1)
    r.band:SetAllPoints()
    r.band:SetColorTexture(0.35, 0.27, 0.15, 0.55)
    r:SetScript("OnClick", function(self)
        if self.zone then
            state.open[self.zone] = not self.open
            state.quest = nil
        elseif self.chain then
            state.chain, state.quest, state.back = self.chain, nil, nil
        elseif self.header then
            state.kind = self.header
            state.key, state.quest = nil, nil
        elseif self.key then
            state.kind, state.key, state.quest = self.kind, self.key, nil
        elseif self.q then
            state.quest, state.back = self.q, nil
        end
        J.Refresh()
    end)
    win.rows[i] = r
    return r
end

local function compendiumItems()
    local items = {}
    for _, k in ipairs(KINDS) do
        local entries = {}
        for key, e in R.Each(k.key) do
            if state.search == "" or (e.name or ""):lower():find(state.search, 1, true) then
                entries[#entries + 1] = { key = key, e = e }
            end
        end
        table.sort(entries, function(a, b) return (a.e.last or 0) > (b.e.last or 0) end)
        local open = state.kind == k.key or state.search ~= ""
        items[#items + 1] = { header = k.key, text = ("|TInterface\\Buttons\\UI-%sButton-Up:16:16|t |cffffd100%s|r"):format(open and "Minus" or "Plus", k.label),
            right = ("|cff8a8a8a%d|r"):format(#entries) }
        if state.kind == k.key or state.search ~= "" then
            for _, it in ipairs(entries) do
                items[#items + 1] = { kind = k.key, key = it.key, text = "   " .. (it.e.name or "?") }
            end
        end
    end
    return items
end

-- Started and finished chains, by zone (yours first). Unstarted chains stay hidden.
local function chainItems()
    C.LogQuests()
    local here = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    local hereInfo = here and C_Map.GetMapInfo(here)
    local hereName = hereInfo and hereInfo.name
    local zones, order = {}, {}
    win.progress = {}
    for id in pairs(ns.data.chains) do
        local v, done, complete = C.Progress(id)
        if v then
            local name = C.Name(id) or "..."
            if state.search == "" or name:lower():find(state.search, 1, true) then
                local zone = C.ZoneName(id) or "Elsewhere"
                if not zones[zone] then zones[zone] = {} order[#order + 1] = zone end
                table.insert(zones[zone], { id = id, name = name, done = done, n = #v.steps, complete = complete })
                win.progress[id] = { v = v, done = done, complete = complete }
            end
        end
    end
    table.sort(order, function(a, b)
        if a == hereName or b == hereName then return a == hereName and b ~= hereName end
        return a < b
    end)
    local items, started, finished = {}, 0, 0
    for _, zone in ipairs(order) do
        local list = zones[zone]
        table.sort(list, function(a, b) return a.name < b.name end)
        local open = state.open[zone]
        if open == nil then open = zone == hereName or state.search ~= "" end
        local doneHere = 0
        for _, c in ipairs(list) do if c.complete then doneHere = doneHere + 1 end end
        items[#items + 1] = { zone = zone, open = open,
            text = ("|TInterface\\Buttons\\UI-%sButton-Up:16:16|t |cffffd100%s|r"):format(open and "Minus" or "Plus", zone),
            right = ("|cff8a8a8a%d/%d|r"):format(doneHere, #list) }
        for _, c in ipairs(list) do
            started = started + 1
            if c.complete then finished = finished + 1 end
            if open then
                items[#items + 1] = { chain = c.id, text = "   " .. C.KindIcon(ns.data.chains[c.id].k, 22) .. c.name,
                    right = c.complete and "|cff1eff00done|r" or ("|cffc0c0c0%d/%d|r"):format(c.done, c.n) }
            end
        end
    end
    win.chainStats = { started = started, finished = finished }
    return items
end

local function timelineItems()
    local items, log = {}, ns.char.log
    for i = #log, 1, -1 do
        local ev = log[i]
        local t = C.Title(ev.q) or ("Quest " .. ev.q)
        if state.search == "" or t:lower():find(state.search, 1, true) then
            items[#items + 1] = { q = ev.q, text = ("|cff8a8a8a%s|r %s %s"):format(_G.date("%d %b", ev.t),
                ev.e == "done" and "|cff1eff00+|r" or "|cffffd100>|r", t) }
        end
    end
    return items
end

local function fillList(items)
    win.items = items
    local visible = math.floor(win.list:GetHeight() / ROW_H)
    state.offset = math.min(state.offset, math.max(0, #items - visible))
    win.listBar:SetRange(#items - visible, state.offset)
    for i = 1, visible do
        local it = items[i + state.offset]
        local r = listRow(i)
        if it then
            r.header, r.kind, r.key, r.q, r.zone, r.chain, r.open = it.header, it.kind, it.key, it.q, it.zone, it.chain, it.open
            r.text:SetText(it.text)
            r.right:SetText(it.right or "")
            r.band:SetShown(it.zone ~= nil or it.header ~= nil)
            r.sel:SetShown((it.key ~= nil and it.key == state.key and it.kind == state.kind)
                or (it.q ~= nil and it.q == state.quest)
                or (it.chain ~= nil and it.chain == state.chain))
            r:Show()
        else
            r:Hide()
        end
    end
    for i = visible + 1, #win.rows do win.rows[i]:Hide() end
end
J.FillList = fillList

-- ------------------------------------------------------------------ page (right)
local function addLine(text, fontName, gap, color)
    local i = #win.used + 1
    local fs = win.lines[i]
    if not fs then
        fs = win.body:CreateFontString(nil, "OVERLAY")
        fs:SetJustifyH("LEFT")
        fs:SetWidth(win.body:GetWidth())
        fs:SetShadowOffset(0, 0)
        win.lines[i] = fs
    end
    font(fs, fontName or "QuestFont", "GameFontBlack", "GameFontHighlight")
    fs:SetTextColor(unpack(color or { 0.18, 0.12, 0.06 }))
    fs:ClearAllPoints()
    fs:SetPoint("TOPLEFT", win.body, "TOPLEFT", 0, -win.y - (gap or 0))
    fs:SetText(text)
    fs:Show()
    win.used[i] = fs
    win.y = win.y + (gap or 0) + fs:GetStringHeight() + 2
end

local function beginPage()
    win.used, win.y = {}, 0
    for _, fs in ipairs(win.lines) do fs:Hide() end
end

local function endPage()
    win.body:SetHeight(math.max(1, win.y))
    win.scroll:SetVerticalScroll(0)
    win.scroll.bar:SetRange(win.y - win.scroll:GetHeight(), 0)
end

local function questRow(q, role)
    local info = C.of[q]
    local chain = info and C.DisplayName(info.id, 20)
    local roles = {}
    for c in (role or ""):gmatch(".") do roles[#roles + 1] = ROLE[c] end
    local parts = { J.QuestLink(q) }
    if #roles > 0 then parts[#parts + 1] = "|cff5e4c36(" .. table.concat(roles, ", ") .. ")|r" end
    if chain then parts[#parts + 1] = "|cff5e4c36- " .. chain .. "|r" end
    return table.concat(parts, " ")
end

local function showEntry(kind, key)
    local e = R.Entry(kind, key)
    beginPage()
    if not e then
        addLine("Nothing here yet.", "QuestFont")
        addLine("The Compendium fills in as you play: the people you talk to, the places you visit, the "
            .. "factions you earn standing with and the items quests ask for. Click a name in a quest "
            .. "to look it up.", "QuestFont", 8)
        return endPage()
    end
    addLine(e.name or "?", "QuestTitleFont", 0, { 0, 0, 0 })
    local sub = KIND_LABEL[kind]
    if kind == "npc" and e.map then
        local m = C_Map.GetMapInfo(e.map)
        local place = m and m.name
        if place then sub = sub .. ", " .. (R.Entry("place", e.map) and J.Link("place", e.map, place) or place) end
    end
    if kind == "place" and e.parent then
        local m = C_Map.GetMapInfo(e.parent)
        if m and m.name then sub = sub .. ", " .. (R.Entry("place", e.parent) and J.Link("place", e.parent, m.name) or m.name) end
    end
    addLine(sub, "GameFontNormalSmall", 2, { 0.42, 0.3, 0.12 })
    addLine(J.Summary(kind, e), "QuestFont", 8)

    -- quests, newest first by our log order isn't kept per entry: sort by ID for now
    local qs = {}
    for q, role in pairs(e.q or {}) do qs[#qs + 1] = { q = q, role = role } end
    table.sort(qs, function(a, b) return a.q < b.q end)
    if #qs > 0 then
        addLine("Quests", "QuestTitleFont", 12, { 0, 0, 0 })
        for _, it in ipairs(qs) do addLine(questRow(it.q, it.role), "QuestFont", 2) end
    end

    -- what they told you: the text you saw for quests they gave or took
    if kind == "npc" then
        local said = false
        for _, it in ipairs(qs) do
            local t, source = R.Text(it.q)
            if t and (t.d or t.c) then
                if not said then addLine("What you were told", "QuestTitleFont", 12, { 0, 0, 0 }) said = true end
                addLine(C.Title(it.q) or ("Quest " .. it.q), "GameFontNormal", 6, { 0.42, 0.3, 0.12 })
                if t.d and it.role:find("g") then addLine(J.Linkify(C.FillText(t.d), false, key), "QuestFont", 2) end
                if t.c and it.role:find("e") and C.done[it.q] then
                    addLine(J.Linkify(C.FillText(t.c), false, key), "QuestFont", 4)
                end
                if source ~= "captured" then addLine("(" .. source .. ")", "GameFontDisableSmall", 2, { 0.45, 0.4, 0.3 }) end
            end
        end
    end
    endPage()
end

-- A quest on the page: its chain and step, when and from whom, and the text you saw.
local function placeLink(map, sub)
    if sub and R.Entry("place", sub) then return J.Link("place", sub, sub) end
    local m = map and C_Map.GetMapInfo(map)
    local name = m and m.name
    if not name then return nil end
    return R.Entry("place", map) and J.Link("place", map, name) or name
end

local function heading(text) addLine(text, "QuestTitleFont", 12, { 0, 0, 0 }) end

-- An NPC by ID: a Compendium link if you've met them, else their name from the game. Names the
-- game doesn't have yet come back nil; the page is redrawn a moment later (a few tries).
local nameTries = {}
local function npcText(id)
    if not id or id <= 0 then return nil end
    local name = C.NpcName(id)
    if not name then
        nameTries[id] = (nameTries[id] or 0) + 1
        if nameTries[id] <= 3 then C_Timer.After(1, J.Refresh) end
        return nil
    end
    return R.Entry("npc", "c" .. id) and J.Link("npc", "c" .. id, name) or name
end

local function money(copper)
    if GetCoinTextureString then return GetCoinTextureString(copper) end
    return ("%dg %ds %dc"):format(copper / 10000, (copper / 100) % 100, copper % 100)
end

-- An item as the game's own link (quality colour), or nil until the game has loaded it.
local itemTries = {}
local function itemLink(id)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local name, link = getInfo(id)
    if link then return link end
    if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    itemTries[id] = (itemTries[id] or 0) + 1
    if itemTries[id] <= 3 then C_Timer.After(1, J.Refresh) end
    return nil
end

local function factionName(id)
    if C_Reputation and C_Reputation.GetFactionDataByID then
        local d = C_Reputation.GetFactionDataByID(id)
        return d and d.name
    end
    return GetFactionInfoByID and (GetFactionInfoByID(id))
end

local function showQuest(q)
    beginPage()
    if state.back then
        addLine("|c" .. LINK_INK .. "|Hplotline:back:0|h< Back|h|r", "GameFontNormalSmall", 0)
    end
    addLine(C.Title(q) or ("Quest " .. q), "QuestTitleFont", state.back and 6 or 0, { 0, 0, 0 })
    local chain = ns.hints.LineText(q)
    if chain then addLine(chain, "GameFontNormalSmall", 2, { 0.42, 0.3, 0.12 }) end
    local t, source = R.Text(q)
    local dev = ns.devText and ns.devText[q] or {}
    -- level, dungeon/raid, zone
    local facts = {}
    if dev.l then facts[#facts + 1] = dev.ml and ("Level %d (requires %d)"):format(dev.l, dev.ml) or ("Level " .. dev.l) end
    local kind = C.QuestKind(q)
    if kind then facts[#facts + 1] = C.KindIcon(kind, 20) .. (kind == "r" and "Raid" or "Dungeon") end
    local area = dev.za and C_Map.GetAreaInfo and C_Map.GetAreaInfo(dev.za)
    if area then facts[#facts + 1] = R.Entry("place", area) and J.Link("place", area, area) or area end
    if #facts > 0 then addLine(table.concat(facts, ", "), "GameFontNormalSmall", 4, { 0.42, 0.3, 0.12 }) end
    local doneLogged = false
    for _, ev in ipairs(ns.char.log) do
        if ev.q == q then
            local who = ev.npc and R.Entry("npc", ev.npc)
            local s = (ev.e == "done" and "Completed " or "Accepted ") .. date(ev.t)
            if who and who.name then s = s .. (ev.e == "done" and " for " or " from ") .. J.Link("npc", ev.npc, who.name) end
            local where = placeLink(ev.map, ev.sub)
            if where then s = s .. " in " .. where end
            addLine(s .. ".", "QuestFont", 6)
            doneLogged = doneLogged or ev.e == "done"
        end
    end
    local acceptLogged, doneByLogged = false, false
    for _, ev in ipairs(ns.char.log) do
        if ev.q == q and ev.npc then
            if ev.e == "accept" then acceptLogged = true else doneByLogged = true end
        end
    end
    local who = {}
    if not acceptLogged then
        local giver = npcText(C.Giver(q))
        if giver then who[#who + 1] = "Given by " .. giver end
    end
    if not doneByLogged then
        local ender = npcText(C.Ender(q))
        if ender then who[#who + 1] = (C.done[q] and "handed in to " or "hand in to ") .. ender end
    end
    if #who > 0 then
        local line = table.concat(who, ", ")
        addLine(line:sub(1, 1):upper() .. line:sub(2) .. ".", "QuestFont", 6)
    end
    if C.done[q] and not doneLogged then addLine("Completed before Plotline was installed.", "QuestFont", 6) end
    if t then
        if t.o then heading("Objectives") addLine(J.Linkify(C.FillText(t.o)), "QuestFont", 2) end
        if t.d then heading("Description") addLine(J.Linkify(C.FillText(t.d)), "QuestFont", 2) end
        if t.c and C.done[q] then heading("Completion") addLine(J.Linkify(C.FillText(t.c)), "QuestFont", 2) end
        -- rewards (dev data)
        local rewards = {}
        if dev.m then rewards[#rewards + 1] = money(dev.m) end
        for _, id in ipairs(dev.ri or {}) do rewards[#rewards + 1] = itemLink(id) or "..." end
        local choices = {}
        for _, id in ipairs(dev.rc or {}) do choices[#choices + 1] = itemLink(id) or "..." end
        local reps = {}
        for _, id in ipairs(dev.rp or {}) do
            local name = factionName(id)
            if name then reps[#reps + 1] = R.Entry("faction", name) and J.Link("faction", name, name) or name end
        end
        if #rewards + #choices + #reps > 0 then
            heading("Rewards")
            if #rewards > 0 then addLine((C.done[q] and "You received: " or "You will receive: ") .. table.concat(rewards, ", "), "QuestFont", 2) end
            if #choices > 0 then addLine((C.done[q] and "You chose one of: " or "Choose one of: ") .. table.concat(choices, ", "), "QuestFont", 2) end
            if #reps > 0 then addLine("Reputation: " .. table.concat(reps, ", "), "QuestFont", 2) end
        end
        if source ~= "captured" then
            addLine("(" .. source .. ", not captured in game)", "GameFontDisableSmall", 10, { 0.45, 0.4, 0.3 })
        end
    else
        addLine("No text saved for this quest yet. Plotline saves it when the quest giver shows it to you.",
            "QuestFont", 10)
    end
    endPage()
end

-- A chain on the page: zone, progress, the steps (reached ones link to their quest), branches.
local function chainLink(id)
    local name = C.DisplayName(id, 20)
    return ("|c%s|Hplotline:chain:%s|h%s|h|r"):format(LINK_INK, id, name)
end

local function showChain(id)
    local p = win.progress and win.progress[id]
    local v = p and p.v
    local ch = ns.data.chains[id]
    beginPage()
    if not v then
        addLine("You haven't started this chain.", "QuestFont")
        return endPage()
    end
    addLine(C.DisplayName(id, 28), "QuestTitleFont", 0, { 0, 0, 0 })
    local zone = C.ZoneName(id)
    local where = zone and (R.Entry("place", ch.z) and J.Link("place", ch.z, zone) or zone)
    local status = p.complete and "Completed" or ("Step %d of %d"):format(v.at or 1, #v.steps)
    addLine((where and (where .. ", ") or "") .. status .. ("  |cff5e4c36(%d of %d steps done)|r"):format(p.done, #v.steps),
        "GameFontNormalSmall", 2, { 0.42, 0.3, 0.12 })
    local first = v.steps[1] and v.steps[1].groups[1] and v.steps[1].groups[1].quests[1]
    local starter = first and npcText(C.Giver(first))
    if starter then addLine("Started by " .. starter, "QuestFont", 6) end
    if ch.from then addLine("Branches off " .. chainLink(ch.from.chain), "QuestFont", 4) end
    heading("Steps")
    for _, row in ipairs(ns.hints.StepRows(v, ns.hints.PARCH)) do
        local text = row.text
        if row.q then text = ("|Hquest:%d|h%s|h"):format(row.q, text) end
        addLine(text, "QuestFont", 2)
    end
    local branches = {}
    for _, b in ipairs(ch.br or {}) do
        if C.done[b.at] then branches[#branches + 1] = chainLink(b.to) end
    end
    if #branches > 0 then
        heading("Branches")
        for _, b in ipairs(branches) do addLine(b, "QuestFont", 2) end
    end
    -- steps done before Plotline: completed, but nothing in this character's timeline
    local logged = {}
    for _, ev in ipairs(ns.char.log) do if ev.e == "done" then logged[ev.q] = true end end
    local before = 0
    C.EachQuest(ch, function(q) if C.done[q] and not logged[q] then before = before + 1 end end)
    if before > 0 then
        addLine(("%d %s of this chain %s completed before Plotline was installed, so there's no text or "
            .. "history for %s."):format(before, before == 1 and "quest" or "quests", before == 1 and "was" or "were",
            before == 1 and "it" or "them"), "GameFontDisableSmall", 12, { 0.45, 0.4, 0.3 })
    end
    endPage()
end

local function chainsOverview()
    beginPage()
    local st = win.chainStats or { started = 0, finished = 0 }
    addLine("Chains", "QuestTitleFont", 0, { 0, 0, 0 })
    addLine(("You've started %d quest chains and finished %d of them."):format(st.started, st.finished), "QuestFont", 6)
    addLine("Chains you haven't started stay hidden, so nothing here gives away what's ahead. Pick one on "
        .. "the left to see its steps.", "QuestFont", 6)
    endPage()
end

-- ------------------------------------------------------------------ refresh / open
function J.Refresh()
    if not win or not win:IsShown() then return end
    J.Dirty()
    if PanelTemplates_SetTab then
        pcall(PanelTemplates_SetTab, win, ({ chains = 1, timeline = 2, compendium = 3 })[state.tab])
    end
    if state.tab == "compendium" then
        fillList(compendiumItems())
        if state.quest then showQuest(state.quest) else showEntry(state.kind, state.key) end
    elseif state.tab == "timeline" then
        fillList(timelineItems())
        if state.quest then
            showQuest(state.quest)
        else
            beginPage()
            addLine("Timeline", "QuestTitleFont", 0, { 0, 0, 0 })
            addLine(("%d quests accepted or completed since Plotline was installed. Click one to read it here.")
                :format(#ns.char.log), "QuestFont", 6)
            endPage()
        end
    else
        fillList(chainItems())
        if state.quest then showQuest(state.quest)
        elseif state.chain then showChain(state.chain)
        else chainsOverview() end
    end
end

local refreshPending = false
function J.RefreshSoon()
    if refreshPending or not win or not win:IsShown() then return end
    refreshPending = true
    C_Timer.After(0.3, function()
        refreshPending = false
        J.Refresh()
    end)
end

function J.Toggle()
    if not win then makeWindow() end
    if win:IsShown() then win:Hide() else win:Show() J.Refresh() end
end

-- Open the Compendium at an entry.
function J.Open(kind, key)
    if not win then makeWindow() end
    state.tab, state.kind, state.key, state.quest, state.back = "compendium", kind, key, nil, nil
    state.search = ""
    win.search:SetText("")
    win:Show()
    J.Refresh()
end

-- A quest on the Journal page; from a Compendium entry, with a link back to it.
function J.OpenQuest(q)
    if not win then makeWindow() end
    state.back = not state.quest and ((state.tab == "compendium" and state.key ~= nil)
        or (state.tab == "chains" and state.chain ~= nil))
    if not win:IsShown() then state.tab, state.back = "timeline", false end
    state.quest = q
    win:Show()
    J.Refresh()
end

-- Open the Chains tab at a chain.
function J.OpenChain(id)
    if not win then makeWindow() end
    state.tab, state.chain, state.quest, state.back = "chains", id, nil, nil
    state.search = ""
    win.search:SetText("")
    local zone = C.ZoneName(id)
    if zone then state.open[zone] = true end
    win:Show()
    J.Refresh()
end

function J.Back()
    state.quest, state.back = nil, nil
    J.Refresh()
end

-- A quest's card beside the Journal (or wherever the click came from).
function J.ShowQuest(q)
    if not win then makeWindow() end
    ns.hints.ShowCard(q, win:IsShown() and win or UIParent)
end

-- ------------------------------------------------------------------ the game's quest text
-- Known names in the quest dialog and quest log become links (setting: PlotlineDB.linkQuestText).
local QUEST_TEXT = { "QuestInfoDescriptionText", "QuestInfoObjectivesText", "QuestInfoRewardText", "QuestProgressText" }

local function linkQuestText()
    if not PlotlineDB.linkQuestText then return end
    for _, name in ipairs(QUEST_TEXT) do
        local fs = _G[name]
        if fs and fs:IsShown() then
            local text = fs:GetText()
            if text and not text:find("|Hplotline:", 1, true) then
                local linked = J.Linkify(text)
                if linked ~= text then
                    fs:SetText(linked)
                    J.EnableLinks(fs:GetParent())
                end
            end
        end
    end
end

-- NPC tooltips: a line for people you've met.
local function unitTooltip(tip, data)
    if tip ~= GameTooltip then return end
    local guid = data and data.guid
    if not guid then return end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind ~= "Creature" then return end
    local e = R.Entry("npc", "c" .. id)
    if not e then return end
    local n = countQuests(e)
    tip:AddLine(("Plotline: met %s%s"):format(date(e.first), n > 0 and (", " .. n .. (n == 1 and " quest" or " quests")) or ""),
        0.6, 0.75, 1)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    if QuestInfo_Display then hooksecurefunc("QuestInfo_Display", linkQuestText) end
    if QuestFrameProgressPanel then QuestFrameProgressPanel:HookScript("OnShow", linkQuestText) end
    if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, unitTooltip)
    end
end)
