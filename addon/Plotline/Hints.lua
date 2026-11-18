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
local LINE_COLOR = { 0.32, 0.32, 0.32 }  -- grey on parchment
local LINE_HOVER = { 0.05, 0.05, 0.05 }  -- darker while hovered: it's clickable
local LOG_BADGE = 22                     -- the small badge at the start of the line in the quest log
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

-- The round badge ("2/5"): the game's minimap-button ring around a dark disc. `size` in pixels.
function H.DecorateBadge(b, size)
    local k = size / 31
    b:SetSize(size, size)
    -- The ring sits off-centre in its texture: at 50 px (LibDBIcon's size for a 31 px button) its
    -- centre is about (15.5, 14.5) from the top-left. Place it so that centre is the button's centre,
    -- then centre the disc and the text there too.
    local ring = b:CreateTexture(nil, "OVERLAY")
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetSize(50 * k, 50 * k)
    ring:SetPoint("TOPLEFT", b, "CENTER", -15.5 * k, 14.5 * k)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(22 * k, 22 * k)
    bg:SetPoint("CENTER")
    b.glow = b:CreateTexture(nil, "OVERLAY", nil, 1)
    b.glow:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    b.glow:SetBlendMode("ADD")
    b.glow:SetAllPoints()
    b.glow:Hide()
    b.text = b:CreateFontString(nil, "OVERLAY", nil, 2)
    font(b.text, size < 28 and "GameFontNormalTiny" or "GameFontNormalSmall", "GameFontNormalSmall")
    b.text:SetWidth(size)
    b.text:SetJustifyH("CENTER")
    b.text:SetPoint("CENTER", b, "CENTER", 0.5, 0)
end

function H.BadgeText(q)
    local info = q and C.of[q]
    local v = info and C.View(info.id, q)
    if not v or not v.at then return nil end
    return info.kind == "step" and ("%d/%d"):format(v.at, #v.steps) or "+"
end

-- The quest log's Back button: our badge sits right of it, in the row at the top of the details.
local function logBackButton()
    local q = QuestMapFrame
    if not q then return nil end
    for _, d in ipairs({ q.QuestsFrame and q.QuestsFrame.DetailsFrame, q.DetailsFrame }) do
        local b = d and ((d.BackFrame and d.BackFrame.BackButton) or d.BackButton)
        if b then return b end
    end
    return nil
end

local logBadge
local function showLogBadge(q)
    local back = logBackButton()
    if not back then
        if logBadge then logBadge:Hide() end
        return false
    end
    if not logBadge then
        logBadge = CreateFrame("Button", nil, back:GetParent())
        H.DecorateBadge(logBadge, 26)
        logBadge:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
        logBadge:SetScript("OnEnter", function(self) H.ShowSteps(self, H.lineQuest) end)
        logBadge:SetScript("OnLeave", hideTip)
        logBadge:SetScript("OnClick", function(self) H.TogglePanel(self, H.lineQuest, WorldMapFrame or UIParent) end)
    end
    logBadge:SetParent(back:GetParent())
    logBadge:SetFrameLevel(back:GetFrameLevel() + 1)
    logBadge:ClearAllPoints()
    logBadge:SetPoint("LEFT", back, "RIGHT", 8, 0)
    logBadge.text:SetText(H.BadgeText(q) or "")
    logBadge:Show()
    return true
end

local function lineHover(on)
    line.text:SetTextColor(unpack(on and LINE_HOVER or LINE_COLOR))
    line.badge.glow:SetShown(on)
end

-- The line under the title is one button: "Chain name, step 2 of 6". The quest dialog has its badge
-- in the corner; the quest log has one in the row with its Back button (or, failing that, inline).
function H.UpdateLine()
    local title = QuestInfoTitleHeader
    local q = questForInfo()
    local text = title and title:IsShown() and H.LineText(q)
    if not text then
        if line then line:Hide() end
        if logBadge then logBadge:Hide() end
        if panel and line and (panel.owner == line or panel.owner == logBadge) then panel:Hide() end
        H.lineQuest = nil
        return
    end
    local inLog = QuestInfoFrame and QuestInfoFrame.questLog
    if q and not inLog then C.RememberTitle(q, GetTitleText()) end
    local parent = title:GetParent()
    if not line then
        line = CreateFrame("Button", nil, parent)   -- clicks only; scrolling passes through
        line.text = line:CreateFontString(nil, "ARTWORK")
        font(line.text, "QuestFontNormalSmall", "GameFontBlackSmall", "GameFontNormalSmall")
        line.text:SetJustifyH("LEFT")
        line.text:SetShadowOffset(0, 0)
        line.badge = CreateFrame("Frame", nil, line)
        H.DecorateBadge(line.badge, LOG_BADGE)
        line.badge:SetPoint("LEFT", line, "LEFT", 0, 0)
        line:SetScript("OnEnter", function(self)
            lineHover(true)
            H.ShowSteps(self, H.lineQuest)
        end)
        line:SetScript("OnLeave", function(self)
            lineHover(false)
            hideTip(self)
        end)
        -- the pinned panel belongs to the window the line is in now: the map or the dialog
        line:SetScript("OnClick", function(self)
            local log = QuestInfoFrame and QuestInfoFrame.questLog
            H.TogglePanel(self, H.lineQuest, log and (WorldMapFrame or UIParent) or QuestFrame)
        end)
    end
    if panel and panel:IsShown() and (panel.owner == line or (logBadge and panel.owner == logBadge))
            and panel.quest ~= q then
        panel:Hide()
    end
    H.lineQuest = q
    line:SetParent(parent)
    line:ClearAllPoints()
    line:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -3)
    local full = title:GetWidth()
    -- in the quest log the badge goes in the Back button's row; inline only if that row isn't found
    local inline = false
    if inLog then
        inline = not showLogBadge(q)
    elseif logBadge then
        logBadge:Hide()
    end
    local offset = inline and (LOG_BADGE + 4) or 0
    line.badge:SetShown(inline)
    line.badge.text:SetText(H.BadgeText(q) or "")
    line.text:ClearAllPoints()
    line.text:SetPoint("LEFT", line, "LEFT", offset, 0)
    line.text:SetWidth(full - offset)
    line.text:SetText(text)
    lineHover(line:IsMouseOver() and true or false)
    local textW = math.min(line.text:GetStringWidth(), full - offset)
    local h = line.text:GetStringHeight()
    line:SetSize(offset + math.max(20, textW), math.max(h, inline and LOG_BADGE or 0))
    line:Show()
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
    badge:SetFrameStrata("HIGH")
    -- Spoken puts a round button in this corner of the quest dialog: sit just left of it then
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    local spoken = isLoaded and isLoaded("Spoken_Quests")
    badge:SetPoint("TOPRIGHT", QuestFrame, "TOPRIGHT", spoken and -38 or -8, -26)
    H.DecorateBadge(badge, 31)
    badge:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight", "ADD")
    badge:SetScript("OnEnter", function(self) H.ShowSteps(self, dialogQuest) end)
    badge:SetScript("OnLeave", hideTip)
    badge:SetScript("OnClick", function(self) H.TogglePanel(self, dialogQuest, QuestFrame) end)
end

-- Colours for the step list: light text for the dark tooltip, dark ink for the parchment panel.
H.DARK = { num = "8a8a8a", ahead = "6a6a6a", cur = "ffffff", done = "a0a0a0", other = "c0c0c0",
           side = "b9b9b9", branch = "6fb3ff", count = "ffd100" }
H.PARCH = { num = "7a6a50", ahead = "9a8a6a", cur = "000000", done = "5e4c36", other = "3e3020",
            side = "4a3c2a", branch = "1a3a7a", count = "7a4f00" }

-- The step list, one record per row: { text, q = quest to open, step, cur }. Done steps and the
-- current one show titles; steps ahead show "???".
function H.StepRows(v, pal)
    pal = pal or H.DARK
    local function c(key, text) return "|cff" .. pal[key] .. text .. "|r" end
    local rows = {}
    local function add(text, q, step, cur) rows[#rows + 1] = { text = text, q = q, step = step, cur = cur } end
    for i, s in ipairs(v.steps) do
        local ahead = v.at and i > v.at and not s.done
        local num = c("num", i .. ".") .. " "
        if ahead then
            add(num .. c("ahead", "???"), nil, i)
        else
            for j, g in ipairs(s.groups) do
                local t = C.GroupTitle(g) or "..."
                local isCur = i == v.at and not g.done
                local key = isCur and "cur" or (g.done and "done" or "other")
                local mark = g.done and (" " .. TICK) or ""
                local count = (j == 1 and i == v.at and #s.groups > 1)
                    and (" " .. c("count", ("(%d/%d)"):format(s.nDone, #s.groups))) or ""
                local pick = g.quests[1]
                for _, q in ipairs(g.quests) do if C.done[q] then pick = q break end end
                add((j == 1 and num or "     ") .. c(key, t) .. mark .. count, pick, j == 1 and i or nil, isCur)
            end
            -- side quests under their step, branches under a finished fork
            for _, g in ipairs(s.groups) do
                for _, q in ipairs(g.quests) do
                    for _, k in ipairs((v.chain.side or {})[q] or {}) do
                        if C.CanTake(k) then
                            add("     " .. c("side", "- " .. (C.Title(k) or "...") .. " (side quest)")
                                .. (C.done[k] and (" " .. TICK) or ""), k)
                        end
                    end
                    if s.done then
                        for _, b in ipairs(v.chain.br or {}) do
                            if b.at == q then add("     " .. c("branch", "Branch: " .. (C.Name(b.to) or "..."))) end
                        end
                    end
                end
            end
        end
    end
    -- long chains: keep the rows around the current step
    if #rows > MAX_ROWS then
        local atRow = 1
        for r, row in ipairs(rows) do
            if row.step == v.at then atRow = r break end
        end
        local cut = math.min(#rows - MAX_ROWS + 1, math.max(0, atRow - 6))
        if cut > 0 then
            local kept = { { text = c("num", ("(%d earlier rows)"):format(cut)) } }
            for r = cut + 1, math.min(#rows, cut + MAX_ROWS - 1) do kept[#kept + 1] = rows[r] end
            rows = kept
        end
    end
    return rows
end

-- ------------------------------------------------------------------ pinned panel + quest card
local card
local ROW_H, PAD = 17, 10

local function newFrame(kind, parent, template, fallback)
    local ok, frame = pcall(CreateFrame, kind, nil, parent, template)
    if ok then return frame end
    return CreateFrame(kind, nil, parent, fallback)
end

local function hideCard()
    if card then card:Hide() end
    H.cardQuest = nil
end

-- Does `f` fit on screen to the right of `beside`?
local function fitsRight(f, beside)
    local right = beside:GetRight()
    if not right then return true end
    local screen = GetScreenWidth() * UIParent:GetEffectiveScale()
    return screen - right * beside:GetEffectiveScale() >= f:GetWidth() * f:GetEffectiveScale() + 8
end

-- The game's own quest card (what a quest link in chat shows), beside the panel.
-- Plus the quest's text (C.QuestText): dev text for now, captured text later.
function H.ShowCard(q, anchor)
    if not card then
        card = CreateFrame("GameTooltip", "PlotlineQuestCard", UIParent, "GameTooltipTemplate")
        local ok, close = pcall(CreateFrame, "Button", nil, card, "UIPanelCloseButton")
        if not ok then
            close = CreateFrame("Button", nil, card)
            close:SetSize(24, 24)
            close:SetNormalTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Up")
            close:SetPushedTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Down")
            close:SetHighlightTexture("Interface\\Buttons\\UI-Panel-MinimizeButton-Highlight", "ADD")
        end
        close:SetPoint("TOPRIGHT", card, "TOPRIGHT", 1, 1)
        close:SetScript("OnClick", function() hideCard() end)
        card.close = close
    end
    card:SetParent(anchor)
    card:SetFrameStrata("TOOLTIP")
    card:SetOwner(anchor, "ANCHOR_NONE")
    card:ClearAllPoints()
    card:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    local ok = pcall(card.SetHyperlink, card, ("quest:%d:-1"):format(q))
    local text, source = C.QuestText(q)
    if not ok or card:NumLines() == 0 then
        card:AddLine(C.Title(q) or ("Quest " .. q), 1, 0.82, 0)
        if not text then card:AddLine("The game has no details for this quest yet.", 0.7, 0.7, 0.7, true) end
    end
    if text then
        if card.SetMinimumWidth then card:SetMinimumWidth(320) end
        if text.d then
            card:AddLine(" ")
            card:AddLine("Description", 1, 0.82, 0)
            card:AddLine(C.FillText(text.d), 1, 1, 1, true)
        end
        -- the hand-in text tells how a quest ends: only for quests already done
        if text.c and C.done[q] then
            card:AddLine(" ")
            card:AddLine("Completion", 1, 0.82, 0)
            card:AddLine(C.FillText(text.c), 1, 1, 1, true)
        end
        if source ~= "captured" then
            card:AddLine(" ")
            card:AddLine(("(%s, not captured in game)"):format(source), 0.5, 0.5, 0.5)
        end
    end
    if card.SetPadding then card:SetPadding(18, 0) end   -- room for the close button
    card:Show()
    -- beside the panel if there's room and the panel isn't already over the map; else below it
    card:ClearAllPoints()
    if not (panel and panel.overMap) and fitsRight(card, anchor) then
        card:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 2, 0)
    else
        card:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
    end
    H.cardQuest = q
end

-- Copy the look of an existing game texture (atlas or file) onto tex. True if one was found.
local function borrow(tex, ...)
    for i = 1, select("#", ...) do
        local src = select(i, ...)
        if type(src) == "string" then
            if (not C_Texture or not C_Texture.GetAtlasInfo or C_Texture.GetAtlasInfo(src)) and tex:SetAtlas(src) ~= false then
                return true
            end
        elseif src and src.GetAtlas then
            local atlas = src:GetAtlas()
            if atlas then tex:SetAtlas(atlas) return true end
            local file = src:GetTexture()
            if file then
                tex:SetTexture(file)
                tex:SetTexCoord(src:GetTexCoord())
                return true
            end
        end
    end
    return false
end

local INSET_TOP = 62   -- below the title bar and the progress line

-- A small window in the game's own frame style (title bar, close button), with the quest log's
-- parchment inside.
local function makePanel()
    panel = newFrame("Frame", UIParent, "ButtonFrameTemplate", "BackdropTemplate")
    if ButtonFrameTemplate_HidePortrait and (panel.PortraitContainer or panel.portrait) then
        ButtonFrameTemplate_HidePortrait(panel)
    end
    if ButtonFrameTemplate_HideButtonBar and panel.Inset then ButtonFrameTemplate_HideButtonBar(panel) end
    if not panel.Inset and panel.SetBackdrop then   -- template missing: plain dialog look
        panel:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border", tile = true, tileSize = 32, edgeSize = 24,
            insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    end
    panel:EnableMouse(true)
    panel:SetClampedToScreen(true)
    panel:Hide()

    -- parchment page
    local page = CreateFrame("Frame", nil, panel)
    page:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -INSET_TOP)
    page:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 8)
    page.bg = page:CreateTexture(nil, "BACKGROUND")
    page.bg:SetAllPoints()
    local details = QuestMapFrame and QuestMapFrame.QuestsFrame and QuestMapFrame.QuestsFrame.DetailsFrame
    if not borrow(page.bg, details and details.Bg, QuestFrameDetailPanel and QuestFrameDetailPanel.Bg,
                  "QuestBG-Parchment", "QuestDetailsBackgrounds") then
        page.bg:SetColorTexture(0.87, 0.78, 0.6, 1)
    end
    if panel.Inset then panel.Inset:Hide() end
    panel.page = page

    -- chain name in the title bar; zone and progress under it
    panel.title = panel.TitleText or (panel.TitleContainer and panel.TitleContainer.TitleText)
    if not panel.title then
        panel.title = panel:CreateFontString(nil, "OVERLAY")
        font(panel.title, "GameFontNormal")
        panel.title:SetPoint("TOP", 0, -6)
    end
    panel.sub = panel:CreateFontString(nil, "OVERLAY")
    font(panel.sub, "GameFontHighlightSmall")
    panel.sub:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -30)
    panel.bar = CreateFrame("StatusBar", nil, panel)
    panel.bar:SetPoint("TOPLEFT", panel.sub, "BOTTOMLEFT", 0, -4)
    panel.bar:SetPoint("RIGHT", panel, "RIGHT", -12, 0)
    panel.bar:SetHeight(8)
    panel.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    panel.bar:SetStatusBarColor(0.85, 0.65, 0.13)
    panel.bar.bg = panel.bar:CreateTexture(nil, "BACKGROUND")
    panel.bar.bg:SetAllPoints()
    panel.bar.bg:SetColorTexture(0, 0, 0, 0.5)

    panel.foot = page:CreateFontString(nil, "OVERLAY")
    font(panel.foot, "GameFontBlackSmall", "GameFontHighlightSmall")
    panel.foot:SetTextColor(0.42, 0.34, 0.22)
    panel.foot:SetText("Click a quest for its details. Shift-click to link it.")
    panel.rows = {}
    panel:SetScript("OnHide", function(self)
        self:Hide()   -- also when the map or dialog it belongs to closes, so it doesn't reopen with it
        hideCard()
    end)
end

-- Put a link to quest q in chat: into the open chat box, or open one with it.
function H.LinkQuest(q)
    local link = GetQuestLink and GetQuestLink(q)
    if not link or link == "" then
        link = ("|cffffff00|Hquest:%d:-1|h[%s]|h|r"):format(q, C.Title(q) or ("Quest " .. q))
    end
    if ChatEdit_InsertLink and ChatEdit_InsertLink(link) then return end
    if ChatFrame_OpenChat then ChatFrame_OpenChat(link) end
end

local function panelRow(i)
    local r = panel.rows[i]
    if r then return r end
    r = CreateFrame("Button", nil, panel.page)
    r:SetHeight(ROW_H)
    r.cur = r:CreateTexture(nil, "BACKGROUND")
    r.cur:SetPoint("TOPLEFT", -4, 1)
    r.cur:SetPoint("BOTTOMRIGHT", 4, -1)
    r.cur:SetColorTexture(0.85, 0.65, 0.13, 0.22)
    r.text = r:CreateFontString(nil, "OVERLAY")
    font(r.text, "QuestFont", "GameFontBlack", "GameFontHighlight")
    r.text:SetShadowOffset(0, 0)
    r.text:SetPoint("LEFT")
    r.text:SetJustifyH("LEFT")
    r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    r:SetScript("OnClick", function(self)
        if not self.q then return end
        if IsModifiedClick and IsModifiedClick("CHATLINK") then
            H.LinkQuest(self.q)
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
    panel.title:SetText(C.Name(info.id) or "Quest chain")
    local done = 0
    for _, s in ipairs(v.steps) do if s.done then done = done + 1 end end
    panel.sub:SetText(("%s  |cffa0a0a0(%d of %d done)|r"):format(subtitle(info, v), done, #v.steps))
    panel.bar:SetMinMaxValues(0, #v.steps)
    panel.bar:SetValue(done)
    local rows = H.StepRows(v, H.PARCH)
    local width = math.max(220, panel.title:GetStringWidth() + 70, panel.sub:GetStringWidth(),
                           panel.foot:GetStringWidth())
    local top = 10
    for i, rec in ipairs(rows) do
        local r = panelRow(i)
        r.q = rec.q
        r.text:SetText(rec.text)
        r:SetEnabled(rec.q ~= nil)
        r.cur:SetShown(rec.cur == true)
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", panel.page, "TOPLEFT", PAD, -(top + (i - 1) * ROW_H))
        width = math.max(width, r.text:GetStringWidth())
        r:Show()
    end
    for i = #rows + 1, #panel.rows do panel.rows[i]:Hide() end
    for i = 1, #rows do panel.rows[i]:SetWidth(width) end
    local bottom = top + #rows * ROW_H + 8
    panel.foot:ClearAllPoints()
    panel.foot:SetPoint("TOPLEFT", panel.page, "TOPLEFT", PAD, -bottom)
    panel:SetSize(width + 2 * PAD + 30, INSET_TOP + bottom + panel.foot:GetStringHeight() + PAD + 8)
end

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
    H.FillPanel()
    -- outside the window it belongs to, on the right; with no room there (e.g. a fullscreen map),
    -- over the map beside the quest log, or left of the quest dialog. Never over the quest text.
    panel:ClearAllPoints()
    panel.overMap = false
    if fitsRight(panel, host) then
        panel:SetPoint("TOPLEFT", host, "TOPRIGHT", 2, -24)
    elseif host == WorldMapFrame and QuestMapFrame and QuestMapFrame:GetLeft() then
        panel:SetPoint("TOPRIGHT", QuestMapFrame, "TOPLEFT", -6, -24)
        panel.overMap = true
    else
        panel:SetPoint("TOPRIGHT", host, "TOPLEFT", -2, -24)
    end
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
    badge.text:SetText(H.BadgeText(dialogQuest) or "")
    badge:Show()
end

-- ------------------------------------------------------------------ quest tracker
-- A grey "2/5" after the title of each tracked quest that's in a chain. It's our own label on the
-- tracker's quest block: the tracker's text is left alone (writing to it risks "action blocked"
-- errors with quest item buttons). Hover for the steps, click to pin them.
local TRACKER_COLOR = { 0.6, 0.6, 0.6 }

local function trackerMark(block)
    local q = block.id
    local text = q and C.of[q] and H.BadgeText(q)
    local mark = block.plotlineMark
    if not text or not block.HeaderText or not block.HeaderText:IsShown() then
        if mark then mark:Hide() end
        return
    end
    if not mark then
        mark = CreateFrame("Button", nil, block)
        mark.text = mark:CreateFontString(nil, "OVERLAY")
        font(mark.text, "ObjectiveTrackerLineFont", "GameFontNormalSmall")
        mark.text:SetPoint("LEFT")
        mark.text:SetTextColor(unpack(TRACKER_COLOR))
        mark:SetScript("OnEnter", function(self)
            self.text:SetTextColor(1, 1, 1)
            H.ShowSteps(self, self.quest)
        end)
        mark:SetScript("OnLeave", function(self)
            self.text:SetTextColor(unpack(TRACKER_COLOR))
            hideTip(self)
        end)
        mark:SetScript("OnClick", function(self)
            H.TogglePanel(self, self.quest, ObjectiveTrackerFrame or UIParent)
        end)
        block.plotlineMark = mark
    end
    mark.quest = q
    mark.text:SetText(text)
    mark:SetSize(mark.text:GetStringWidth() + 2, 14)
    -- just after the title; a title that wraps gets the mark at the end of its first line
    local head = block.HeaderText
    local w = math.min(head:GetStringWidth(), head:GetWidth())
    mark:ClearAllPoints()
    mark:SetPoint("TOPLEFT", head, "TOPLEFT", w + 4, 0)
    mark:SetFrameLevel(block:GetFrameLevel() + 5)
    mark:Show()
end

-- Walk the tracker for quest blocks: they carry the quest ID as .id and the title as .HeaderText.
-- (Other trackers, e.g. achievements, also use .id: only quests in the quest log count.)
local function scanTracker(frame, depth)
    if not frame or depth > 7 then return end
    for _, child in ipairs({ frame:GetChildren() }) do
        if child.HeaderText and type(child.id) == "number" then
            local inLog = C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(child.id)
            if inLog or child.plotlineMark then trackerMark(child) end
        else
            scanTracker(child, depth + 1)
        end
    end
end

local trackerPending = false
function H.UpdateTracker()
    if trackerPending or not ObjectiveTrackerFrame then return end
    trackerPending = true
    C_Timer.After(0.05, function()
        trackerPending = false
        scanTracker(ObjectiveTrackerFrame, 0)
    end)
end

local function hookTracker()
    if ObjectiveTracker_Update then hooksecurefunc("ObjectiveTracker_Update", H.UpdateTracker) end
    if ObjectiveTrackerFrame and ObjectiveTrackerFrame.Update then
        hooksecurefunc(ObjectiveTrackerFrame, "Update", H.UpdateTracker)
    end
    if ObjectiveTrackerManager and ObjectiveTrackerManager.UpdateAll then
        hooksecurefunc(ObjectiveTrackerManager, "UpdateAll", H.UpdateTracker)
    end
    H.UpdateTracker()
end

-- ------------------------------------------------------------------ events
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        if not C.Init() then return end
        if QuestInfo_Display then hooksecurefunc("QuestInfo_Display", H.UpdateLine) end
        QuestFrame:HookScript("OnShow", function() H.UpdateDialog(GetQuestID and GetQuestID()) end)
        hookTracker()
        for _, ev in ipairs({ "QUEST_DETAIL", "QUEST_PROGRESS", "QUEST_COMPLETE", "QUEST_FINISHED",
                              "QUEST_TURNED_IN", "QUEST_DATA_LOAD_RESULT", "QUEST_LOG_UPDATE",
                              "QUEST_WATCH_LIST_CHANGED" }) do
            pcall(self.RegisterEvent, self, ev)
        end
        C.onTitle = function()
            if H.lineQuest and line and line:IsShown() then line.text:SetText(H.LineText(H.lineQuest) or "") end
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
    elseif event == "QUEST_LOG_UPDATE" or event == "QUEST_WATCH_LIST_CHANGED" then
        H.UpdateTracker()
    end
end)
