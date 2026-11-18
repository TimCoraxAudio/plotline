-- SPDX-License-Identifier: GPL-3.0-or-later
-- Plotline: hints on the game's own quest windows (docs/DESIGN.md).
--   * a line under the quest title, "Chain name, step 3 of 7", in the quest dialog and the
--     quest log details (both drawn by the game's shared QuestInfo_Display);
--   * a badge in the quest dialog's corner (hover for details, click to show/hide the steps);
--   * a side tab docked to the quest dialog listing the chain's steps. Steps ahead of the
--     current one show as "???" (no spoilers).
-- We only add to Blizzard's frames, after their code runs (hooksecurefunc / events).

local _, ns = ...
local C = ns.chains
local H = {}
ns.hints = H

local LINE_COLOR = { 0.48, 0.31, 0.0 }   -- dark gold, readable on parchment
local TICK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"
local MAX_ROWS = 22                      -- side tab rows before older steps are folded away

local function font(fs, ...)
    for i = 1, select("#", ...) do
        local obj = _G[select(i, ...)]
        if obj then fs:SetFontObject(obj) return end
    end
end

-- ------------------------------------------------------------------ text
local function stepWord(v)
    return ("step %d of %d"):format(v.at or 1, #v.steps)
end

function H.LineText(q)
    local info = q and C.of[q]
    if not info then return nil end
    local v = C.View(info.id, q)
    if not v or not v.at then return nil end
    local name = C.Name(info.id) or "Quest chain"
    if info.kind == "side" then
        return ("%s, side quest"):format(name)
    elseif info.kind == "turnin" then
        return ("%s, reward"):format(name)
    end
    return ("%s, %s"):format(name, stepWord(v))
end

-- ------------------------------------------------------------------ line under the title
local line

local function questForInfo()
    if QuestInfoFrame and QuestInfoFrame.questLog then
        return C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
    end
    return GetQuestID and GetQuestID()
end

-- Point everything that hangs off `from` at `to` instead, so our line pushes it down.
local function reanchor(parent, from, to)
    local function move(r)
        if r == to or not r.GetNumPoints then return end
        local points, hit = {}, false
        for i = 1, r:GetNumPoints() do
            local p, rel, rp, x, y = r:GetPoint(i)
            if rel == from then rel, hit = to, true end
            points[i] = { p, rel, rp, x, y }
        end
        if not hit then return end
        r:ClearAllPoints()
        for _, pt in ipairs(points) do r:SetPoint(pt[1], pt[2], pt[3], pt[4], pt[5]) end
    end
    for _, r in ipairs({ parent:GetRegions() }) do move(r) end
    for _, r in ipairs({ parent:GetChildren() }) do move(r) end
end

function H.UpdateLine()
    local title = QuestInfoTitleHeader
    local q = questForInfo()
    local text = title and title:IsShown() and H.LineText(q)
    if not text then
        if line then line:Hide() end
        H.lineQuest = nil
        return
    end
    if q and not (QuestInfoFrame and QuestInfoFrame.questLog) then C.RememberTitle(q, GetTitleText()) end
    local parent = title:GetParent()
    if not line then
        line = parent:CreateFontString(nil, "ARTWORK")
        font(line, "QuestFontNormalSmall", "GameFontBlackSmall", "GameFontNormalSmall")
        line:SetJustifyH("LEFT")
        line:SetTextColor(unpack(LINE_COLOR))
    end
    line:SetParent(parent)
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    line:SetWidth(title:GetWidth())
    line:SetText(text)
    line:Show()
    H.lineQuest = q
    reanchor(parent, title, line)
end

-- ------------------------------------------------------------------ badge + side tab
local badge, tab
local dialogQuest

local function makeBadge()
    badge = CreateFrame("Button", nil, QuestFrame)
    badge:SetSize(31, 31)
    badge:SetFrameStrata("HIGH")
    badge:SetPoint("TOPRIGHT", QuestFrame, "TOPRIGHT", -8, -26)
    local bg = badge:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(24, 24)
    bg:SetPoint("CENTER")
    local ring = badge:CreateTexture(nil, "OVERLAY")
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetSize(53, 53)
    ring:SetPoint("TOPLEFT")
    badge.text = badge:CreateFontString(nil, "OVERLAY")
    font(badge.text, "GameFontNormalSmall")
    badge.text:SetPoint("CENTER", 0, 1)
    badge:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
    badge:SetScript("OnClick", function()
        PlotlineDB.sideTab = not PlotlineDB.sideTab
        H.UpdateDialog()
        if badge:IsMouseOver() then badge:GetScript("OnEnter")(badge) end
    end)
    badge:SetScript("OnEnter", function(self)
        local info = dialogQuest and C.of[dialogQuest]
        if not info then return end
        local v = C.View(info.id, dialogQuest)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(C.Name(info.id) or "Quest chain", 1, 1, 1)
        local zone = C.ZoneName(info.id)
        if zone then GameTooltip:AddLine(zone, 0.8, 0.8, 0.8) end
        local done = 0
        for _, s in ipairs(v.steps) do if s.done then done = done + 1 end end
        GameTooltip:AddLine(("Step %d of %d"):format(v.at or 1, #v.steps), 1, 0.82, 0)
        GameTooltip:AddLine(("%d %s done"):format(done, done == 1 and "step" or "steps"), 0.6, 0.6, 0.6)
        GameTooltip:AddLine(PlotlineDB.sideTab and "Click to hide the steps" or "Click to show the steps",
            0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function makeTab()
    tab = CreateFrame("Frame", nil, QuestFrame, "BackdropTemplate")
    tab:SetWidth(240)
    tab:SetPoint("TOPLEFT", QuestFrame, "TOPRIGHT", -2, -20)
    tab:SetPoint("BOTTOMLEFT", QuestFrame, "BOTTOMRIGHT", -2, 4)
    tab:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 },
    })
    tab.head = tab:CreateFontString(nil, "OVERLAY")
    font(tab.head, "GameFontNormalLarge", "GameFontNormal")
    tab.head:SetPoint("TOPLEFT", 16, -16)
    tab.head:SetPoint("RIGHT", -14, 0)
    tab.head:SetJustifyH("LEFT")
    tab.sub = tab:CreateFontString(nil, "OVERLAY")
    font(tab.sub, "GameFontHighlightSmall")
    tab.sub:SetPoint("TOPLEFT", tab.head, "BOTTOMLEFT", 0, -3)
    tab.sub:SetJustifyH("LEFT")
    tab.body = tab:CreateFontString(nil, "OVERLAY")
    font(tab.body, "GameFontHighlight")
    tab.body:SetPoint("TOPLEFT", tab.sub, "BOTTOMLEFT", 0, -10)
    tab.body:SetPoint("RIGHT", -14, 0)
    tab.body:SetJustifyH("LEFT")
    tab.body:SetJustifyV("TOP")
    tab.body:SetSpacing(3)
end

-- The step list. Done steps and the current one show titles; steps ahead show "???".
function H.StepRows(v)
    local rows = {}
    local function add(s) rows[#rows + 1] = s end
    for i, s in ipairs(v.steps) do
        local ahead = v.at and i > v.at and not s.done
        local num = ("|cff8a8a8a%d.|r "):format(i)
        if ahead then
            add(num .. "|cff6a6a6a???|r")
        else
            for j, g in ipairs(s.groups) do
                local t = C.GroupTitle(g) or "..."
                local color = (i == v.at and not g.done) and "|cffffffff" or (g.done and "|cffa0a0a0" or "|cffc0c0c0")
                local mark = g.done and (" " .. TICK) or ""
                local count = (j == 1 and i == v.at and #s.groups > 1)
                    and (" |cffffd100(%d/%d)|r"):format(s.nDone, #s.groups) or ""
                add((j == 1 and num or "     ") .. color .. t .. "|r" .. mark .. count)
            end
            -- side quests under their step, branches under a finished fork
            for _, g in ipairs(s.groups) do
                for _, q in ipairs(g.quests) do
                    for _, k in ipairs((v.chain.side or {})[q] or {}) do
                        if C.CanTake(k) then
                            add(("     |cffb9b9b9- %s (side quest)|r%s"):format(C.Title(k) or "...",
                                C.done[k] and (" " .. TICK) or ""))
                        end
                    end
                    if s.done then
                        for _, b in ipairs(v.chain.br or {}) do
                            if b.at == q then
                                add(("     |cff6fb3ffBranch: %s|r"):format(C.Name(b.to) or "..."))
                            end
                        end
                    end
                end
            end
        end
    end
    -- long chains: keep the rows around the current step
    if #rows > MAX_ROWS then
        local cut = #rows - MAX_ROWS + 1
        local atRow = 1
        for r, text in ipairs(rows) do
            if text:find(("^|cff8a8a8a%d%%."):format(v.at or 1)) then atRow = r break end
        end
        cut = math.min(cut, math.max(0, atRow - 6))
        if cut > 0 then
            local kept = { ("|cff8a8a8a(%d earlier rows)|r"):format(cut) }
            for r = cut + 1, math.min(#rows, cut + MAX_ROWS - 1) do kept[#kept + 1] = rows[r] end
            rows = kept
        end
    end
    return rows
end

function H.UpdateDialog(q)
    if q ~= nil then dialogQuest = q end
    local info = dialogQuest and C.of[dialogQuest]
    local v = info and C.View(info.id, dialogQuest)
    if not v or not v.at then
        if badge then badge:Hide() end
        if tab then tab:Hide() end
        return
    end
    if not badge then makeBadge() end
    badge.text:SetText(info.kind == "step" and ("%d/%d"):format(v.at, #v.steps) or "+")
    badge:Show()
    if not PlotlineDB.sideTab then
        if tab then tab:Hide() end
        return
    end
    if not tab then makeTab() end
    tab.head:SetText(C.Name(info.id) or "Quest chain")
    local sub = ("Step %d of %d"):format(v.at, #v.steps)
    if info.kind == "side" then sub = "Side quest at step " .. v.at
    elseif info.kind == "turnin" then sub = "Reward for step " .. v.at end
    tab.sub:SetText(sub)
    tab.body:SetText(table.concat(H.StepRows(v), "\n"))
    tab:Show()
end

-- ------------------------------------------------------------------ events
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        if not C.Init() then return end
        if QuestInfo_Display then hooksecurefunc("QuestInfo_Display", H.UpdateLine) end
        QuestFrame:HookScript("OnShow", function() H.UpdateDialog(GetQuestID and GetQuestID()) end)
        for _, ev in ipairs({ "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_FINISHED",
                              "QUEST_TURNED_IN", "QUEST_DATA_LOAD_RESULT" }) do
            pcall(self.RegisterEvent, self, ev)
        end
        C.onTitle = function()
            if H.lineQuest and line and line:IsShown() then line:SetText(H.LineText(H.lineQuest) or "") end
            if QuestFrame:IsShown() then H.UpdateDialog() end
        end
    elseif event == "QUEST_DETAIL" or event == "QUEST_PROGRESS" or event == "QUEST_COMPLETE" then
        local q = GetQuestID and GetQuestID()
        C.RememberTitle(q, GetTitleText and GetTitleText())
        H.UpdateDialog(q)
    elseif event == "QUEST_FINISHED" then
        dialogQuest = nil
        if badge then badge:Hide() end
        if tab then tab:Hide() end
    elseif event == "QUEST_TURNED_IN" then
        local q = ...
        if q then C.done[q] = true end
    elseif event == "QUEST_DATA_LOAD_RESULT" then
        C.TitleLoaded((...))
    end
end)
