-- SPDX-License-Identifier: GPL-3.0-or-later
-- Plotline: storylines that run across chains (docs/STORYLINES.md).
--   * sagas: chains (and loose quests) that tell one story, from the overlay (Data/Sagas.lua);
--   * waiting: a started chain whose next step needs a higher level ("continues at level 35");
--   * leads: items in your bags or mailbox that start a quest you haven't done yet, with where
--     they came from (letters from the mail, mostly);
--   * the level-up reminder (setting levelReminder): one chat line per started chain whose next
--     step has just become possible.
-- Spoiler rules: a saga names only the parts this character has started; unseen ones are at most
-- counted (setting sagaHints). Leads name the chain only if you've started it.

local _, ns = ...
local C = ns.chains
local S = {}
ns.story = S

local sagaOf = {}      -- [chain id or questID] = { id = saga id, part = index }
local startedBy = {}   -- [itemID] = { questIDs it starts }
local inLog = {}

local CLASS_SORT = { [61] = 9, [81] = 1, [82] = 7, [141] = 2, [161] = 8, [162] = 4, [261] = 3, [262] = 5, [263] = 11 }

function S.Init()
    local sagas = ns.overlay and ns.overlay.sagas or {}
    for id, sg in pairs(sagas) do
        for i, p in ipairs(sg.parts or {}) do
            local key = p.chain or p.quest
            if key and (not p.chain or ns.data.chains[p.chain]) then sagaOf[key] = { id = id, part = i } end
        end
    end
    for q, r in pairs(ns.data.quests) do
        if r.si then
            startedBy[r.si] = startedBy[r.si] or {}
            table.insert(startedBy[r.si], q)
        end
    end
end

-- ------------------------------------------------------------------ sagas
function S.Saga(id) return ns.overlay and ns.overlay.sagas and ns.overlay.sagas[id] end

function S.SagaName(id)
    local sg = S.Saga(id)
    return sg and C.Title(sg.n) or nil
end

-- The saga a chain (or a loose quest) is part of: saga id, part index.
function S.SagaOf(key)
    local s = sagaOf[key]
    if s then return s.id, s.part end
end

-- A saga part as this character sees it: { chain, quest, started, done, name }.
local function partState(p)
    if p.chain then
        local v, _, complete = C.Progress(p.chain)
        return { chain = p.chain, started = v ~= nil, done = complete or false,
                 name = v and C.DisplayName(p.chain, 20) or nil }
    end
    local q = p.quest
    if not C.CanTake(q) then return nil end
    local started = C.done[q] or inLog[q] or false
    return { quest = q, started = started, done = C.done[q] or false, name = started and C.Title(q) or nil }
end

-- Every part of a saga this character can take, in story order, and how many they've started.
function S.Parts(id)
    local sg = S.Saga(id)
    if not sg then return {}, 0 end
    local out, started = {}, 0
    for i, p in ipairs(sg.parts or {}) do
        if not p.chain or ns.data.chains[p.chain] then
            local st = partState(p)
            if st then
                st.index = i
                out[#out + 1] = st
                if st.started then started = started + 1 end
            end
        end
    end
    return out, started
end

-- "Part of a longer storyline: 2 of 3" for a chain or quest, or nil. Counts chains only (a loose
-- quest is a detour, not a part you'd count).
function S.SagaLine(key)
    local id = S.SagaOf(key)
    if not id then return nil end
    local parts = S.Parts(id)
    local n, at, unseen = 0, nil, 0
    for _, p in ipairs(parts) do
        if p.chain then
            n = n + 1
            if p.chain == key then at = n end
            if not p.started then unseen = unseen + 1 end
        end
    end
    if n < 2 then return nil end
    if unseen > 0 and not PlotlineDB.sagaHints then return nil end   -- would hint at parts not found yet
    if at then return ("Part of a longer storyline: chain %d of %d"):format(at, n), id end
    return "Part of a longer storyline", id
end

-- ------------------------------------------------------------------ waiting
-- The level a chain's next step needs, if that's above the character's level: the lowest minimum
-- level among the next step's quests they can take. nil if nothing waits on level.
function S.WaitingLevel(v, level)
    level = level or UnitLevel("player")
    for _, st in ipairs(v.steps) do
        if not st.done and not st.skipped then
            local need
            for _, g in ipairs(st.groups) do
                if not g.done then
                    for _, q in ipairs(g.quests) do
                        local r = ns.data.quests[q]
                        if inLog[q] then return nil end
                        local ml = r and (r.ml or r.l)
                        if ml then need = need and math.min(need, ml) or ml end
                    end
                end
            end
            if need and need > level then return need end
            return nil
        end
    end
    return nil
end

-- How a quest starts, for its page: "item" (an item or letter starts it), "handin" (handed in
-- at the NPC, never in the quest log), or nil.
function S.Hook(q)
    local r = ns.data.quests[q]
    if not r then return nil end
    if r.ac then return "handin" end
    if r.si then return "item" end
end

-- The class name a chain is filed under (class quests), or nil.
function S.ClassName(id)
    local ch = ns.data.chains[id]
    local cls = ch and ch.cat and CLASS_SORT[ch.cat]
    if not cls then return nil end
    local info = C_CreatureInfo and C_CreatureInfo.GetClassInfo and C_CreatureInfo.GetClassInfo(cls)
    if info and info.className then return info.className end
    return GetClassInfo and (GetClassInfo(cls)) or nil
end

-- ------------------------------------------------------------------ leads
local function leads() return ns.char.leads end

-- Clear leads whose quest is now accepted or done.
function S.TidyLeads()
    for q in pairs(leads()) do
        if C.done[q] or inLog[q] then leads()[q] = nil end
    end
end

local function here()
    return C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
end

local function noteLead(item, from, sender, subject)
    local qs = startedBy[item]
    if not qs then return false end
    local added = false
    for _, q in ipairs(qs) do
        if C.CanTake(q) and not C.done[q] and not inLog[q] then
            local l = leads()[q]
            if not l then
                leads()[q] = { item = item, from = from, sender = sender, subject = subject, t = time(), map = here() }
                added = true
            elseif from == "mail" and l.from ~= "mail" then
                l.from, l.sender, l.subject = "mail", sender, subject   -- the mail says more than the bag
            end
        end
    end
    return added
end

function S.ScanBags()
    local numSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    local itemID = (C_Container and C_Container.GetContainerItemID) or GetContainerItemID
    if not numSlots or not itemID then return end
    local added = false
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, numSlots(bag) or 0 do
            local id = itemID(bag, slot)
            if id and noteLead(id, "bag") then added = true end
        end
    end
    return added
end

function S.ScanMail()
    if not GetInboxNumItems then return end
    local added = false
    for i = 1, GetInboxNumItems() do
        local _, _, sender, subject, _, _, _, hasItem = GetInboxHeaderInfo(i)
        if hasItem then
            for j = 1, ATTACHMENTS_MAX_RECEIVE or 16 do
                local _, id = GetInboxItem(i, j)
                if type(id) ~= "number" and GetInboxItemLink then
                    id = tonumber((GetInboxItemLink(i, j) or ""):match("item:(%d+)"))
                end
                if type(id) == "number" and noteLead(id, "mail", sender, subject) then added = true end
            end
        end
    end
    return added
end

-- Open leads this character can act on, newest first: { q, lead }.
function S.Leads()
    S.TidyLeads()
    local out = {}
    for q, l in pairs(leads()) do out[#out + 1] = { q = q, lead = l } end
    table.sort(out, function(a, b) return (a.lead.t or 0) > (b.lead.t or 0) end)
    return out
end

-- The started chain a lead's quest belongs to, if any (unstarted chains stay hidden).
function S.LeadChain(q)
    local info = C.of[q]
    if info and C.Progress(info.id) then return info.id end
end

-- ------------------------------------------------------------------ level-up reminder
local function remind(old, new)
    if not PlotlineDB.levelReminder then return end
    local msgs = {}
    for id in pairs(ns.data.chains) do
        local v, _, complete = C.Progress(id)
        if v and not complete then
            local before = S.WaitingLevel(v, old)
            if before and before <= new then
                msgs[#msgs + 1] = ("%s can continue (level %d)."):format(C.DisplayName(id, 14), before)
            end
        end
    end
    for _, it in ipairs(S.Leads()) do
        local r = ns.data.quests[it.q]
        local ml = r and r.ml
        if ml and ml > old and ml <= new then
            local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
            local link = select(2, getInfo(it.lead.item)) or "An item you carry"
            msgs[#msgs + 1] = ("%s can start its quest now."):format(link)
        end
    end
    table.sort(msgs)
    for _, m in ipairs(msgs) do print("|cffffd100Plotline|r " .. m) end
    if #msgs > 0 then print("|cffffd100Plotline|r Open the Journal with /pl j.  (Turn these off: /plotline reminders)") end
end

-- ------------------------------------------------------------------ events
local level
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        if not ns.data then return end
        ns.char.leads = ns.char.leads or {}
        S.Init()
        level = UnitLevel("player")
        for _, ev in ipairs({ "PLAYER_LEVEL_UP", "BAG_UPDATE_DELAYED", "MAIL_INBOX_UPDATE",
                              "QUEST_ACCEPTED", "QUEST_TURNED_IN", "QUEST_LOG_UPDATE" }) do
            pcall(self.RegisterEvent, self, ev)
        end
        C_Timer.After(5, function()
            inLog = C.LogQuests()
            S.ScanBags()
        end)
        return
    end
    if event == "PLAYER_LEVEL_UP" then
        local new = ... or UnitLevel("player")
        C.LoadCompleted()
        inLog = C.LogQuests()
        remind(level or new - 1, new)
        level = new
    elseif event == "BAG_UPDATE_DELAYED" then
        if S.ScanBags() and ns.journal then ns.journal.RefreshSoon() end
    elseif event == "MAIL_INBOX_UPDATE" then
        if S.ScanMail() and ns.journal then ns.journal.RefreshSoon() end
    else
        if event == "QUEST_ACCEPTED" or event == "QUEST_TURNED_IN" then
            local q = ...
            if q then ns.char.leads[q] = nil end
        end
        inLog = C.LogQuests()
        S.TidyLeads()
    end
end)
