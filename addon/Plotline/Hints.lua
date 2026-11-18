-- SPDX-License-Identifier: GPL-3.0-or-later
-- Plotline: hints on the game's own quest windows (docs/DESIGN.md).
--   * a line under the quest title, "Chain name, step 3 of 7", in the quest dialog and the
--     quest log details (both drawn by the game's shared QuestInfo_Display);
--   * a badge in the quest dialog's corner, "2/5";
--   * hovering the badge or the line shows the chain's steps in a tooltip. Steps ahead of the
--     current one show as "???" (no spoilers);
--   * clicking the badge or the line pins the steps as a panel. Clicking a step there shows the
--     game's quest card for it; shift-click links it in chat.
-- We only add to Blizzard's frames, after their code runs (hooksecurefunc / events).

local _, ns = ...
local C = ns.chains
local H = {}
ns.hints = H

local hideTip, panel   -- defined with the tooltip and panel code below
local LINE_COLOR = { 0.48, 0.31, 0.0 }   -- dark gold, readable on parchment
local TICK = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"
local MAX_ROWS = 22                      -- tooltip rows before older steps are folded away

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
        if line then line:Hide() line.hover:Hide() end
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
    if panel and panel:IsShown() and line.hover and panel.owner == line.hover and panel.quest ~= q then
        panel:Hide()
    end
    H.lineQuest = q
    if not line.hover then
        line.hover = CreateFrame("Button", nil, parent)   -- clicks only; scrolling passes through
        line.hover:SetScript("OnEnter", function(self) H.ShowSteps(self, H.lineQuest) end)
        line.hover:SetScript("OnLeave", hideTip)
        line.hover:SetScript("OnClick", function(self)
            H.TogglePanel(self, H.lineQuest, WorldMapFrame or UIParent)
        end)
    end
    line.hover:SetParent(parent)
    line.hover:ClearAllPoints()
    line.hover:SetPoint("TOPLEFT", line, "TOPLEFT")
    line.hover:SetPoint("BOTTOMLEFT", line, "BOTTOMLEFT")
    line.hover:SetWidth(math.max(20, line:GetStringWidth()))
    line.hover:Show()
    reanchor(parent, title, line)
end

-- ------------------------------------------------------------------ badge + steps tooltip
local badge, dialogQuest

-- The chain's steps as a tooltip on `owner`, for quest q.
local function subtitle(info, v)
    local sub = ("Step %d of %d"):format(v.at, #v.steps)
    if info.kind == "side" then sub = "Side quest at step " .. v.at
    elseif info.kind == "turnin" then sub = "Reward for step " .. v.at end
    local zone = C.ZoneName(info.id)
    return zone and (sub .. ", " .. zone) or sub
end

function H.ShowSteps(owner, q)
    if panel and panel:IsShown() and panel.owner == owner then return end
    local info = q and C.of[q]
    local v = info and C.View(info.id, q)
    if not v or not v.at then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:AddLine(C.Name(info.id) or "Quest chain")
    GameTooltip:AddLine(subtitle(info, v), 1, 1, 1)
    GameTooltip:AddLine(" ")
    for _, row in ipairs(H.StepRows(v)) do GameTooltip:AddLine(row.text, 1, 1, 1) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to pin, then click a quest for its details", 0.5, 0.5, 0.5)
    GameTooltip:Show()
    H.tipOwner, H.tipQuest = owner, q
end

function hideTip(owner)
    if GameTooltip:GetOwner() == owner then GameTooltip:Hide() end
    H.tipOwner, H.tipQuest = nil, nil
end

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
    badge:SetScript("OnEnter", function(self) H.ShowSteps(self, dialogQuest) end)
    badge:SetScript("OnLeave", hideTip)
    badge:SetScript("OnClick", function(self) H.TogglePanel(self, dialogQuest, QuestFrame) end)
end

-- The step list. Done steps and the current one show titles; steps ahead show "???".
function H.StepRows(v)
    local rows = {}
    local function add(text, q) rows[#rows + 1] = { text = text, q = q } end
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
                local pick = g.quests[1]
                for _, q in ipairs(g.quests) do if C.done[q] then pick = q break end end
                add((j == 1 and num or "     ") .. color .. t .. "|r" .. mark .. count, pick)
            end
            -- side quests under their step, branches under a finished fork
            for _, g in ipairs(s.groups) do
                for _, q in ipairs(g.quests) do
                    for _, k in ipairs((v.chain.side or {})[q] or {}) do
                        if C.CanTake(k) then
                            add(("     |cffb9b9b9- %s (side quest)|r%s"):format(C.Title(k) or "...",
                                C.done[k] and (" " .. TICK) or ""), k)
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
        for r, row in ipairs(rows) do
            if row.text:find(("^|cff8a8a8a%d%%."):format(v.at or 1)) then atRow = r break end
        end
        cut = math.min(cut, math.max(0, atRow - 6))
        if cut > 0 then
            local kept = { { text = ("|cff8a8a8a(%d earlier rows)|r"):format(cut) } }
            for r = cut + 1, math.min(#rows, cut + MAX_ROWS - 1) do kept[#kept + 1] = rows[r] end
            rows = kept
        end
    end
    return rows
end

-- ------------------------------------------------------------------ pinned panel + quest card
local card
local ROW_H, PAD = 16, 10

local function newFrame(kind, parent, template, fallback)
    local ok, frame = pcall(CreateFrame, kind, nil, parent, template)
    if ok then return frame end
    return CreateFrame(kind, nil, parent, fallback)
end

-- The game's own quest card (what a quest link in chat shows), beside the panel.
-- Later: the description and completion text captured when the player did the quest.
function H.ShowCard(q, anchor)
    if not card then
        card = CreateFrame("GameTooltip", "PlotlineQuestCard", UIParent, "GameTooltipTemplate")
    end
    card:SetOwner(anchor, "ANCHOR_NONE")
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 2, 0)
    local ok = pcall(card.SetHyperlink, card, ("quest:%d:-1"):format(q))
    if not ok or card:NumLines() == 0 then
        card:AddLine(C.Title(q) or ("Quest " .. q), 1, 0.82, 0)
        card:AddLine("The game has no details for this quest yet.", 0.7, 0.7, 0.7, true)
    end
    card:Show()
    H.cardQuest = q
end

local function hideCard()
    if card then card:Hide() end
    H.cardQuest = nil
end

local function makePanel()
    panel = newFrame("Frame", UIParent, "TooltipBackdropTemplate", "BackdropTemplate")
    if not panel.NineSlice and panel.SetBackdrop then
        panel:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        panel:SetBackdropColor(0, 0, 0, 0.9)
    end
    panel:EnableMouse(true)
    panel:SetClampedToScreen(true)
    panel:Hide()
    panel.head = panel:CreateFontString(nil, "OVERLAY")
    font(panel.head, "GameFontNormal")
    panel.head:SetPoint("TOPLEFT", PAD, -PAD)
    panel.sub = panel:CreateFontString(nil, "OVERLAY")
    font(panel.sub, "GameFontHighlightSmall")
    panel.sub:SetPoint("TOPLEFT", panel.head, "BOTTOMLEFT", 0, -2)
    panel.foot = panel:CreateFontString(nil, "OVERLAY")
    font(panel.foot, "GameFontDisableSmall", "GameFontHighlightSmall")
    panel.foot:SetText("Click a quest for its details. Shift-click to link it.")
    panel.rows = {}
    panel:SetScript("OnHide", hideCard)
end

local function panelRow(i)
    local r = panel.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, panel)
    r:SetHeight(ROW_H)
    r.text = r:CreateFontString(nil, "OVERLAY")
    font(r.text, "GameFontHighlight")
    r.text:SetPoint("LEFT")
    r.text:SetJustifyH("LEFT")
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    r:SetScript("OnClick", function(self)
        if not self.q then return end
        if IsModifiedClick and IsModifiedClick("CHATLINK") and ChatEdit_InsertLink then
            ChatEdit_InsertLink(("|cffffff00|Hquest:%d:-1|h[%s]|h|r"):format(self.q, C.Title(self.q) or self.q))
        elseif H.cardQuest == self.q then
            hideCard()
        else
            H.ShowCard(self.q, panel)
        end
    end)
    panel.rows[i] = r
    return r
end

function H.FillPanel()
    local q = panel.quest
    local info = q and C.of[q]
    local v = info and C.View(info.id, q)
    if not v or not v.at then panel:Hide() return end
    panel.head:SetText(C.Name(info.id) or "Quest chain")
    panel.sub:SetText(subtitle(info, v))
    local rows = H.StepRows(v)
    local width = math.max(panel.head:GetStringWidth(), panel.sub:GetStringWidth(), panel.foot:GetStringWidth())
    local top = PAD + panel.head:GetStringHeight() + 2 + panel.sub:GetStringHeight() + 8
    for i, rec in ipairs(rows) do
        local r = panelRow(i)
        r.q = rec.q
        r.text:SetText(rec.text)
        r:SetEnabled(rec.q ~= nil)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -(top + (i - 1) * ROW_H))
        width = math.max(width, r.text:GetStringWidth())
        r:Show()
    end
    for i = #rows + 1, #panel.rows do panel.rows[i]:Hide() end
    for i = 1, #rows do panel.rows[i]:SetWidth(width) end
    local bottom = top + #rows * ROW_H + 6
    panel.foot:ClearAllPoints()
    panel.foot:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -bottom)
    panel:SetSize(width + 2 * PAD, bottom + panel.foot:GetStringHeight() + PAD)
end

-- Pin the steps for quest q beside `owner`; a second click on the same owner unpins.
-- The panel belongs to `host` (the quest dialog or the world map), so it closes with it.
function H.GetPanel() return panel end

function H.TogglePanel(owner, q, host)
    if not panel then makePanel() end
    if panel:IsShown() and panel.owner == owner then
        panel:Hide()
        return
    end
    if GameTooltip:GetOwner() == owner then GameTooltip:Hide() end
    hideCard()
    panel.owner, panel.quest = owner, q
    panel:SetParent(host)
    panel:SetFrameStrata("DIALOG")
    panel:ClearAllPoints()
    panel:SetPoint("TOPLEFT", owner, "TOPRIGHT", 4, 0)
    H.FillPanel()
    panel:Show()
end

function H.UpdateDialog(q)
    if q ~= nil then dialogQuest = q end
    local info = dialogQuest and C.of[dialogQuest]
    local v = info and C.View(info.id, dialogQuest)
    if not v or not v.at then
        if badge then badge:Hide() end
        return
    end
    if not badge then makeBadge() end
    badge.text:SetText(info.kind == "step" and ("%d/%d"):format(v.at, #v.steps) or "+")
    badge:Show()
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
            if H.tipOwner and GameTooltip:GetOwner() == H.tipOwner then H.ShowSteps(H.tipOwner, H.tipQuest) end
            if panel and panel:IsShown() then H.FillPanel() end
        end
    elseif event == "QUEST_DETAIL" or event == "QUEST_PROGRESS" or event == "QUEST_COMPLETE" then
        local q = GetQuestID and GetQuestID()
        C.RememberTitle(q, GetTitleText and GetTitleText())
        H.UpdateDialog(q)
    elseif event == "QUEST_FINISHED" then
        dialogQuest = nil
        if badge then badge:Hide() end
        if panel and badge and panel.owner == badge then panel:Hide() end
    elseif event == "QUEST_TURNED_IN" then
        local q = ...
        if q then C.done[q] = true end
    elseif event == "QUEST_DATA_LOAD_RESULT" then
        C.TitleLoaded((...))
    end
end)
