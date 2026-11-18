-- SPDX-License-Identifier: GPL-3.0-or-later
-- Plotline: chain lookups. Which chain a quest is in, which steps this character can take,
-- where they are, and quest titles (asked from the game: the data holds IDs only).

local _, ns = ...
local C = {}
ns.chains = C

C.of = {}      -- [questID] = { id = chain id, kind = "step" | "side" | "turnin", parent = questID }
C.done = {}    -- [questID] = true for completed quests
local titles, pending = {}, {}
local me = {}
local inLog = {}   -- quests in the quest log right now (C.LogQuests)

function C.Init()
    local d = ns.data
    if not d then return false end
    for id, ch in pairs(d.chains) do
        for _, layer in ipairs(ch.s) do
            for _, grp in ipairs(layer) do
                for _, q in ipairs(grp) do C.of[q] = { id = id, kind = "step" } end
            end
        end
        for p, ks in pairs(ch.side or {}) do
            for _, k in ipairs(ks) do C.of[k] = { id = id, kind = "side", parent = p } end
        end
        for p, ks in pairs(ch.t or {}) do
            for _, k in ipairs(ks) do C.of[k] = { id = id, kind = "turnin", parent = p } end
        end
    end
    me.faction = UnitFactionGroup("player") == "Horde" and "H" or "A"
    me.race = select(3, UnitRace("player"))
    me.class = select(3, UnitClass("player"))
    C.LoadCompleted()
    return true
end

function C.LoadCompleted()
    wipe(C.done)
    local ids = C_QuestLog.GetAllCompletedQuestIDs and C_QuestLog.GetAllCompletedQuestIDs()
    for _, q in ipairs(ids or {}) do C.done[q] = true end
end

local function has(list, x)
    for _, v in ipairs(list) do if v == x then return true end end
    return false
end

-- Can this character take quest q? Retired quests (not served by the Forever server) never.
function C.CanTake(q)
    local r = ns.data.quests[q]
    if not r then return true end
    if r.gone then return false end
    if r.f and r.f ~= me.faction then return false end
    if r.r and not has(r.r, me.race) then return false end
    if r.c and not has(r.c, me.class) then return false end
    return true
end

-- The chain as this character sees it. Steps with nothing they can take are skipped; a group
-- (one quest and its variants) is done when any variant is done, a step when all its groups are.
-- focus: the quest being looked at; its step is `at`. Side quests and turn-ins use their parent.
function C.View(id, focus)
    local ch = ns.data.chains[id]
    if not ch then return nil end
    local info = C.of[focus]
    local anchor = (info and info.parent) or focus
    local steps, at = {}, nil
    for _, layer in ipairs(ch.s) do
        local groups, hasFocus, nDone = {}, false, 0
        for _, grp in ipairs(layer) do
            local take, done, isFocus = {}, false, false
            for _, q in ipairs(grp) do
                if C.done[q] then done = true end
                if q == anchor then isFocus = true end
                if C.CanTake(q) or q == anchor then take[#take + 1] = q end
            end
            if #take > 0 then
                groups[#groups + 1] = { quests = take, done = done, focus = isFocus }
                hasFocus = hasFocus or isFocus
                if done then nDone = nDone + 1 end
            end
        end
        if #groups > 0 then
            steps[#steps + 1] = { groups = groups, done = nDone == #groups, nDone = nDone, focus = hasFocus }
            if hasFocus then at = #steps end
        end
    end
    -- A step you didn't do, before one you've done or have in your log, was skipped: Forever made
    -- some steps optional (e.g. the Defias Traitor escort before VanCleef). It doesn't block the chain.
    local reached = 0
    for i, st in ipairs(steps) do
        if st.done or st.focus then reached = i end
        for _, g in ipairs(st.groups) do
            for _, q in ipairs(g.quests) do if inLog[q] then reached = math.max(reached, i) end end
        end
    end
    for i = 1, reached - 1 do
        if not steps[i].done then steps[i].skipped = true end
    end
    return { id = id, chain = ch, steps = steps, at = at, kind = info and info.kind or "step" }
end

-- Quest titles come from the game. A title it hasn't loaded yet comes back nil and is
-- requested; C.onTitle is called when it arrives.
function C.Title(q)
    if not q then return nil end
    if titles[q] then return titles[q] end
    local t = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(q)
    if t and t ~= "" then
        titles[q] = t
        return t
    end
    if C_QuestLog.RequestLoadQuestByID and not pending[q] then
        pending[q] = true
        C_QuestLog.RequestLoadQuestByID(q)
    end
    return nil
end

function C.RememberTitle(q, t)
    if q and t and t ~= "" then titles[q] = t end
end

function C.TitleLoaded(q)
    if pending[q] then
        pending[q] = nil
        if C.onTitle then C.onTitle(q) end
    end
end

-- A group's title: the first of its quests the game knows.
function C.GroupTitle(grp)
    for _, q in ipairs(grp.quests) do
        local t = C.Title(q)
        if t then return t end
    end
    return nil
end

function C.Name(id)
    local ch = ns.data.chains[id]
    return ch and C.Title(ch.n) or nil
end

function C.ZoneName(id)
    local ch = ns.data.chains[id]
    local info = ch and ch.z and C_Map.GetMapInfo and C_Map.GetMapInfo(ch.z)
    return info and info.name or nil
end

-- Text for a quest's card: what the player was shown (captured in game), else the dev-only file
-- Data/DevQuestText.lua if it's there (never in releases). Returns text, source.
function C.QuestText(q)
    return ns.record.Text(q)
end

-- Fill in the game's placeholders for this character: $N name, $C class, $R race,
-- $G male:female; and $B line break.
function C.FillText(t)
    local male = UnitSex("player") ~= 3
    t = t:gsub("%$[Gg]%s*([^:;]*):([^;]*);", function(m, f) return male and m or f end)
    t = t:gsub("%$[Bb]", "\n")
    t = t:gsub("%$[Nn]", (UnitName("player") or "you"))
    t = t:gsub("%$[Cc]", (UnitClass("player") or "adventurer"))
    t = t:gsub("%$[Rr]", (UnitRace("player") or "adventurer"))
    return t
end

-- Quests in the quest log right now.
function C.LogQuests()
    wipe(inLog)
    local n = C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetNumQuestLogEntries() or 0
    for i = 1, n do
        local info = C_QuestLog.GetInfo(i)
        if info and not info.isHeader and info.questID then inLog[info.questID] = true end
    end
    return inLog
end

local function eachQuest(ch, fn)
    for _, layer in ipairs(ch.s) do
        for _, g in ipairs(layer) do for _, q in ipairs(g) do fn(q) end end
    end
    for _, ks in pairs(ch.side or {}) do for _, q in ipairs(ks) do fn(q) end end
    for _, ks in pairs(ch.t or {}) do for _, q in ipairs(ks) do fn(q) end end
end
C.EachQuest = eachQuest

-- Where this character is in a chain, for the Journal. nil if they haven't started it (no quest
-- done or in the log: unstarted chains stay hidden). Otherwise the view (focused on the quest in
-- the log, else the first step not done), the number of steps done, and whether it's complete.
-- Uses C_QuestLog's completed quests, so chains finished before Plotline was installed count.
function C.Progress(id)
    local ch = ns.data.chains[id]
    if not ch then return nil end
    local started, focus = false, nil
    eachQuest(ch, function(q)
        if C.done[q] or inLog[q] then started = true end
        if inLog[q] and not focus and C.of[q] and C.of[q].kind == "step" then focus = q end
    end)
    if not started then return nil end
    local v = C.View(id, focus or -1)
    if not v or #v.steps == 0 then return nil end
    local done = 0
    for _, s in ipairs(v.steps) do if s.done or s.skipped then done = done + 1 end end
    if not focus then
        for _, s in ipairs(v.steps) do
            if not s.done and not s.skipped then focus = s.groups[1].quests[1] break end
        end
        focus = focus or v.steps[#v.steps].groups[1].quests[1]
        v = C.View(id, focus)
    end
    return v, done, done == #v.steps
end
