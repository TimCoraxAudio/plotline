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
local views = {}    -- [quest] = the pack's entry, gendered for this character

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

-- The pack's text for quest q as { t, d, o, p, c }, with this character's gendered forms
-- (pF / cF ship where female readers saw different words). nil if the pack has none.
local function view(e)
    local female = UnitSex("player") == 3
    return {
        t = e.t, d = e.d, o = e.o,
        p = female and e.pF or e.p,
        c = female and e.cF or e.c,
    }
end

function T.Get(q)
    if not q or not load() then return nil end
    if views[q] == nil then
        local e = pack().quests[q]
        views[q] = e and view(e) or false
    end
    return views[q] or nil
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
