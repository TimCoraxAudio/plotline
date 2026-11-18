-- SPDX-License-Identifier: GPL-3.0-or-later
-- Plotline: entry point. Sets up SavedVariables; features come later.

local ADDON_NAME, ns = ...

local DEFAULTS = {
    recapOnLogin = true,
    linkQuestText = true,  -- known names in the game's quest text become Compendium links
}

local CHAR_DEFAULTS = {
    seenChains = {},   -- [chainSlug] = true once the player has seen its first quest
    history = {},      -- turn-in log: { questID = n, time = t }
    notes = {},        -- [chainSlug or questID] = "text"
    known = {},        -- Compendium: { npc = {}, place = {}, faction = {}, item = {} } (Record.lua)
    text = {},         -- [questID] = { d, o, p, c }: the quest text this character was shown
    log = {},          -- timeline: { t = time, e = "accept" | "done", q = questID, npc, map }
}

local function applyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            target[k] = type(v) == "table" and {} or v
        end
    end
    return target
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, name)
    if event == "ADDON_LOADED" and name == ADDON_NAME then
        PlotlineDB = applyDefaults(PlotlineDB or {}, DEFAULTS)
        PlotlineCharDB = applyDefaults(PlotlineCharDB or {}, CHAR_DEFAULTS)
        for _, kind in ipairs({ "npc", "place", "faction", "item" }) do
            PlotlineCharDB.known[kind] = PlotlineCharDB.known[kind] or {}
        end
        ns.db, ns.char = PlotlineDB, PlotlineCharDB
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

-- /plotline: status. /plotline journal (or j): the Journal. /plotline quest <id>: what Plotline knows about a quest.
-- /plotline probe [watch]: reports which game APIs this client has (Probe.lua).
SLASH_PLOTLINE1 = "/plotline"
SLASH_PLOTLINE2 = "/pl"
SlashCmdList.PLOTLINE = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "probe" then return ns.probe.run() end
    if msg == "probe watch" then return ns.probe.watch() end
    if msg == "journal" or msg == "j" then return ns.journal.Toggle() end
    if msg == "tracker" then return ns.debugTracker() end
    if msg == "linktest" then return ns.linkTest() end
    if msg == "mouse" then
        -- what's under the cursor, top first: for finding what blocks clicks or hovers
        local foci = GetMouseFoci and GetMouseFoci() or { GetMouseFocus and GetMouseFocus() }
        local out = {}
        for _, f in ipairs(foci) do
            out[#out + 1] = (f.GetDebugName and f:GetDebugName() or tostring(f)) .. (f.IsMouseEnabled and
                (f:IsMouseEnabled() and " (mouse)" or "") or "") .. (f.GetHyperlinksEnabled and f:GetHyperlinksEnabled()
                and " (links)" or "")
        end
        print("|cffffd100Plotline|r under the mouse: " .. #out .. " frames (copy window open)")
        ns.ShowCopy("under the mouse", out)
        return
    end
    local kind, n = msg:match("^icon%s+(%a)%s+(%d+)$")
    if kind then
        PlotlineDB.icon = PlotlineDB.icon or {}
        PlotlineDB.icon[kind] = tonumber(n)
        print(("|cffffd100Plotline|r %s icon set to %s %s"):format(kind == "r" and "raid" or "dungeon", n,
            ns.chains.KindIcon(kind, 16)))
        return
    end
    if msg == "icons" then
        for _, k in ipairs({ "d", "r" }) do
            for i, ic in ipairs(ns.chains.ICON_CHOICES[k]) do
                local t = ns.chains.IconText(ic, 20)
                print(("|cffffd100Plotline|r %s %d: %s  %s"):format(k == "r" and "raid" or "dungeon", i,
                    t or "(not in this client)", ic.atlas or ic.file))
            end
        end
        print("Pick with /plotline icon d <number> (dungeon) or /plotline icon r <number> (raid).")
        return
    end
    local q = tonumber(msg:match("^q%a*%s+(%d+)$") or "")
    if q then return ns.debugQuest(q) end
    if msg ~= "" then
        print(("|cffffd100Plotline|r unknown command \"%s\". Commands: journal (j), quest <id>, tracker, icons, "
            .. "icon d|r <n>, linktest, mouse, probe, probe watch."):format(msg))
        return
    end
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local version = getMeta and getMeta(ADDON_NAME, "Version") or "?"
    local ok = ns.db ~= nil and ns.char ~= nil
    print(("|cffffd100Plotline|r %s loaded. Saved settings: %s. Client interface: %s.")
        :format(version, ok and "ready" or "MISSING", select(4, GetBuildInfo())))
    if ns.data then
        local n = 0
        for _ in pairs(ns.data.chains) do n = n + 1 end
        print(("|cffffd100Plotline|r chain data: %d chains, built %s."):format(n, ns.data.built or "?"))
    else
        print("|cffffd100Plotline|r no chain data. Build it with: uv run pipeline/build_addon_data.py")
    end
end

-- /plotline quest <id>: the chain line and step list for a quest, in chat.
function ns.debugQuest(q)
    local C = ns.chains
    local info = C and C.of[q]
    if not info then
        print(("|cffffd100Plotline|r quest %d is in no chain."):format(q))
        return
    end
    print(("|cffffd100Plotline|r %d: %s [%s, %s]"):format(q, ns.hints.LineText(q) or "?", info.id, info.kind))
    local v = C.View(info.id, q)
    for _, row in ipairs(ns.hints.StepRows(v)) do print("   " .. row.text) end
end

-- /plotline tracker: which tracker lines Plotline matched to quests, for checking the tracker marks.
function ns.debugTracker()
    local found = ns.hints.ScanTracker()
    print(("|cffffd100Plotline|r tracker: %s, %d quest titles matched."):format(
        ObjectiveTrackerFrame and "found" or "NOT FOUND", #found))
    for _, f in ipairs(found) do
        local parent = f.fs:GetParent()
        print(("   %d %s %s"):format(f.q, ns.chains.of[f.q] and "(chain)" or "(no chain)",
            parent and parent.GetDebugName and parent:GetDebugName() or "?"))
    end
end

-- A small window with text selected for copying (Ctrl+C), for sharing debug output.
local copyFrame
function ns.ShowCopy(title, lines)
    if not copyFrame then
        local ok, f = pcall(CreateFrame, "Frame", "PlotlineCopyFrame", UIParent, "BasicFrameTemplateWithInset")
        if not ok then f = CreateFrame("Frame", "PlotlineCopyFrame", UIParent, "BackdropTemplate") end
        f:SetSize(520, 300)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        tinsert(UISpecialFrames, "PlotlineCopyFrame")
        f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        f.title:SetPoint("TOP", 0, -6)
        local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
        scroll:SetPoint("TOPLEFT", 12, -30)
        scroll:SetPoint("BOTTOMRIGHT", -30, 12)
        local box = CreateFrame("EditBox", nil, scroll)
        box:SetMultiLine(true)
        box:SetAutoFocus(false)
        box:SetFontObject(ChatFontNormal)
        box:SetWidth(470)
        box:SetScript("OnEscapePressed", function() f:Hide() end)
        scroll:SetScrollChild(box)
        f.box = box
        copyFrame = f
    end
    copyFrame.title:SetText("Plotline: " .. title .. "  (Ctrl+C to copy)")
    copyFrame.box:SetText(table.concat(lines, "\n"))
    copyFrame:Show()
    copyFrame.box:SetFocus()
    copyFrame.box:HighlightText()
end

-- /plotline linktest: which kinds of text frame and link type take hovers and clicks on this
-- client. Each link prints a chat line when hovered or clicked.
function ns.linkTest()
    local types = {
        { "quest", "|cffffff00|Hquest:288:-1|h[quest link]|h|r" },
        { "item", "|cff1eff00|Hitem:2594::::::::::::|h[item link]|h|r" },
        { "addon", "|cff6fb3ff|Haddon:Plotline:test:1|h[addon: link]|h|r" },
        { "plotline", "|cff6fb3ff|Hplotline:test:1|h[plotline: link]|h|r" },
        { "garrmission", "|cff6fb3ff|Hgarrmission:plotline:test|h[garrmission: link]|h|r" },
    }
    local f = ns.linkTestFrame
    if not f then
        local ok
        ok, f = pcall(CreateFrame, "Frame", "PlotlineLinkTest", UIParent, "BasicFrameTemplateWithInset")
        if not ok then f = CreateFrame("Frame", "PlotlineLinkTest", UIParent, "BackdropTemplate") end
        f:SetSize(460, 260)
        f:SetPoint("CENTER")
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        tinsert(UISpecialFrames, "PlotlineLinkTest")
        local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOP", 0, -6)
        title:SetText("Plotline link test: hover and click each link")
        local function report(kind)
            return function(_, link, text) print(("|cffffd100Plotline|r %s: %s"):format(kind, link)) end
        end
        -- left: FontStrings in a plain frame with hyperlinks enabled
        local plain = CreateFrame("Frame", nil, f)
        plain:SetPoint("TOPLEFT", 16, -40)
        plain:SetSize(200, 200)
        plain:EnableMouse(true)
        if plain.SetHyperlinksEnabled then plain:SetHyperlinksEnabled(true) end
        plain:SetScript("OnHyperlinkEnter", report("text enter"))
        plain:SetScript("OnHyperlinkClick", report("text click"))
        local head = plain:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        head:SetPoint("TOPLEFT")
        head:SetText("Plain text")
        for i, t in ipairs(types) do
            local fs = plain:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            fs:SetPoint("TOPLEFT", 0, -10 - i * 24)
            fs:SetText(t[2])
        end
        -- right: SimpleHTML
        local ok2, html = pcall(CreateFrame, "SimpleHTML", nil, f)
        local head2 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        head2:SetPoint("TOPLEFT", 240, -40)
        head2:SetText(ok2 and "SimpleHTML" or "SimpleHTML: not available")
        if ok2 then
            html:SetPoint("TOPLEFT", 240, -74)
            html:SetSize(200, 160)
            pcall(html.SetFontObject, html, GameFontNormal)
            pcall(html.SetFontObject, html, "p", GameFontNormal)
            if html.SetHyperlinksEnabled then html:SetHyperlinksEnabled(true) end
            html:SetScript("OnHyperlinkEnter", report("html enter"))
            html:SetScript("OnHyperlinkClick", report("html click"))
            local lines = {}
            for _, t in ipairs(types) do lines[#lines + 1] = t[2] end
            html:SetText(table.concat(lines, "\n\n"))
        end
        ns.linkTestFrame = f
    end
    f:Show()
    print("|cffffd100Plotline|r link test open: hover and click each link, then send a screenshot of chat.")
end
