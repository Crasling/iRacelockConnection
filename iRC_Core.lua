local addonName, private = ...
local iRC = LibStub("AceAddon-3.0"):NewAddon("iRCGuildConnect")
private.iRC = iRC

iRC.Name = addonName or "iRC"
iRC.LDBroker = LibStub("LibDataBroker-1.1", true)
iRC.LDBIcon = LibStub("LibDBIcon-1.0", true)

local getAddOnInfo = C_AddOns and C_AddOns.GetAddOnInfo or GetAddOnInfo
local getAddOnMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
local addOnTitle
if getAddOnInfo then
    local ok, _, title = pcall(getAddOnInfo, iRC.Name)
    if ok then addOnTitle = title end
end
iRC.Title = tostring(addOnTitle or "iRC: Guild Connect")
    :gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("%s*v?[%d%.]+$", "")
iRC.Version = getAddOnMetadata and getAddOnMetadata(iRC.Name, "Version") or "Unknown"
iRC.Author = getAddOnMetadata and getAddOnMetadata(iRC.Name, "Author") or "Crasling"
iRC.DisplayName = "iRC"
iRC.IconPath = "Interface\\AddOns\\iRC\\Images\\Logo_iRC"
-- Dedicated iRC prefix for guild connection traffic.
iRC.Prefix = "iRCConnV1"
-- Testing-only controls are restricted to these exact character/realm pairs.
iRC.TestAdminNames = {
    "Crasling-Soulseeker",
    "Crasjin-Soulseeker",
    "Crasblight-Soulseeker",
    "Crasdrum-Soulseeker"
}
iRC.Frame = CreateFrame("Frame")
iRC.LegacyAddonName = "iRacelockConnection"

function iRC:DisableLegacyAddon()
    if self.Name == self.LegacyAddonName then return false end
    local getInfo = C_AddOns and C_AddOns.GetAddOnInfo or GetAddOnInfo
    local disable = C_AddOns and C_AddOns.DisableAddOn or DisableAddOn
    if not getInfo or not disable then return false end
    local ok, installed = pcall(getInfo, self.LegacyAddonName)
    if not ok or not installed then return false end
    local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    self.LegacyAddonWasLoaded = isLoaded and isLoaded(self.LegacyAddonName) and true or false
    pcall(disable, self.LegacyAddonName)
    iRCDB.legacyAddonDisabled = true
    return true
end
iRC.GameVersion, iRC.GameBuild, iRC.GameBuildDate, iRC.GameTocVersion = GetBuildInfo()
local gameTocNumber = tonumber(iRC.GameTocVersion) or 0
if gameTocNumber >= 120000 then
    iRC.GameVersionName = "Retail WoW"
elseif gameTocNumber > 50000 and gameTocNumber < 59999 then
    iRC.GameVersionName = "Classic MoP"
elseif gameTocNumber > 40000 and gameTocNumber < 49999 then
    iRC.GameVersionName = "Classic Cata"
elseif gameTocNumber > 30000 and gameTocNumber < 39999 then
    iRC.GameVersionName = "Classic WotLK"
elseif gameTocNumber >= 20500 and gameTocNumber < 30000 then
    iRC.GameVersionName = "Anniversary TBC"
elseif gameTocNumber >= 20000 and gameTocNumber < 20500 then
    iRC.GameVersionName = "Classic TBC"
elseif gameTocNumber > 10000 and gameTocNumber < 19999 then
    iRC.GameVersionName = "Classic Era"
else
    iRC.GameVersionName = "Unknown Version"
end
iRC.Colors = {
    iRC = "|cffff9716",
    White = "|cFFFFFFFF",
    Red = "|cFFFF0000",
    Green = "|cFF00FF00",
    Yellow = "|cFFFFFF00",
    Orange = "|cFFFFA500",
    Gray = "|cFF808080",
    Reset = "|r",
}
iRC.ColorValues = {
    Orange = { 1, 0.59, 0.09 },
    Green = { 0, 1, 0 },
    Yellow = { 1, 1, 0 },
    Gray = { 0.50, 0.50, 0.50 },
}

-- Keep automatic addon traffic away from the busy login frame. Each caller
-- gets its own delay so independent startup packets do not form a new burst.
function iRC:GetStartupTrafficDelay()
    return 3 + math.random() * 5
end

function iRC:EnableIdleWindowFade(frame)
    if not frame or frame.idleFadeEnabled then return end
    frame.idleFadeEnabled = true
    frame.idleFadeOutsideFor = 0
    frame:HookScript("OnUpdate", function(self, elapsed)
        local mouseOver = self.IsMouseOver and self:IsMouseOver()
            or (MouseIsOver and MouseIsOver(self))
        if mouseOver then
            self.idleFadeOutsideFor = 0
            if self:GetAlpha() ~= 1 then self:SetAlpha(1) end
            return
        end
        self.idleFadeOutsideFor = (self.idleFadeOutsideFor or 0) + elapsed
        if self.idleFadeOutsideFor < 2 then return end
        local alpha = self:GetAlpha()
        if alpha > 0.45 then self:SetAlpha(math.max(0.45, alpha - elapsed * 0.9)) end
    end)
    frame:HookScript("OnShow", function(self)
        self.idleFadeOutsideFor = 0
        self:SetAlpha(1)
    end)
end

local lowTrafficPending, lowTrafficPendingCount, lowTrafficGeneration = {}, 0, 0
local LOW_TRAFFIC_QUEUE_LIMIT = 32

function iRC:IsLowTrafficMode()
    return self.LowTrafficMode == true or (UnitAffectingCombat and UnitAffectingCombat("player"))
        or (InCombatLockdown and InCombatLockdown())
end

function iRC:DeferLowTraffic(key, callback)
    if not self:IsLowTrafficMode() then return false end
    if type(key) == "string" and type(callback) == "function" then
        if not lowTrafficPending[key] then
            if lowTrafficPendingCount >= LOW_TRAFFIC_QUEUE_LIMIT then return true end
            lowTrafficPendingCount = lowTrafficPendingCount + 1
        end
        lowTrafficPending[key] = callback
    end
    return true
end

function iRC:EnterLowTrafficMode()
    self.LowTrafficMode = true
    lowTrafficGeneration = lowTrafficGeneration + 1
    self:DebugMsg("Low Traffic Mode enabled: combat started.", 3)
end

function iRC:LeaveLowTrafficMode()
    if UnitAffectingCombat and UnitAffectingCombat("player") then return end
    lowTrafficGeneration = lowTrafficGeneration + 1
    local generation = lowTrafficGeneration
    local delay = self:GetStartupTrafficDelay()
    if not C_Timer or not C_Timer.After then self.LowTrafficMode = false; return end
    C_Timer.After(delay, function()
        if generation ~= lowTrafficGeneration or (UnitAffectingCombat and UnitAffectingCombat("player"))
            or (InCombatLockdown and InCombatLockdown()) then return end
        iRC.LowTrafficMode = false
        local keys = {}
        for key in pairs(lowTrafficPending) do keys[#keys + 1] = key end
        table.sort(keys)
        local callbacks = lowTrafficPending
        lowTrafficPending = {}
        lowTrafficPendingCount = 0
        local networkCount, localCount = 0, 0
        for _, key in ipairs(keys) do
            if key:find("^traffic:") then networkCount = networkCount + 1 else localCount = localCount + 1 end
        end
        for index, key in ipairs(keys) do
            C_Timer.After((index - 1) * 0.35, function()
                local callback = callbacks[key]
                if not callback then return end
                if iRC:IsLowTrafficMode() then iRC:DeferLowTraffic(key, callback) else callback() end
            end)
        end
        iRC:DebugMsg("Low Traffic Mode ended: " .. tostring(#keys) .. " queued task(s) resumed ("
            .. tostring(networkCount) .. " network, " .. tostring(localCount)
            .. " local). Inapplicable tasks may skip without sending.", 3)
    end)
end

function iRC:SendAddonTraffic(prefix, message, distribution, target)
    message = tostring(message or "")
    if #message > 255 then
        self:DebugMsg("Blocked oversized addon message (" .. tostring(#message) .. " bytes) for " .. tostring(prefix or "?"), 1)
        return false
    end
    local now = GetTime and GetTime() or 0
    local readyAt = tonumber(self.StartupTrafficReadyAt) or 0
    if readyAt > now and C_Timer and C_Timer.After then
        C_Timer.After(readyAt - now, function()
            iRC:SendAddonTraffic(prefix, message, distribution, target)
        end)
        return true
    end
    local sent
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        sent = C_ChatInfo.SendAddonMessage(prefix, message, distribution, target)
    elseif SendAddonMessage then
        sent = SendAddonMessage(prefix, message, distribution, target)
    end
    if sent and self.TrafficMonitorEnabled then self:RecordTrafficBytes("out", #tostring(prefix or "") + #message, prefix, message) end
    return sent or false
end

local trafficBuckets = { incoming = {}, outgoing = {} }
local trafficTypeBuckets = {}
local trafficFrame
local monitoredPrefixes = { iRCConnV1 = true, iRCGridV1 = true, iRCIconV1 = true, iRCGFRoster = true, RLAddon = true }

function iRC:RecordTrafficBytes(direction, bytes, prefix, message)
    if not self.TrafficMonitorEnabled then return end
    bytes = tonumber(bytes) or 0
    local buckets = direction == "in" and trafficBuckets.incoming or trafficBuckets.outgoing
    local second = math.floor(GetTime and GetTime() or 0)
    local slot = second % 60 + 1
    local bucket = buckets[slot]
    if not bucket or bucket.second ~= second then
        bucket = { second = second, bytes = 0 }
        buckets[slot] = bucket
    end
    bucket.bytes = bucket.bytes + bytes
    local kind = type(message) == "string" and message:match("^([A-Z][A-Z0-9_]*)") or nil
    local label = tostring(prefix or "?") .. "/" .. (kind or "other")
    local typeBuckets = trafficTypeBuckets[label]
    if not typeBuckets then typeBuckets = {}; trafficTypeBuckets[label] = typeBuckets end
    local typeBucket = typeBuckets[slot]
    if not typeBucket or typeBucket.second ~= second then
        typeBucket = { second = second, incoming = 0, outgoing = 0 }
        typeBuckets[slot] = typeBucket
    end
    if direction == "in" then typeBucket.incoming = typeBucket.incoming + bytes
    else typeBucket.outgoing = typeBucket.outgoing + bytes end
end

function iRC:GetTrafficBytesLastMinute()
    local now = math.floor(GetTime and GetTime() or 0)
    local function total(buckets)
        local bytes = 0
        for _, bucket in pairs(buckets) do
            if bucket.second > now - 60 and bucket.second <= now then bytes = bytes + bucket.bytes end
        end
        return bytes
    end
    return total(trafficBuckets.incoming), total(trafficBuckets.outgoing)
end

function iRC:GetTrafficHotspots()
    local now, rows = math.floor(GetTime and GetTime() or 0), {}
    for label, buckets in pairs(trafficTypeBuckets) do
        local incoming, outgoing = 0, 0
        for _, bucket in pairs(buckets) do
            if bucket.second > now - 60 and bucket.second <= now then
                incoming = incoming + bucket.incoming
                outgoing = outgoing + bucket.outgoing
            end
        end
        if incoming + outgoing > 0 then
            rows[#rows + 1] = { label = label, incoming = incoming, outgoing = outgoing, bytes = incoming + outgoing }
        end
    end
    table.sort(rows, function(a, b) return a.bytes > b.bytes end)
    return rows
end

function iRC:SetTrafficMonitorEnabled(enabled)
    enabled = enabled == true and self:IsTestAdmin()
    self.TrafficMonitorEnabled = enabled
    if not enabled then
        if trafficFrame then trafficFrame:UnregisterAllEvents() end
        wipe(trafficBuckets.incoming)
        wipe(trafficBuckets.outgoing)
        wipe(trafficTypeBuckets)
        return
    end
    if not trafficFrame then
        trafficFrame = CreateFrame("Frame")
        trafficFrame:SetScript("OnEvent", function(_, event, ...)
            if event == "CHAT_MSG_ADDON" then
                local prefix, message, _, sender = ...
                if monitoredPrefixes[prefix] and iRC:NormalizeName(sender) ~= iRC:NormalizeName(iRC:GetPlayerName()) then
                    iRC:RecordTrafficBytes("in", #prefix + #(message or ""), prefix, message)
                end
            elseif event == "CHAT_MSG_CHANNEL" then
                local message, sender = ...
                local channelName = select(9, ...)
                if type(message) == "string" and channelName == "iRacelockConnection"
                    and message:sub(1, #"iRCGridV1:") == "iRCGridV1:"
                    and iRC:NormalizeName(sender) ~= iRC:NormalizeName(iRC:GetPlayerName()) then
                    iRC:RecordTrafficBytes("in", #message, "iRCGridV1", "CHANNEL")
                end
            end
        end)
    end
    trafficFrame:RegisterEvent("CHAT_MSG_ADDON")
    trafficFrame:RegisterEvent("CHAT_MSG_CHANNEL")
end

local functionProfileBuckets = {}
local wrappedFunctions = {}
local functionProfileTargets = {
    { "GetConnection" }, { "GetConnectionRules" }, { "IsGuildFoundRequired" },
    { "GetGuildFoundTradeStatus" }, { "GetGuildRosterSnapshot" }, { "GetGuildRosterRows" },
    { "GetMemberVerification" }, { "FindConnectionProfile" }, { "CheckPresenceMismatches" },
    { "GetRaceOverview" }, { "GetGlobalRaceOverview" },
    { "ConnectionDashboard", "Refresh" }, { "ConnectionDashboard", "RenderVisibleRows" },
    { "GuildMap", "UpdatePins" }, { "GuildMap", "Cleanup" },
    { "RaceGrid", "Refresh" }, { "RaceGrid", "BuildOwnGuildReports" },
    { "RaceLockedSync", "GetStatus" }, { "RaceLockedSync", "DescribeStatus" },
    { "Professions", "CollectSkills" }, { "Professions", "CollectOpenRecipes" },
    { "Enforcement", "CheckGroup" }, { "Enforcement", "CheckTradeRestriction" },
}

function iRC:RecordFunctionTime(label, elapsed)
    local second = math.floor(GetTime and GetTime() or 0)
    local buckets = functionProfileBuckets[label]
    if not buckets then buckets = {}; functionProfileBuckets[label] = buckets end
    local slot = second % 60 + 1
    local bucket = buckets[slot]
    if not bucket or bucket.second ~= second then
        bucket = { second = second, ms = 0, calls = 0 }
        buckets[slot] = bucket
    end
    bucket.ms = bucket.ms + math.max(0, elapsed)
    bucket.calls = bucket.calls + 1
end

function iRC:GetFunctionHotspots()
    local now, rows = math.floor(GetTime and GetTime() or 0), {}
    for label, buckets in pairs(functionProfileBuckets) do
        local ms, calls = 0, 0
        for _, bucket in pairs(buckets) do
            if bucket.second > now - 60 and bucket.second <= now then
                ms, calls = ms + bucket.ms, calls + bucket.calls
            end
        end
        if calls > 0 then rows[#rows + 1] = { label = label, ms = ms, calls = calls } end
    end
    table.sort(rows, function(a, b) return a.ms > b.ms end)
    return rows
end

function iRC:SetFunctionProfilerEnabled(enabled)
    enabled = enabled == true and self:IsTestAdmin() and type(debugprofilestop) == "function"
    if enabled == self.FunctionProfilerEnabled then return end
    self.FunctionProfilerEnabled = enabled
    if not enabled then
        for _, entry in ipairs(wrappedFunctions) do
            if entry.owner[entry.method] == entry.wrapper then entry.owner[entry.method] = entry.original end
        end
        wipe(wrappedFunctions)
        wipe(functionProfileBuckets)
        return
    end
    wipe(functionProfileBuckets)
    for _, target in ipairs(functionProfileTargets) do
        local owner = target[2] and self[target[1]] or self
        local method = target[2] or target[1]
        local original = owner and owner[method]
        if type(original) == "function" then
            local label = target[2] and (target[1] .. ":" .. method) or ("iRC:" .. method)
            local function finish(startedAt, ...)
                self:RecordFunctionTime(label, debugprofilestop() - startedAt)
                return ...
            end
            local wrapper = function(...) return finish(debugprofilestop(), original(...)) end
            owner[method] = wrapper
            wrappedFunctions[#wrappedFunctions + 1] = { owner = owner, method = method, original = original, wrapper = wrapper }
        end
    end
end

local DEFAULT_SETTINGS = {
    mainWindowScale = 1,
    verificationWindowScale = 1,
    shareGlobalRaceGrid = true,
    debugMode = false,
    testGuildMasterOverride = false,
    suppressPresenceWarnings = false,
    suppressRuleSending = false,
    showTrafficMonitorForTesting = false,
    showFunctionProfilerForTesting = false,
    showOfficerSettingsForTesting = false,
    hideAttentionReminders = true,
    showGuildMap = true,
    guildMapPinSize = 12,
    shareGuildMapPosition = true,
}

iRC.DefaultConnectionRules = {
    guildRace = "",
    raceLock = false,
    nativeTongueOnly = false,
    selfFoundOnly = false,
    guildFoundOnly = false,
    level60GuildFound = false,
    allowLevel60WithoutSelfFound = false,
    sameRaceGroupsOnly = false,
    sameRaceMinimumLevel = 1,
    allowLevel60MixedRaceGroups = false,
    guildGroupsOnly = false,
    guildGroupsMinimumLevel = 1,
    guildFoundTradeExceptions = false,
    guildMapEnabled = false,
    disableGuildLevel60Message = false,
    disableGuildDeathMessage = false,
    guildContacts = "",
}

iRC.DefaultRankPermissions = {
    verification = 1, presence = 1, incidents = 1,
    guildBanks = 1, notifications = 1, homepage = 0,
}
iRC.GuildHomepageDescriptionMaxLength = 160
iRC.GuildHomepageIcons = {
    "Interface\\Icons\\INV_Misc_QuestionMark", "Interface\\Icons\\INV_BannerPVP_01", "Interface\\Icons\\INV_BannerPVP_02",
    "Interface\\Icons\\INV_Shield_05", "Interface\\Icons\\INV_Shield_06", "Interface\\Icons\\INV_Shield_09",
    "Interface\\Icons\\INV_Sword_27", "Interface\\Icons\\INV_Axe_09", "Interface\\Icons\\INV_Hammer_04",
    "Interface\\Icons\\INV_Helmet_06", "Interface\\Icons\\INV_Helmet_24", "Interface\\Icons\\INV_Crown_01",
    "Interface\\Icons\\Spell_Holy_PrayerOfHealing", "Interface\\Icons\\Spell_Shadow_RaiseDead", "Interface\\Icons\\Spell_Nature_ProtectionformNature",
    "Interface\\Icons\\Ability_Warrior_BattleShout", "Interface\\Icons\\Ability_Rogue_MasterOfSubtlety", "Interface\\Icons\\Ability_Hunter_BeastCall",
    "Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend", "Interface\\Icons\\Achievement_GuildPerk_HastyHearth",
}

iRC.DefaultGuildFoundTradeExceptions = {
    conjured = false, healthstones = false, questItems = false,
    customItems = false, lockpickOutgoing = false, lockpickIncoming = false,
    warlockSummons = false, magePortals = false,
}

iRC.GuildFoundTradeExceptionItems = {
    conjured = { 5350, 2288, 2136, 3772, 8077, 8078, 8079, 5349, 1113, 1114, 1487, 8075, 8076, 22895 },
    healthstones = { 5512, 19004, 19005, 5511, 19006, 19007, 5509, 19008, 19009, 5510, 19010, 19011, 9421, 19012, 19013 },
    questItems = { 7740, 7741 },
    lockboxes = { 16882, 16883, 16884, 16885, 4632, 4633, 4634, 4636, 4637, 4638, 5758, 5759, 5760, 6354, 6355, 6712, 12033, 13875, 13918 },
}

iRC.GuildFoundTradeExceptionItemNames = {
    [5350] = "Conjured Water", [2288] = "Conjured Fresh Water", [2136] = "Conjured Purified Water",
    [3772] = "Conjured Spring Water", [8077] = "Conjured Mineral Water", [8078] = "Conjured Sparkling Water",
    [8079] = "Conjured Crystal Water", [5349] = "Conjured Muffin", [1113] = "Conjured Bread",
    [1114] = "Conjured Rye", [1487] = "Conjured Pumpernickel", [8075] = "Conjured Sourdough",
    [8076] = "Conjured Sweet Roll", [22895] = "Conjured Cinnamon Roll",
    [5512] = "Minor Healthstone", [19004] = "Minor Healthstone", [19005] = "Minor Healthstone",
    [5511] = "Lesser Healthstone", [19006] = "Lesser Healthstone", [19007] = "Lesser Healthstone",
    [5509] = "Healthstone", [19008] = "Healthstone", [19009] = "Healthstone", [5510] = "Greater Healthstone",
    [19010] = "Greater Healthstone", [19011] = "Greater Healthstone", [9421] = "Major Healthstone",
    [19012] = "Major Healthstone", [19013] = "Major Healthstone",
    [7740] = "Gni'kiv Medallion", [7741] = "The Shaft of Tsol",
    [16882] = "Battered Junkbox", [16883] = "Worn Junkbox", [16884] = "Sturdy Junkbox",
    [16885] = "Heavy Junkbox", [4632] = "Ornate Bronze Lockbox", [4633] = "Heavy Bronze Lockbox",
    [4634] = "Iron Lockbox", [4636] = "Strong Iron Lockbox", [4637] = "Steel Lockbox",
    [4638] = "Reinforced Steel Lockbox", [5758] = "Mithril Lockbox", [5759] = "Thorium Lockbox",
    [5760] = "Eternium Lockbox", [6354] = "Small Locked Chest", [6355] = "Sturdy Locked Chest",
    [6712] = "Clockwork Box", [12033] = "Thaurissan Family Jewels", [13875] = "Ironbound Locked Chest",
    [13918] = "Reinforced Locked Chest",
}

iRC.GuildRaceOrder = { "HUMAN", "DWARF", "NIGHTELF", "GNOME", "ORC", "SCOURGE", "TAUREN", "TROLL" }
iRC.GuildRaceTBCOrder = { "DRAENEI", "BLOODELF" }
local GuildRaceLookup = {}
for _, race in ipairs(iRC.GuildRaceOrder) do GuildRaceLookup[race] = true end
for _, race in ipairs(iRC.GuildRaceTBCOrder) do GuildRaceLookup[race] = true end

function iRC:Print(message)
    print(self.Colors.iRC .. "[iRC]: " .. self.Colors.Reset .. tostring(message))
end

function iRC:DebugMsg(message, level)
    if not self:GetSettings().debugMode then return end
    local L = self.L or {}
    local prefix = level == 3 and L.DEBUG_INFO or (level == 2 and L.DEBUG_WARNING or L.DEBUG_ERROR)
    print((prefix or "") .. tostring(message) .. (L.DEBUG_RESET or ""))
end

function iRC:Text(key, ...)
    local value = self.L and self.L[key] or key
    if select("#", ...) > 0 then return string.format(value, ...) end
    return value
end

function iRC:GetDisplayVersion()
    return self.Version
end

local newestVersionSeen

local function versionParts(version)
    local parts = {}
    for value in tostring(version or ""):gmatch("%d+") do
        parts[#parts + 1] = tonumber(value) or 0
        if #parts == 3 then break end
    end
    return #parts == 3 and parts or nil
end

local function isNewerVersion(candidate, current)
    local candidateParts, currentParts = versionParts(candidate), versionParts(current)
    if not candidateParts or not currentParts then return false end
    for index = 1, 3 do
        if candidateParts[index] ~= currentParts[index] then
            return candidateParts[index] > currentParts[index]
        end
    end
    return false
end

local function isTestRevision(version)
    local count = 0
    for _ in tostring(version or ""):gmatch("%d+") do count = count + 1 end
    return count > 3
end

function iRC:CheckForNewVersion(version)
    -- Test revisions are shared for compatibility diagnostics, but must never
    -- advertise themselves as public updates or show update notices locally.
    if isTestRevision(self.Version) or isTestRevision(version) then return false end
    if not isNewerVersion(version, self.Version) then return false end
    if newestVersionSeen and not isNewerVersion(version, newestVersionSeen) then return false end
    local settings = self:GetSettings()
    local lastVersion = tostring(settings.newVersionNoticeVersion or "")
    local lastAt = math.floor(tonumber(settings.newVersionNoticeAt) or 0)
    if not isNewerVersion(version, lastVersion) and time() - lastAt < 86400 then
        newestVersionSeen = version
        return false
    end
    newestVersionSeen = version
    settings.newVersionNoticeVersion = version
    settings.newVersionNoticeAt = time()
    self:Print(self.Colors.Yellow .. self:Text("NEW_VERSION_AVAILABLE", version) .. self.Colors.Reset)
    return true
end

function iRC:PrintLoaded()
    print(self:Text("ADDON_PREFIX") .. self:Text("LOADED", self.DisplayName, self:GetDisplayVersion()))
end

function iRC:CloseWindowsExcept(keptFrame)
    local windows = {
        self.SettingsFrame,
        self.MainUI and self.MainUI.frame,
        self.ConnectionDashboard and self.ConnectionDashboard.frame,
    }
    for _, window in ipairs(windows) do
        if window and window ~= keptFrame and window.IsShown and window:IsShown() then window:Hide() end
    end
end

function iRC:CloseAllWindows()
    self:CloseWindowsExcept(nil)
end

function iRC:NormalizeName(name)
    if type(name) ~= "string" or name == "" then return "" end
    return string.lower((name:match("^([^-]+)") or name))
end

function iRC:SupportsTBCPlayableRaces()
    return (tonumber(self.GameTocVersion) or 0) >= 20000
end

function iRC:GetSelfFoundState()
    if not UnitBuff then return false end
    for index = 1, 40 do
        local auraName, _, _, _, _, _, _, _, _, spellId = UnitBuff("player", index)
        if not auraName then break end
        if spellId == 431567 then return true end
    end
    return false
end

function iRC:GetSelfFoundHistory()
    iRCCharDB = iRCCharDB or {}
    iRCCharDB.selfFoundHistory = iRCCharDB.selfFoundHistory or {}
    return iRCCharDB.selfFoundHistory
end

function iRC:RecordSelfFoundState()
    local history = self:GetSelfFoundHistory()
    local now, level = time(), UnitLevel("player") or 1
    local active = self:GetSelfFoundState()
    history.firstObservedAt = history.firstObservedAt or now
    history.firstObservedLevel = history.firstObservedLevel or level
    history.lastObservedAt = now
    history.lastObservedLevel = level
    history.currentlyActive = active and true or false

    if active then
        -- Self-Found cannot be restored after it is genuinely removed.  An
        -- active aura therefore proves an older Broken record was a transient
        -- load-screen read and can safely be repaired.
        history.firstEndedAt = nil
        history.firstEndedLevel = nil
        history.endedWithLevel60Exception = nil
        history.pendingEndAt = nil
        history.firstSelfFoundAt = history.firstSelfFoundAt or now
        history.firstSelfFoundLevel = history.firstSelfFoundLevel or level
        history.lastSelfFoundAt = now
    elseif history.firstSelfFoundAt and not history.firstEndedAt and self.SelfFoundAuraReady and not history.pendingEndAt then
        -- UnitBuff can briefly return an incomplete aura list while entering
        -- the world.  Require a delayed, second absent reading before the
        -- irreversible history flag is written.
        history.pendingEndAt = now
        if C_Timer and C_Timer.After then
            C_Timer.After(3, function() iRC:ConfirmSelfFoundEnded(now) end)
        end
    end
    return history
end

function iRC:ConfirmSelfFoundEnded(expectedAt)
    local history = self:GetSelfFoundHistory()
    if history.pendingEndAt ~= expectedAt then return end
    history.pendingEndAt = nil
    if not self.SelfFoundAuraReady or self:GetSelfFoundState() then return end
    if history.firstSelfFoundAt and not history.firstEndedAt then
        local now, level = time(), UnitLevel("player") or 1
        local rules = self:GetConnectionRules()
        local allowedAtMaxLevel = rules and self:GetProgressionMode(rules) == "SELF_FOUND_OR_GUILD_FOUND"
            or (level >= 60 and rules and (rules.level60GuildFound or rules.allowLevel60WithoutSelfFound))
        history.firstEndedAt = now
        history.firstEndedLevel = level
        history.endedWithLevel60Exception = allowedAtMaxLevel and true or false
    end
end

function iRC:GetSelfFoundEvidence()
    local history = self:RecordSelfFoundState()
    local active = history.currentlyActive and true or false
    local evidence = {
        active = active,
        firstObservedAt = history.firstObservedAt,
        firstObservedLevel = history.firstObservedLevel,
        firstSelfFoundAt = history.firstSelfFoundAt,
        firstSelfFoundLevel = history.firstSelfFoundLevel,
        endedAt = history.firstEndedAt,
        endedAtLevel = history.firstEndedLevel,
        endedWithLevel60Exception = history.endedWithLevel60Exception and true or false,
    }
    if history.firstEndedAt and not history.endedWithLevel60Exception then
        evidence.status = "BROKEN"
    elseif history.firstSelfFoundAt and history.firstSelfFoundLevel == 1 then
        evidence.status = active and "VERIFIED" or "LEVEL_60_EXCEPTION"
    elseif history.firstSelfFoundAt then
        evidence.status = active and "TRACKED" or "LEVEL_60_EXCEPTION"
    else
        evidence.status = "UNVERIFIED"
    end
    return evidence
end

function iRC:GetPlayerName()
    if GetUnitName then return GetUnitName("player", true) or UnitName("player") end
    return UnitName("player")
end

function iRC:GetGuildKey()
    local guildName = GetGuildInfo and GetGuildInfo("player")
    if type(guildName) ~= "string" or guildName == "" then return nil end
    local realmName = GetRealmName and GetRealmName() or ""
    return string.lower(guildName .. "@" .. realmName)
end

function iRC:IsInGuildConnection()
    return self:GetGuildKey() ~= nil
end

function iRC:GetSettings()
    iRCDB = iRCDB or {}
    iRCDB.settings = iRCDB.settings or {}
    for key, value in pairs(DEFAULT_SETTINGS) do
        if iRCDB.settings[key] == nil then
            iRCDB.settings[key] = value
        end
    end
    -- Public guild discovery is a core connection feature, not an optional
    -- preference. Migrate previously disabled profiles immediately.
    iRCDB.settings.shareGlobalRaceGrid = true
    iRCDB.settings.minimapButton = iRCDB.settings.minimapButton or {}
    if iRCDB.settings.minimapButton.hide == nil then
        iRCDB.settings.minimapButton.hide = iRCDB.settings.showMinimapButton == false
    end
    if iRCDB.settings.minimapButton.minimapPos == nil then
        iRCDB.settings.minimapButton.minimapPos = -30
    end
    return iRCDB.settings
end

local function decodeRulesTimestamp(value)
    value = tostring(value or ""):lower()
    if value == "" or #value > 12 or not value:match("^[0-9a-f]+$") then return 0 end
    return tonumber(value, 16) or 0
end

function iRC:StampConnectionRules(connection)
    if not self:IsGuildMaster() then return false end
    connection = connection or self:GetConnection()
    if not connection then return false end
    local stamp = math.max(time(), decodeRulesTimestamp(connection.rulesTimestampHex) + 1)
    connection.rulesTimestampHex = string.format("%x", stamp)
    connection.rulesTimestampSource = self:GetPlayerName()
    connection.rulesRelayedBy = self:GetPlayerName()
    connection.rulesReceivedAt = stamp
    return true
end

function iRC:EnsureConnectionRulesTimestamp(connection)
    connection = connection or self:GetConnection()
    if not connection then return "0", "" end
    if (not connection.rulesTimestampHex or connection.rulesTimestampHex == "") and self:IsGuildMaster() then
        self:StampConnectionRules(connection)
    end
    return connection.rulesTimestampHex or "0", connection.rulesTimestampSource or ""
end

local initializedConnections = setmetatable({}, { __mode = "k" })

function iRC:GetConnection()
    local key = self:GetGuildKey()
    -- Dropdown initialization can read rules before ADDON_LOADED restores the DB.
    -- Let callers use defaults until then, without creating early saved state.
    if not key or not iRCDB then return nil end
    iRCDB.connections = iRCDB.connections or {}
    local connection = iRCDB.connections[key]
    if not connection then
        connection = { key = key, guildName = GetGuildInfo("player"), rulesVersion = 1, active = false, members = {} }
        iRCDB.connections[key] = connection
    end
    if initializedConnections[connection] then return connection end
    if connection.active == nil then connection.active = false end
    connection.guildNotifications = connection.guildNotifications or { welcomeNewMembers = false }
    if connection.guildNotifications.welcomeNewMembers == nil then
        connection.guildNotifications.welcomeNewMembers = false
    end
    for _, key in ipairs({ "disableOfficerWarnings", "disableWhisperWarnings", "disableGuildWarnings" }) do
        if connection.guildNotifications[key] == nil then connection.guildNotifications[key] = false end
    end
    connection.guildBankExceptions = connection.guildBankExceptions or { members = {} }
    connection.guildBankExceptions.members = connection.guildBankExceptions.members or {}
    connection.guildBankExceptions.details = connection.guildBankExceptions.details or {}
    connection.guildFoundTradeExceptionSettings = connection.guildFoundTradeExceptionSettings or {}
    for key, value in pairs(self.DefaultGuildFoundTradeExceptions) do
        if connection.guildFoundTradeExceptionSettings[key] == nil then
            connection.guildFoundTradeExceptionSettings[key] = value
        end
    end
    connection.guildFoundTradeExceptionSettings.items = connection.guildFoundTradeExceptionSettings.items or {}
    for category in pairs(self.GuildFoundTradeExceptionItems) do
        connection.guildFoundTradeExceptionSettings.items[category] = connection.guildFoundTradeExceptionSettings.items[category] or {}
    end
    connection.guildContactDetails = connection.guildContactDetails or {}
    connection.guildContactsTimestamp = tonumber(connection.guildContactsTimestamp) or 0
    connection.guildHomepageDescription = connection.guildHomepageDescription or { text = "", timestamp = 0, editedBy = "" }
    connection.guildHomepageDescription.text = tostring(connection.guildHomepageDescription.text or ""):sub(1, self.GuildHomepageDescriptionMaxLength)
    connection.guildHomepageDescription.timestamp = tonumber(connection.guildHomepageDescription.timestamp) or 0
    connection.guildHomepageDescription.editedBy = tostring(connection.guildHomepageDescription.editedBy or "")
    connection.guildHomepageIcon = connection.guildHomepageIcon or { icon = 0, timestamp = 0, editedBy = "" }
    connection.guildHomepageIcon.icon = math.max(0, math.min(#self.GuildHomepageIcons, math.floor(tonumber(connection.guildHomepageIcon.icon) or 0)))
    connection.guildHomepageIcon.timestamp = tonumber(connection.guildHomepageIcon.timestamp) or 0
    connection.guildHomepageIcon.editedBy = tostring(connection.guildHomepageIcon.editedBy or "")
    connection.rankPermissions = connection.rankPermissions or {}
    for permission, rankIndex in pairs(self.DefaultRankPermissions) do
        if connection.rankPermissions[permission] == nil then connection.rankPermissions[permission] = rankIndex end
    end
    connection.members = connection.members or {}
    connection.rules = connection.rules or {}
    for key, value in pairs(self.DefaultConnectionRules) do
        if connection.rules[key] == nil then connection.rules[key] = value end
    end
    if connection.rules.guildRace == "" and self:IsGuildMaster() then
        local _, raceFile = UnitRace("player")
        connection.rules.guildRace = self:NormalizeGuildRace(raceFile)
        self:StampConnectionRules(connection)
    end
    initializedConnections[connection] = true
    return connection
end

function iRC:RecordManagementConnectionStatus(category, createdBy, createdAt, relayedBy, receivedAt)
    local connection = self:GetConnection()
    if not connection or type(category) ~= "string" then return end
    connection.managementConnectionStatus = connection.managementConnectionStatus or {}
    local current = connection.managementConnectionStatus[category]
    createdAt = math.floor(tonumber(createdAt) or 0)
    if current and createdAt < math.floor(tonumber(current.createdAt) or 0) then return end
    connection.managementConnectionStatus[category] = {
        createdBy = tostring(createdBy or ""), createdAt = createdAt,
        relayedBy = tostring(relayedBy or ""), receivedAt = math.floor(tonumber(receivedAt) or time()),
    }
end

function iRC:IsGuildAdmin()
    if self:IsGuildMaster() then return true end
    if not GetGuildInfo then return false end
    local _, _, rankIndex = GetGuildInfo("player")
    return type(rankIndex) == "number" and rankIndex <= 1
end

function iRC:GetPlayerGuildRankIndex()
    if self:IsTestAdminGuildMaster() then return 0 end
    local rankIndex
    if GetGuildInfo then
        local _, _, playerRankIndex = GetGuildInfo("player")
        rankIndex = playerRankIndex
    end
    if type(rankIndex) ~= "number" then rankIndex = self:GetGuildMemberRankIndex(self:GetPlayerName()) end
    return type(rankIndex) == "number" and rankIndex or nil
end

function iRC:GetGuildMemberRankIndex(name)
    if not name or not GetNumGuildMembers or not GetGuildRosterInfo then return nil end
    for index = 1, GetNumGuildMembers(true) do
        local memberName, _, rankIndex = GetGuildRosterInfo(index)
        if self:NormalizeName(memberName) == self:NormalizeName(name) then return rankIndex end
    end
    return nil
end

function iRC:HasGuildPermission(permission)
    if self:IsGuildMaster() then return true end
    local connection, rankIndex = self:GetConnection(), self:GetPlayerGuildRankIndex()
    local allowed = connection and connection.rankPermissions and tonumber(connection.rankPermissions[permission])
    if allowed == nil then allowed = self.DefaultRankPermissions[permission] end
    return rankIndex ~= nil and allowed ~= nil and rankIndex <= allowed
end

function iRC:GetGuildRankPermission(permission)
    local connection = self:GetConnection()
    local value = connection and connection.rankPermissions and tonumber(connection.rankPermissions[permission])
    if value == nil then value = self.DefaultRankPermissions[permission] end
    return math.max(0, math.min(9, math.floor(tonumber(value) or 0)))
end

function iRC:HasAnyManagementPermission()
    for permission in pairs(self.DefaultRankPermissions) do
        if self:HasGuildPermission(permission) then return true end
    end
    return false
end

function iRC:GetGuildRankOptions()
    local found, options = {}, {}
    if GetNumGuildMembers and GetGuildRosterInfo then
        for index = 1, GetNumGuildMembers(true) do
            local _, rankName, rankIndex = GetGuildRosterInfo(index)
            if type(rankIndex) == "number" and not found[rankIndex] then
                found[rankIndex] = rankName or ("Rank " .. rankIndex)
            end
        end
    end
    for rankIndex, rankName in pairs(found) do options[#options + 1] = { index = rankIndex, name = rankName } end
    table.sort(options, function(a, b) return a.index < b.index end)
    return options
end

function iRC:SetGuildRankPermission(permission, rankIndex)
    if not self:IsGuildMaster() or self.DefaultRankPermissions[permission] == nil then return false end
    local connection = self:GetConnection()
    rankIndex = math.max(0, math.min(9, math.floor(tonumber(rankIndex) or 0)))
    connection.rankPermissions[permission] = rankIndex
    connection.rankPermissionsTimestamp = math.max(time(), (tonumber(connection.rankPermissionsTimestamp) or 0) + 1)
    self:RecordManagementConnectionStatus("notifications", self:GetPlayerName(), connection.rankPermissionsTimestamp,
        self:GetPlayerName(), connection.rankPermissionsTimestamp)
    if self.SendRankPermissions then self:SendRankPermissions(nil, true) end
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    return true
end

function iRC:IsGuildMaster()
    if self:IsTestGuildMaster() or self:IsTestAdminGuildMaster() then return true end
    return self:GetPlayerGuildRankIndex() == 0
end

function iRC:IsTestGuildMasterName(name)
    if type(name) ~= "string" or name == "" then return false end

    local configuredName = self.TestGuildMasterName
    if type(configuredName) ~= "string" or configuredName == "" then return false end
    if string.lower(name) == string.lower(configuredName) then return true end

    -- The local player name can omit the realm. Only accept that short form when
    -- it resolves to the exact configured realm, never just a matching name.
    local testName, testRealm = configuredName:match("^(.+)%-(.+)$")
    if not testName or name:find("-", 1, true) or string.lower(name) ~= string.lower(testName) then
        return false
    end

    return GetRealmName and string.lower(GetRealmName()) == string.lower(testRealm) or false
end

function iRC:IsTestAdminName(name)
    if type(name) ~= "string" or name == "" then return false end
    local configuredNames = self.TestAdminNames or {}
    -- Retained as a test harness override; production uses TestAdminNames.
    if type(self.TestAdminName) == "string" and self.TestAdminName ~= "" then
        configuredNames = { self.TestAdminName }
    end
    for _, configuredName in ipairs(configuredNames) do
        if type(configuredName) == "string" and configuredName ~= "" then
            if string.lower(name) == string.lower(configuredName) then return true end
            local testName, testRealm = configuredName:match("^(.+)%-(.+)$")
            if testName and not name:find("-", 1, true) and string.lower(name) == string.lower(testName)
                and GetRealmName and string.lower(GetRealmName()) == string.lower(testRealm) then return true end
        end
    end
    return false
end

function iRC:IsTestGuildMaster()
    return self:IsTestGuildMasterName(self:GetPlayerName())
end

function iRC:IsTestAdmin()
    return self:IsTestAdminName(self:GetPlayerName())
end

function iRC:IsTestAdminGuildMaster()
    return self:IsTestAdmin() and self:GetSettings().testGuildMasterOverride == true
end

function iRC:SuppressesPresenceWarnings()
    return self:IsTestAdmin() and self:GetSettings().suppressPresenceWarnings == true
end

function iRC:SuppressesRuleSending()
    return self:IsTestAdmin() and self:GetSettings().suppressRuleSending == true
end

function iRC:ActivateGuildForTesting()
    if not self:IsTestAdmin() then return false end
    self:GetSettings().testGuildMasterOverride = true
    return self:SetGuildConnectionActive(true)
end

function iRC:IsGuildMasterName(name)
    if self:IsTestGuildMasterName(name) or self:IsTestAdminName(name) then return true end
    if type(name) ~= "string" or not GetNumGuildMembers or not GetGuildRosterInfo then return false end
    for index = 1, GetNumGuildMembers(true) do
        local memberName, _, rankIndex = GetGuildRosterInfo(index)
        if self:NormalizeName(memberName) == self:NormalizeName(name) then return rankIndex == 0 end
    end
    return false
end

function iRC:IsGuildMemberName(name)
    if type(name) ~= "string" or not GetNumGuildMembers or not GetGuildRosterInfo then return false end
    for index = 1, GetNumGuildMembers(true) do
        local memberName = GetGuildRosterInfo(index)
        if self:NormalizeName(memberName) == self:NormalizeName(name) then return true end
    end
    return false
end

function iRC:GetGuildFoundTradeStatus(name, allowOfflineGuildMember)
    if type(name) ~= "string" or name == "" then return false, "Choose a guild member first." end
    if not self:IsGuildMemberName(name) then
        return false, name .. " is not in your guild."
    end

    local targetIsGuildBank = self:IsGuildBankException(name)
    if self.RaceLockedSync and not self:IsGuildBankException(self:GetPlayerName()) then
        local ownVerified, ownClean = self.RaceLockedSync:GetLocalRawStatus()
        local own = self.RaceLockedSync:GetStatus(self:GetPlayerName())
        if own then
            if own.verified ~= nil then ownVerified = own.verified end
            if own.clean ~= nil then ownClean = own.clean end
        end
        if not ownVerified or not ownClean then
            return false, self:Text("RL_LOCAL_INELIGIBLE_DETAIL",
                self:Text(ownVerified and "RL_VERIFIED" or "RL_UNVERIFIED"),
                self:Text(ownClean and "RL_CLEAN" or "RL_FLAGGED"))
        end
    end

    -- A configured Guild Bank is the trusted destination/source exception.
    -- The local character must still pass the check above, but the bank must
    -- not be rejected by its own Self-Found, verification or gold state.
    if targetIsGuildBank then return true end

    local profile = self:FindConnectionProfile(name)
    if not allowOfflineGuildMember then
        local verification = self.GetMemberVerification and self:GetMemberVerification(name, true, profile) or nil
        if not profile or not verification or verification.state ~= "verified" then
            return false, name .. " does not have a current iRC response."
        end
    end

    -- Offline mail cannot require live presence, but it must still use a saved
    -- Guild Found decision. A roster entry alone is never sufficient.
    if self.RaceLockedSync then
        local status = self.RaceLockedSync:GetStatus(name)
        if status and (status.lastSeen or status.gmTimestamp) then
            if status.verified == true and status.clean == true then return true end
            return false, self:Text("RL_MEMBER_INELIGIBLE_DETAIL", name,
                self:Text(status.verified and "RL_VERIFIED" or "RL_UNVERIFIED"),
                self:Text(status.clean and "RL_CLEAN" or "RL_FLAGGED"))
        end
        if allowOfflineGuildMember then
            return false, self:Text("RL_MEMBER_NO_SAVED_VERIFICATION", name)
        end
    elseif allowOfflineGuildMember then
        return false, self:Text("RL_MEMBER_NO_SAVED_VERIFICATION", name)
    end

    local evidence = profile and profile.selfFoundEvidence or nil
    local status = evidence and evidence.status or "UNVERIFIED"
    if status == "VERIFIED" or status == "LEVEL_60_EXCEPTION" then return true end
    return false, name .. " does not have verified Self-Found history (" .. string.lower(status) .. ")."
end

function iRC:IsGuildOnlyGroup()
    if not self:IsGuildConnectionActive() then return false end
    local inRaid = IsInRaid and IsInRaid()
    local memberCount = inRaid and (GetNumGroupMembers and GetNumGroupMembers() or 0) or (GetNumSubgroupMembers and GetNumSubgroupMembers() or 0)
    if memberCount < 1 then return false end
    for index = 1, memberCount do
        local unit = inRaid and "raid" .. index or "party" .. index
        if (not UnitIsUnit or not UnitIsUnit(unit, "player")) and not self:IsGuildMemberName(UnitName(unit)) then return false end
    end
    return true
end

function iRC:NormalizeGuildRace(race)
    local token = tostring(race or ""):upper():gsub("%s+", "")
    if token == "UNDEAD" then token = "SCOURGE" end
    return GuildRaceLookup[token] and token or ""
end

function iRC:GetAvailableGuildRaces()
    local races = {}
    for _, race in ipairs(self.GuildRaceOrder) do races[#races + 1] = race end
    if self:SupportsTBCPlayableRaces() then
        for _, race in ipairs(self.GuildRaceTBCOrder) do races[#races + 1] = race end
    end
    return races
end

function iRC:GetGuildRace()
    return self:NormalizeGuildRace(self:GetConnectionRules().guildRace)
end

function iRC:SetGuildRace(race)
    if not self:IsGuildMaster() then return false end
    local normalizedRace = self:NormalizeGuildRace(race)
    if normalizedRace == "" then return false end
    local connection = self:GetConnection()
    if not connection then return false end
    if connection.rules.raceLock ~= true then return false end
    connection.rules.guildRace = normalizedRace
    self:StampConnectionRules(connection)
    if self.ScheduleConnectionRulesBroadcast then self:ScheduleConnectionRulesBroadcast() end
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    return true
end

function iRC:IsGuildConnectionActive()
    local connection = self:GetConnection()
    return connection and connection.active == true or false
end

function iRC:SetGuildConnectionActive(active, receivedFromGuild)
    if not receivedFromGuild and not self:IsGuildMaster() then return false end
    local connection = self:GetConnection()
    if not connection then return false end
    active = active and true or false
    if connection.active == active then return false end
    connection.active = active
    if active and not receivedFromGuild and self:GetGuildRace() == "" then
        local _, raceFile = UnitRace("player")
        connection.rules.guildRace = self:NormalizeGuildRace(raceFile)
        self:StampConnectionRules(connection)
    end
    if not active then
        if self.ResetPresenceNotificationChecks then self:ResetPresenceNotificationChecks() end
        connection.attentionSince = {}
        connection.newMemberChecks = {}
    end
    if not receivedFromGuild and self.SendGuildActivation then self:SendGuildActivation(nil, true) end
    if active and not receivedFromGuild then
        if self.SendConnectionRules then self:SendConnectionRules(nil, true) end
        if self.SendHello then self:SendHello() end
        if self.Compatibility and self.Compatibility.BroadcastAll then self.Compatibility:BroadcastAll() end
    end
    if active and self.RaceLockedSync then self.RaceLockedSync:Broadcast() end
    if active and self.RefreshGuildRoster then self:RefreshGuildRoster() end
    if self.Enforcement then self.Enforcement:Refresh() end
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    return true
end

function iRC:SetGuildHomepageDescription(value)
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("homepage") then return false end
    if self:IsLowTrafficMode() then return false end
    local connection = self:GetConnection()
    if not connection then return false end
    value = tostring(value or ""):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s%s+", " ")
    value = value:sub(1, self.GuildHomepageDescriptionMaxLength)
    if self:ContainsProfanity(value) then
        self:Print(self.Colors.Red .. self:Text("GUILD_DESCRIPTION_PROFANITY") .. self.Colors.Reset)
        return false
    end
    local data = connection.guildHomepageDescription
    local now = GetServerTime and GetServerTime() or time()
    data.text = value
    data.timestamp = math.max(now, math.floor(tonumber(data.timestamp) or 0) + 1)
    data.editedBy = self:GetPlayerName()
    self:RecordManagementConnectionStatus("homepage", data.editedBy, data.timestamp, self:GetPlayerName(), data.timestamp)
    if self.SendGuildHomepageDescription then self:SendGuildHomepageDescription(nil, true) end
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    if self.RaceGrid then self.RaceGrid:BroadcastReport(false) end
    return true
end

function iRC:SetGuildHomepageIcon(icon)
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("homepage") then return false end
    local connection = self:GetConnection()
    icon = math.floor(tonumber(icon) or 0)
    if not connection or icon < 1 or icon > #self.GuildHomepageIcons then return false end
    local data = connection.guildHomepageIcon
    local now = GetServerTime and GetServerTime() or time()
    data.icon = icon
    data.timestamp = math.max(now, math.floor(tonumber(data.timestamp) or 0) + 1)
    data.editedBy = self:GetPlayerName()
    self:RecordManagementConnectionStatus("homepage", data.editedBy, data.timestamp, self:GetPlayerName(), data.timestamp)
    if self.SendGuildHomepageIcon then self:SendGuildHomepageIcon(nil, true) end
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    if self.RaceGrid then self.RaceGrid:BroadcastReport(false) end
    return true
end

function iRC:GetConnectionRules()
    local connection = self:GetConnection()
    return connection and connection.rules or self.DefaultConnectionRules
end

function iRC:IsAddonResponseRequired(connection)
    connection = connection or self:GetConnection()
    if not connection or connection.active ~= true then return false end
    local rules = connection.rules or self.DefaultConnectionRules
    return rules.raceLock == true or rules.nativeTongueOnly == true
        or rules.selfFoundOnly == true or rules.guildFoundOnly == true or rules.level60GuildFound == true
        or rules.sameRaceGroupsOnly == true or rules.guildGroupsOnly == true
end

function iRC:IsNewMemberWelcomeEnabled()
    local connection = self:GetConnection()
    return connection and connection.guildNotifications
        and connection.guildNotifications.welcomeNewMembers == true or false
end

function iRC:IsAutomaticWarningDisabled(channel)
    local connection = self:GetConnection()
    local settings = connection and connection.guildNotifications
    local key = ({ OFFICER = "disableOfficerWarnings", WHISPER = "disableWhisperWarnings", GUILD = "disableGuildWarnings" })[channel]
    return key and settings and settings[key] == true or false
end

local function normalizeFullPlayerName(name, defaultRealm)
    name = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return "" end
    local character, realm = name:match("^([^-]+)%-(.+)$")
    character = character or name
    realm = realm or defaultRealm
    if not realm or realm == "" then return string.lower(character) end
    return string.lower(character .. "-" .. tostring(realm):gsub("%s+", ""))
end

function iRC:ResolveGuildMemberFullName(name)
    if type(name) ~= "string" or name == "" or not GetNumGuildMembers or not GetGuildRosterInfo then return nil end
    local hasRealm = name:find("-", 1, true) ~= nil
    local wantedFull = normalizeFullPlayerName(name, GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName and GetRealmName())
    local wantedShort, match
    if not hasRealm then wantedShort = self:NormalizeName(name) end
    for index = 1, GetNumGuildMembers(true) do
        local rosterName = GetGuildRosterInfo(index)
        if rosterName then
            local rosterFull = normalizeFullPlayerName(rosterName, GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName and GetRealmName())
            local matches = hasRealm and rosterFull == wantedFull or (wantedShort and self:NormalizeName(rosterName) == wantedShort)
            if matches then
                if match and match ~= rosterFull then return nil end
                match = rosterFull
            end
        end
    end
    return match
end

function iRC:IsGuildBankException(name, connection)
    connection = connection or self:GetConnection()
    local exceptions = connection and connection.guildBankExceptions
    local key = normalizeFullPlayerName(name, GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName and GetRealmName())
    return key ~= "" and exceptions and exceptions.members and exceptions.members[key] == true or false
end

function iRC:GetGuildBankExceptionDetails(name)
    local connection = self:GetConnection()
    local exceptions = connection and connection.guildBankExceptions
    local key = normalizeFullPlayerName(name, GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName and GetRealmName())
    return exceptions and exceptions.details and exceptions.details[key] or nil
end

function iRC:GetGuildBankType(name, connection)
    connection = connection or self:GetConnection()
    if not self:IsGuildBankException(name, connection) then return nil end
    local exceptions = connection.guildBankExceptions
    local key = normalizeFullPlayerName(name, GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName and GetRealmName())
    local detail = exceptions.details and exceptions.details[key]
    return detail and detail.bankType == "PERSONAL" and "PERSONAL" or "GUILD"
end

function iRC:IsGuildBankSnapshotPublisher(name, connection)
    return self:GetGuildBankType(name, connection) == "GUILD"
end

function iRC:FormatPlayerName(name)
    name = tostring(name or "")
    local character, realm = name:match("^([^-]+)%-(.+)$")
    if character then
        local currentRealm = GetNormalizedRealmName and GetNormalizedRealmName() or ""
        if currentRealm == "" then currentRealm = GetRealmName and GetRealmName() or "" end
        local normalizedRealm = tostring(realm):gsub("%s+", ""):lower()
        local normalizedCurrent = tostring(currentRealm):gsub("%s+", ""):lower()
        if normalizedRealm == normalizedCurrent then return character end
        return name
    end
    return name
end

function iRC:GetGuildBankExceptionText()
    local connection = self:GetConnection()
    local names = {}
    for name, enabled in pairs(connection and connection.guildBankExceptions and connection.guildBankExceptions.members or {}) do
        if enabled then names[#names + 1] = name end
    end
    table.sort(names)
    return table.concat(names, ", ")
end

function iRC:MarkGuildFoundRequired(connection)
    connection = connection or self:GetConnection()
    local guildKey = self:GetGuildKey()
    if not connection or not guildKey then return false end
    connection.guildFoundEverActive = true
    iRCCharDB = iRCCharDB or {}
    iRCCharDB.guildFoundGuilds = iRCCharDB.guildFoundGuilds or {}
    iRCCharDB.guildFoundGuilds[guildKey] = true
    return true
end

function iRC:IsGuildFoundRequired(connection)
    connection = connection or self:GetConnection()
    local guildKey = connection and connection.key
    if not connection or not guildKey then return false end
    local rules = connection.rules or self.DefaultConnectionRules
    if rules.guildFoundOnly == true or rules.level60GuildFound == true then
        self:MarkGuildFoundRequired(connection)
        return true
    end
    return connection.guildFoundEverActive == true
        or (iRCCharDB and iRCCharDB.guildFoundGuilds and iRCCharDB.guildFoundGuilds[guildKey] == true)
end

function iRC:GetProgressionMode(rules)
    rules = rules or self:GetConnectionRules() or self.DefaultConnectionRules
    if rules.selfFoundOnly then return "SELF_FOUND" end
    if rules.guildFoundOnly then return "GUILD_FOUND" end
    if rules.level60GuildFound then return "SELF_FOUND_OR_GUILD_FOUND" end
    return "NONE"
end

function iRC:GetMaxLevelProgressionMode(rules)
    rules = rules or self:GetConnectionRules() or self.DefaultConnectionRules
    if rules.level60GuildFound then return "GUILD_FOUND" end
    if rules.allowLevel60WithoutSelfFound then return "UNRESTRICTED" end
    return "SELF_FOUND"
end

function iRC:SetProgressionMode(mode)
    if not self:IsGuildMaster() then return false end
    local connection = self:GetConnection()
    if not connection then return false end
    if mode == "SELF_FOUND" then
        connection.rules.selfFoundOnly = true
        connection.rules.guildFoundOnly = false
        connection.rules.level60GuildFound = false
        connection.rules.allowLevel60WithoutSelfFound = false
    elseif mode == "SELF_FOUND_OR_GUILD_FOUND" then
        connection.rules.selfFoundOnly = false
        connection.rules.guildFoundOnly = false
        connection.rules.level60GuildFound = true
        connection.rules.allowLevel60WithoutSelfFound = false
        self:MarkGuildFoundRequired(connection)
    elseif mode == "GUILD_FOUND" then
        connection.rules.selfFoundOnly = false
        connection.rules.guildFoundOnly = true
        connection.rules.level60GuildFound = false
        connection.rules.allowLevel60WithoutSelfFound = false
        self:MarkGuildFoundRequired(connection)
    else
        connection.rules.selfFoundOnly = false
        connection.rules.guildFoundOnly = false
        connection.rules.level60GuildFound = false
        connection.rules.allowLevel60WithoutSelfFound = false
    end
    if mode == "SELF_FOUND" or mode == "GUILD_FOUND" or mode == "SELF_FOUND_OR_GUILD_FOUND" then
        self:GetSettings().hideAttentionReminders = true
    end
    self:StampConnectionRules(connection)
    if self.ScheduleConnectionRulesBroadcast then self:ScheduleConnectionRulesBroadcast() end
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    if self.Enforcement then self.Enforcement:Refresh() end
    return true
end

function iRC:SetMaxLevelProgressionMode(mode)
    if not self:IsGuildMaster() or self:GetProgressionMode() ~= "SELF_FOUND" then return false end
    local connection = self:GetConnection()
    if not connection then return false end
    connection.rules.level60GuildFound = mode == "GUILD_FOUND"
    connection.rules.allowLevel60WithoutSelfFound = mode == "UNRESTRICTED"
    if connection.rules.level60GuildFound then self:MarkGuildFoundRequired(connection) end
    self:StampConnectionRules(connection)
    if self.ScheduleConnectionRulesBroadcast then self:ScheduleConnectionRulesBroadcast() end
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    if self.Enforcement then self.Enforcement:Refresh() end
    return true
end

function iRC:SetConnectionRule(key, value)
    if not self:IsGuildMaster() or self.DefaultConnectionRules[key] == nil then return false end
    local connection = self:GetConnection()
    if not connection then return false end
    value = value and true or false
    if value and (key == "nativeTongueOnly" or key == "sameRaceGroupsOnly" or key == "allowLevel60MixedRaceGroups")
        and connection.rules.raceLock ~= true then return false end
    connection.rules[key] = value
    if key == "raceLock" and not value then
        connection.rules.nativeTongueOnly = false
        connection.rules.sameRaceGroupsOnly = false
        connection.rules.allowLevel60MixedRaceGroups = false
    end
    if value and key == "level60GuildFound" then
        connection.rules.allowLevel60WithoutSelfFound = false
    elseif value and key == "allowLevel60WithoutSelfFound" then
        connection.rules.level60GuildFound = false
    end
    if connection.rules.selfFoundOnly and connection.rules.level60GuildFound then self:MarkGuildFoundRequired(connection) end
    self:StampConnectionRules(connection)
    if self.ScheduleConnectionRulesBroadcast then self:ScheduleConnectionRulesBroadcast() end
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    if self.Enforcement then self.Enforcement:Refresh() end
    if self.GuildMap then
        if self.GuildMap.UpdateToggle then self.GuildMap.UpdateToggle() end
        self.GuildMap:UpdatePins()
        if key == "guildMapEnabled" and value then self.GuildMap:SchedulePosition(3) end
    end
    return true
end

function iRC:SetSameRaceMinimumLevel(value)
    if not self:IsGuildMaster() then return false end
    local connection = self:GetConnection()
    if not connection then return false end
    connection.rules.sameRaceMinimumLevel = math.max(1, math.min(60, math.floor(tonumber(value) or 1)))
    self:StampConnectionRules(connection)
    if self.ScheduleConnectionRulesBroadcast then self:ScheduleConnectionRulesBroadcast() end
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    if self.Enforcement then self.Enforcement:Refresh() end
    return true
end

function iRC:SetGuildGroupsMinimumLevel(value)
    if not self:IsGuildMaster() then return false end
    local connection = self:GetConnection()
    if not connection then return false end
    connection.rules.guildGroupsMinimumLevel = math.max(1, math.min(60, math.floor(tonumber(value) or 1)))
    self:StampConnectionRules(connection)
    if self.ScheduleConnectionRulesBroadcast then self:ScheduleConnectionRulesBroadcast() end
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    if self.Enforcement then self.Enforcement:Refresh() end
    return true
end

function iRC:SetGuildContacts(value)
    if not self:HasGuildPermission("homepage") then return false end
    local connection = self:GetConnection()
    if not connection then return false end
    value = tostring(value or ""):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s%s+", " ")
    if #value > 140 then
        self:Print(self.Colors.Red .. self:Text("GUILD_CONTACTS_TOO_LONG") .. self.Colors.Reset)
        return false
    end
    local previous = {}
    for name in tostring(connection.rules.guildContacts or ""):gmatch("[^,]+") do
        local fullName = self:ResolveGuildMemberFullName(name:gsub("^%s+", ""):gsub("%s+$", ""))
        if fullName then previous[fullName] = true end
    end
    local now = GetServerTime and GetServerTime() or time()
    local normalized, details, count = {}, {}, 0
    for name in value:gmatch("[^,]+") do
        local fullName = self:ResolveGuildMemberFullName(name:gsub("^%s+", ""):gsub("%s+$", ""))
        if not fullName then return false end
        count = count + 1
        if count > 5 then
            self:Print(self.Colors.Red .. self:Text("GUILD_CONTACTS_TOO_LONG") .. self.Colors.Reset)
            return false
        end
        normalized[#normalized + 1] = fullName
        details[fullName] = connection.guildContactDetails[fullName]
        if not details[fullName] and not previous[fullName] then
            details[fullName] = { addedAt = now, addedBy = self:GetPlayerName(), updatedAt = now, note = "" }
        end
    end
    value = table.concat(normalized, ", ")
    if #value > 140 then
        self:Print(self.Colors.Red .. self:Text("GUILD_CONTACTS_TOO_LONG") .. self.Colors.Reset)
        return false
    end
    connection.guildContactDetails = details
    connection.rules.guildContacts = value
    connection.guildContactsTimestamp = math.max(time(), connection.guildContactsTimestamp + 1)
    connection.guildContactsSource = self:GetPlayerName()
    self:RecordManagementConnectionStatus("homepage", connection.guildContactsSource, connection.guildContactsTimestamp,
        self:GetPlayerName(), connection.guildContactsTimestamp)
    if self:IsGuildMaster() then
        self:StampConnectionRules(connection)
        if self.ScheduleConnectionRulesBroadcast then self:ScheduleConnectionRulesBroadcast() end
    elseif self.SendGuildContacts then
        self:SendGuildContacts(nil, true)
    end
    if self.SendGuildContactMetadata then self:SendGuildContactMetadata(nil, nil, true) end
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    return true
end

function iRC:GetGuildContactDetails(name)
    local connection = self:GetConnection()
    local fullName = self:ResolveGuildMemberFullName(name) or name
    return connection and connection.guildContactDetails and connection.guildContactDetails[fullName] or nil
end

iRC.Frame:RegisterEvent("ADDON_LOADED")
iRC.Frame:RegisterEvent("PLAYER_LOGIN")
iRC.Frame:RegisterEvent("PLAYER_REGEN_DISABLED")
iRC.Frame:RegisterEvent("PLAYER_REGEN_ENABLED")
iRC.Frame:SetScript("OnEvent", function(_, event, loadedName)
    if event == "ADDON_LOADED" then
        if loadedName ~= iRC.Name then return end
        iRCDB = iRCDB or {}
        iRCDB.connections = iRCDB.connections or {}
        iRC:GetSettings()
        iRCCharDB = iRCCharDB or {}
        iRC:DisableLegacyAddon()
    elseif event == "PLAYER_LOGIN" then
        iRC.StartupTrafficReadyAt = (GetTime and GetTime() or 0) + 3
        iRC:DebugMsg(iRC:Text("DEBUG_MODE"), 3)
        iRC:PrintLoaded()
        C_Timer.After(10, function()
            local settings = iRC:GetSettings()
            if settings.raceLockedForkReminderShown then return end
            local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
            if isLoaded and isLoaded("RaceLockedForkEU") then
                settings.raceLockedForkReminderShown = true
                iRC:Print(iRC:Text("RACELOCKED_FORK_DISABLE_REMINDER"))
            end
        end)
        if iRC.LegacyAddonWasLoaded then
            iRC:Print(iRC.Colors.Yellow .. "The old iRacelockConnection addon was disabled. Please /reload before using iRC." .. iRC.Colors.Reset)
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        iRC:EnterLowTrafficMode()
        iRC:CloseAllWindows()
    elseif event == "PLAYER_REGEN_ENABLED" then
        iRC:LeaveLowTrafficMode()
    end
end)
