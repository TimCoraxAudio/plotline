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
local ROW_H = 16

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

local function onLink(_, link, text, button)
    if link == "plotline:back:0" then
        J.Back()
        return
    end
    local kind, key = link:match("^plotline:(%a+):(.+)$")
    if kind then
        J.Open(kind, (kind == "place" or kind == "item") and tonumber(key) or key)   -- subzones: by name
        return
    end
    local q = tonumber(link:match("^quest:(%d+)"))
    if q then
        if IsModifiedClick and IsModifiedClick("CHATLINK") then ns.hints.LinkQuest(q) else J.OpenQuest(q) end
    end
end

local function onLinkEnter(self, link)
    local kind, key = link:match("^plotline:(%a+):(.+)$")
    if not kind or kind == "back" then return end
    if kind == "place" or kind == "item" then key = tonumber(key) or key end   -- subzones: by name
    local e = R.Entry(kind, key)
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
    GameTooltip:AddLine(e.name or "?")
    GameTooltip:AddLine(J.Summary(kind, e), 1, 1, 1, true)
    GameTooltip:AddLine("Click to open in the Compendium", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function onLinkLeave() GameTooltip:Hide() end

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
local state = { tab = "compendium", kind = "npc", key = nil, offset = 0, search = "" }

local function scrollArea(parent)
    local sf = CreateFrame("ScrollFrame", nil, parent)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(1, 1)
    sf:SetScrollChild(child)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function(self, delta)
        local max = math.max(0, child:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * 40)))
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
    win:SetSize(700, 500)
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
    win.search:SetSize(196, 20)
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
    win.list:SetWidth(210)
    win.list:EnableMouseWheel(true)
    win.list:SetScript("OnMouseWheel", function(_, delta)
        state.offset = math.max(0, state.offset - delta * 3)
        J.Refresh()
    end)
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
    win.scroll:SetPoint("BOTTOMRIGHT", -14, 12)
    local body = win.scroll.child
    body:SetWidth(430)
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
    r:SetPoint("RIGHT", win.list, "RIGHT")
    r.text = r:CreateFontString(nil, "OVERLAY")
    font(r.text, "GameFontHighlightSmall")
    r.text:SetPoint("LEFT", 4, 0)
    r.text:SetPoint("RIGHT", -4, 0)
    r.text:SetJustifyH("LEFT")
    r.text:SetWordWrap(false)
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    r.sel = r:CreateTexture(nil, "BACKGROUND")
    r.sel:SetAllPoints()
    r.sel:SetColorTexture(0.2, 0.35, 0.6, 0.6)
    r:SetScript("OnClick", function(self)
        if self.header then
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
        items[#items + 1] = { header = k.key, text = ("|cffffd100%s|r |cff8a8a8a(%d)|r"):format(k.label, #entries) }
        if state.kind == k.key or state.search ~= "" then
            for _, it in ipairs(entries) do
                items[#items + 1] = { kind = k.key, key = it.key, text = "   " .. (it.e.name or "?") }
            end
        end
    end
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
    local visible = math.floor(win.list:GetHeight() / ROW_H)
    state.offset = math.min(state.offset, math.max(0, #items - visible))
    for i = 1, visible do
        local it = items[i + state.offset]
        local r = listRow(i)
        if it then
            r.header, r.kind, r.key, r.q = it.header, it.kind, it.key, it.q
            r.text:SetText(it.text)
            r.sel:SetShown((it.key ~= nil and it.key == state.key and it.kind == state.kind)
                or (it.q ~= nil and it.q == state.quest))
            r:Show()
        else
            r:Hide()
        end
    end
    for i = visible + 1, #win.rows do win.rows[i]:Hide() end
end

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
end

local function questRow(q, role)
    local info = C.of[q]
    local chain = info and C.Name(info.id)
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

local function showQuest(q)
    beginPage()
    if state.back then
        addLine("|c" .. LINK_INK .. "|Hplotline:back:0|h< Back|h|r", "GameFontNormalSmall", 0)
    end
    addLine(C.Title(q) or ("Quest " .. q), "QuestTitleFont", state.back and 6 or 0, { 0, 0, 0 })
    local chain = ns.hints.LineText(q)
    if chain then addLine(chain, "GameFontNormalSmall", 2, { 0.42, 0.3, 0.12 }) end
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
    if C.done[q] and not doneLogged then addLine("Completed before Plotline was installed.", "QuestFont", 6) end
    local t, source = R.Text(q)
    if t then
        if t.o then heading("Objectives") addLine(J.Linkify(C.FillText(t.o)), "QuestFont", 2) end
        if t.d then heading("Description") addLine(J.Linkify(C.FillText(t.d)), "QuestFont", 2) end
        if t.c and C.done[q] then heading("Completion") addLine(J.Linkify(C.FillText(t.c)), "QuestFont", 2) end
        if source ~= "captured" then
            addLine("(" .. source .. ", not captured in game)", "GameFontDisableSmall", 10, { 0.45, 0.4, 0.3 })
        end
    else
        addLine("No text saved for this quest yet. Plotline saves it when the quest giver shows it to you.",
            "QuestFont", 10)
    end
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
        fillList({})
        beginPage()
        addLine("Chains", "QuestTitleFont", 0, { 0, 0, 0 })
        addLine("Coming next: your chains by zone, with their steps.", "QuestFont", 6)
        endPage()
    end
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
    state.back = state.tab == "compendium" and state.key ~= nil and not state.quest
    if not win:IsShown() then state.tab, state.back = "timeline", false end
    state.quest = q
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
