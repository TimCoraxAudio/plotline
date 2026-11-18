-- SPDX-License-Identifier: GPL-3.0-or-later
-- Plotline: entry point. Sets up SavedVariables; features come later.

local ADDON_NAME, ns = ...

local DEFAULTS = {
    recapOnLogin = true,
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

-- /plotline: confirms the add-on loaded and its saved settings are in place.
-- /plotline probe [watch]: reports which game APIs this client has (Probe.lua).
SLASH_PLOTLINE1 = "/plotline"
SlashCmdList.PLOTLINE = function(msg)
    msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "probe" then return ns.probe.run() end
    if msg == "probe watch" then return ns.probe.watch() end
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local version = getMeta and getMeta(ADDON_NAME, "Version") or "?"
    local ok = ns.db ~= nil and ns.char ~= nil
    print(("|cffffd100Plotline|r %s loaded. Saved settings: %s. Client interface: %s.")
        :format(version, ok and "ready" or "MISSING", select(4, GetBuildInfo())))
end
