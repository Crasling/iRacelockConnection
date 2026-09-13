local _, private = ...
local iRC = private and private.iRC
if not iRC then return end

local GuildMap = { positions = {}, pins = {}, pool = {} }
iRC.GuildMap = GuildMap

local POSITION_VERSION = "1"
local POSITION_LIFETIME = 90
local initialized, mapInitialized, positionSendPending
local mapTicker
local pinMenu

local function hidePinMenu()
    if pinMenu then pinMenu:Hide() end
end

local function showPinMenu(pin)
    if not pin.playerName then return end
    if not pinMenu then
        pinMenu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        pinMenu:SetSize(120, 58)
        pinMenu:SetFrameStrata("FULLSCREEN_DIALOG")
        pinMenu:SetClampedToScreen(true)
        pinMenu:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        pinMenu:SetBackdropColor(0.025, 0.02, 0.015, 0.97)
        pinMenu:SetBackdropBorderColor(0.65, 0.43, 0.15, 1)
        pinMenu:EnableMouse(true)
        local function addAction(offset, prefix, action)
            local button = CreateFrame("Button", nil, pinMenu, "BackdropTemplate")
            button:SetHeight(23)
            button:SetPoint("TOPLEFT", 5, offset)
            button:SetPoint("TOPRIGHT", -5, offset)
            button:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
            button:SetBackdropColor(0.09, 0.07, 0.045, 0.9)
            button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            button.text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            button.text:SetPoint("LEFT", 8, 0)
            button:SetScript("OnClick", function()
                local name = pinMenu.playerName
                hidePinMenu()
                if name then action(name) end
            end)
            button.prefix = prefix
            return button
        end
        pinMenu.whisper = addAction(-5, "Whisper ", function(name)
            if ChatFrame_SendTell then ChatFrame_SendTell(iRC:FormatPlayerName(name)) end
        end)
        pinMenu.invite = addAction(-30, "Invite ", function(name)
            if C_PartyInfo and C_PartyInfo.InviteUnit then
                C_PartyInfo.InviteUnit(name)
            elseif InviteUnit then
                InviteUnit(name)
            end
        end)
        pinMenu:Hide()
        local outsideClickWatcher = CreateFrame("Frame")
        outsideClickWatcher:RegisterEvent("GLOBAL_MOUSE_DOWN")
        outsideClickWatcher:SetScript("OnEvent", function()
            if pinMenu:IsShown() and not MouseIsOver(pinMenu) then hidePinMenu() end
        end)
    end
    pinMenu.playerName = pin.playerName
    local shortName = iRC:FormatPlayerName(pin.playerName)
    pinMenu.whisper.text:SetText(pinMenu.whisper.prefix .. shortName)
    pinMenu.invite.text:SetText(pinMenu.invite.prefix .. shortName)
    pinMenu:SetWidth(math.max(100, math.ceil(math.max(pinMenu.whisper.text:GetStringWidth(), pinMenu.invite.text:GetStringWidth())) + 26))
    local x, y = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    pinMenu:ClearAllPoints()
    pinMenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, y / scale)
    pinMenu:Show()
end

local function enabled()
    return iRC:IsGuildConnectionActive() and iRC:GetConnectionRules().guildMapEnabled == true
end

function GuildMap:IsVisible()
    return enabled() and iRC:GetSettings().showGuildMap ~= false
end

local function clearPin(name)
    local pin = GuildMap.pins[name]
    if not pin then return end
    if pinMenu and pinMenu:IsShown() and pinMenu.playerName == pin.playerName then hidePinMenu() end
    pin:Hide()
    pin.playerName, pin.classFile, pin.level = nil, nil, nil
    GuildMap.pins[name] = nil
    GuildMap.pool[#GuildMap.pool + 1] = pin
end

function GuildMap:Clear()
    for name in pairs(self.pins) do clearPin(name) end
    wipe(self.positions)
end

function GuildMap:Cleanup()
    if not enabled() then self:Clear(); return end
    local now = GetTime()
    local rosterOnline = {}
    if iRC.GetGuildRosterSnapshot then
        for _, member in ipairs(iRC:GetGuildRosterSnapshot()) do
            rosterOnline[iRC:NormalizeName(member.name)] = member.online == true
        end
    end
    for name, position in pairs(self.positions) do
        if now - (position.receivedAt or 0) > POSITION_LIFETIME or rosterOnline[name] == false then
            self.positions[name] = nil
            clearPin(name)
        end
    end
end

local function acquirePin(parent)
    local pin = table.remove(GuildMap.pool)
    if not pin then
        pin = CreateFrame("Frame", nil, parent)
        local size = math.max(5, math.min(15, math.floor(tonumber(iRC:GetSettings().guildMapPinSize) or 12)))
        pin:SetSize(size, size)
        pin:SetFrameStrata("HIGH")
        pin.border = pin:CreateTexture(nil, "BACKGROUND")
        pin.border:SetAllPoints()
        pin.border:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
        pin.border:SetVertexColor(0, 0, 0, 0.85)
        pin.center = pin:CreateTexture(nil, "ARTWORK")
        pin.center:SetPoint("TOPLEFT", 1, -1)
        pin.center:SetPoint("BOTTOMRIGHT", -1, 1)
        pin.center:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask")
        pin:EnableMouse(true)
        pin:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local shortName = iRC:FormatPlayerName(self.playerName or "Unknown")
            local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[self.classFile or ""]
            if color then GameTooltip:AddLine(shortName, color.r, color.g, color.b) else GameTooltip:AddLine(shortName) end
            GameTooltip:AddLine("Level " .. tostring(self.level or 0) .. " " .. tostring(self.className or self.classFile or "Unknown"), 0.65, 0.65, 0.65)
            GameTooltip:Show()
        end)
        pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
        pin:SetScript("OnMouseUp", function(self, button)
            if button == "RightButton" then
                GameTooltip:Hide()
                showPinMenu(self)
            end
        end)
    end
    pin:SetParent(parent)
    local size = math.max(5, math.min(15, math.floor(tonumber(iRC:GetSettings().guildMapPinSize) or 12)))
    pin:SetSize(size, size)
    pin:Show()
    return pin
end

local function mapPosition(mapId, x, y, displayedMapId)
    if mapId == displayedMapId then return x, y end
    if not CreateVector2D or not C_Map or not C_Map.GetWorldPosFromMapPos or not C_Map.GetMapPosFromWorldPos then return nil end
    local ok, convertedX, convertedY = pcall(function()
        local continent, world = C_Map.GetWorldPosFromMapPos(mapId, CreateVector2D(x, y))
        if not continent or not world then return nil end
        local _, position = C_Map.GetMapPosFromWorldPos(continent, world, displayedMapId)
        if not position then return nil end
        return position:GetXY()
    end)
    if not ok or not convertedX or not convertedY or convertedX < 0 or convertedX > 1 or convertedY < 0 or convertedY > 1 then return nil end
    return convertedX, convertedY
end

local function groupedMembers()
    local members = {}
    local prefix, count = IsInRaid() and "raid" or "party", IsInRaid() and GetNumGroupMembers() or GetNumSubgroupMembers()
    for index = 1, count do
        local name = GetUnitName(prefix .. index, true)
        if name then members[iRC:NormalizeName(name)] = true end
    end
    return members
end

function GuildMap:UpdatePins()
    if iRC:DeferLowTraffic("ui:guild-map", function() GuildMap:UpdatePins() end) then return end
    self:Cleanup()
    if not WorldMapFrame or not WorldMapFrame:IsShown() or not self:IsVisible() then
        for name in pairs(self.pins) do clearPin(name) end
        return
    end
    local mapId = WorldMapFrame:GetMapID()
    local child = WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
    if not mapId or not child or child:GetWidth() <= 0 or child:GetHeight() <= 0 then return end
    local shown = {}
    local grouped = groupedMembers()
    for name, position in pairs(self.positions) do
        -- Blizzard already draws party and raid members. Suppress our guild
        -- pin so one character cannot appear at both a cached and live spot.
        local x, y
        if not grouped[name] then x, y = mapPosition(position.mapId, position.x, position.y, mapId) end
        if x and y then
            shown[name] = true
            local pin = self.pins[name] or acquirePin(child)
            self.pins[name] = pin
            pin:ClearAllPoints()
            pin:SetPoint("CENTER", child, "TOPLEFT", x * child:GetWidth(), -y * child:GetHeight())
            local profile = iRC:FindConnectionProfile(name)
            local classFile = profile and profile.class or ""
            local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
            pin.center:SetVertexColor(color and color.r or 1, color and color.g or 1, color and color.b or 1, 1)
            pin.playerName, pin.classFile, pin.level = position.name or name, classFile, profile and profile.level or 0
            pin.className = classFile ~= "" and classFile:sub(1, 1) .. classFile:sub(2):lower() or "Unknown"
        end
    end
    for name in pairs(self.pins) do if not shown[name] then clearPin(name) end end
end

function GuildMap:BroadcastPosition()
    if not enabled() or iRC:GetSettings().shareGuildMapPosition == false or not C_Map then return false end
    local _, instanceType = GetInstanceInfo()
    if instanceType and instanceType ~= "none" then return false end
    local mapId = C_Map.GetBestMapForUnit("player")
    local position = mapId and C_Map.GetPlayerMapPosition(mapId, "player")
    if not position then return false end
    local x, y = position:GetXY()
    if not x or not y or (x == 0 and y == 0) then return false end
    local xWire, yWire = math.floor(x * 10000 + 0.5), math.floor(y * 10000 + 0.5)
    local message = table.concat({ "MAP_POS", POSITION_VERSION, tostring(mapId), tostring(xWire), tostring(yWire) }, "\t")
    return iRC:SendAddonTraffic(iRC.Prefix, message, "GUILD")
end

function GuildMap:SchedulePosition(maximumDelay, minimumDelay)
    if positionSendPending then return false end
    if not C_Timer or not C_Timer.After then return self:BroadcastPosition() end
    positionSendPending = true
    minimumDelay = math.max(0, tonumber(minimumDelay) or 0)
    maximumDelay = math.max(minimumDelay, tonumber(maximumDelay) or 3)
    C_Timer.After(minimumDelay + math.random() * (maximumDelay - minimumDelay), function()
        positionSendPending = false
        GuildMap:BroadcastPosition()
    end)
    return true
end

local function scheduleNextPosition()
    if not C_Timer or not C_Timer.After then return end
    C_Timer.After(25, function()
        GuildMap:BroadcastPosition()
        GuildMap:Cleanup()
        scheduleNextPosition()
    end)
end

local function initializeMap()
    if mapInitialized or not WorldMapFrame or not WorldMapFrame.ScrollContainer then return end
    mapInitialized = true
    local function addLabelOutline(label)
        local fontFile, fontSize = label:GetFont()
        if fontFile and fontSize then label:SetFont(fontFile, fontSize, "OUTLINE") end
    end
    local toggle = CreateFrame("CheckButton", "iRCGuildMapToggle", WorldMapFrame, "UICheckButtonTemplate")
    toggle:SetSize(22, 22)
    -- Keep this below Blizzard's top-right controls. The map canvas renders
    -- above ordinary children, so retain WorldMapFrame as the anchor and put
    -- the control explicitly above the ScrollContainer.
    toggle:SetPoint("TOPRIGHT", WorldMapFrame, "TOPRIGHT", -60, -82)
    toggle:SetFrameLevel((WorldMapFrame.ScrollContainer:GetFrameLevel() or 0) + 20)
    toggle.label = toggle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    toggle.label:SetPoint("RIGHT", toggle, "LEFT", -2, 0)
    toggle.label:SetText("iRC: Share my Pos.")
    addLabelOutline(toggle.label)
    toggle:SetScript("OnClick", function(self)
        iRC:GetSettings().shareGuildMapPosition = self:GetChecked() and true or false
        if self:GetChecked() then GuildMap:SchedulePosition(1) end
        if iRC.RefreshOptionsIfShown then iRC:RefreshOptionsIfShown() end
    end)
    local showToggle = CreateFrame("CheckButton", "iRCGuildMapShowToggle", WorldMapFrame, "UICheckButtonTemplate")
    showToggle:SetSize(22, 22)
    showToggle:SetPoint("TOPRIGHT", toggle, "BOTTOMRIGHT", 0, -2)
    showToggle:SetFrameLevel((WorldMapFrame.ScrollContainer:GetFrameLevel() or 0) + 20)
    showToggle.label = showToggle:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    showToggle.label:SetPoint("RIGHT", showToggle, "LEFT", -2, 0)
    showToggle.label:SetText("iRC: Show Guild Members")
    addLabelOutline(showToggle.label)
    showToggle:SetScript("OnClick", function(self)
        GuildMap:SetShown(self:GetChecked() and true or false)
        if iRC.RefreshOptionsIfShown then iRC:RefreshOptionsIfShown() end
    end)
    local function updateToggle()
        toggle:SetShown(enabled())
        toggle:SetChecked(iRC:GetSettings().shareGuildMapPosition ~= false)
        showToggle:SetShown(enabled())
        showToggle:SetChecked(iRC:GetSettings().showGuildMap ~= false)
    end
    GuildMap.UpdateToggle = updateToggle
    if WorldMapFrame.OnMapChanged then hooksecurefunc(WorldMapFrame, "OnMapChanged", function() GuildMap:UpdatePins() end) end
    WorldMapFrame.ScrollContainer:HookScript("OnMouseWheel", function() GuildMap:UpdatePins() end)
    WorldMapFrame:HookScript("OnShow", function()
        updateToggle()
        -- Incoming positions update pins immediately. This slower ticker is
        -- only needed to expire stale pins while the map remains open.
        if not mapTicker and C_Timer and C_Timer.NewTicker then mapTicker = C_Timer.NewTicker(15, function() GuildMap:UpdatePins() end) end
        GuildMap:UpdatePins()
    end)
    WorldMapFrame:HookScript("OnHide", function()
        hidePinMenu()
        if mapTicker then mapTicker:Cancel(); mapTicker = nil end
        for name in pairs(GuildMap.pins) do clearPin(name) end
    end)
    updateToggle()
end

function GuildMap:SetShown(enabledValue)
    iRC:GetSettings().showGuildMap = enabledValue and true or false
    if self.UpdateToggle then self.UpdateToggle() end
    self:UpdatePins()
end

function GuildMap:SetPinSize(value)
    value = math.max(5, math.min(15, math.floor(tonumber(value) or 12)))
    iRC:GetSettings().guildMapPinSize = value
    for _, pin in pairs(self.pins) do pin:SetSize(value, value) end
    self:UpdatePins()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        if initialized then return end
        initialized = true
        initializeMap()
        GuildMap:SchedulePosition(8, 3)
        scheduleNextPosition()
    elseif event == "ADDON_LOADED" then
        initializeMap()
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        GuildMap:SchedulePosition(3)
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- Remove newly grouped members immediately, even if the full map
        -- refresh is deferred by combat low-traffic mode.
        for name in pairs(groupedMembers()) do clearPin(name) end
        GuildMap:UpdatePins()
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, _, sender = ...
        if prefix ~= iRC.Prefix or not enabled() or not iRC:IsGuildMemberName(sender)
            or iRC:NormalizeName(sender) == iRC:NormalizeName(iRC:GetPlayerName()) then return end
        local version, mapId, xWire, yWire = tostring(message or ""):match("^MAP_POS\t([^\t]+)\t(%d+)\t(%d+)\t(%d+)$")
        mapId, xWire, yWire = tonumber(mapId), tonumber(xWire), tonumber(yWire)
        if version ~= POSITION_VERSION or not mapId or not xWire or not yWire or xWire > 10000 or yWire > 10000 then return end
        GuildMap.positions[iRC:NormalizeName(sender)] = {
            name = sender, mapId = mapId, x = xWire / 10000, y = yWire / 10000, receivedAt = GetTime(),
        }
        GuildMap:UpdatePins()
    end
end)
