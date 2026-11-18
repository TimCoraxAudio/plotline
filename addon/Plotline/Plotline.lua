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
    if msg == "mouse" then
        -- what's under the cursor, top first: for finding what blocks clicks or hovers
        local foci = GetMouseFoci and GetMouseFoci() or { GetMouseFocus and GetMouseFocus() }
        print("|cffffd100Plotline|r under the mouse:")
        for _, f in ipairs(foci) do
            print("   " .. (f.GetDebugName and f:GetDebugName() or tostring(f)) .. (f.IsMouseEnabled and
                (f:IsMouseEnabled() and " (mouse)" or "") or "") .. (f.GetHyperlinksEnabled and f:GetHyperlinksEnabled()
                and " (links)" or ""))
        end
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
