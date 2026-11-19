-- SPDX-License-Identifier: GPL-3.0-or-later
-- Plotline: minimap button. Click opens the Journal; drag moves it around the minimap (the angle is
-- saved in PlotlineDB.minimap); /plotline minimap hides or shows it. Drawn like the game's own
-- minimap buttons (tracking ring, dark disc), no libraries.

local _, ns = ...
local M = {}
ns.minimap = M

local SIZE = 31
local button

local atan2 = math.atan2 or math.atan

local function place()
    local angle = math.rad(PlotlineDB.minimap.angle or 200)
    local x, y = math.cos(angle), math.sin(angle)
    local w, h = Minimap:GetWidth() / 2 + 5, Minimap:GetHeight() / 2 + 5
    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    if shape == "SQUARE" then
        -- on a square minimap, run along the edge instead of the circle
        local m = math.max(math.abs(x), math.abs(y))
        x, y = x / m, y / m
    end
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", x * w, y * h)
end

local function onDragUpdate()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    PlotlineDB.minimap.angle = math.deg(atan2(py / scale - my, px / scale - mx)) % 360
    place()
end

local function create()
    button = CreateFrame("Button", "PlotlineMinimapButton", Minimap)
    button:SetSize(SIZE, SIZE)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetSize(24, 24)
    bg:SetPoint("CENTER")
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    icon:SetSize(18, 18)
    icon:SetPoint("CENTER")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    button.icon = icon
    local ring = button:CreateTexture(nil, "OVERLAY")
    ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    ring:SetSize(50, 50)
    ring:SetPoint("TOPLEFT", button, "CENTER", -15.5, 14.5)   -- the ring is off-centre in its file

    button:SetScript("OnClick", function() ns.journal.Toggle() end)
    button:SetScript("OnMouseDown", function() icon:SetTexCoord(0.1, 0.9, 0.1, 0.9) end)
    button:SetScript("OnMouseUp", function() icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) end)
    button:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:SetScript("OnUpdate", onDragUpdate)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Plotline")
        GameTooltip:AddLine("Click to open the Journal", 1, 1, 1)
        GameTooltip:AddLine("Drag to move this button", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

function M.Update()
    if PlotlineDB.minimap.hide then
        if button then button:Hide() end
        return
    end
    if not button then create() end
    place()
    button:Show()
end

function M.Toggle()
    PlotlineDB.minimap.hide = not PlotlineDB.minimap.hide
    M.Update()
    print(("|cffffd100Plotline|r minimap button %s. /plotline minimap to %s it."):format(
        PlotlineDB.minimap.hide and "hidden" or "shown", PlotlineDB.minimap.hide and "show" or "hide"))
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    PlotlineDB.minimap = PlotlineDB.minimap or { angle = 200, hide = false }
    M.Update()
end)
