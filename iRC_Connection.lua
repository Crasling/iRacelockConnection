local _, private = ...
local iRC = private and private.iRC
if not iRC then return end

local SEP = "\t"
local WIRE_VERSION = "9"
local MINIMUM_RULESET_VERSION = { 0, 4, 1 }
local requestNumber = 0
local SECONDS_PER_DAY = 86400
local lastPresencePollAt = 0
local ACTIVATION_REQUEST_COOLDOWN = 10
local lastActivationRequestAt, lastActivationRequestGuild
local guildUpdatePending = false
local ignoreGuildUpdatesUntil = 0
local seenGroupViolations = {}
local RULE_AUTHORITY_TIMEOUT = 90
local RULE_AUTHORITY_STARTUP_GRACE = 15
local incidentUploadAt = {}
local guildFoundAuditUploadAt = {}
local guildBankTransfers = {}
local MAX_GUILD_BANKS = 32
local MAX_GUILD_BANK_WIRE = 1200
local GUILD_BANK_CHUNK_SIZE = 80
local profileUIRefreshPending = false
local pendingHello = {}
local pendingRulesBroadcast
local profileDebugSummary = { count = 0, names = {}, scheduled = false }
local rulesAckSummaries = {}
local legacyRulesAckSummaries = {}
iRC.ConnectionSessionStartedAt = time()

local function supportsCurrentRuleset(version)
    local parts = {}
    for value in tostring(version or ""):gmatch("%d+") do
        parts[#parts + 1] = tonumber(value) or 0
        if #parts == 3 then break end
    end
    if #parts ~= 3 then return false end
    for index = 1, 3 do
        if parts[index] ~= MINIMUM_RULESET_VERSION[index] then
            return parts[index] > MINIMUM_RULESET_VERSION[index]
        end
    end
    return true
end

local function registerPrefix(prefix)
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then return C_ChatInfo.RegisterAddonMessagePrefix(prefix) end
    if RegisterAddonMessagePrefix then return RegisterAddonMessagePrefix(prefix) end
end

local function send(prefix, message, distribution, target)
    return iRC:SendAddonTraffic(prefix, message, distribution, target)
end

local function schedulePresenceReview()
    if not C_Timer or not C_Timer.After then return end
    C_Timer.After(5, function()
        if iRC.CheckPresenceMismatches then iRC:CheckPresenceMismatches() end
    end)
end

local function split(message)
    local values = {}
    message = tostring(message or "") .. SEP
    for value in message:gmatch("(.-)" .. SEP) do values[#values + 1] = value end
    return values
end

local function profileWireParts(profile)
    local evidence = profile.selfFoundEvidence or {}
    return {
        iRC.Version, profile.name or "Unknown", profile.guid or "", profile.race or "Unknown", profile.class or "UNKNOWN",
        tostring(profile.level or 1), "0", profile.selfFound and "1" or "0",
        "0", "0", "0",
        "@", "",
        evidence.status or "UNVERIFIED",
        tostring(math.floor((tonumber(evidence.firstSelfFoundAt) or 0) / SECONDS_PER_DAY)),
        tostring(math.floor((tonumber(evidence.endedAt) or 0) / SECONDS_PER_DAY)),
        "0",
        profile.shareGlobalRaceGrid and "1" or "0",
        profile.testGuildMasterOverride and "1" or "0",
        profile.hideChatIcon and "1" or "0",
        profile.currentGroupRuleViolation and "1" or "0",
    }
end

local function addProfileParts(parts, profile)
    for _, value in ipairs(profileWireParts(profile)) do parts[#parts + 1] = value end
    return table.concat(parts, SEP)
end

local function profileFromWire(parts, startIndex)
    local name = parts[startIndex + 1]
    if not name or name == "" then return nil end
    return {
        addonVersion = parts[startIndex] or "Unknown", name = name, guid = parts[startIndex + 2] or "",
        race = parts[startIndex + 3] or "Unknown", class = parts[startIndex + 4] or "UNKNOWN",
        level = tonumber(parts[startIndex + 5]) or 1,
        selfFound = parts[startIndex + 7] == "1",
        selfFoundEvidence = {
            status = parts[startIndex + 13] or "UNVERIFIED",
            firstSelfFoundAt = (tonumber(parts[startIndex + 14]) or 0) * SECONDS_PER_DAY,
            endedAt = (tonumber(parts[startIndex + 15]) or 0) * SECONDS_PER_DAY,
        },
        lastSeen = time(),
        shareGlobalRaceGrid = parts[startIndex + 17] == "1",
        testGuildMasterOverride = parts[startIndex + 18] == "1",
        hideChatIcon = parts[startIndex + 19] == "1",
        currentGroupRuleViolation = parts[startIndex + 20] == "1",
    }
end

local function scheduleProfileUIRefresh()
    if iRC:DeferLowTraffic("ui:profiles", scheduleProfileUIRefresh) then return end
    if profileUIRefreshPending then return end
    if not C_Timer or not C_Timer.After then
        if iRC.MainUI then iRC.MainUI:RefreshIfShown() end
        if iRC.ConnectionDashboard then iRC.ConnectionDashboard:RefreshIfShown() end
        return
    end
    profileUIRefreshPending = true
    C_Timer.After(0.25, function()
        profileUIRefreshPending = false
        if iRC.MainUI then iRC.MainUI:RefreshIfShown() end
        if iRC.ConnectionDashboard then iRC.ConnectionDashboard:RefreshIfShown() end
    end)
end

local function summarizeProfileDebug(sender)
    if not iRC:GetSettings().debugMode then return end
    local key = iRC:NormalizeName(sender)
    if not profileDebugSummary.names[key] then
        profileDebugSummary.names[key] = true
        profileDebugSummary.count = profileDebugSummary.count + 1
    end
    if profileDebugSummary.scheduled or not C_Timer or not C_Timer.After then return end
    profileDebugSummary.scheduled = true
    C_Timer.After(2, function()
        local count = profileDebugSummary.count
        profileDebugSummary = { count = 0, names = {}, scheduled = false }
        if count > 0 then iRC:DebugMsg(iRC:Text("PROFILES_RECEIVED_SUMMARY", count), 3) end
    end)
end

local function summarizeRulesAck(sender, timestampHex)
    if not iRC:GetSettings().debugMode or not C_Timer or not C_Timer.After then return end
    local key = tostring(timestampHex or "0"):lower()
    local summary = rulesAckSummaries[key]
    if not summary then
        summary = { count = 0, names = {} }
        rulesAckSummaries[key] = summary
        C_Timer.After(2, function()
            local completed = rulesAckSummaries[key]
            rulesAckSummaries[key] = nil
            if completed and completed.count > 0 then
                iRC:DebugMsg(iRC:Text("RULES_CHECKSUM_VERIFIED_SUMMARY", completed.count, key), 3)
            end
        end)
    end
    local senderKey = iRC:NormalizeName(sender)
    if not summary.names[senderKey] then
        summary.names[senderKey] = true
        summary.count = summary.count + 1
    end
end

local function summarizeLegacyRulesAck(sender, timestampHex)
    if not iRC:GetSettings().debugMode or not C_Timer or not C_Timer.After then return end
    local key = tostring(timestampHex or "0"):lower()
    local summary = legacyRulesAckSummaries[key]
    if not summary then
        summary = { count = 0, names = {} }
        legacyRulesAckSummaries[key] = summary
        C_Timer.After(2, function()
            local completed = legacyRulesAckSummaries[key]
            legacyRulesAckSummaries[key] = nil
            if completed and completed.count > 0 then
                iRC:DebugMsg(iRC:Text("RULES_CHECKSUM_LEGACY_SUMMARY", completed.count, key), 3)
            end
        end)
    end
    local senderKey = iRC:NormalizeName(sender)
    if not summary.names[senderKey] then
        summary.names[senderKey] = true
        summary.count = summary.count + 1
    end
end

function iRC:GetLocalProfile()
    local raceName, raceFile = UnitRace("player")
    local _, classFile = UnitClass("player")
    return {
        addonVersion = self.Version, name = self:GetPlayerName() or "Unknown", guid = UnitGUID("player") or "",
        race = raceFile or raceName or "Unknown", class = classFile or "UNKNOWN", level = UnitLevel("player") or 1,
        selfFound = self:GetSelfFoundState(), selfFoundEvidence = self:GetSelfFoundEvidence(),
        shareGlobalRaceGrid = true,
        testGuildMasterOverride = self:IsTestAdminGuildMaster(),
        hideChatIcon = iRCCharDB and iRCCharDB.hideChatIcon == true,
        currentGroupRuleViolation = self.Enforcement and self.Enforcement.IsCurrentGroupViolation
            and self.Enforcement:IsCurrentGroupViolation() or false,
        lastSeen = time(),
    }
end

function iRC:StoreMemberProfile(profile)
    if type(profile) ~= "table" or not profile.name or not self:IsGuildConnectionActive() then return end
    self:CheckForNewVersion(profile.addonVersion)
    local connection = self:GetConnection()
    if not connection then return end
    connection.members[self:NormalizeName(profile.name)] = profile
    if self.ConnectionDashboard and self.ConnectionDashboard.ScheduleAttentionReminderCheck then
        self.ConnectionDashboard:ScheduleAttentionReminderCheck()
    end
    scheduleProfileUIRefresh()
end

function iRC:SendHello(targetName)
    if not self:IsGuildConnectionActive() then return end
    local profile = self:GetLocalProfile()
    self:StoreMemberProfile(profile)
    send(self.Prefix, addProfileParts({ "HELLO", WIRE_VERSION }, profile), targetName and "WHISPER" or "GUILD", targetName)
    self:DebugMsg(self:Text("PROFILE_SENT"), 3)
end

local function scheduleHello(targetName, maximumDelay)
    local key = targetName and ("whisper:" .. iRC:NormalizeName(targetName)) or "guild"
    if pendingHello[key] then return false end
    if not C_Timer or not C_Timer.After then iRC:SendHello(targetName); return true end
    pendingHello[key] = true
    local delay = 0.2 + math.random() * math.max(0, (tonumber(maximumDelay) or 5) - 0.2)
    C_Timer.After(delay, function()
        pendingHello[key] = nil
        iRC:SendHello(targetName)
    end)
    return true
end

function iRC:SendGuildActivation(targetName, force)
    if not force and self:DeferLowTraffic("traffic:activation:" .. tostring(targetName or "guild"), function() iRC:SendGuildActivation(targetName, force) end) then return false end
    if not self:IsInGuildConnection() then return end
    local isBroadcaster = self:IsRulesetBroadcaster()
    if not self:IsGuildMaster() and not isBroadcaster then return end
    local distribution = targetName and "WHISPER" or "GUILD"
    send(self.Prefix, table.concat({ "GUILD_ACTIVATION", WIRE_VERSION, self:IsGuildConnectionActive() and "1" or "0" }, SEP), distribution, targetName)
    self:DebugMsg(self:Text("GUILD_ACTIVATION_SENT", self:IsGuildConnectionActive() and self:Text("GUILD_ACTIVE") or self:Text("GUILD_INACTIVE")), 3)
end

function iRC:RequestGuildActivation(force)
    -- An inactive new client must be able to bootstrap during combat; otherwise
    -- it cannot answer presence checks until Low Traffic Mode ends.
    if self:IsGuildConnectionActive()
        and self:DeferLowTraffic("traffic:activation-request", function() iRC:RequestGuildActivation(force) end) then return false end
    if not self:IsInGuildConnection() or (not force and (self:IsGuildConnectionActive() or self:IsGuildMaster())) then return false end
    local guildKey, now = self:GetGuildKey(), GetTime()
    if not force and lastActivationRequestGuild == guildKey and lastActivationRequestAt
        and now - lastActivationRequestAt < ACTIVATION_REQUEST_COOLDOWN then return false end
    lastActivationRequestGuild, lastActivationRequestAt = guildKey, now
    send(self.Prefix, table.concat({ "GUILD_ACTIVATION_REQUEST", WIRE_VERSION }, SEP), "GUILD")
    self:DebugMsg(self:Text("GUILD_ACTIVATION_REQUESTED"), 3)
    return true
end

local function getRosterRank(name)
    if type(name) ~= "string" or not GetNumGuildMembers or not GetGuildRosterInfo then return nil end
    local wanted = iRC:NormalizeName(name)
    for index = 1, GetNumGuildMembers(true) do
        local memberName, _, rankIndex = GetGuildRosterInfo(index)
        if iRC:NormalizeName(memberName) == wanted then return tonumber(rankIndex) end
    end
end

local function getRulesRank(name, connection)
    local key = iRC:NormalizeName(name)
    local profile = connection and connection.members and connection.members[key]
    if key == iRC:NormalizeName(iRC:GetPlayerName()) and iRC:IsTestAdminGuildMaster() then return 0 end
    if profile and profile.testGuildMasterOverride == true and iRC:IsTestAdminName(name) then return 0 end
    local rankIndex = getRosterRank(name)
    return type(rankIndex) == "number" and rankIndex >= 0 and rankIndex or nil
end

local function getRulesAuthority()
    local connection = iRC:GetConnection()
    if not connection or connection.active ~= true then return nil end
    local ownName, now = iRC:GetPlayerName(), time()
    local bestName, bestRank = nil, nil
    local function consider(name, rank)
        if rank and (not bestRank or rank < bestRank
            or (rank == bestRank and iRC:NormalizeName(name) < iRC:NormalizeName(bestName))) then
            bestName, bestRank = name, rank
        end
    end
    consider(ownName, getRulesRank(ownName, connection))
    local count = GetNumGuildMembers and GetGuildRosterInfo and GetNumGuildMembers(true) or 0
    for index = 1, count do
        local name, _, _, _, _, _, _, _, online = GetGuildRosterInfo(index)
        if name and online and iRC:NormalizeName(name) ~= iRC:NormalizeName(ownName) then
            local profile = connection.members[iRC:NormalizeName(name)]
            local lastSeen = profile and tonumber(profile.lastSeen)
            if lastSeen and lastSeen >= (iRC.ConnectionSessionStartedAt or 0)
                and lastSeen <= now and now - lastSeen <= RULE_AUTHORITY_TIMEOUT then
                consider(name, getRulesRank(name, connection))
            end
        end
    end
    return bestName, bestRank
end

local function rulesBackupFingerprint(rules, timestampHex, timestampSource, includeContacts)
    rules = rules or {}
    return table.concat({
        rules.nativeTongueOnly and "1" or "0",
        rules.selfFoundOnly and "1" or "0",
        rules.level60GuildFound and "1" or "0",
        rules.allowLevel60WithoutSelfFound and "1" or "0",
        rules.sameRaceGroupsOnly and "1" or "0",
        rules.allowLevel60MixedRaceGroups and "1" or "0",
        iRC:NormalizeGuildRace(rules.guildRace),
        tostring(math.max(1, math.min(60, math.floor(tonumber(rules.sameRaceMinimumLevel) or 1)))),
        rules.guildGroupsOnly and "1" or "0",
        tostring(math.max(1, math.min(60, math.floor(tonumber(rules.guildGroupsMinimumLevel) or 1)))),
        includeContacts and tostring(rules.guildContacts or ""):gsub("[%c]", " "):sub(1, 140) or "",
        tostring(timestampHex or "0"):lower(),
        tostring(timestampSource or ""):gsub("[%c]", " "):sub(1, 80),
    }, SEP)
end

local function rulesBackupChecksum(value)
    local first, second = 1, 0
    for index = 1, #value do
        first = (first + value:byte(index)) % 65521
        second = (second + first) % 65521
    end
    return string.format("%04x%04x", second, first)
end

local function guildSettingsChecksum(enabled, timestamp, source)
    return rulesBackupChecksum(table.concat({ enabled and "1" or "0", tostring(timestamp or 0), tostring(source or "") }, SEP))
end

local TRADE_EXCEPTION_KEYS = {
    "conjured", "healthstones", "questItems", "customItems",
    "lockpickOutgoing", "lockpickIncoming", "warlockSummons", "magePortals",
}

local function tradeExceptionsMask(settings)
    local mask = 0
    for index, key in ipairs(TRADE_EXCEPTION_KEYS) do
        if settings and settings[key] == true then mask = mask + (2 ^ (index - 1)) end
    end
    return mask
end

local TRADE_ITEM_CATEGORIES = { "conjured", "healthstones", "questItems", "lockboxes" }

local function tradeItemMasks(settings)
    local masks = {}
    for _, category in ipairs(TRADE_ITEM_CATEGORIES) do
        local mask, selected = 0, settings and settings.items and settings.items[category] or {}
        for index, itemId in ipairs(iRC.GuildFoundTradeExceptionItems[category] or {}) do
            if selected[itemId] == true then mask = mask + (2 ^ (index - 1)) end
        end
        masks[#masks + 1] = tostring(mask)
    end
    return table.concat(masks, ",")
end

local function tradeExceptionsChecksum(mask, itemMasks, timestamp, source)
    return rulesBackupChecksum(table.concat({ tostring(mask), tostring(itemMasks or "0,0,0,0"), tostring(timestamp or 0), tostring(source or "") }, SEP))
end

local function rankPermissionsWire(values)
    local fields = {}
    for _, key in ipairs({ "verification", "presence", "incidents", "guildBanks", "notifications", "homepage" }) do
        fields[#fields + 1] = tostring(math.max(0, math.min(9, math.floor(tonumber(values and values[key]) or iRC.DefaultRankPermissions[key]))))
    end
    return table.concat(fields, ",")
end

function iRC:SendRankPermissions(targetName, force)
    if not force and self:DeferLowTraffic("traffic:rank-permissions:" .. tostring(targetName or "guild"), function() iRC:SendRankPermissions(targetName, force) end) then return false end
    if not self:IsGuildConnectionActive() or not self:IsGuildMaster() then return false end
    local connection = self:GetConnection()
    local timestamp = math.floor(tonumber(connection.rankPermissionsTimestamp) or 0)
    if timestamp <= 0 then
        timestamp = time(); connection.rankPermissionsTimestamp = timestamp
    end
    local wire = rankPermissionsWire(connection.rankPermissions)
    send(self.Prefix, table.concat({ "RANK_PERMISSIONS", WIRE_VERSION, wire, tostring(timestamp),
        rulesBackupChecksum(wire .. SEP .. timestamp) }, SEP), targetName and "WHISPER" or "GUILD", targetName)
    return true
end

local function guildBanksWire(members)
    local names = {}
    for name, enabled in pairs(members or {}) do if enabled then names[#names + 1] = tostring(name) end end
    table.sort(names)
    return table.concat(names, ",")
end

local function guildBanksChecksum(names, timestamp, source)
    return rulesBackupChecksum(table.concat({ tostring(names or ""), tostring(timestamp or 0), tostring(source or "") }, SEP))
end

local function validBranchChecksum(value)
    value = tostring(value or ""):lower()
    return value == "root" or value:match("^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$") ~= nil
end

local function resolutionContains(resolutions, checksum)
    checksum = tostring(checksum or "root"):lower()
    for value in tostring(resolutions or ""):lower():gmatch("[^,]+") do
        if value == checksum then return true end
    end
    return false
end

local function validResolutions(resolutions)
    resolutions = tostring(resolutions or ""):lower()
    if #resolutions > 17 then return false end
    if resolutions == "" then return true end
    local count = 0
    for value in resolutions:gmatch("[^,]+") do
        if not validBranchChecksum(value) then return false end
        count = count + 1
    end
    return count > 0 and count <= 2
end

local function resolvedPair(first, second)
    local values = { tostring(first or "root"):lower(), tostring(second or "root"):lower() }
    table.sort(values)
    return table.concat(values, ",")
end

local function mergeGuildBankNames(first, second)
    local names = {}
    for name in (tostring(first or "") .. "," .. tostring(second or "")):gmatch("[^,]+") do
        if name ~= "" then names[name] = true end
    end
    return guildBanksWire(names)
end

local function showManagementConflict(kind, incomingSource, acceptIncoming, keepCurrent, mergeValues, conflictId, currentValue, incomingValue, mergedValue)
    iRC.PendingManagementConflicts = iRC.PendingManagementConflicts or {}
    local existing = iRC.PendingManagementConflicts[kind]
    if existing and conflictId and existing.id == conflictId then return false end
    iRC.PendingManagementConflicts[kind] = {
        id = conflictId,
        source = incomingSource,
        acceptIncoming = acceptIncoming,
        keepCurrent = keepCurrent,
        mergeValues = mergeValues,
        currentValue = currentValue,
        incomingValue = incomingValue,
        mergedValue = mergedValue,
    }
    local label = iRC:Text(kind == "BANKS" and "MANAGEMENT_CONFLICT_BANKS" or "MANAGEMENT_CONFLICT_WELCOME")
    iRC:Print(iRC.Colors.Yellow .. iRC:Text("MANAGEMENT_CONFLICT_CHAT", label, incomingSource) .. iRC.Colors.Reset)
    if iRC.RefreshOptionsIfShown then iRC:RefreshOptionsIfShown() end
    return true
end

function iRC:GetPendingManagementConflict(kind)
    return self.PendingManagementConflicts and self.PendingManagementConflicts[kind] or nil
end

function iRC:ResolveManagementConflict(kind, action)
    local conflicts = self.PendingManagementConflicts
    local conflict = conflicts and conflicts[kind]
    if not conflict then return false end
    local callback = action == "merge" and conflict.mergeValues
        or (action == true or action == "incoming") and conflict.acceptIncoming
        or conflict.keepCurrent
    if not callback or callback() == false then return false end
    conflicts[kind] = nil
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    return true
end

local function sendManagementConflict(target, kind, value, timestamp, source, checksum, parentChecksum, resolutions)
    if iRC:DeferLowTraffic("traffic:management-conflict:" .. tostring(target or "") .. ":" .. tostring(kind or ""), function()
        sendManagementConflict(target, kind, value, timestamp, source, checksum, parentChecksum, resolutions)
    end) then return false end
    timestamp = tonumber(timestamp)
    source = tostring(source or "")
    checksum = tostring(checksum or "")
    if not target or target == "" or not timestamp or timestamp <= 0 or source == "" or checksum == "" then
        return false
    end
    if kind == "BANKS" and #tostring(value or "") > 120 then
        local total = math.ceil(#value / GUILD_BANK_CHUNK_SIZE)
        local transferId = tostring(checksum or "") .. tostring(timestamp or 0)
        for index = 1, total do
            send(iRC.Prefix, table.concat({
                "MGMT_BANKS_CHUNK", WIRE_VERSION, transferId, tostring(index), tostring(total),
                tostring(timestamp or 0), tostring(source or ""), tostring(checksum or ""),
                tostring(parentChecksum or "root"), tostring(resolutions or ""),
                value:sub((index - 1) * GUILD_BANK_CHUNK_SIZE + 1, index * GUILD_BANK_CHUNK_SIZE),
            }, SEP), "WHISPER", target)
        end
        return true
    end
    return send(iRC.Prefix, table.concat({
        "MGMT_CONFLICT", WIRE_VERSION, kind, tostring(value or ""), tostring(timestamp or 0),
        tostring(source or ""), tostring(checksum or ""), tostring(parentChecksum or ""), tostring(resolutions or ""),
    }, SEP), "WHISPER", target)
end

function iRC:SendGuildManagementSettings(targetName, force)
    if not force and self:DeferLowTraffic("traffic:management:" .. tostring(targetName or "guild"), function() iRC:SendGuildManagementSettings(targetName, force) end) then return false end
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("notifications") then return false end
    if not force and not self:IsRulesetBroadcaster() then return false end
    local connection = self:GetConnection()
    local settings = connection and connection.guildNotifications
    if not settings then return false end
    local timestamp = math.floor(tonumber(settings.timestamp) or 0)
    local source = tostring(settings.source or ""):gsub("[%c]", ""):sub(1, 80)
    -- No officer may invent a timestamp for the default. Only an explicit
    -- An authorized management change creates the first package; afterwards an authorized rank may
    -- relay the exact newest value it has received.
    if timestamp <= 0 or source == "" then
        return false
    end
    local enabled = settings.welcomeNewMembers ~= false
    local warningMask = (settings.disableOfficerWarnings and 1 or 0) + (settings.disableWhisperWarnings and 2 or 0) + (settings.disableGuildWarnings and 4 or 0)
    local distribution = targetName and "WHISPER" or "GUILD"
    send(self.Prefix, table.concat({
        "GUILD_SETTINGS", WIRE_VERSION, enabled and "1" or "0", tostring(timestamp), source,
        guildSettingsChecksum(enabled, timestamp, source), tostring(warningMask),
    }, SEP), distribution, targetName)
    self:DebugMsg(self:Text("GUILD_SETTINGS_SENT"), 3)
    return true
end

function iRC:SendGuildBankMetadata(targetName, onlyName, force)
    if not force and self:DeferLowTraffic("traffic:bank-metadata:" .. tostring(targetName or "guild"), function() iRC:SendGuildBankMetadata(targetName, onlyName, force) end) then return false end
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("guildBanks") then return false end
    local connection = self:GetConnection()
    local exceptions = connection and connection.guildBankExceptions
    local sentAny = false
    for name, detail in pairs(exceptions and exceptions.details or {}) do
        if exceptions.members[name] and (not onlyName or name == onlyName) then
            local note = tostring(detail.note or ""):gsub("[%c]", " "):sub(1, 80)
            send(self.Prefix, table.concat({
                "GUILD_BANK_NOTE", WIRE_VERSION, name,
                tostring(math.floor(tonumber(detail.addedAt) or 0)),
                tostring(detail.addedBy or ""):gsub("[%c]", " "):sub(1, 40),
                tostring(math.floor(tonumber(detail.updatedAt) or detail.addedAt or 0)), note,
                detail.bankType == "PERSONAL" and "P" or "G",
            }, SEP), targetName and "WHISPER" or "GUILD", targetName)
            sentAny = true
        end
    end
    return sentAny
end

function iRC:SendGuildContactMetadata(targetName, onlyName, force)
    if not force and self:DeferLowTraffic("traffic:contact-metadata:" .. tostring(targetName or "guild"), function() iRC:SendGuildContactMetadata(targetName, onlyName, force) end) then return false end
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("homepage") then return false end
    local connection = self:GetConnection()
    local contacts = tostring(connection.rules.guildContacts or "")
    local active = {}
    for name in contacts:gmatch("[^,]+") do active[name:gsub("^%s+", ""):gsub("%s+$", "")] = true end
    local sentAny = false
    for name, detail in pairs(connection.guildContactDetails or {}) do
        if active[name] and (not onlyName or name == onlyName) then
            send(self.Prefix, table.concat({ "GUILD_CONTACT_NOTE", WIRE_VERSION, name,
                tostring(math.floor(tonumber(detail.addedAt) or 0)),
                tostring(detail.addedBy or ""):gsub("[%c]", " "):sub(1, 40),
                tostring(math.floor(tonumber(detail.updatedAt) or detail.addedAt or 0)),
                tostring(detail.note or ""):gsub("[%c]", " "):sub(1, 80),
            }, SEP), targetName and "WHISPER" or "GUILD", targetName)
            sentAny = true
        end
    end
    return sentAny
end

function iRC:SendGuildContacts(targetName, force)
    if not force and self:DeferLowTraffic("traffic:contacts:" .. tostring(targetName or "guild"), function() iRC:SendGuildContacts(targetName, force) end) then return false end
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("homepage") then return false end
    local connection = self:GetConnection()
    local contacts = tostring(connection.rules.guildContacts or ""):gsub("[%c]", " "):sub(1, 140)
    local timestamp = math.floor(tonumber(connection.guildContactsTimestamp) or 0)
    local source = tostring(connection.guildContactsSource or self:GetPlayerName()):gsub("[%c]", ""):sub(1, 40)
    if timestamp <= 0 then timestamp = time(); connection.guildContactsTimestamp = timestamp end
    local checksum = rulesBackupChecksum(contacts .. SEP .. timestamp .. SEP .. source)
    send(self.Prefix, table.concat({ "GUILD_CONTACTS", WIRE_VERSION, contacts, tostring(timestamp), source, checksum }, SEP),
        targetName and "WHISPER" or "GUILD", targetName)
    self:SendGuildContactMetadata(targetName, nil, force)
    return true
end

function iRC:SendGuildHomepageDescription(targetName, force)
    if not force and self:DeferLowTraffic("traffic:homepage-description:" .. tostring(targetName or "guild"), function()
        iRC:SendGuildHomepageDescription(targetName, force)
    end) then return false end
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("homepage") then return false end
    if not force and not self:IsRulesetBroadcaster() then return false end
    local data = self:GetConnection().guildHomepageDescription
    local timestamp = math.floor(tonumber(data.timestamp) or 0)
    local editedBy = tostring(data.editedBy or ""):gsub("[%c]", ""):sub(1, 40)
    if timestamp <= 0 or editedBy == "" then return false end
    local value = tostring(data.text or ""):gsub("[%c]", " "):sub(1, self.GuildHomepageDescriptionMaxLength)
    if self:ContainsProfanity(value) then return false end
    local checksum = rulesBackupChecksum(value .. SEP .. timestamp .. SEP .. editedBy)
    send(self.Prefix, table.concat({ "GUILD_HOMEPAGE_DESC", WIRE_VERSION, value, tostring(timestamp), editedBy, checksum }, SEP),
        targetName and "WHISPER" or "GUILD", targetName)
    return true
end

function iRC:SendGuildHomepageIcon(targetName, force)
    if not force and self:DeferLowTraffic("traffic:homepage-icon:" .. tostring(targetName or "guild"), function()
        iRC:SendGuildHomepageIcon(targetName, force)
    end) then return false end
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("homepage") then return false end
    if not force and not self:IsRulesetBroadcaster() then return false end
    local data = self:GetConnection().guildHomepageIcon
    local icon, timestamp = math.floor(tonumber(data.icon) or 0), math.floor(tonumber(data.timestamp) or 0)
    local editedBy = tostring(data.editedBy or ""):gsub("[%c]", ""):sub(1, 80)
    if icon < 1 or icon > #self.GuildHomepageIcons or timestamp <= 0 or editedBy == "" then return false end
    local checksum = rulesBackupChecksum(table.concat({ icon, timestamp, editedBy }, SEP))
    send(self.Prefix, table.concat({ "GUILD_HOMEPAGE_ICON", WIRE_VERSION, icon, timestamp, editedBy, checksum }, SEP),
        targetName and "WHISPER" or "GUILD", targetName)
    return true
end

function iRC:SetGuildContactNote(name, note)
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("homepage") then return false end
    local connection = self:GetConnection()
    local fullName = self:ResolveGuildMemberFullName(name)
    if not fullName or not tostring(connection.rules.guildContacts or ""):find(fullName, 1, true) then return false end
    local now = GetServerTime and GetServerTime() or time()
    local detail = connection.guildContactDetails[fullName] or { addedAt = now, addedBy = self:GetPlayerName() }
    detail.note = tostring(note or ""):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 80)
    detail.updatedAt = math.max(math.floor(tonumber(detail.updatedAt) or 0) + 1, now)
    connection.guildContactDetails[fullName] = detail
    self:RecordManagementConnectionStatus("homepage", self:GetPlayerName(), detail.updatedAt,
        self:GetPlayerName(), detail.updatedAt)
    self:SendGuildContactMetadata(nil, fullName, true)
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    return true
end

function iRC:SetGuildBankNote(name, note)
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("guildBanks") then return false end
    local connection = self:GetConnection()
    local exceptions = connection.guildBankExceptions
    local fullName = self:ResolveGuildMemberFullName(name)
    if not fullName or not exceptions.members[fullName] then return false end
    note = tostring(note or ""):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", ""):sub(1, 80)
    local now = GetServerTime and GetServerTime() or time()
    local detail = exceptions.details[fullName] or { addedAt = now, addedBy = self:GetPlayerName() }
    detail.note = note
    detail.updatedAt = math.max(math.floor(tonumber(detail.updatedAt) or 0) + 1, now)
    exceptions.details[fullName] = detail
    self:RecordManagementConnectionStatus("guildFound", self:GetPlayerName(), detail.updatedAt,
        self:GetPlayerName(), detail.updatedAt)
    self:SendGuildBankMetadata(nil, fullName, true)
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    return true
end

function iRC:SetGuildBankType(name, bankType)
    if bankType ~= "GUILD" and bankType ~= "PERSONAL" then return false end
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("guildBanks") then return false end
    local connection = self:GetConnection()
    local fullName = self:ResolveGuildMemberFullName(name)
    local exceptions = connection and connection.guildBankExceptions
    if not fullName or not exceptions or not exceptions.members[fullName] then return false end
    local now = GetServerTime and GetServerTime() or time()
    local detail = exceptions.details[fullName] or { addedAt = now, addedBy = self:GetPlayerName(), note = "" }
    if (detail.bankType or "GUILD") == bankType then return true end
    detail.bankType = bankType
    detail.updatedAt = math.max(math.floor(tonumber(detail.updatedAt) or 0) + 1, now)
    exceptions.details[fullName] = detail
    self:SendGuildBankMetadata(nil, fullName, true)
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    if self.MainUI then self.MainUI:RefreshIfShown() end
    return true
end

function iRC:SetNewMemberWelcomeEnabled(enabled)
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("notifications") then return false end
    local connection = self:GetConnection()
    local settings = connection.guildNotifications
    local now = GetServerTime and GetServerTime() or time()
    settings.welcomeNewMembers = enabled and true or false
    settings.timestamp = math.max(math.floor(tonumber(settings.timestamp) or 0) + 1, now)
    settings.source = self:GetPlayerName()
    self:RecordManagementConnectionStatus("notifications", settings.source, settings.timestamp, self:GetPlayerName(), settings.timestamp)
    self:SendGuildManagementSettings(nil, true)
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    return true
end

function iRC:SetAutomaticWarningDisabled(channel, disabled)
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("notifications") then return false end
    local settings = self:GetConnection().guildNotifications
    local key = ({ OFFICER = "disableOfficerWarnings", WHISPER = "disableWhisperWarnings", GUILD = "disableGuildWarnings" })[channel]
    if not key then return false end
    settings[key] = disabled and true or false
    local now = GetServerTime and GetServerTime() or time()
    settings.timestamp = math.max(math.floor(tonumber(settings.timestamp) or 0) + 1, now)
    settings.source = self:GetPlayerName()
    self:RecordManagementConnectionStatus("notifications", settings.source, settings.timestamp, self:GetPlayerName(), settings.timestamp)
    self:SendGuildManagementSettings(nil, true)
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    return true
end

function iRC:GetGuildFoundTradeExceptionSettings()
    local connection = self:GetConnection()
    return connection and connection.guildFoundTradeExceptionSettings or self.DefaultGuildFoundTradeExceptions
end

function iRC:SetGuildFoundTradeException(key, enabled)
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("guildBanks")
        or not self:GetConnectionRules().guildFoundTradeExceptions
        or self.DefaultGuildFoundTradeExceptions[key] == nil then return false end
    local connection = self:GetConnection()
    local settings = connection.guildFoundTradeExceptionSettings
    local wasEnabled = settings[key] == true
    local itemCategory = ({
        conjured = "conjured",
        healthstones = "healthstones",
        questItems = "questItems",
        lockpickOutgoing = "lockboxes",
        lockpickIncoming = "lockboxes",
    })[key]
    local categoryWasEnabled = wasEnabled
    if itemCategory == "lockboxes" then
        categoryWasEnabled = settings.lockpickOutgoing == true or settings.lockpickIncoming == true
    end
    settings[key] = enabled and true or false
    if enabled and not categoryWasEnabled and itemCategory then
        settings.items = settings.items or {}
        settings.items[itemCategory] = {}
        for _, itemId in ipairs(self.GuildFoundTradeExceptionItems[itemCategory] or {}) do
            settings.items[itemCategory][itemId] = true
        end
    end
    settings.timestamp = math.max(time(), math.floor(tonumber(settings.timestamp) or 0) + 1)
    settings.source = self:GetPlayerName()
    self:RecordManagementConnectionStatus("guildFound", settings.source, settings.timestamp, self:GetPlayerName(), settings.timestamp)
    self:SendGuildFoundTradeExceptions(nil, true)
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    return true
end

function iRC:SetGuildFoundTradeExceptionItem(category, itemId, enabled)
    local presets = self.GuildFoundTradeExceptionItems[category]
    itemId = tonumber(itemId)
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("guildBanks")
        or not self:GetConnectionRules().guildFoundTradeExceptions or not presets or not itemId then return false end
    local known
    for _, presetId in ipairs(presets) do if presetId == itemId then known = true break end end
    if not known then return false end
    local settings = self:GetGuildFoundTradeExceptionSettings()
    settings.items = settings.items or {}
    settings.items[category] = settings.items[category] or {}
    settings.items[category][itemId] = enabled and true or nil
    settings.timestamp = math.max(time(), math.floor(tonumber(settings.timestamp) or 0) + 1)
    settings.source = self:GetPlayerName()
    self:RecordManagementConnectionStatus("guildFound", settings.source, settings.timestamp, self:GetPlayerName(), settings.timestamp)
    self:SendGuildFoundTradeExceptions(nil, true)
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    return true
end

function iRC:SendGuildFoundTradeExceptions(targetName, force)
    if not force and self:DeferLowTraffic("traffic:trade-exceptions:" .. tostring(targetName or "guild"), function() iRC:SendGuildFoundTradeExceptions(targetName, force) end) then return false end
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("guildBanks") then return false end
    if not force and not self:IsRulesetBroadcaster() then return false end
    local settings = self:GetGuildFoundTradeExceptionSettings()
    local timestamp = math.floor(tonumber(settings.timestamp) or 0)
    local source = tostring(settings.source or ""):gsub("[%c]", ""):sub(1, 80)
    if timestamp <= 0 or source == "" then return false end
    local mask = tradeExceptionsMask(settings)
    local itemMasks = tradeItemMasks(settings)
    send(self.Prefix, table.concat({ "GF_TRADE_EXCEPTIONS", WIRE_VERSION, tostring(mask),
        tostring(timestamp), source, tradeExceptionsChecksum(mask, itemMasks, timestamp, source), itemMasks }, SEP),
        targetName and "WHISPER" or "GUILD", targetName)
    return true
end

function iRC:SendGuildBankExceptions(targetName, force)
    if not force and self:DeferLowTraffic("traffic:banks:" .. tostring(targetName or "guild"), function() iRC:SendGuildBankExceptions(targetName, force) end) then return false end
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("guildBanks") then return false end
    if not force and not self:IsRulesetBroadcaster() then return false end
    local connection = self:GetConnection()
    local exceptions = connection and connection.guildBankExceptions
    local timestamp = exceptions and math.floor(tonumber(exceptions.timestamp) or 0) or 0
    local source = exceptions and tostring(exceptions.source or ""):gsub("[%c]", ""):sub(1, 40) or ""
    if timestamp <= 0 or source == "" then return false end
    local names = guildBanksWire(exceptions.members)
    if #names > MAX_GUILD_BANK_WIRE then return false end
    local checksum = guildBanksChecksum(names, timestamp, source)
    if exceptions.checksum and exceptions.checksum ~= checksum then
        self:DebugMsg(self:Text("GUILD_BANKS_RELAY_BLOCKED"), 2)
        return false
    end
    local distribution = targetName and "WHISPER" or "GUILD"
    if #names <= 120 then
        send(self.Prefix, table.concat({
            "GUILD_BANKS", WIRE_VERSION, names, tostring(timestamp), source,
            checksum, tostring(exceptions.parentChecksum or "root"), tostring(exceptions.resolutions or ""),
        }, SEP), distribution, targetName)
    else
        local total = math.ceil(#names / GUILD_BANK_CHUNK_SIZE)
        local transferId = checksum .. tostring(timestamp)
        for index = 1, total do
            send(self.Prefix, table.concat({
                "GUILD_BANKS_CHUNK", WIRE_VERSION, transferId, tostring(index), tostring(total),
                tostring(timestamp), source, checksum, tostring(exceptions.parentChecksum or "root"),
                tostring(exceptions.resolutions or ""),
                names:sub((index - 1) * GUILD_BANK_CHUNK_SIZE + 1, index * GUILD_BANK_CHUNK_SIZE),
            }, SEP), distribution, targetName)
        end
    end
    self:DebugMsg(self:Text("GUILD_BANKS_SENT"), 3)
    if targetName then self:SendGuildBankMetadata(targetName, nil, force) end
    return true
end

function iRC:SetGuildBankExceptions(value, resolutions)
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("guildBanks") then return false end
    local members, count = {}, 0
    for entry in tostring(value or ""):gmatch("[^,;\r\n]+") do
        entry = entry:gsub("^%s+", ""):gsub("%s+$", "")
        if entry ~= "" then
            local fullName = self:ResolveGuildMemberFullName(entry)
            if not fullName then
                self:Print(self.Colors.Red .. self:Text("GUILD_BANK_INVALID_MEMBER", entry) .. self.Colors.Reset)
                return false
            end
            if not members[fullName] then count = count + 1 end
            if count > MAX_GUILD_BANKS then
                self:Print(self.Colors.Red .. self:Text("GUILD_BANK_TOO_MANY") .. self.Colors.Reset)
                return false
            end
            members[fullName] = true
        end
    end
    local connection = self:GetConnection()
    local exceptions = connection.guildBankExceptions
    if #guildBanksWire(members) > MAX_GUILD_BANK_WIRE then
        self:Print(self.Colors.Red .. self:Text("GUILD_BANK_TOO_LONG") .. self.Colors.Reset)
        return false
    end
    local parentChecksum = exceptions.checksum or "root"
    local now = GetServerTime and GetServerTime() or time()
    local previousMembers = exceptions.members or {}
    local previousDetails = exceptions.details or {}
    local details = {}
    for name in pairs(members) do
        details[name] = previousDetails[name]
        if not details[name] and not previousMembers[name] then
            details[name] = { addedAt = now, addedBy = self:GetPlayerName(), updatedAt = now, note = "" }
        end
    end
    exceptions.members = members
    exceptions.details = details
    exceptions.timestamp = math.max(math.floor(tonumber(exceptions.timestamp) or 0) + 1, now)
    exceptions.source = self:GetPlayerName()
    exceptions.parentChecksum = parentChecksum
    exceptions.resolutions = tostring(resolutions or ""):lower():sub(1, 17)
    exceptions.checksum = guildBanksChecksum(guildBanksWire(members), exceptions.timestamp, exceptions.source)
    self:RecordManagementConnectionStatus("guildFound", exceptions.source, exceptions.timestamp,
        self:GetPlayerName(), exceptions.timestamp)
    self:SendGuildBankExceptions(nil, true)
    self:SendGuildBankMetadata(nil, nil, true)
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    if self.Enforcement then self.Enforcement:Refresh() end
    self:Print(self:Text("GUILD_BANK_SAVED", count))
    return true
end

function iRC:IsRulesetBroadcaster()
    local name, rank = getRulesAuthority()
    local isSelf = name ~= nil and self:NormalizeName(name) == self:NormalizeName(self:GetPlayerName())
    -- A newly loaded officer has not received the other clients' profiles yet.
    -- Give the actual active authority time to answer before permitting a
    -- non-Guild-Master fallback broadcaster to elect itself.
    if isSelf and not self:IsGuildMaster()
        and time() - (self.ConnectionSessionStartedAt or time()) < RULE_AUTHORITY_STARTUP_GRACE then
        return false, name, rank
    end
    return isSelf, name, rank
end

function iRC:ScheduleConnectionRulesBroadcast()
    if not C_Timer or not C_Timer.After then return self:SendConnectionRules(nil, true) end
    local guildKey = self:GetGuildKey()
    if not guildKey then return false end
    local token = {}
    pendingRulesBroadcast = { token = token, guildKey = guildKey }
    C_Timer.After(5, function()
        if not pendingRulesBroadcast or pendingRulesBroadcast.token ~= token then return end
        pendingRulesBroadcast = nil
        if iRC:GetGuildKey() == guildKey then iRC:SendConnectionRules(nil, true) end
    end)
    return true
end

function iRC:SendConnectionRules(targetName, force)
    -- Rule edits are published only after five quiet seconds. A direct force
    -- sync remains immediate, while routine relays wait for the final edit.
    if pendingRulesBroadcast and not force then return false end
    if not force and self:DeferLowTraffic("traffic:rules:" .. tostring(targetName or "guild"), function() iRC:SendConnectionRules(targetName, force) end) then return false end
    if self:SuppressesRuleSending() then return false end
    local isBroadcaster = self:IsRulesetBroadcaster()
    if not self:IsGuildConnectionActive() or not isBroadcaster then return end
    local rules = self:GetConnectionRules()
    local connection = self:GetConnection()
    local timestampHex, timestampSource = self:EnsureConnectionRulesTimestamp(connection)
    -- A non-GM client may only relay the exact ruleset it previously received.
    -- This prevents a same-rank elected broadcaster from propagating locally
    -- edited values while retaining the Guild Master's timestamp and source.
    if not self:IsGuildMaster()
        and (connection.receivedRulesBackupVersion ~= 1
            or connection.receivedRulesBackup ~= rulesBackupFingerprint(rules, timestampHex, timestampSource)) then
        self:DebugMsg(self:Text("RULES_RELAY_BLOCKED_BACKUP"), 2)
        return false
    end
    local distribution = targetName and "WHISPER" or "GUILD"
    local backup = rulesBackupFingerprint(rules, timestampHex, timestampSource)
    if force and not targetName then pendingRulesBroadcast = nil end
    send(self.Prefix, table.concat({
        "RULES", WIRE_VERSION,
        rules.nativeTongueOnly and "1" or "0",
        rules.selfFoundOnly and "1" or "0",
        rules.level60GuildFound and "1" or "0",
        rules.allowLevel60WithoutSelfFound and "1" or "0",
        rules.sameRaceGroupsOnly and "1" or "0",
        rules.allowLevel60MixedRaceGroups and "1" or "0",
        iRC:NormalizeGuildRace(rules.guildRace),
        tostring(math.max(1, math.min(60, math.floor(tonumber(rules.sameRaceMinimumLevel) or 1)))),
        rules.guildGroupsOnly and "1" or "0",
        tostring(math.max(1, math.min(60, math.floor(tonumber(rules.guildGroupsMinimumLevel) or 1)))),
        "",
        timestampHex,
        tostring(timestampSource or ""):gsub("[%c]", " "):sub(1, 80),
        rulesBackupChecksum(backup),
        rules.guildFoundTradeExceptions and "1" or "0",
        rulesBackupChecksum(table.concat({ rules.guildFoundTradeExceptions and "1" or "0", timestampHex, tostring(timestampSource or "") }, SEP)),
        self.Version,
        rules.guildMapEnabled and "1" or "0",
        rulesBackupChecksum(table.concat({ rules.guildMapEnabled and "1" or "0", timestampHex, tostring(timestampSource or "") }, SEP)),
        rules.raceLock == true and "1" or "0",
        rulesBackupChecksum(table.concat({ rules.raceLock == true and "1" or "0", timestampHex, tostring(timestampSource or "") }, SEP)),
        rules.guildFoundOnly and "1" or "0",
        rulesBackupChecksum(table.concat({ rules.guildFoundOnly and "1" or "0", timestampHex, tostring(timestampSource or "") }, SEP)),
        (rules.disableGuildLevel60Message and "1" or "0") .. (rules.disableGuildDeathMessage and "1" or "0"),
        rulesBackupChecksum(table.concat({
            rules.disableGuildLevel60Message and "1" or "0", rules.disableGuildDeathMessage and "1" or "0",
            timestampHex, tostring(timestampSource or ""),
        }, SEP)),
    }, SEP), distribution, targetName)
    if self:IsGuildMaster() and self.SendGuildContacts then self:SendGuildContacts(targetName, force) end
    if self:IsGuildMaster() and self.SendRankPermissions then self:SendRankPermissions(targetName, force) end
    self:DebugMsg(self:Text("RULES_SENT"), 3)
end

function iRC:RequestConnectionRules()
    if self:DeferLowTraffic("traffic:rules-request", function() iRC:RequestConnectionRules() end) then return false end
    if not self:IsInGuildConnection() then return false end
    local connection = self:GetConnection()
    local timestampHex = tostring(connection and connection.rulesTimestampHex or "0"):lower()
    if #timestampHex > 12 or not timestampHex:match("^[0-9a-f]+$") then timestampHex = "0" end
    return send(self.Prefix, table.concat({ "RULES_REQUEST", WIRE_VERSION, timestampHex }, SEP), "GUILD") and true or false
end

function iRC:ForceGuildSync()
    if self:IsLowTrafficMode() then
        self:Print(self.Colors.Yellow .. self:Text("FORCE_GUILD_SYNC_COMBAT") .. self.Colors.Reset)
        return false
    end
    if not self:IsInGuildConnection() then return false end
    self:RequestGuildActivation(true)
    self:RequestConnectionRules()
    self:SendHello()
    if self:IsGuildConnectionActive() then self:RequestGuildPresence(false) end
    if self:IsRulesetBroadcaster() then
        self:SendGuildActivation(nil, true)
        self:SendConnectionRules(nil, true)
        self:SendGuildManagementSettings(nil, true)
        self:SendGuildBankExceptions(nil, true)
        self:SendGuildBankMetadata(nil, nil, true)
        self:SendGuildFoundTradeExceptions(nil, true)
        self:SendGuildHomepageDescription(nil, true)
        self:SendGuildHomepageIcon(nil, true)
    end
    if self.RaceLockedSync then self.RaceLockedSync:Broadcast() end
    self:Print(self.Colors.Green .. self:Text("FORCE_GUILD_SYNC_DONE") .. self.Colors.Reset)
    return true
end

function iRC:RequestGuildPresence(isOfficerPoll)
    -- Presence probes and their small HELLO replies remain live in combat;
    -- deferring either side would make an active client appear missing.
    if not self:IsGuildConnectionActive() then return false end
    if not ((C_ChatInfo and C_ChatInfo.SendAddonMessage) or SendAddonMessage) then return false end
    local result = send(self.Prefix, table.concat({ "PRESENCE_REQUEST", WIRE_VERSION, isOfficerPoll and "OFFICER_POLL" or "REQUEST" }, SEP), "GUILD")
    if result == false or type(result) == "number" and result ~= 0 then return false end
    if isOfficerPoll then lastPresencePollAt = time() end
    self:DebugMsg(self:Text("PRESENCE_POLL_SENT"), 3)
    if isOfficerPoll then schedulePresenceReview() end
    return true
end

function iRC:PollGuildPresence()
    if not self:IsGuildConnectionActive() or not self:HasGuildPermission("presence") or time() - lastPresencePollAt < 55 then return false end
    return self:RequestGuildPresence(true)
end

function iRC:RequestInspection(targetName)
    if not self:IsGuildConnectionActive() or type(targetName) ~= "string" or targetName == "" then return false end
    requestNumber = requestNumber + 1
    send(self.Prefix, table.concat({ "INSPECT_REQUEST", WIRE_VERSION, tostring(time()) .. "-" .. tostring(requestNumber) }, SEP), "WHISPER", targetName)
    return true
end

function iRC:SendInspection(targetName, requestId)
    if not self:IsGuildConnectionActive() or not requestId then return end
    send(self.Prefix, addProfileParts({ "INSPECT_DATA", WIRE_VERSION, requestId }, self:GetLocalProfile()), "WHISPER", targetName)
end

local function cleanWireText(value, limit)
    return tostring(value or ""):gsub("[%c]", " "):sub(1, limit)
end

local GUILD_FOUND_AUDIT_ACTIONS = {
    TRADE_BLOCKED = true,
    TRADE_EXCEPTION_APPROVED = true,
    MAIL_BLOCKED = true,
    INBOX_BLOCKED = true,
    AUCTION_HOUSE_BLOCKED = true,
}

function iRC:StoreGuildFoundAudit(record)
    if type(record) ~= "table" or not GUILD_FOUND_AUDIT_ACTIONS[record.action] then return false end
    local connection = self:GetConnection()
    if not connection then return false end
    connection.guildFoundAudit = connection.guildFoundAudit or {}
    local id = cleanWireText(record.id, 100)
    if id == "" then return false end
    for _, existing in ipairs(connection.guildFoundAudit) do
        if existing.id == id then return false end
    end
    connection.guildFoundAudit[#connection.guildFoundAudit + 1] = {
        id = id,
        player = cleanWireText(record.player, 80),
        occurredAt = math.floor(tonumber(record.occurredAt) or time()),
        action = record.action,
        target = cleanWireText(record.target, 80),
        receivedAt = time(),
    }
    while #connection.guildFoundAudit > 200 do table.remove(connection.guildFoundAudit, 1) end
    if self.RefreshOptionsIfShown then self:RefreshOptionsIfShown() end
    return true
end

function iRC:GetGuildFoundAuditRecords()
    local connection = self:GetConnection()
    return connection and connection.guildFoundAudit or {}
end

function iRC:RecordGuildFoundAudit(action, target)
    local pureGuildFound = self:GetProgressionMode() == "GUILD_FOUND"
    if ((UnitLevel("player") or 0) < 60 and not pureGuildFound and not self:IsGuildBankException(self:GetPlayerName())) or not self:IsGuildFoundRequired()
        or not GUILD_FOUND_AUDIT_ACTIONS[action] then return false end
    local occurredAt = time()
    local player = self:GetPlayerName()
    local id = table.concat({ self:NormalizeName(player), occurredAt, action, cleanWireText(target, 40) }, ":")
    self:StoreGuildFoundAudit({ id = id, player = player, occurredAt = occurredAt, action = action, target = target })
    send(self.Prefix, table.concat({ "GF_AUDIT", WIRE_VERSION, id, tostring(occurredAt), action, cleanWireText(target, 80) }, SEP), "GUILD")
    self:DebugMsg(self:Text("GUILDFOUND_AUDIT_SENT", action), 3)
    return true
end

function iRC:UploadGuildFoundAudit(targetName)
    local targetRank = getRosterRank(targetName)
    if targetRank == nil or targetRank > 1 then return false end
    local key, now = self:NormalizeName(targetName), time()
    if guildFoundAuditUploadAt[key] and now - guildFoundAuditUploadAt[key] < 300 then return false end
    guildFoundAuditUploadAt[key] = now
    local records, sentCount = self:GetGuildFoundAuditRecords(), 0
    for index = #records, math.max(1, #records - 19), -1 do
        local record = records[index]
        if record.player and self:NormalizeName(record.player) == self:NormalizeName(self:GetPlayerName())
            and now - (tonumber(record.occurredAt) or 0) <= 604800 then
            send(self.Prefix, table.concat({
                "GF_AUDIT", WIRE_VERSION, cleanWireText(record.id, 100), tostring(record.occurredAt),
                record.action, cleanWireText(record.target, 80),
            }, SEP), "WHISPER", targetName)
            sentCount = sentCount + 1
        end
    end
    if sentCount > 0 then self:DebugMsg(self:Text("GUILDFOUND_AUDIT_HISTORY_SENT", sentCount, targetName), 3) end
    return sentCount > 0
end

function iRC:SendGroupViolation(record)
    if not self:IsGuildConnectionActive() or type(record) ~= "table" then return false end
    local occurredAt = math.floor(tonumber(record.occurredAt) or time())
    local instanceName = cleanWireText(record.instanceName, 40)
    local players = cleanWireText(table.concat(record.players or {}, ", "), 80)
    local violationId = cleanWireText(record.id or (self:NormalizeName(self:GetPlayerName()) .. ":" .. occurredAt), 60)
    record.id = violationId
    send(self.Prefix, table.concat({ "GROUP_VIOLATION", WIRE_VERSION, violationId, tostring(occurredAt), instanceName, players }, SEP), "GUILD")
    local locallyReported = false
    if self:IsPresenceNotificationLeader() and SendChatMessage and not seenGroupViolations[violationId] then
        seenGroupViolations[violationId] = true
        record.reporter = record.reporter or self:GetPlayerName()
        self:StoreOfficerIncident(record)
        if not self:IsAutomaticWarningDisabled("OFFICER") then SendChatMessage(self:Text("GROUP_VIOLATION_OFFICER", self:GetPlayerName(), instanceName, players), "OFFICER") end
        locallyReported = true
    end
    return locallyReported
end

function iRC:StoreOfficerIncident(record)
    if type(record) ~= "table" or not record.id then return false end
    local connection = self:GetConnection()
    if not connection then return false end
    connection.officerIncidents = connection.officerIncidents or {}
    for _, existing in ipairs(connection.officerIncidents) do
        if existing.id == record.id then return false end
    end
    connection.officerIncidents[#connection.officerIncidents + 1] = {
        id = record.id,
        reporter = cleanWireText(record.reporter, 80),
        occurredAt = math.floor(tonumber(record.occurredAt) or time()),
        instanceName = cleanWireText(record.instanceName, 60),
        players = type(record.players) == "table" and cleanWireText(table.concat(record.players, ", "), 100)
            or cleanWireText(record.players, 100),
        reason = cleanWireText(record.reason, 160),
        receivedAt = time(),
    }
    while #connection.officerIncidents > 100 do table.remove(connection.officerIncidents, 1) end
    if self.ConnectionDashboard then self.ConnectionDashboard:RefreshIfShown() end
    return true
end

function iRC:UploadOfficerIncidentsToGM(targetName)
    local ownRankIndex
    if GetGuildInfo then
        local _, _, playerRankIndex = GetGuildInfo("player")
        ownRankIndex = playerRankIndex
    end
    if ownRankIndex ~= 1 or getRosterRank(targetName) ~= 0 then return false end
    local targetKey, now = self:NormalizeName(targetName), time()
    if incidentUploadAt[targetKey] and now - incidentUploadAt[targetKey] < 300 then return false end
    incidentUploadAt[targetKey] = now
    local connection = self:GetConnection()
    local uploaded = false
    for _, record in ipairs(connection and connection.officerIncidents or {}) do
        if now - (tonumber(record.occurredAt) or 0) <= 86400 then
            send(self.Prefix, table.concat({
                "INCIDENT_UPLOAD", WIRE_VERSION,
                cleanWireText(record.id, 60), cleanWireText(record.reporter, 50),
                tostring(math.floor(tonumber(record.occurredAt) or now)),
                cleanWireText(record.instanceName, 40), cleanWireText(record.players, 60),
            }, SEP), "WHISPER", targetName)
            uploaded = true
        end
    end
    if uploaded then self:DebugMsg(self:Text("INCIDENTS_UPLOADED_TO_GM", targetName), 3) end
    return uploaded
end

local function senderIsKnown(sender)
    local connection = iRC:GetConnection()
    return connection and connection.members[iRC:NormalizeName(sender)] ~= nil
end

local function handleMessage(prefix, message, distribution, sender)
    if prefix ~= iRC.Prefix or not iRC:IsInGuildConnection() then return end
    if iRC:NormalizeName(sender) == iRC:NormalizeName(iRC:GetPlayerName()) then return end
    local parts, kind = split(message), nil
    kind = parts[1]
    if kind == "BANK_SNAPSHOT" then
        if distribution == "GUILD" and iRC:IsGuildConnectionActive() and iRC.GuildBankSnapshot then
            iRC.GuildBankSnapshot:Receive(message, sender)
        end
        return
    end
    if kind == "PROF_SUM" or kind == "PROF_REC" then
        if distribution == "GUILD" and iRC.Professions then iRC.Professions:Receive(message, sender) end
        return
    end
    if (kind == "GUILD_BANKS_CHUNK" or kind == "MGMT_BANKS_CHUNK") and parts[2] == WIRE_VERSION
        and iRC:IsGuildMemberName(sender) then
        local transferId = tostring(parts[3] or "")
        local index, total = tonumber(parts[4]), tonumber(parts[5])
        local timestamp, source = tonumber(parts[6]), tostring(parts[7] or "")
        local checksum, parentChecksum = tostring(parts[8] or ""):lower(), tostring(parts[9] or "root"):lower()
        local resolutions, chunk = tostring(parts[10] or ""):lower(), tostring(parts[11] or "")
        if transferId == "" or #transferId > 32 or not index or not total or index < 1 or index > total
            or total > 20 or #chunk > GUILD_BANK_CHUNK_SIZE or not timestamp or timestamp <= 0
            or #source > 40 or source == "" or not validBranchChecksum(parentChecksum)
            or not validResolutions(resolutions) then return end
        local key = iRC:NormalizeName(sender) .. ":" .. kind .. ":" .. transferId
        local transfer = guildBankTransfers[key]
        if not transfer or transfer.total ~= total or transfer.checksum ~= checksum then
            transfer = { total = total, checksum = checksum, chunks = {}, received = 0, createdAt = time() }
            guildBankTransfers[key] = transfer
        end
        if not transfer.chunks[index] then
            transfer.chunks[index] = chunk
            transfer.received = transfer.received + 1
        end
        if transfer.received == total then
            local names = table.concat(transfer.chunks)
            guildBankTransfers[key] = nil
            if #names > MAX_GUILD_BANK_WIRE then return end
            local rebuilt = kind == "GUILD_BANKS_CHUNK"
                and table.concat({ "GUILD_BANKS", WIRE_VERSION, names, tostring(timestamp), source, checksum, parentChecksum, resolutions }, SEP)
                or table.concat({ "MGMT_CONFLICT", WIRE_VERSION, "BANKS", names, tostring(timestamp), source, checksum, parentChecksum, resolutions }, SEP)
            handleMessage(prefix, rebuilt, distribution, sender)
        end
        for savedKey, saved in pairs(guildBankTransfers) do
            if time() - (saved.createdAt or 0) > 30 then guildBankTransfers[savedKey] = nil end
        end
        return
    end
    if kind == "GUILD_ACTIVATION" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        local active = parts[3] == "1"
        -- Any elected rank may relay an active connection to a new member, but
        -- only the actual Guild Master may turn an established guild off.
        if not active and not iRC:IsGuildMasterName(sender) then return end
        local changed = iRC:SetGuildConnectionActive(active, true)
        if active and changed then scheduleHello(nil, 3) end
        iRC:DebugMsg(iRC:Text("GUILD_ACTIVATION_RECEIVED", sender, active and iRC:Text("GUILD_ACTIVE") or iRC:Text("GUILD_INACTIVE")), 3)
        return
    elseif kind == "GUILD_ACTIVATION_REQUEST" and parts[2] == WIRE_VERSION and iRC:IsRulesetBroadcaster()
        and (distribution == "GUILD" or iRC:IsGuildMemberName(sender)) then
        -- Bootstrap the requesting client directly. A guild broadcast can be
        -- missed while its roster and addon-message state are still loading,
        -- leaving that client inactive and therefore unable to send HELLO.
        iRC:SendGuildActivation(sender, true)
        if iRC:IsGuildConnectionActive() then
            iRC:SendConnectionRules(sender)
            iRC:SendGuildManagementSettings(sender)
            iRC:SendGuildBankExceptions(sender)
            iRC:SendGuildFoundTradeExceptions(sender)
            iRC:SendGuildHomepageDescription(sender)
            iRC:SendGuildHomepageIcon(sender)
            send(iRC.Prefix, table.concat({ "PRESENCE_REQUEST", WIRE_VERSION, "REQUEST" }, SEP), "WHISPER", sender)
        end
        return
    elseif kind == "RULES_REQUEST" and parts[2] == WIRE_VERSION and distribution == "GUILD"
        and iRC:IsGuildMemberName(sender) and iRC:IsRulesetBroadcaster() and iRC:IsGuildConnectionActive() then
        local requestedHex = tostring(parts[3] or "0"):lower()
        local requestedTimestamp = #requestedHex <= 12 and requestedHex:match("^[0-9a-f]+$")
            and (tonumber(requestedHex, 16) or 0) or -1
        local connection = iRC:GetConnection()
        local localHex = tostring(connection and connection.rulesTimestampHex or "0"):lower()
        local localTimestamp = localHex:match("^[0-9a-f]+$") and (tonumber(localHex, 16) or 0) or 0
        if requestedTimestamp >= 0 and localTimestamp > requestedTimestamp then iRC:SendConnectionRules(sender) end
        return
    end
    if not iRC:IsGuildConnectionActive() then return end
    if kind == "HELLO" and parts[2] == WIRE_VERSION then
        local profile = profileFromWire(parts, 3)
        if profile and iRC:NormalizeName(profile.name) == iRC:NormalizeName(sender) then
            iRC:StoreMemberProfile(profile)
            summarizeProfileDebug(sender)
            iRC:UploadOfficerIncidentsToGM(sender)
            iRC:UploadGuildFoundAudit(sender)
            if iRC.RaceLockedSync then iRC.RaceLockedSync:RelayOverrides(sender) end
        end
    elseif kind == "PRESENCE_REQUEST" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        if parts[3] == "OFFICER_POLL" then
            -- Replies are whispered to the polling officer, not to everyone
            -- who heard the request. Never postpone our own poll here.
            schedulePresenceReview()
        end
        iRC:DebugMsg(iRC:Text("PRESENCE_POLL_RECEIVED", sender), 3)
        scheduleHello(sender, 5)
    elseif kind == "GROUP_VIOLATION" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        local violationId, occurredAt = parts[3], tonumber(parts[4])
        local instanceName, players = cleanWireText(parts[5], 60), cleanWireText(parts[6], 100)
        if violationId and violationId ~= "" and #violationId <= 100 and occurredAt
            and occurredAt <= time() + 300 and occurredAt >= time() - 86400
            and iRC:IsPresenceNotificationLeader() and SendChatMessage then
            if not seenGroupViolations[violationId] then
                seenGroupViolations[violationId] = true
                iRC:StoreOfficerIncident({
                    id = violationId, reporter = sender, occurredAt = occurredAt,
                    instanceName = instanceName, players = players,
                })
                if not iRC:IsAutomaticWarningDisabled("OFFICER") then SendChatMessage(iRC:Text("GROUP_VIOLATION_OFFICER", sender, instanceName, players), "OFFICER") end
            end
            -- Always acknowledge a valid repeat. The first acknowledgement may
            -- have been lost even though the officer notice was already sent.
            send(iRC.Prefix, table.concat({ "GROUP_VIOLATION_ACK", WIRE_VERSION, violationId }, SEP), "WHISPER", sender)
        end
    elseif kind == "GROUP_VIOLATION_ACK" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        if iRC.MarkGroupViolationReported then iRC:MarkGroupViolationReported(parts[3]) end
    elseif kind == "GF_AUDIT" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) and iRC:HasGuildPermission("incidents") then
        local occurredAt, action = tonumber(parts[4]), parts[5]
        if occurredAt and occurredAt <= time() + 300 and occurredAt >= time() - 604800
            and GUILD_FOUND_AUDIT_ACTIONS[action] then
            iRC:StoreGuildFoundAudit({
                id = cleanWireText(parts[3], 100), player = sender, occurredAt = occurredAt,
                action = action, target = cleanWireText(parts[6], 80),
            })
            iRC:DebugMsg(iRC:Text("GUILDFOUND_AUDIT_RECEIVED", action, sender), 3)
        end
    elseif kind == "INCIDENT_UPLOAD" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        local ownRankIndex
        if GetGuildInfo then
            local _, _, playerRankIndex = GetGuildInfo("player")
            ownRankIndex = playerRankIndex
        end
        local occurredAt = tonumber(parts[5])
        if ownRankIndex == 0 and getRosterRank(sender) == 1 and parts[3] and parts[3] ~= "" and occurredAt
            and occurredAt <= time() + 300 and occurredAt >= time() - 86400 then
            iRC:StoreOfficerIncident({
                id = cleanWireText(parts[3], 70), reporter = cleanWireText(parts[4], 60),
                occurredAt = occurredAt, instanceName = cleanWireText(parts[6], 45),
                players = cleanWireText(parts[7], 60),
            })
        end
    elseif kind == "INSPECT_REQUEST" then
        local requestId = parts[2] == WIRE_VERSION and parts[3] or nil
        if requestId and senderIsKnown(sender) then iRC:SendInspection(sender, requestId) end
    elseif kind == "INSPECT_DATA" and parts[2] == WIRE_VERSION then
        local profile = profileFromWire(parts, 4)
        if profile and senderIsKnown(sender) and iRC:NormalizeName(profile.name) == iRC:NormalizeName(sender) then iRC:StoreMemberProfile(profile) end
    elseif kind == "RANK_PERMISSIONS" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        local connection = iRC:GetConnection()
        local senderRank = getRulesRank(sender, connection)
        local wire, timestamp, checksum = tostring(parts[3] or ""), tonumber(parts[4]), tostring(parts[5] or ""):lower()
        local now = time()
        if senderRank == 0 and timestamp and timestamp > 0 and timestamp <= now + 300
            and checksum == rulesBackupChecksum(wire .. SEP .. timestamp)
            and timestamp >= math.floor(tonumber(connection.rankPermissionsTimestamp) or 0) then
            local values, count = {}, 0
            for value in wire:gmatch("[^,]+") do
                value = tonumber(value)
                if not value or value < 0 or value > 9 then count = -99; break end
                count = count + 1; values[count] = math.floor(value)
            end
            if count == 6 then
                for index, key in ipairs({ "verification", "presence", "incidents", "guildBanks", "notifications", "homepage" }) do
                    connection.rankPermissions[key] = values[index]
                end
                connection.rankPermissionsTimestamp = math.floor(timestamp)
                iRC:RecordManagementConnectionStatus("notifications", sender, timestamp, sender, now)
                if iRC.RefreshOptionsIfShown then iRC:RefreshOptionsIfShown() end
                if iRC.ConnectionDashboard then iRC.ConnectionDashboard:RefreshIfShown() end
            end
        end
    elseif kind == "GUILD_SETTINGS" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        local connection = iRC:GetConnection()
        local senderRank = getRulesRank(sender, connection)
        local senderIsGuildMaster = getRosterRank(sender) == 0
        local receiverIsGuildMaster = getRosterRank(iRC:GetPlayerName()) == 0
        local enabled = parts[3] == "1"
        local timestamp = tonumber(parts[4])
        local source = tostring(parts[5] or ""):gsub("[%c]", ""):sub(1, 80)
        local checksum = tostring(parts[6] or ""):lower()
        local warningMask = parts[7] and math.max(0, math.min(7, math.floor(tonumber(parts[7]) or 0))) or nil
        local now = GetServerTime and GetServerTime() or time()
        if senderRank and senderRank <= (connection.rankPermissions.notifications or 1) and timestamp and timestamp > 0 and timestamp <= now + 300
            and source ~= "" and checksum == guildSettingsChecksum(enabled, timestamp, source) then
            local connection = iRC:GetConnection()
            local settings = connection.guildNotifications
            local savedTimestamp = math.floor(tonumber(settings.timestamp) or 0)
            local savedSource = tostring(settings.source or "")
            local currentEnabled = settings.welcomeNewMembers == true
            if timestamp < savedTimestamp then return end
            local function applyWarningSettings()
                if warningMask == nil then return end
                settings.disableOfficerWarnings = warningMask % 2 >= 1
                settings.disableWhisperWarnings = math.floor(warningMask / 2) % 2 >= 1
                settings.disableGuildWarnings = math.floor(warningMask / 4) % 2 >= 1
            end
            if senderIsGuildMaster then
                settings.welcomeNewMembers = enabled
                applyWarningSettings()
                settings.timestamp = math.floor(timestamp)
                settings.source = source
                iRC:RecordManagementConnectionStatus("notifications", source, timestamp, sender, now)
                if iRC.PendingManagementConflicts then iRC.PendingManagementConflicts.WELCOME = nil end
                iRC:DebugMsg(iRC:Text("GUILD_SETTINGS_RECEIVED", sender), 3)
                if iRC.RefreshOptionsIfShown then iRC:RefreshOptionsIfShown() end
            elseif receiverIsGuildMaster and (timestamp > savedTimestamp or enabled ~= currentEnabled) then
                -- The Guild Master confirms a delegated change by saving and
                -- broadcasting a fresh GM-authored package.
                applyWarningSettings()
                iRC:SetNewMemberWelcomeEnabled(enabled)
                if iRC.PendingManagementConflicts then iRC.PendingManagementConflicts.WELCOME = nil end
            elseif timestamp == savedTimestamp and enabled ~= currentEnabled then
                local currentChecksum = guildSettingsChecksum(currentEnabled, savedTimestamp, savedSource)
                sendManagementConflict(sender, "WELCOME", currentEnabled and "1" or "0", savedTimestamp, savedSource, currentChecksum)
                showManagementConflict("WELCOME", source, function()
                    iRC:SetNewMemberWelcomeEnabled(enabled)
                end, function()
                    iRC:SetNewMemberWelcomeEnabled(currentEnabled)
                end)
            elseif timestamp > savedTimestamp then
                settings.welcomeNewMembers = enabled
                applyWarningSettings()
                settings.timestamp = math.floor(timestamp)
                settings.source = source
                iRC:RecordManagementConnectionStatus("notifications", source, timestamp, sender, now)
                iRC:DebugMsg(iRC:Text("GUILD_SETTINGS_RECEIVED", sender), 3)
                if iRC.RefreshOptionsIfShown then iRC:RefreshOptionsIfShown() end
            end
        end
    elseif kind == "GUILD_HOMEPAGE_DESC" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        if iRC:DeferLowTraffic("traffic:homepage-description-receive:" .. iRC:NormalizeName(sender), function()
            handleMessage(prefix, message, distribution, sender)
        end) then return end
        local connection = iRC:GetConnection()
        local senderRank = getRulesRank(sender, connection)
        local value, timestamp = tostring(parts[3] or ""), tonumber(parts[4])
        local editedBy = tostring(parts[5] or ""):gsub("[%c]", ""):sub(1, 80)
        local checksum = tostring(parts[6] or ""):lower()
        local saved = connection.guildHomepageDescription
        if #value <= iRC.GuildHomepageDescriptionMaxLength and not value:find("[%c]")
            and not iRC:ContainsProfanity(value)
            and senderRank and senderRank <= (connection.rankPermissions.homepage or 0)
            and timestamp and timestamp > math.floor(tonumber(saved.timestamp) or 0) and timestamp <= time() + 300
            and editedBy ~= "" and checksum == rulesBackupChecksum(value .. SEP .. timestamp .. SEP .. editedBy) then
            saved.text, saved.timestamp, saved.editedBy = value, math.floor(timestamp), editedBy
            iRC:RecordManagementConnectionStatus("homepage", editedBy, timestamp, sender, time())
            if iRC.RefreshOptionsIfShown then iRC:RefreshOptionsIfShown() end
            if iRC.RaceGrid then iRC.RaceGrid:BroadcastReport(false) end
        end
    elseif kind == "GUILD_HOMEPAGE_ICON" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        local connection = iRC:GetConnection()
        local senderRank = getRulesRank(sender, connection)
        local icon, timestamp = tonumber(parts[3]), tonumber(parts[4])
        local editedBy, checksum = tostring(parts[5] or ""):gsub("[%c]", ""):sub(1, 80), tostring(parts[6] or ""):lower()
        local saved = connection.guildHomepageIcon
        if icon and icon == math.floor(icon) and icon >= 1 and icon <= #iRC.GuildHomepageIcons
            and senderRank and senderRank <= (connection.rankPermissions.homepage or 0)
            and timestamp and timestamp > math.floor(tonumber(saved.timestamp) or 0) and timestamp <= time() + 300
            and editedBy ~= "" and checksum == rulesBackupChecksum(table.concat({ icon, timestamp, editedBy }, SEP)) then
            saved.icon, saved.timestamp, saved.editedBy = icon, math.floor(timestamp), editedBy
            iRC:RecordManagementConnectionStatus("homepage", editedBy, timestamp, sender, time())
            if iRC.RefreshOptionsIfShown then iRC:RefreshOptionsIfShown() end
            if iRC.RaceGrid then iRC.RaceGrid:BroadcastReport(false) end
        end
    elseif kind == "GUILD_CONTACTS" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        local connection = iRC:GetConnection()
        local senderRank = getRulesRank(sender, connection)
        local contacts, timestamp = tostring(parts[3] or ""), tonumber(parts[4])
        local source, checksum = tostring(parts[5] or ""):gsub("[%c]", ""):sub(1, 40), tostring(parts[6] or ""):lower()
        local valid, count = #contacts <= 140, 0
        for name in contacts:gmatch("[^,]+") do
            count = count + 1
            if count > 5 or not iRC:ResolveGuildMemberFullName(name:gsub("^%s+", ""):gsub("%s+$", "")) then valid = false end
        end
        if valid and senderRank and senderRank <= (connection.rankPermissions.homepage or 0)
            and timestamp and timestamp > math.floor(tonumber(connection.guildContactsTimestamp) or 0) and timestamp <= time() + 300
            and source ~= "" and checksum == rulesBackupChecksum(contacts .. SEP .. timestamp .. SEP .. source) then
            connection.rules.guildContacts = contacts
            connection.guildContactsTimestamp, connection.guildContactsSource = math.floor(timestamp), source
            iRC:RecordManagementConnectionStatus("homepage", source, timestamp, sender, time())
            if iRC.RefreshOptionsIfShown then iRC:RefreshOptionsIfShown() end
        end
    elseif kind == "GUILD_CONTACT_NOTE" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        local connection = iRC:GetConnection()
        local senderRank = getRulesRank(sender, connection)
        local name, addedAt = tostring(parts[3] or ""), tonumber(parts[4])
        local addedBy = tostring(parts[5] or ""):gsub("[%c]", ""):sub(1, 40)
        local updatedAt, note = tonumber(parts[6]), tostring(parts[7] or "")
        local fullName = iRC:ResolveGuildMemberFullName(name)
        local now = GetServerTime and GetServerTime() or time()
        if senderRank and senderRank <= (connection.rankPermissions.homepage or 0) and fullName == name and addedAt and addedAt > 0 and addedAt <= now + 300
            and updatedAt and updatedAt >= addedAt and updatedAt <= now + 300 and addedBy ~= ""
            and #note <= 80 and not note:find("[%c]") then
            connection.guildContactDetails = connection.guildContactDetails or {}
            local current = connection.guildContactDetails[name]
            if not current or updatedAt > math.floor(tonumber(current.updatedAt) or 0) then
                connection.guildContactDetails[name] = { addedAt = math.floor(addedAt), addedBy = addedBy,
                    updatedAt = math.floor(updatedAt), note = note }
                iRC:RecordManagementConnectionStatus("homepage", sender, updatedAt, sender, now)
                if iRC.RefreshOptionsIfShown then iRC:RefreshOptionsIfShown() end
            end
        end
    elseif kind == "GUILD_BANK_NOTE" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        local connection = iRC:GetConnection()
        local senderRank = getRulesRank(sender, connection)
        local name = tostring(parts[3] or "")
        local addedAt = tonumber(parts[4])
        local addedBy = tostring(parts[5] or ""):gsub("[%c]", ""):sub(1, 40)
        local updatedAt = tonumber(parts[6])
        local note = tostring(parts[7] or "")
        local bankType = parts[8] == "P" and "PERSONAL" or "GUILD"
        local fullName = iRC:ResolveGuildMemberFullName(name)
        local now = GetServerTime and GetServerTime() or time()
        if senderRank and senderRank <= (connection.rankPermissions.guildBanks or 1) and fullName == name and addedAt and addedAt > 0 and addedAt <= now + 300
            and updatedAt and updatedAt >= addedAt and updatedAt <= now + 300 and addedBy ~= ""
            and #note <= 80 and not note:find("[%c]") then
            local exceptions = connection.guildBankExceptions
            exceptions.details = exceptions.details or {}
            local current = exceptions.details[name]
            if not current or updatedAt > math.floor(tonumber(current.updatedAt) or 0) then
                exceptions.details[name] = { addedAt = math.floor(addedAt), addedBy = addedBy,
                    updatedAt = math.floor(updatedAt), note = note, bankType = bankType }
                iRC:RecordManagementConnectionStatus("guildFound", sender, updatedAt, sender, now)
                if iRC.RefreshOptionsIfShown then iRC:RefreshOptionsIfShown() end
            end
        end
    elseif kind == "GF_TRADE_EXCEPTIONS" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        local connection = iRC:GetConnection()
        local senderRank = getRulesRank(sender, connection)
        local senderIsGuildMaster = getRosterRank(sender) == 0
        local receiverIsGuildMaster = getRosterRank(iRC:GetPlayerName()) == 0
        local mask, timestamp = tonumber(parts[3]), tonumber(parts[4])
        local source = tostring(parts[5] or ""):gsub("[%c]", ""):sub(1, 80)
        local checksum = tostring(parts[6] or ""):lower()
        local itemMasks = tostring(parts[7] or "")
        local now = GetServerTime and GetServerTime() or time()
        if senderRank and senderRank <= (connection.rankPermissions.guildBanks or 1)
            and mask and mask >= 0 and mask <= 255 and mask == math.floor(mask)
            and timestamp and timestamp > 0 and timestamp <= now + 300 and source ~= ""
            and itemMasks:match("^%d+,%d+,%d+,%d+$") and #itemMasks <= 45
            and checksum == tradeExceptionsChecksum(mask, itemMasks, timestamp, source) then
            local settings = connection.guildFoundTradeExceptionSettings
            local savedTimestamp = math.floor(tonumber(settings.timestamp) or 0)
            if timestamp < savedTimestamp then return end
            if senderIsGuildMaster or timestamp > savedTimestamp then
                for index, key in ipairs(TRADE_EXCEPTION_KEYS) do
                    settings[key] = math.floor(mask / (2 ^ (index - 1))) % 2 == 1
                end
                settings.items = settings.items or {}
                local itemMaskValues = {}
                for value in itemMasks:gmatch("%d+") do itemMaskValues[#itemMaskValues + 1] = tonumber(value) or 0 end
                for categoryIndex, category in ipairs(TRADE_ITEM_CATEGORIES) do
                    settings.items[category] = {}
                    local itemMask = itemMaskValues[categoryIndex] or 0
                    for itemIndex, itemId in ipairs(iRC.GuildFoundTradeExceptionItems[category] or {}) do
                        if math.floor(itemMask / (2 ^ (itemIndex - 1))) % 2 == 1 then
                            settings.items[category][itemId] = true
                        end
                    end
                end
                settings.timestamp, settings.source = math.floor(timestamp), source
                iRC:RecordManagementConnectionStatus("guildFound", source, timestamp, sender, now)
                if receiverIsGuildMaster and not senderIsGuildMaster then
                    settings.timestamp = math.max(now, settings.timestamp + 1)
                    settings.source = iRC:GetPlayerName()
                    iRC:SendGuildFoundTradeExceptions(nil, true)
                end
                if iRC.RefreshOptionsIfShown then iRC:RefreshOptionsIfShown() end
            end
        end
    elseif kind == "GUILD_BANKS" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        local connection = iRC:GetConnection()
        local senderRank = getRulesRank(sender, connection)
        local senderIsGuildMaster = getRosterRank(sender) == 0
        local receiverIsGuildMaster = getRosterRank(iRC:GetPlayerName()) == 0
        local names = tostring(parts[3] or "")
        local timestamp = tonumber(parts[4])
        local source = tostring(parts[5] or ""):gsub("[%c]", ""):sub(1, 40)
        local checksum = tostring(parts[6] or ""):lower()
        local parentChecksum = tostring(parts[7] or "root"):lower()
        local resolutions = tostring(parts[8] or ""):lower()
        local sourceRank = getRulesRank(source, connection)
        local now = GetServerTime and GetServerTime() or time()
        if senderRank and senderRank <= (connection.rankPermissions.guildBanks or 1) and #names <= MAX_GUILD_BANK_WIRE and timestamp and timestamp > 0 and timestamp <= now + 300
            and source ~= "" and (senderIsGuildMaster or (sourceRank ~= nil and sourceRank <= (connection.rankPermissions.guildBanks or 1)))
            and validBranchChecksum(parentChecksum) and validResolutions(resolutions)
            and checksum == guildBanksChecksum(names, timestamp, source) then
            local members, valid, count = {}, true, 0
            for name in names:gmatch("[^,]+") do
                local fullName = iRC:ResolveGuildMemberFullName(name)
                if not fullName or fullName ~= name then valid = false; break end
                if not members[fullName] then count = count + 1 end
                if count > MAX_GUILD_BANKS then valid = false; break end
                members[fullName] = true
            end
            local exceptions = connection.guildBankExceptions
            local savedTimestamp = math.floor(tonumber(exceptions.timestamp) or 0)
            local currentNames = guildBanksWire(exceptions.members)
            local currentChecksum = tostring(exceptions.checksum or "root"):lower()
            local incomingResolvesCurrent = resolutionContains(resolutions, currentChecksum)
            local incomingIsChild = parentChecksum == currentChecksum
            local incomingIsAncestor = tostring(exceptions.parentChecksum or "root"):lower() == checksum
            if valid and timestamp < savedTimestamp then return end
            local function applyIncoming()
                local previousDetails = exceptions.details or {}
                local details = {}
                for name in pairs(members) do
                    details[name] = previousDetails[name] or {
                        addedAt = math.floor(timestamp), addedBy = source,
                        updatedAt = math.floor(timestamp), note = "",
                    }
                end
                exceptions.members = members
                exceptions.details = details
                exceptions.timestamp = math.floor(timestamp)
                exceptions.source = source
                exceptions.checksum = checksum
                exceptions.parentChecksum = parentChecksum
                exceptions.resolutions = resolutions
                iRC:RecordManagementConnectionStatus("guildFound", source, timestamp, sender, now)
                if (senderIsGuildMaster or incomingResolvesCurrent) and iRC.PendingManagementConflicts then
                    iRC.PendingManagementConflicts.BANKS = nil
                end
                iRC:DebugMsg(iRC:Text("GUILD_BANKS_RECEIVED", sender), 3)
                if iRC.RefreshOptionsIfShown then iRC:RefreshOptionsIfShown() end
                if iRC.Enforcement then iRC.Enforcement:Refresh() end
            end
            if valid and checksum == currentChecksum then
                iRC:RecordManagementConnectionStatus("guildFound", source, timestamp, sender, now)
                return
            elseif valid and senderIsGuildMaster then
                -- The actual roster Guild Master resolves same-age or newer
                -- management branches without an ancestry conflict.
                applyIncoming()
            elseif valid and receiverIsGuildMaster then
                -- A valid change from a delegated rank is confirmed by the
                -- Guild Master and immediately becomes a new GM-authored head.
                local pair = resolvedPair(currentChecksum, checksum)
                iRC:SetGuildBankExceptions(names, pair)
                if iRC.PendingManagementConflicts then iRC.PendingManagementConflicts.BANKS = nil end
            elseif valid and timestamp >= savedTimestamp and (incomingResolvesCurrent or incomingIsChild) then
                applyIncoming()
            elseif valid and incomingIsAncestor then
                return
            elseif valid then
                local pair = resolvedPair(currentChecksum, checksum)
                local merged = mergeGuildBankNames(currentNames, names)
                local conflictId = pair
                local isNewConflict = showManagementConflict("BANKS", source,
                    function() iRC:SetGuildBankExceptions(names, pair) end,
                    function() iRC:SetGuildBankExceptions(currentNames, pair) end,
                    function() iRC:SetGuildBankExceptions(merged, pair) end,
                    conflictId, currentNames, names, merged)
                if isNewConflict then
                    sendManagementConflict(sender, "BANKS", currentNames, savedTimestamp,
                        tostring(exceptions.source or ""), currentChecksum,
                        tostring(exceptions.parentChecksum or "root"), tostring(exceptions.resolutions or ""))
                end
            end
        end
    elseif kind == "MGMT_CONFLICT" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        local connection = iRC:GetConnection()
        if not connection then return end
        local senderRank = getRulesRank(sender, connection)
        local settingKind, value = parts[3], tostring(parts[4] or "")
        local timestamp, source = tonumber(parts[5]), tostring(parts[6] or ""):gsub("[%c]", ""):sub(1, 80)
        local checksum = tostring(parts[7] or ""):lower()
        local now = GetServerTime and GetServerTime() or time()
        local permission = settingKind == "WELCOME" and "notifications"
            or settingKind == "BANKS" and "guildBanks" or nil
        local allowedRank = permission and iRC:GetGuildRankPermission(permission)
        if allowedRank and senderRank and senderRank <= allowedRank and timestamp and timestamp > 0 and timestamp <= now + 300 and source ~= "" then
            if settingKind == "WELCOME" and (value == "0" or value == "1")
                and checksum == guildSettingsChecksum(value == "1", timestamp, source) then
                local settings, incoming = connection.guildNotifications, value == "1"
                local current = settings.welcomeNewMembers == true
                if timestamp == math.floor(tonumber(settings.timestamp) or 0) and incoming ~= current then
                    showManagementConflict("WELCOME", source, function()
                        iRC:SetNewMemberWelcomeEnabled(incoming)
                    end, function() iRC:SetNewMemberWelcomeEnabled(current) end)
                end
            elseif settingKind == "BANKS" and #value <= MAX_GUILD_BANK_WIRE
                and checksum == guildBanksChecksum(value, timestamp, source) then
                local parentChecksum = tostring(parts[8] or "root"):lower()
                local resolutions = tostring(parts[9] or ""):lower()
                local members, valid, count = {}, true, 0
                for name in value:gmatch("[^,]+") do
                    local fullName = iRC:ResolveGuildMemberFullName(name)
                    if not fullName or fullName ~= name then valid = false; break end
                    if not members[fullName] then count = count + 1 end
                    if count > MAX_GUILD_BANKS then valid = false; break end
                    members[fullName] = true
                end
                local exceptions = connection.guildBankExceptions
                local currentNames = guildBanksWire(exceptions.members)
                local currentChecksum = tostring(exceptions.checksum or "root"):lower()
                local incomingAlreadyResolved = resolutionContains(exceptions.resolutions, checksum)
                    or tostring(exceptions.parentChecksum or "root"):lower() == checksum
                if valid and validBranchChecksum(parentChecksum) and validResolutions(resolutions)
                    and checksum ~= currentChecksum and not incomingAlreadyResolved then
                    local pair = resolvedPair(currentChecksum, checksum)
                    local merged = mergeGuildBankNames(currentNames, value)
                    showManagementConflict("BANKS", source,
                        function() iRC:SetGuildBankExceptions(value, pair) end,
                        function() iRC:SetGuildBankExceptions(currentNames, pair) end,
                        function() iRC:SetGuildBankExceptions(merged, pair) end,
                        pair, currentNames, value, merged)
                end
            end
        end
    elseif kind == "RULES_ACK" and parts[2] == WIRE_VERSION and iRC:IsGuildMemberName(sender) then
        local connection = iRC:GetConnection()
        local timestampHex, timestampSource = iRC:EnsureConnectionRulesTimestamp(connection)
        local expected = rulesBackupChecksum(rulesBackupFingerprint(iRC:GetConnectionRules(), timestampHex, timestampSource))
        local expectedExtension = rulesBackupChecksum(table.concat({
            iRC:GetConnectionRules().guildFoundTradeExceptions and "1" or "0", timestampHex, tostring(timestampSource or ""),
        }, SEP))
        local expectedMapExtension = rulesBackupChecksum(table.concat({
            iRC:GetConnectionRules().guildMapEnabled and "1" or "0", timestampHex, tostring(timestampSource or ""),
        }, SEP))
        local expectedRaceLockExtension = rulesBackupChecksum(table.concat({
            iRC:GetConnectionRules().raceLock == true and "1" or "0", timestampHex, tostring(timestampSource or ""),
        }, SEP))
        local expectedGuildFoundExtension = rulesBackupChecksum(table.concat({
            iRC:GetConnectionRules().guildFoundOnly and "1" or "0", timestampHex, tostring(timestampSource or ""),
        }, SEP))
        local expectedAnnouncementExtension = rulesBackupChecksum(table.concat({
            iRC:GetConnectionRules().disableGuildLevel60Message and "1" or "0",
            iRC:GetConnectionRules().disableGuildDeathMessage and "1" or "0", timestampHex, tostring(timestampSource or ""),
        }, SEP))
        if tostring(parts[3] or ""):lower() == tostring(timestampHex):lower()
            and tostring(parts[4] or ""):lower() == expected then
            if tostring(parts[5] or ""):lower() == expectedExtension
                and tostring(parts[6] or ""):lower() == expectedMapExtension
                and (tostring(parts[7] or "") == "" or tostring(parts[7]):lower() == expectedRaceLockExtension)
                and (tostring(parts[8] or "") == "" or tostring(parts[8]):lower() == expectedGuildFoundExtension)
                and (tostring(parts[9] or "") == "" or tostring(parts[9]):lower() == expectedAnnouncementExtension) then
                summarizeRulesAck(sender, timestampHex)
            elseif tostring(parts[5] or "") == "" or tostring(parts[6] or "") == "" then
                summarizeLegacyRulesAck(sender, timestampHex)
            else
                iRC:DebugMsg(iRC:Text("RULES_CHECKSUM_ACK_MISMATCH", sender), 1)
            end
        else
            iRC:DebugMsg(iRC:Text("RULES_CHECKSUM_ACK_MISMATCH", sender), 1)
        end
    elseif kind == "RULES" and parts[2] == WIRE_VERSION then
        iRC:CheckForNewVersion(parts[19])
        local connection = iRC:GetConnection()
        local timestampHex = tostring(parts[14] or "0"):lower()
        local timestampSource = tostring(parts[15] or ""):sub(1, 80)
        local validTimestamp = #timestampHex <= 12 and timestampHex:match("^[0-9a-f]+$") ~= nil
        local incomingTimestamp = validTimestamp and (tonumber(timestampHex, 16) or 0) or -1
        local savedHex = tostring(connection and connection.rulesTimestampHex or "0"):lower()
        local savedTimestamp = savedHex:match("^[0-9a-f]+$") and (tonumber(savedHex, 16) or 0) or 0
        local senderRank = getRulesRank(sender, connection)
        -- Only the real roster rank 0 gets final rules authority, while the
        -- timestamp gate below still protects a newer local ruleset.
        local senderIsGuildMaster = getRosterRank(sender) == 0
        if senderIsGuildMaster then
            timestampSource = sender
            if not validTimestamp or incomingTimestamp > time() + 300 then
                incomingTimestamp = time()
                timestampHex = string.format("%x", incomingTimestamp)
                validTimestamp = true
            end
        end
        local timestampSourceValid = incomingTimestamp == 0
            or (timestampSource ~= "" and iRC:IsGuildMasterName(timestampSource))
        local incomingRules = {
            nativeTongueOnly = parts[3] == "1",
            selfFoundOnly = parts[4] == "1",
            level60GuildFound = parts[5] == "1",
            allowLevel60WithoutSelfFound = parts[6] == "1",
            sameRaceGroupsOnly = parts[7] == "1",
            allowLevel60MixedRaceGroups = parts[8] == "1",
            guildRace = iRC:NormalizeGuildRace(parts[9]),
            sameRaceMinimumLevel = math.max(1, math.min(60, math.floor(tonumber(parts[10]) or 1))),
            guildGroupsOnly = parts[11] == "1",
            guildGroupsMinimumLevel = math.max(1, math.min(60, math.floor(tonumber(parts[12]) or 1))),
            guildFoundTradeExceptions = parts[17] == "1",
            guildMapEnabled = parts[20] == "1",
            raceLock = parts[22] == "1",
            guildFoundOnly = parts[24] == "1",
            disableGuildLevel60Message = tostring(parts[26] or ""):sub(1, 1) == "1",
            disableGuildDeathMessage = tostring(parts[26] or ""):sub(2, 2) == "1",
        }
        -- Older clients do not know this extension. Their relays must not
        -- silently clear announcement preferences already received locally.
        if not parts[26] or parts[26] == "" then
            incomingRules.disableGuildLevel60Message = connection and connection.rules.disableGuildLevel60Message or false
            incomingRules.disableGuildDeathMessage = connection and connection.rules.disableGuildDeathMessage or false
        end
        local legacyContacts = tostring(parts[13] or ""):sub(1, 140)
        if legacyContacts ~= "" then incomingRules.guildContacts = legacyContacts end
        if not incomingRules.raceLock then
            incomingRules.nativeTongueOnly = false
            incomingRules.sameRaceGroupsOnly = false
            incomingRules.allowLevel60MixedRaceGroups = false
        end
        local incomingBackup = rulesBackupFingerprint(incomingRules, timestampHex, timestampSource)
        local legacyIncomingBackup = rulesBackupFingerprint(incomingRules, timestampHex, timestampSource, true)
        local incomingContactCount = 0
        for contact in legacyContacts:gmatch("[^,]+") do
            if contact:gsub("%s+", "") ~= "" then incomingContactCount = incomingContactCount + 1 end
        end
        local progressionIsExclusive = not (incomingRules.level60GuildFound and incomingRules.allowLevel60WithoutSelfFound)
            and not (incomingRules.guildFoundOnly and (incomingRules.selfFoundOnly or incomingRules.level60GuildFound))
            and (incomingRules.selfFoundOnly or not incomingRules.allowLevel60WithoutSelfFound)
        local incomingChecksum = tostring(parts[16] or ""):lower()
        local checksumValid = incomingChecksum == "" or incomingChecksum == rulesBackupChecksum(incomingBackup)
            or incomingContactCount <= 5 and incomingChecksum == rulesBackupChecksum(legacyIncomingBackup)
        local exceptionFlagPresent = parts[17] == "0" or parts[17] == "1"
        local exceptionChecksum = tostring(parts[18] or ""):lower()
        local exceptionChecksumValid = not exceptionFlagPresent or exceptionChecksum == rulesBackupChecksum(table.concat({
            incomingRules.guildFoundTradeExceptions and "1" or "0", timestampHex, timestampSource,
        }, SEP))
        local mapFlagPresent = parts[20] == "0" or parts[20] == "1"
        local mapChecksum = tostring(parts[21] or ""):lower()
        local mapChecksumValid = not mapFlagPresent or mapChecksum == rulesBackupChecksum(table.concat({
            incomingRules.guildMapEnabled and "1" or "0", timestampHex, timestampSource,
        }, SEP))
        local raceLockFlagPresent = parts[22] == "0" or parts[22] == "1"
        local raceLockChecksum = tostring(parts[23] or ""):lower()
        local raceLockChecksumValid = not raceLockFlagPresent or raceLockChecksum == rulesBackupChecksum(table.concat({
            incomingRules.raceLock and "1" or "0", timestampHex, timestampSource,
        }, SEP))
        local guildFoundFlagPresent = parts[24] == "0" or parts[24] == "1"
        local guildFoundChecksum = tostring(parts[25] or ""):lower()
        local guildFoundChecksumValid = not guildFoundFlagPresent or guildFoundChecksum == rulesBackupChecksum(table.concat({
            incomingRules.guildFoundOnly and "1" or "0", timestampHex, timestampSource,
        }, SEP))
        local announcementFlags = tostring(parts[26] or "")
        local announcementFlagsPresent = announcementFlags:match("^[01][01]$") ~= nil
        local announcementChecksum = tostring(parts[27] or ""):lower()
        local announcementChecksumValid = (announcementFlags == "" or announcementFlagsPresent)
            and (not announcementFlagsPresent or announcementChecksum == rulesBackupChecksum(table.concat({
            incomingRules.disableGuildLevel60Message and "1" or "0",
            incomingRules.disableGuildDeathMessage and "1" or "0", timestampHex, timestampSource,
        }, SEP)))
        local rulesSchemaSupported = supportsCurrentRuleset(parts[19])
            and raceLockFlagPresent and guildFoundFlagPresent
            and raceLockChecksumValid and guildFoundChecksumValid
        local sameStampMatches = incomingTimestamp ~= savedTimestamp or not connection
            or connection.receivedRulesBackupVersion ~= 1 or not connection.receivedRulesBackup
            or connection.receivedRulesBackup == incomingBackup
        local authorityName, authorityRank = getRulesAuthority()
        local senderIsAuthority = senderIsGuildMaster or senderRank ~= nil and (authorityRank == nil or senderRank < authorityRank
            or (senderRank == authorityRank and (not authorityName
                or distribution == "WHISPER"
                or iRC:NormalizeName(authorityName) == iRC:NormalizeName(sender))))
        local timestampAccepted = validTimestamp and incomingTimestamp >= savedTimestamp
        local contentAccepted = senderIsGuildMaster or checksumValid and exceptionChecksumValid and mapChecksumValid
            and raceLockChecksumValid and guildFoundChecksumValid and announcementChecksumValid and sameStampMatches
        local acceptRules = rulesSchemaSupported and timestampAccepted and (senderIsGuildMaster
            or senderIsAuthority and progressionIsExclusive and incomingContactCount <= 5
                and validTimestamp and incomingTimestamp <= time() + 300 and timestampSourceValid
                and contentAccepted)
        if connection and acceptRules then
            for key, value in pairs(incomingRules) do connection.rules[key] = value end
            connection.rulesTimestampHex = timestampHex
            connection.rulesTimestampSource = timestampSource
            connection.rulesRelayedBy = sender
            connection.rulesReceivedAt = time()
            connection.receivedRulesBackup = incomingBackup
            connection.receivedRulesBackupVersion = 1
            connection.receivedRulesChecksum = rulesBackupChecksum(incomingBackup)
            if incomingRules.level60GuildFound or incomingRules.guildFoundOnly then iRC:MarkGuildFoundRequired(connection) end
            if iRC.RefreshOptionsIfShown then iRC:RefreshOptionsIfShown() end
            if iRC.Enforcement then iRC.Enforcement:Refresh() end
            if iRC.GuildMap then
                if iRC.GuildMap.UpdateToggle then iRC.GuildMap.UpdateToggle() end
                iRC.GuildMap:UpdatePins()
                if incomingRules.guildMapEnabled then iRC.GuildMap:SchedulePosition(5) end
            end
            iRC:DebugMsg(iRC:Text("RULES_RECEIVED", sender), 3)
            local receivedExtensionChecksum = rulesBackupChecksum(table.concat({
                incomingRules.guildFoundTradeExceptions and "1" or "0", timestampHex, timestampSource,
            }, SEP))
            local receivedMapChecksum = rulesBackupChecksum(table.concat({
                incomingRules.guildMapEnabled and "1" or "0", timestampHex, timestampSource,
            }, SEP))
            local receivedRaceLockChecksum = rulesBackupChecksum(table.concat({
                incomingRules.raceLock and "1" or "0", timestampHex, timestampSource,
            }, SEP))
            local receivedGuildFoundChecksum = rulesBackupChecksum(table.concat({
                incomingRules.guildFoundOnly and "1" or "0", timestampHex, timestampSource,
            }, SEP))
            local receivedAnnouncementChecksum = rulesBackupChecksum(table.concat({
                incomingRules.disableGuildLevel60Message and "1" or "0",
                incomingRules.disableGuildDeathMessage and "1" or "0", timestampHex, timestampSource,
            }, SEP))
            send(iRC.Prefix, table.concat({ "RULES_ACK", WIRE_VERSION, timestampHex,
                connection.receivedRulesChecksum, receivedExtensionChecksum, receivedMapChecksum, receivedRaceLockChecksum,
                receivedGuildFoundChecksum, receivedAnnouncementChecksum }, SEP), "WHISPER", sender)
        elseif connection and senderRank ~= nil then
            if senderIsAuthority and not senderIsGuildMaster and (not checksumValid or not sameStampMatches) then
                iRC:DebugMsg(iRC:Text("RULES_CHECKSUM_MISMATCH", sender, timestampHex), 1)
            end
            if not senderIsAuthority then iRC:DebugMsg(iRC:Text("RULES_IGNORED_LOWER_AUTHORITY", sender), 3) end
        end
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        registerPrefix(iRC.Prefix)
        ignoreGuildUpdatesUntil = GetTime() + 8
        C_Timer.After(iRC:GetStartupTrafficDelay(), function()
            iRC:SendGuildActivation()
            iRC:RequestGuildActivation()
            scheduleHello(nil, 5)
            if iRC:HasGuildPermission("presence") then iRC:PollGuildPresence() else iRC:RequestGuildPresence() end
            iRC:RequestConnectionRules()
            iRC:SendGuildManagementSettings()
            iRC:SendGuildBankExceptions()
            iRC:SendGuildFoundTradeExceptions()
            iRC:SendGuildHomepageDescription()
        end)
        if C_Timer and C_Timer.NewTicker then
            C_Timer.NewTicker(60, function()
                iRC:SendGuildActivation()
                iRC:RequestGuildActivation()
                scheduleHello(nil, 15)
            end)
            C_Timer.NewTicker(120, function()
                iRC:SendConnectionRules()
            end)
            C_Timer.NewTicker(300, function()
                iRC:SendGuildManagementSettings()
                iRC:SendGuildBankExceptions()
                iRC:SendGuildFoundTradeExceptions()
                iRC:SendGuildHomepageDescription()
            end)
            C_Timer.NewTicker(60, function()
                iRC:PollGuildPresence()
            end)
        end
    elseif event == "PLAYER_GUILD_UPDATE" then
        local unit = ...
        if unit ~= "player" or guildUpdatePending or GetTime() < ignoreGuildUpdatesUntil then return end
        guildUpdatePending = true
        C_Timer.After(1, function()
            guildUpdatePending = false
            iRC:SendGuildActivation()
            iRC:RequestGuildActivation()
            scheduleHello(nil, 5)
            if iRC:HasGuildPermission("presence") then iRC:PollGuildPresence() else iRC:RequestGuildPresence() end
            iRC:SendConnectionRules()
            iRC:SendGuildManagementSettings()
            iRC:SendGuildBankExceptions()
            iRC:SendGuildFoundTradeExceptions()
            iRC:SendGuildHomepageDescription()
        end)
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, distribution, sender = ...
        handleMessage(prefix, message, distribution, sender)
    end
end)
