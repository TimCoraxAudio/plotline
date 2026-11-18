-- SPDX-License-Identifier: GPL-3.0-or-later
-- Plotline: records what this character has done, for the Compendium and the Timeline.
--   * people you've spoken to (quest givers, turn-ins, gossip), places you've been, factions
--     you've gained standing with, items quests asked for or gave you; each with the quests
--     involved and when;
--   * the quest text you were shown (accept, progress, completion);
--   * a timeline of accepted and completed quests.
-- All of it is stored per character in PlotlineCharDB, on the player's own machine only.

local _, ns = ...
local R = {}
ns.record = R

local function db() return ns.char end

-- "Creature-0-6808-0-3-2104-D0F15E2D9E" -> "c2104"; game objects -> "o123". Players and pets: nil.
function R.UnitKey(unit)
    local guid = UnitGUID(unit)
    if not guid then return nil end
    local kind, _, _, _, _, id = strsplit("-", guid)
    if kind == "Creature" or kind == "Vehicle" then return "c" .. id end
    if kind == "GameObject" then return "o" .. id end
    return nil
end

local function here()
    local map = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    return map
end

local function mapName(map)
    local info = map and C_Map.GetMapInfo(map)
    return info and info.name or nil
end

-- One entry in a Compendium category: name, first/last seen, times, quests involved.
local function touch(kind, key, name, q, role)
    if not key then return nil end
    local k = db().known[kind]
    local e = k[key]
    local now = time()
    if not e then
        e = { first = now, seen = 0, q = {} }
        k[key] = e
    end
    if name and name ~= "" then e.name = name end
    e.last = now
    e.seen = e.seen + 1
    if q then
        local roles = e.q[q] or ""
        if role and not roles:find(role, 1, true) then roles = roles .. role end
        e.q[q] = roles
    end
    return e
end

function R.MeetUnit(unit, q, role)
    local key = R.UnitKey(unit)
    local e = touch("npc", key, UnitName(unit), q, role)
    if e then
        local map = here()
        if map then e.map = map end
    end
    return key
end

function R.Visit(q, role)
    local map = here()
    if not map then return end
    local name = mapName(map)
    touch("place", map, name, q, role)
    -- the zone above a subzone map too, so "Wetlands" collects Menethil Harbor's quests
    local info = C_Map.GetMapInfo(map)
    if info and info.parentMapID and info.mapType and info.mapType > 3 then
        touch("place", info.parentMapID, mapName(info.parentMapID), q, role)
    end
    -- towns and other subzones mostly have no map of their own: keep them by name
    local sub = GetSubZoneText and GetSubZoneText()
    if sub and sub ~= "" and sub ~= name then
        local e = touch("place", sub, sub, q, role)
        e.parent = map
    end
end

-- Items a quest asks for ("n") or gives ("r"), read from the open quest window.
local function questItems(q)
    local function scan(kind, role, count)
        for i = 1, count or 0 do
            local link = GetQuestItemLink and GetQuestItemLink(kind, i)
            local id = link and tonumber(link:match("item:(%d+)"))
            local name = link and link:match("%[(.-)%]")
            if id then touch("item", id, name, q, role) end
        end
    end
    scan("required", "n", GetNumQuestItems and GetNumQuestItems())
    scan("reward", "r", GetNumQuestRewards and GetNumQuestRewards())
    scan("choice", "r", GetNumQuestChoices and GetNumQuestChoices())
end

local function capture(q, field, text)
    if not q or not text or text == "" then return end
    local t = db().text[q] or {}
    db().text[q] = t
    t[field] = text
end

local function log(event, q, npc)
    local l = db().log
    local last = l[#l]
    if last and last.e == event and last.q == q and time() - last.t < 60 then return end   -- no doubles
    local sub = GetSubZoneText and GetSubZoneText()
    l[#l + 1] = { t = time(), e = event, q = q, npc = npc, map = here(), sub = sub ~= "" and sub or nil }
end

-- Standing changes arrive as chat messages just after a turn-in: "Reputation with X increased by N."
local repPattern
local function factionFromMessage(msg)
    if not repPattern then
        local fmt = FACTION_STANDING_INCREASED or "Reputation with %s increased by %d."
        local p = fmt:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
        p = p:gsub("%%s", "(.-)")
        p = p:gsub("%%d", "%%d+")
        repPattern = "^" .. p .. "$"
    end
    return msg:match(repPattern)
end

local lastTurnIn, lastTurnInTime, lastNpc, lastNpcQuest

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        for _, ev in ipairs({ "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_ACCEPTED",
                              "QUEST_TURNED_IN", "GOSSIP_SHOW", "QUEST_GREETING", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
                              "CHAT_MSG_COMBAT_FACTION_CHANGE" }) do
            pcall(self.RegisterEvent, self, ev)
        end
        R.Visit()
        return
    end
    local q = GetQuestID and GetQuestID()
    if event == "QUEST_DETAIL" then
        lastNpc, lastNpcQuest = R.MeetUnit("npc", q, "g"), q
        capture(q, "d", GetQuestText and GetQuestText())
        capture(q, "o", GetObjectiveText and GetObjectiveText())
        questItems(q)
    elseif event == "QUEST_PROGRESS" then
        R.MeetUnit("npc", q, "e")
        capture(q, "p", GetProgressText and GetProgressText())
    elseif event == "QUEST_COMPLETE" then
        lastNpc, lastNpcQuest = R.MeetUnit("npc", q, "e"), q
        capture(q, "c", GetRewardText and GetRewardText())
        questItems(q)
    elseif event == "GOSSIP_SHOW" or event == "QUEST_GREETING" then
        R.MeetUnit("npc")
    elseif event == "QUEST_ACCEPTED" then
        local id = ...
        if id then
            R.Visit(id, "a")
            log("accept", id, lastNpcQuest == id and lastNpc or nil)
        end
    elseif event == "QUEST_TURNED_IN" then
        local id = ...
        if id then
            R.Visit(id, "d")
            log("done", id, lastNpcQuest == id and lastNpc or nil)
            lastTurnIn, lastTurnInTime = id, GetTime()
        end
    elseif event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_INDOORS" then
        R.Visit()
    elseif event == "CHAT_MSG_COMBAT_FACTION_CHANGE" then
        local name = factionFromMessage((...) or "")
        if name then
            local recent = lastTurnIn and GetTime() - lastTurnInTime < 3
            touch("faction", name, name, recent and lastTurnIn or nil, "d")
        end
    end
    if ns.journal then
        ns.journal.Dirty()
        ns.journal.Refresh()
    end
end)

-- What Plotline knows about a quest's text: captured in game first, then the dev-only file.
function R.Text(q)
    local t = ns.char and ns.char.text and ns.char.text[q]
    if t and (t.d or t.c) then return t, "captured" end
    t = ns.devText and ns.devText[q]
    if t then return t, "dev text" end
    return nil
end

-- Lookup helpers for the Compendium.
function R.Entry(kind, key)
    local k = ns.char and ns.char.known[kind]
    return k and k[key]
end

function R.Each(kind)
    return pairs(ns.char and ns.char.known[kind] or {})
end
