-- SPDX-License-Identifier: GPL-3.0-or-later
-- The quest text pack: Plotline_QuestText, a separate load-on-demand add-on holding Blizzard's
-- quest text (docs/DATA.md). Plotline works without it. It's loaded the first time a text is
-- asked for, and only on English clients (the pack is enUS). Text the player was shown in game
-- (Record.lua) always comes first; this only fills gaps.

local _, ns = ...
local T = {}
ns.text = T

local PACK = "Plotline_QuestText"
local LOCALES = { enUS = true, enGB = true }
local status        -- nil until tried; then "loaded" or why not

local function pack()
    return _G.PlotlineQuestText
end

local function load()
    if status then return status == "loaded" end
    if pack() then
        status = "loaded"
    elseif not LOCALES[GetLocale()] then
        status = "English clients only"
    else
        local loadAddOn = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
        local ok, loaded, reason = false, nil, nil
        if loadAddOn then ok, loaded, reason = pcall(loadAddOn, PACK) end
        if ok and loaded and pack() then
            status = "loaded"
        elseif reason then
            status = _G["ADDON_" .. tostring(reason)] or tostring(reason)   -- e.g. "Missing", "Disabled"
        else
            status = "not installed"
        end
    end
    return status == "loaded"
end

-- The pack's text for quest q as { t, d, o }: title, description, objectives (the opening prompt;
-- the pack holds no progress or completion text). Placeholders ($g etc.) are filled by C.FillText.
function T.Get(q)
    if not q or not load() then return nil end
    return pack().quests[q]
end

-- Like Get, but never loads the pack: for hot paths such as titles.
function T.Peek(q)
    if not status or status ~= "loaded" then return nil end
    return T.Get(q)
end

-- For /plotline: "loaded" (and the build date) or why it isn't.
function T.Status()
    load()
    local p = pack()
    return status, p and p.built
end
