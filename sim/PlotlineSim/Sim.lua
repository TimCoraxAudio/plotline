-- SPDX-License-Identifier: GPL-3.0-or-later
-- PlotlineSim: a dev-only add-on that fakes a player and sets up one UI scene, so wowless (a headless
-- WoW client) can lay out Plotline's frames for a screenshot. Never shipped. See sim/README.md.
-- Generated.lua (written by sim/make_scene.py, git-ignored) sets PlotlineSimConfig before this file.

local _, sim = ...
local cfg = PlotlineSimConfig or {}
local scene = cfg.scene or "dialog"
local titles = cfg.titles or {}
local Q = cfg.quest or 141          -- the quest in the dialog: "The Defias Brotherhood" step 4
local done = cfg.done or { 65, 132, 135 }

-- wowless shows no chat, but it logs Lua errors: route our messages through the error handler so they
-- reach the run's log as "error: PlotlineSim: ..." lines (sim/report.py lists them as notes).
local function say(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    pcall(geterrorhandler(), "PlotlineSim: " .. table.concat(parts, " "))
end
sim.say = say

local function title(q)
    return titles[q] or ("Quest " .. q)
end

-- ------------------------------------------------------------ the fake player
UnitFactionGroup = function() return "Alliance", "Alliance" end
UnitRace = function() return "Human", "Human", 1 end
UnitClass = function() return "Warrior", "WARRIOR", 1 end
UnitName = function(unit)
    if unit == "player" then return "Simtester" end
    if unit == "npc" then return "Gryan Stoutmantle" end
end
UnitLevel = function() return 14 end
UnitGUID = function(unit)
    if unit == "npc" then return "Creature-0-0-0-0-234-0000000000" end
    return "Player-0-00000000"
end

C_QuestLog = C_QuestLog or {}
C_QuestLog.GetAllCompletedQuestIDs = function() return done end
C_QuestLog.IsQuestFlaggedCompleted = function(q)
    for _, d in ipairs(done) do if d == q then return true end end
    return false
end
C_QuestLog.GetTitleForQuestID = function(q) return title(q) end
C_QuestLog.RequestLoadQuestByID = function() end

-- The quest log holds the dialog quest once accepted (scenes that need it set cfg.inLog).
local log = cfg.inLog and { Q } or {}
C_QuestLog.GetNumQuestLogEntries = function() return #log, #log end
C_QuestLog.GetInfo = function(i)
    local q = log[i]
    if q then return { questID = q, title = title(q), isHeader = false, level = 14 } end
end
C_QuestLog.GetQuestIDForLogIndex = function(i) return log[i] end

-- ------------------------------------------------------------ the quest dialog
-- Placeholder prose unless the workflow was asked for real text (cfg.text). Real quest text is
-- Blizzard's: it may only reach a private screenshot, never the repo.
local body = cfg.text and cfg.text[Q] or {
    d = "Placeholder quest text. In the game this is the quest giver's speech, a paragraph or two "
        .. "long, so the layout can be judged with text of a realistic length. "
        .. "Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor.",
    o = "Placeholder objective: do the thing, then return.",
}
GetQuestID = function() return Q end
GetTitleText = function() return title(Q) end
GetQuestText = function() return body.d end
GetObjectiveText = function() return body.o end
GetProgressText = function() return body.p or "" end
GetRewardText = function() return body.c or "" end
GetNumQuestRewards = function() return 0 end
GetNumQuestChoices = function() return 0 end
GetNumQuestItems = function() return 0 end
GetRewardMoney = function() return 0 end
GetRewardXP = function() return 0 end

-- ------------------------------------------------------------ helpers
local function fire(event, ...)
    local frames = { GetFramesRegisteredForEvent(event) }
    for _, f in ipairs(frames) do
        local h = f:GetScript("OnEvent")
        if h then
            local ok, err = pcall(h, f, event, ...)
            if not ok then say("error in", f:GetDebugName(), event, err) end
        end
    end
end

local function try(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then say(what, "failed:", err) end
end

local function openDialog()
    fire("QUEST_DETAIL")
    if not QuestFrame:IsShown() then
        try("ShowUIPanel(QuestFrame)", ShowUIPanel, QuestFrame)
        if not QuestFrame:IsShown() then QuestFrame:Show() end
    end
    if QuestInfo_Display and QUEST_TEMPLATE_DETAIL then
        try("QuestInfo_Display", QuestInfo_Display, QUEST_TEMPLATE_DETAIL, QuestDetailScrollChildFrame,
            nil, nil, nil)
    end
    if sim.ns then try("UpdateDialog", sim.ns.hints.UpdateDialog, Q) end
end

-- Plotline's private namespace. The shipped add-on keeps it private; sim/run.sh runs a copy of Plotline
-- with one extra file, DevNS.lua, that stores it in PlotlineDevNS.
local function plotline()
    return PlotlineDevNS
end

-- Chat lines (print, /plotline output) go to the log too.
local function captureChat()
    if DEFAULT_CHAT_FRAME and not sim.chatHooked then
        sim.chatHooked = true
        hooksecurefunc(DEFAULT_CHAT_FRAME, "AddMessage", function(_, msg)
            say("chat:", (tostring(msg):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")))
        end)
    end
end

-- What a scene left on screen, for the log.
local function describe()
    local function shown(f) return f and f.IsShown and f:IsShown() and "shown" or "hidden" end
    say("QuestFrame", shown(QuestFrame), "GameTooltip", shown(GameTooltip),
        GameTooltip and GameTooltip.NumLines and ("lines " .. GameTooltip:NumLines()) or "",
        "Journal", shown(PlotlineJournalFrame), "Card", shown(PlotlineQuestCard))
    local ns = sim.ns
    if ns and ns.hints then
        say("LineText", tostring(ns.hints.LineText(Q)), "BadgeText", tostring(ns.hints.BadgeText(Q)))
    end
    if GameTooltip and GameTooltip:IsShown() then
        for i = 1, GameTooltip:NumLines() do
            local fs = _G["GameTooltipTextLeft" .. i]
            if fs then say("tooltip", i, tostring(fs:GetText())) end
        end
    end
end

local scenes = {}

scenes.dialog = function(ns)
    openDialog()
end

scenes.steps = function(ns)
    openDialog()
    try("ShowSteps", ns.hints.ShowSteps, QuestFrame, Q)
end

scenes.panel = function(ns)
    openDialog()
    try("TogglePanel", ns.hints.TogglePanel, QuestFrame, Q, QuestFrame)
end

scenes.card = function(ns)
    openDialog()
    try("ShowCard", ns.hints.ShowCard, Q, QuestFrame)
end

scenes.journal = function(ns)
    try("Journal", ns.journal.Toggle)
end

scenes.journalquest = function(ns)
    try("Journal quest", ns.journal.OpenQuest, Q)
end

scenes.journalchain = function(ns)
    try("Journal chain", ns.journal.OpenChain, "the-defias-brotherhood-65")
end

scenes.chat = function(ns)
    SlashCmdList.PLOTLINE("quest " .. Q)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    local ns = plotline()
    sim.ns = ns
    if not ns then return say("no PlotlineDevNS: is Plotline loaded?") end
    local fn = scenes[scene]
    if not fn then return say("unknown scene", scene) end
    captureChat()
    say("scene", scene, "faction", UnitFactionGroup("player"), "chain of", Q, tostring(ns.chains.of[Q] and ns.chains.of[Q].id))
    try("scene " .. scene, fn, ns)
    describe()
end)
