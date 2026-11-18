-- SPDX-License-Identifier: GPL-3.0-or-later
-- Plotline: entry point. Sets up SavedVariables; features come later.

local ADDON_NAME, ns = ...

local DEFAULTS = {
    recapOnLogin = true,
    sideTab = true,    -- show the chain's steps beside the quest dialog
}

local CHAR_DEFAULTS = {
    seenChains = {},   -- [chainSlug] = true once the player has seen its first quest
    history = {},      -- turn-in log: { questID = n, time = t }
    notes = {},        -- [chainSlug or questID] = "text"
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
        ns.db, ns.char = PlotlineDB, PlotlineCharDB
        self:UnregisterEvent("ADDON_LOADED")
    end
end)

-- /plotline: status. /plotline quest <id>: what Plotline knows about a quest.
-- /plotline probe [watch]: reports which game APIs this client has (Probe.lua).
SLASH_PLOTLINE1 = "/plotline"
SLASH_PLOTLINE2 = "/pl"
SlashCmdList.PLOTLINE = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "probe" then return ns.probe.run() end
    if msg == "probe watch" then return ns.probe.watch() end
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
    for _, row in ipairs(ns.hints.StepRows(v)) do print("   " .. row) end
end
