-- SPDX-License-Identifier: GPL-3.0-or-later
-- Plotline: API probe. "/plotline probe" reports which game APIs this client has, so the
-- add-on can be designed around what WoW Forever really offers. "/plotline probe watch" also
-- reports what the quest and gossip APIs return the next few times you talk to an NPC.
-- Results go to chat and to PlotlineDB.probe (written to the SavedVariables file on logout or
-- /reload). Only API names, field names and IDs are stored, never quest text.

local ADDON_NAME, ns = ...

local function resolve(path)
    local v = _G
    for part in path:gmatch("[^%.]+") do
        if type(v) ~= "table" then return nil end
        v = v[part]
    end
    return v
end

-- Functions and frames, grouped by what Plotline would use them for.
local CHECKS = {
    { "Quest dialog", { "GetQuestID", "GetTitleText", "GetQuestText", "GetObjectiveText", "GetRewardText",
        "GetProgressText", "DeclineQuest", "QuestFrame", "QuestFrameDetailPanel", "QuestInfoTitleHeader" } },
    { "Gossip / greeting lists", { "C_GossipInfo", "C_GossipInfo.GetAvailableQuests", "C_GossipInfo.GetActiveQuests",
        "GetGossipAvailableQuests", "GetNumAvailableQuests", "GetAvailableTitle", "GetAvailableQuestInfo",
        "GossipFrame", "GossipFrame.GreetingPanel", "GossipGreetingScrollFrame", "QuestFrameGreetingPanel",
        "QuestTitleButton1", "GossipTitleButton1" } },
    { "Quest log", { "GetQuestLogTitle", "GetNumQuestLogEntries", "GetQuestLogSelection", "C_QuestLog",
        "C_QuestLog.GetInfo", "C_QuestLog.GetQuestIDForLogIndex", "QuestLog_Update", "QuestLogFrame",
        "QuestLogDetailScrollChildFrame", "QuestLogQuestTitle", "QuestMapFrame", "QuestMapFrame.DetailsFrame",
        "QuestMapFrame_ShowQuestDetails", "QuestInfo_Display", "QuestScrollFrame", "QuestLogQuests_Update",
        "C_QuestLog.GetSelectedQuest", "C_QuestLog.GetTitleForQuestID", "C_QuestLog.GetNumQuestLogEntries", "QuestWatch_Update",
        "QuestWatchFrame", "ObjectiveTrackerFrame" } },
    { "Completion history", { "GetQuestsCompleted", "C_QuestLog.IsQuestFlaggedCompleted",
        "C_QuestLog.GetAllCompletedQuestIDs", "IsQuestFlaggedCompleted" } },
    { "Tooltips / NPCs", { "UnitGUID", "GameTooltip", "TooltipDataProcessor", "TooltipDataProcessor.AddTooltipPostCall",
        "Enum.TooltipDataType" } },
    { "Nameplates", { "C_NamePlate", "C_NamePlate.GetNamePlateForUnit", "C_NamePlate.GetNamePlates",
        "NamePlateDriverFrame" } },
    { "Maps / pins", { "C_Map", "C_Map.GetBestMapForUnit", "C_Map.GetPlayerMapPosition", "WorldMapFrame",
        "WorldMapFrame.ScrollContainer", "WorldMapFrame.AddDataProvider", "Minimap", "C_Minimap",
        "HBD_Pins_MiniMap" } },
    { "Settings / UI", { "Settings", "Settings.RegisterAddOnCategory", "InterfaceOptions_AddCategory",
        "C_AddOns", "LibStub", "ButtonFrameTemplate_HidePortrait", "PortraitFrameTemplateMixin",
        "PanelTemplates_SetNumTabs", "ScrollUtil", "CreateScrollBoxListLinearView" } },
}

local EVENTS = {
    "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_ACCEPTED", "QUEST_TURNED_IN",
    "QUEST_REMOVED", "QUEST_LOG_UPDATE", "QUEST_GREETING", "GOSSIP_SHOW", "QUEST_FINISHED",
    "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED", "UPDATE_MOUSEOVER_UNIT", "QUEST_WATCH_UPDATE",
}

-- Script handlers worth knowing about on existing frames.
local SCRIPTS = {
    { "GameTooltip", "OnTooltipSetUnit" },
    { "GameTooltip", "OnTooltipSetItem" },
}

local function say(msg) print("|cffffd100Plotline probe|r " .. msg) end

local function run()
    local out = { build = { GetBuildInfo() }, time = time(), apis = {}, events = {}, scripts = {} }
    local missing = 0
    for _, group in ipairs(CHECKS) do
        local have, lack = {}, {}
        for _, name in ipairs(group[2]) do
            local v = resolve(name)
            out.apis[name] = v ~= nil and type(v) or false
            if v ~= nil then have[#have + 1] = name else lack[#lack + 1] = name; missing = missing + 1 end
        end
        say(("|cffffffff%s|r: %d/%d"):format(group[1], #have, #group[2]))
        if #lack > 0 then print("   |cff9d9d9dmissing:|r " .. table.concat(lack, ", ")) end
    end

    local f, bad = CreateFrame("Frame"), {}
    for _, ev in ipairs(EVENTS) do
        local ok = pcall(f.RegisterEvent, f, ev)
        out.events[ev] = ok
        if ok then f:UnregisterEvent(ev) else bad[#bad + 1] = ev end
    end
    say(("|cffffffffEvents|r: %d/%d"):format(#EVENTS - #bad, #EVENTS))
    if #bad > 0 then print("   |cff9d9d9dunknown:|r " .. table.concat(bad, ", ")) end

    for _, s in ipairs(SCRIPTS) do
        local frame = resolve(s[1])
        local ok = frame and frame.HasScript and frame:HasScript(s[2]) or false
        out.scripts[s[1] .. ":" .. s[2]] = ok
        say(("%s:%s %s"):format(s[1], s[2], ok and "|cff1eff00yes|r" or "|cffff4040no|r"))
    end

    -- Return shapes that differ between client generations.
    if GetQuestLogTitle and GetNumQuestLogEntries and GetNumQuestLogEntries() > 0 then
        local r = { GetQuestLogTitle(1) }
        local shape = {}
        for i = 1, select("#", GetQuestLogTitle(1)) do shape[i] = type(r[i]) end
        out.questLogTitleShape = shape
        say("GetQuestLogTitle(1) returns " .. table.concat(shape, ", "))
    end
    if GetQuestsCompleted then
        local n, t = 0, GetQuestsCompleted()
        for _ in pairs(t or {}) do n = n + 1 end
        out.completedCount = n
        say(("GetQuestsCompleted: %d quests"):format(n))
    end

    PlotlineDB.probe = out
    say(("done, %d APIs missing. Saved to PlotlineDB.probe on /reload or logout."):format(missing))
end

-- Watch mode: report what the quest/gossip APIs return at the next few NPCs.
local watcher, watchLeft, plateSeen, tipSeen = CreateFrame("Frame"), 0, 0, 0

local function keysOf(t)
    local k = {}
    for key in pairs(t or {}) do k[#k + 1] = tostring(key) end
    table.sort(k)
    return table.concat(k, ",")
end

local function record(kind, data)
    local log = PlotlineDB.probeWatch or {}
    PlotlineDB.probeWatch = log
    data.event, data.time = kind, time()
    log[#log + 1] = data
end

watcher:SetScript("OnEvent", function(self, event, ...)
    local npc = UnitGUID("npc")
    if event == "QUEST_DETAIL" then
        local id = GetQuestID and GetQuestID()
        say(("QUEST_DETAIL: GetQuestID() = %s, npc = %s"):format(tostring(id), tostring(npc)))
        record(event, { questID = id, npc = npc })
    elseif event == "GOSSIP_SHOW" then
        local info = { npc = npc }
        if C_GossipInfo and C_GossipInfo.GetAvailableQuests then
            local q = C_GossipInfo.GetAvailableQuests()
            info.available = #q
            info.fields = q[1] and keysOf(q[1]) or ""
            info.ids = {}
            for i, v in ipairs(q) do info.ids[i] = v.questID end
            say(("GOSSIP_SHOW: %d available; fields: %s"):format(#q, info.fields))
        elseif GetGossipAvailableQuests then
            local n = select("#", GetGossipAvailableQuests())
            info.legacyValues = n
            say(("GOSSIP_SHOW (old API): GetGossipAvailableQuests returned %d values"):format(n))
        end
        record(event, info)
    elseif event == "QUEST_GREETING" then
        local n = GetNumAvailableQuests and GetNumAvailableQuests() or 0
        local info = { npc = npc, available = n }
        if n > 0 and GetAvailableQuestInfo then
            info.availableInfo = { GetAvailableQuestInfo(1) }
            for i, v in ipairs(info.availableInfo) do info.availableInfo[i] = tostring(v) end
        end
        say(("QUEST_GREETING: %d available; GetAvailableQuestInfo(1) = %s"):format(n,
            info.availableInfo and table.concat(info.availableInfo, ", ") or "n/a"))
        record(event, info)
    elseif event == "QUEST_ACCEPTED" or event == "QUEST_TURNED_IN" then
        local a, b = ...
        say(("%s: args %s, %s"):format(event, tostring(a), tostring(b)))
        record(event, { arg1 = a, arg2 = b })
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        -- Put a small gold marker on friendly NPC nameplates: if you can see it, attaching our own
        -- icons to nameplates works on this client.
        local unit = ...
        local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit(unit)
        local friendly, player = UnitIsFriend("player", unit), UnitIsPlayer(unit)
        if plate and friendly and not player then
            if not plate.plotlineProbe then
                plate.plotlineProbe = plate:CreateTexture(nil, "OVERLAY")
                plate.plotlineProbe:SetSize(12, 12)
                plate.plotlineProbe:SetPoint("BOTTOM", plate, "TOP", 0, 2)
                plate.plotlineProbe:SetColorTexture(1, 0.82, 0, 1)
            end
            plate.plotlineProbe:Show()
        end
        plateSeen = plateSeen + 1
        if plateSeen <= 8 then
            record(event, { guid = UnitGUID(unit), plate = plate ~= nil, friendly = friendly, player = player,
                            hasUnitFrame = plate and plate.UnitFrame ~= nil or false })
        end
        return
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local plate = C_NamePlate and C_NamePlate.GetNamePlateForUnit(...)
        if plate and plate.plotlineProbe then plate.plotlineProbe:Hide() end
        return
    end
    watchLeft = watchLeft - 1
    if watchLeft <= 0 then
        self:UnregisterAllEvents()
        say("watch finished. /reload to write the results to the SavedVariables file.")
    end
end)

local function watch()
    PlotlineDB.probeWatch = {}
    plateSeen, tipSeen = 0, 0
    for _, ev in ipairs({ "QUEST_DETAIL", "GOSSIP_SHOW", "QUEST_GREETING", "QUEST_ACCEPTED",
                          "QUEST_TURNED_IN", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED" }) do
        pcall(watcher.RegisterEvent, watcher, ev)
    end
    -- Unit tooltips: the modern tooltip system if present, else the old script handler.
    local function onUnitTip(tip, guid)
        if watchLeft <= 0 or not guid then return end
        tip:AddLine("Plotline probe: " .. guid, 1, 0.82, 0)
        tipSeen = tipSeen + 1
        if tipSeen <= 5 then record("TOOLTIP_UNIT", { guid = guid }) end
    end
    if not ns.probeTooltipHooked then
        if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
            ns.probeTooltipHooked = "TooltipDataProcessor"
            TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tip, data)
                if tip == GameTooltip then onUnitTip(tip, data and data.guid) end
            end)
        elseif GameTooltip and GameTooltip:HasScript("OnTooltipSetUnit") then
            ns.probeTooltipHooked = "OnTooltipSetUnit"
            GameTooltip:HookScript("OnTooltipSetUnit", function(tip)
                local _, unit = tip:GetUnit()
                onUnitTip(tip, unit and UnitGUID(unit))
            end)
        end
    end
    watchLeft = 40
    say("watching. Talk to an NPC with chat options as well as quests (an innkeeper or a town quest giver), "
        .. "turn in a quest, hover over a few NPCs, and turn on friendly nameplates (Shift+V): a gold square "
        .. "above friendly NPC nameplates means icons can go there.")
end

ns.probe = { run = run, watch = watch }
