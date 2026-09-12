local _, private = ...
local iRC = private and private.iRC
if not iRC then return end

local Sync = {}
iRC.RaceLockedSync = Sync
local IRC_ROSTER = "iRCGFRoster"
local lastBroadcast, pendingRelays = {}, {}
local moneyReady = false
local moneyValidationAllowedAt = 0
local moneyWatchdog
local playedTicker, playedRequestToken
local playedSuppressedChatFrames = {}
local localHistory
local sentDebugSummary = { count = 0 }

local function hideAutomaticTimePlayed(_, event)
    if event == "TIME_PLAYED_MSG" and playedRequestToken then return true end
end

local function restorePlayedChatFrames()
    for chatFrame in pairs(playedSuppressedChatFrames) do
        if chatFrame and chatFrame.RegisterEvent then chatFrame:RegisterEvent("TIME_PLAYED_MSG") end
        playedSuppressedChatFrames[chatFrame] = nil
    end
end

local function suppressPlayedChatFrames()
    restorePlayedChatFrames()
    for index = 1, tonumber(NUM_CHAT_WINDOWS) or 10 do
        local chatFrame = _G["ChatFrame" .. index]
        if chatFrame and chatFrame.IsEventRegistered and chatFrame:IsEventRegistered("TIME_PLAYED_MSG") then
            playedSuppressedChatFrames[chatFrame] = true
            chatFrame:UnregisterEvent("TIME_PLAYED_MSG")
        end
    end
end

function Sync:RequestHiddenTimePlayed()
    if playedRequestToken or not RequestTimePlayed then return false end
    local token = {}
    playedRequestToken = token
    suppressPlayedChatFrames()
    RequestTimePlayed()
    C_Timer.After(10, function()
        if playedRequestToken ~= token then return end
        playedRequestToken = nil
        restorePlayedChatFrames()
    end)
    return true
end

local function shortName(name)
    return type(name) == "string" and name:match("^([^-]+)") or nil
end

local function number(value, maximum)
    value = tonumber(value)
    if not value or value ~= value or value < 0 or value > maximum or value % 1 ~= 0 then return nil end
    return value
end

local function wireBool(value)
    if value == true then return "1" end
    if value == false then return "0" end
    return "-"
end

local function readBool(value)
    if value == "1" then return true end
    if value == "0" then return false end
end

local function validBool(value)
    return value == "1" or value == "0" or value == "-"
end

local function connection()
    if not iRC:IsGuildConnectionActive() then return nil end
    local db = iRC:GetConnection()
    db.guildFoundRoster = db.guildFoundRoster or {}
    if not db.legacyRaceLockedRosterCleared then
        for key, entry in pairs(db.guildFoundRoster) do
            local source = type(entry) == "table" and tostring(entry.source or "") or ""
            local overrideSource = type(entry) == "table" and tostring(entry.overrideSource or "") or ""
            if source:find("^RaceLocked") or overrideSource:find("^RaceLocked") then db.guildFoundRoster[key] = nil end
        end
        db.legacyRaceLockedRosterCleared = true
    end
    db.raceDeaths = db.raceDeaths or {}
    db.deathReports = db.deathReports or {}
    return db
end

local function refresh()
    if iRC.ConnectionDashboard then iRC.ConnectionDashboard:RefreshIfShown() end
    if iRC.MainUI then iRC.MainUI:RefreshIfShown() end
end

local function send(prefix, payload, target)
    if not connection() or #payload > 255 then return false end
    if not iRC:SendAddonTraffic(prefix, payload, target and "WHISPER" or "GUILD", target) then return false end
    if iRC:GetSettings().debugMode and prefix == IRC_ROSTER and C_Timer and C_Timer.After then
        sentDebugSummary.count = sentDebugSummary.count + 1
        local token = {}
        sentDebugSummary.token = token
        C_Timer.After(2, function()
            if sentDebugSummary.token ~= token then return end
            local count = sentDebugSummary.count
            sentDebugSummary = { count = 0 }
            if count > 0 then iRC:DebugMsg(iRC:Text("IRC_GF_SYNC_SENT_SUMMARY", count), 3) end
        end)
    else
        iRC:DebugMsg(iRC:Text(prefix == IRC_ROSTER and "IRC_GF_SYNC_SENT" or "RL_SYNC_SENT", prefix), 3)
    end
    return true
end

local function entryFor(name)
    local db = connection()
    if not db or not iRC:IsGuildMemberName(name) then return nil end
    local key = iRC:NormalizeName(name)
    local entry = db.guildFoundRoster[key]
    if not entry then
        entry = { name = shortName(name) }
        db.guildFoundRoster[key] = entry
    end
    return entry
end

function Sync:GetStatus(name, snapshot)
    local db = snapshot
    if db == nil then db = connection() end
    local entry = db and db.active == true and db.guildFoundRoster and db.guildFoundRoster[iRC:NormalizeName(name)]
    if not entry then return nil end
    if iRC:NormalizeName(name) == iRC:NormalizeName(iRC:GetPlayerName()) then
        entry.verified, entry.clean, entry.tamperAt = self:GetLocalRawStatus()
        local history = localHistory and localHistory()
        if history then
            entry.moneyBefore = history.moneyBeforeDiscrepancy
            entry.moneyAfter = history.moneyAfterDiscrepancy
            entry.moneyBeforeAt = history.moneyBeforeDiscrepancyAt
            entry.moneyAfterAt = history.moneyAfterDiscrepancyAt
            entry.playedBefore = history.playedBeforeDiscrepancy
            entry.playedAfter = history.playedAfterDiscrepancy
            entry.playedBeforeAt = history.playedBeforeDiscrepancyAt
            entry.playedAfterAt = history.playedAfterDiscrepancyAt
        end
    end
    local effectiveVerified = entry.gmVerified
    local effectiveClean = entry.gmClean
    if effectiveVerified == nil then effectiveVerified = entry.verified end
    -- A decision only clears evidence that existed before it. A later gold
    -- discrepancy must require a fresh review instead of inheriting an older
    -- Clean override.
    local discrepancyAt = tonumber(entry.tamperAt) or 0
    local decisionAt = tonumber(entry.gmTimestamp) or 0
    if effectiveClean == nil or discrepancyAt > 0 and decisionAt <= discrepancyAt then
        effectiveClean = entry.clean
    end
    return {
        -- Keep the member report as audit metadata, but use an explicit Guild
        -- Master decision as the effective Guild Found result. Addon presence
        -- is evaluated separately, so an override cannot hide a missing client.
        verified = effectiveVerified, clean = effectiveClean, source = entry.source,
        lastSeen = entry.lastSeen, gmTimestamp = entry.gmTimestamp,
        overrideSource = entry.overrideSource, directOverride = entry.directOverride,
        tamperAt = entry.tamperAt, rawVerified = entry.verified, rawClean = entry.clean,
        moneyBefore = entry.moneyBefore, moneyAfter = entry.moneyAfter,
        moneyBeforeAt = entry.moneyBeforeAt, moneyAfterAt = entry.moneyAfterAt,
        playedBefore = entry.playedBefore, playedAfter = entry.playedAfter,
        playedBeforeAt = entry.playedBeforeAt, playedAfterAt = entry.playedAfterAt,
        gmVerified = entry.gmVerified, gmClean = entry.gmClean,
        cleanDecisionSuperseded = entry.gmClean ~= nil and discrepancyAt > 0 and decisionAt <= discrepancyAt,
    }
end

localHistory = function()
    iRCCharDB = iRCCharDB or {}
    iRCCharDB.guildFoundHistory = iRCCharDB.guildFoundHistory or {}
    return iRCCharDB.guildFoundHistory
end

-- Keep a second, lightly sealed copy under an intentionally generic key. This
-- is not cryptographic protection (SavedVariables are player-owned), but it
-- detects casual edits that only change the plainly readable snapshot.
local function snapshotSalt()
    local identity = iRC:NormalizeName(iRC:GetPlayerName()) or ""
    local value = 7919
    for index = 1, #identity do
        value = (value * 33 + identity:byte(index)) % 1048573
    end
    return value
end

local function sealSnapshot(value)
    value = tonumber(value)
    if not value or value < 0 or value % 1 ~= 0 then return nil end
    return string.format("%X", value * 257 + snapshotSalt())
end

local function unsealSnapshot(value)
    if type(value) ~= "string" or value == "" or value:find("[^0-9A-Fa-f]") then return nil end
    local encoded = tonumber(value, 16)
    if not encoded then return nil end
    local decoded = (encoded - snapshotSalt()) / 257
    if decoded < 0 or decoded % 1 ~= 0 then return nil end
    return decoded
end

local function writeMoneySnapshot(history, value)
    history.money = value
    history.rk = sealSnapshot(value)
end

function Sync:ObserveSelfFound()
    local history = localHistory()
    if iRC:GetSelfFoundState() then
        if (UnitLevel("player") or 0) >= 60 then history.maxLevelSelfFound = true end
    end
end

function Sync:IsGuildFoundSubject()
    if not iRC:IsGuildConnectionActive() or not iRC:IsGuildFoundRequired() then return false end
    local progression = iRC:GetProgressionMode()
    return progression == "GUILD_FOUND" or progression == "SELF_FOUND_OR_GUILD_FOUND"
        or (UnitLevel("player") or 0) >= 60
        or iRC:IsGuildBankException(iRC:GetPlayerName())
end

function Sync:IsMoneyMonitoringActive()
    return iRC:IsGuildConnectionActive()
end

function Sync:RefreshMoneyMonitoring()
    if not moneyReady or not GetMoney then return end
    local history, active = localHistory(), self:IsMoneyMonitoringActive()
    if history.moneyMonitoringActive ~= active then
        writeMoneySnapshot(history, GetMoney())
        history.moneyMonitoringActive = active
    end
end

function Sync:SaveCurrentMoney(reason)
    if not moneyReady or not GetMoney then return false end
    local history = localHistory()
    writeMoneySnapshot(history, GetMoney())
    history.moneyMonitoringActive = self:IsMoneyMonitoringActive()
    history.moneyLastLoggedAt = time()
    history.moneyLastLogReason = tostring(reason or "UPDATE")
    return true
end

function Sync:CheckLocalMoneySnapshot()
    if iRC:IsLowTrafficMode() or not moneyReady or not GetMoney then return false end
    local history = localHistory()
    local openSnapshot = tonumber(history.money)
    local sealedSnapshot = unsealSnapshot(history.rk)
    -- Never repair a mismatched saved snapshot here; login validation owns
    -- tamper detection. This only catches a missed in-game money event.
    if sealedSnapshot == nil or openSnapshot ~= sealedSnapshot then return false end
    local current = GetMoney()
    if current == sealedSnapshot then return false end
    return self:SaveCurrentMoney("LOCAL_MONEY_WATCHDOG")
end

function Sync:ValidateMoney()
    if moneyReady then return end
    if GetTime and GetTime() < moneyValidationAllowedAt then return end
    local current = GetMoney and GetMoney()
    if not current then return end
    local history = localHistory()
    local monitoringActive = self:IsMoneyMonitoringActive()
    local openSnapshot = tonumber(history.money)
    local sealedExists = history.rk ~= nil
    local sealedSnapshot = unsealSnapshot(history.rk)
    local snapshotMismatch = sealedExists
        and (sealedSnapshot == nil or openSnapshot == nil or sealedSnapshot ~= openSnapshot)
    local baseline = sealedSnapshot or openSnapshot
    if monitoringActive and history.moneyMonitoringActive == true and baseline ~= nil
        and (snapshotMismatch or baseline ~= current) then
        local discrepancyAt = time()
        history.moneyDiscrepancyAt = discrepancyAt
        history.moneyBeforeDiscrepancy = baseline
        history.moneyAfterDiscrepancy = current
        history.moneyBeforeDiscrepancyAt = tonumber(history.moneyLastLoggedAt) or 0
        history.moneyAfterDiscrepancyAt = discrepancyAt
        history.moneyDiscrepancyNoticeAt = nil
    end
    -- Existing installations have no sealed value yet. The first login after
    -- upgrading establishes it without treating the migration as tampering.
    writeMoneySnapshot(history, current)
    history.moneyMonitoringActive = monitoringActive
    history.moneyLastLoggedAt = time()
    history.moneyLastLogReason = "LOGIN_VALIDATION"
    moneyReady = true
    self:ObserveSelfFound()
end

function Sync:GetLocalRawStatus()
    self:ObserveSelfFound()
    local history = localHistory()
    local verified = history.maxLevelSelfFound == true
    local clean, tamperAt = history.moneyDiscrepancyAt == nil, history.moneyDiscrepancyAt or 0
    return verified, clean, tamperAt
end

local function storeSelf(name, verified, clean, tamperAt, source, moneyBefore, moneyAfter, moneyBeforeAt, moneyAfterAt,
    playedBefore, playedAfter, playedBeforeAt, playedAfterAt)
    local entry = entryFor(name)
    if not entry then return end
    entry.verified, entry.clean, entry.tamperAt = verified, clean, tamperAt
    if tonumber(tamperAt) and tonumber(tamperAt) > 0 then
        entry.moneyBefore, entry.moneyAfter = tonumber(moneyBefore), tonumber(moneyAfter)
        entry.moneyBeforeAt, entry.moneyAfterAt = tonumber(moneyBeforeAt), tonumber(moneyAfterAt)
        entry.playedBefore, entry.playedAfter = tonumber(playedBefore), tonumber(playedAfter)
        entry.playedBeforeAt, entry.playedAfterAt = tonumber(playedBeforeAt), tonumber(playedAfterAt)
    else
        entry.moneyBefore, entry.moneyAfter = nil, nil
        entry.moneyBeforeAt, entry.moneyAfterAt = nil, nil
        entry.playedBefore, entry.playedAfter = nil, nil
        entry.playedBeforeAt, entry.playedAfterAt = nil, nil
    end
    entry.source, entry.lastSeen = source, time()
end

local function storeOverride(name, verified, clean, stamp, source, direct)
    local entry = entryFor(name)
    if not entry or not stamp or stamp < 1 or stamp > time() + 300 then return false end
    local previous = entry.gmTimestamp or 0
    if stamp < previous then return false end
    if stamp == previous then
        if entry.gmVerified ~= verified or entry.gmClean ~= clean then return false end
        if direct then entry.directOverride, entry.overrideSource = true, source end
        return true
    end
    entry.gmVerified, entry.gmClean, entry.gmTimestamp = verified, clean, stamp
    entry.overrideSource, entry.directOverride = source, direct == true
    return true
end

local function overridePayload(marker, entry)
    return marker .. entry.name .. "," .. wireBool(entry.gmVerified) .. "," .. wireBool(entry.gmClean) .. "," .. tostring(entry.gmTimestamp)
end

local function relayPayload(entry)
    return "R:" .. entry.name .. "," .. wireBool(entry.gmVerified) .. "," .. wireBool(entry.gmClean)
        .. "," .. tostring(entry.gmTimestamp) .. "," .. tostring(entry.overrideSource or "")
end

local function queueRelay(name)
    local db, entry = connection(), entryFor(name)
    if not db or not entry or not entry.gmTimestamp then return end
    local key, guildKey = iRC:NormalizeName(name), db.key
    if pendingRelays[key] then return end
    local token = {}
    pendingRelays[key] = token
    C_Timer.After(1.5 + math.random() * 2, function()
        if pendingRelays[key] ~= token then return end
        pendingRelays[key] = nil
        local current = connection()
        if not current or current.key ~= guildKey then return end
        local row = current.guildFoundRoster[key]
        if row and row.gmTimestamp and iRC:IsRulesetBroadcaster() then send(IRC_ROSTER, relayPayload(row)) end
    end)
end

function Sync:RelayOverrides(targetName)
    if iRC:DeferLowTraffic("traffic:verification-overrides:" .. tostring(targetName or "guild"), function() Sync:RelayOverrides(targetName) end) then return false end
    local db = connection()
    if not db or not iRC:IsRulesetBroadcaster() then return false end
    local payload, sent = "R:", false
    local function flush()
        if #payload <= 2 then return end
        if send(IRC_ROSTER, payload, targetName) then sent = true end
        payload = "O:"
    end
    local rows = {}
    for _, entry in pairs(db.guildFoundRoster or {}) do
        -- Decisions created locally before the relay-source field existed can
        -- be attributed safely only on their original authorized client.
        if type(entry) == "table" and entry.directOverride and entry.overrideSource == "iRC"
            and iRC:HasGuildPermission("verification") then
            entry.overrideSource = iRC:GetPlayerName()
        end
        local sourceRank = type(entry) == "table" and iRC:GetGuildMemberRankIndex(entry.overrideSource)
        local allowedRank = db.rankPermissions.verification or 1
        if type(entry) == "table" and entry.name and entry.gmTimestamp and sourceRank and sourceRank <= allowedRank
            and iRC:IsGuildMemberName(entry.name) then
            rows[#rows + 1] = entry
        end
    end
    table.sort(rows, function(a, b) return iRC:NormalizeName(a.name) < iRC:NormalizeName(b.name) end)
    for _, entry in ipairs(rows) do
        local row = entry.name .. "," .. wireBool(entry.gmVerified) .. ","
            .. wireBool(entry.gmClean) .. "," .. tostring(entry.gmTimestamp) .. "," .. entry.overrideSource
        if #payload > 2 and #payload + #row + 1 > 255 then flush() end
        if #payload + #row + (#payload > 2 and 1 or 0) <= 255 then
            payload = payload .. (#payload > 2 and "," or "") .. row
        end
    end
    flush()
    return sent
end

function Sync:SetOverride(name, verified, clean, goldOnly)
    if not iRC:HasGuildPermission("verification") or not connection() or not iRC:IsGuildMemberName(name) then return false end
    local memberLevel
    if GetNumGuildMembers and GetGuildRosterInfo then
        for index = 1, GetNumGuildMembers(true) do
            local memberName, _, _, level = GetGuildRosterInfo(index)
            if iRC:NormalizeName(memberName) == iRC:NormalizeName(name) then
                memberLevel = tonumber(level) or 0
                break
            end
        end
    end
    local progression = iRC:GetProgressionMode()
    local allowsEarlyVerification = progression == "GUILD_FOUND" or progression == "SELF_FOUND_OR_GUILD_FOUND"
    if not memberLevel or (not goldOnly and verified ~= nil and memberLevel < 60 and not allowsEarlyVerification) then
        iRC:Print(iRC:Text("RL_OVERRIDE_LEVEL_60_ONLY"))
        return false
    end
    if verified ~= nil and type(verified) ~= "boolean" or clean ~= nil and type(clean) ~= "boolean" then return false end
    local entry = entryFor(name)
    local stamp = math.max(time(), (entry.gmTimestamp or 0) + 1, (entry.tamperAt or 0) + 1)
    if not storeOverride(name, verified, clean, stamp, iRC:GetPlayerName(), true) then return false end
    send(IRC_ROSTER, overridePayload("G:", entry))
    iRC:Print(iRC:Text("RL_OVERRIDE_SAVED", entry.name))
    refresh()
    return true
end

function Sync:SetGoldOverride(name, clean)
    if clean ~= nil and type(clean) ~= "boolean" then return false end
    local entry = entryFor(name)
    if not entry then return false end
    -- A gold review must not alter an existing eligibility decision.
    return self:SetOverride(name, entry.gmVerified, clean, true)
end

function Sync:DescribeStatus(name, compact, status, goldOnly)
    if status == nil then status = self:GetStatus(name) end
    if not status then return iRC:Text("RL_STATUS_UNKNOWN") end
    local verified = status.verified == nil and "RL_STATUS_UNKNOWN" or (status.verified and "RL_VERIFIED" or "RL_UNVERIFIED")
    local clean = status.clean == nil and "RL_STATUS_UNKNOWN" or (status.clean and "RL_CLEAN" or "RL_FLAGGED")
    local text = goldOnly and iRC:Text("VERIFICATION_GOLD", iRC:Text(clean))
        or (iRC:Text(verified) .. " / " .. iRC:Text(clean))
    if not compact then
        local details = {}
        if status.source and status.source ~= "" then details[#details + 1] = iRC:Text("RL_REPORT_SOURCE", status.source) end
        if status.lastSeen and status.lastSeen > 0 then details[#details + 1] = iRC:Text("RL_LAST_REPORT", date("%Y-%m-%d %H:%M", status.lastSeen)) end
        if status.tamperAt and status.tamperAt > 0 then details[#details + 1] = iRC:Text("RL_DISCREPANCY_SEEN", date("%Y-%m-%d %H:%M", status.tamperAt)) end
        if status.gmTimestamp then
            details[#details + 1] = iRC:Text(status.directOverride and "RL_GM_DIRECT" or "RL_GM_RELAY")
            details[#details + 1] = iRC:Text("RL_DECISION_TIME", date("%Y-%m-%d %H:%M", status.gmTimestamp))
        end
        if #details > 0 then text = text .. "\n" .. table.concat(details, "\n") end
    end
    return text
end

function Sync:ReceiveRoster(message, sender)
    if not connection() or not iRC:IsGuildMemberName(sender) or type(message) ~= "string" or #message > 255 then return end
    local marker, payload = message:sub(1, 2), message:sub(3)
    local fields = {}
    for value in (payload .. ","):gmatch("(.-),") do fields[#fields + 1] = value end
    if marker == "S:" then
        local name = fields[1]
        if iRC:NormalizeName(name) ~= iRC:NormalizeName(sender) then return end
        if (fields[2] ~= "0" and fields[2] ~= "1") or (fields[3] ~= "0" and fields[3] ~= "1") then return end
        local tamperAt = number(fields[4], time() + 300)
        if not tamperAt then return end
        local moneyBefore = number(fields[8], 1000000000000000)
        local moneyAfter = number(fields[9], 1000000000000000)
        local moneyBeforeAt = number(fields[10], time() + 300)
        local moneyAfterAt = number(fields[11], time() + 300)
        local playedBefore = number(fields[12], 1000000000)
        local playedAfter = number(fields[13], 1000000000)
        local playedBeforeAt = number(fields[14], time() + 300)
        local playedAfterAt = number(fields[15], time() + 300)
        storeSelf(name, readBool(fields[2]), readBool(fields[3]), tamperAt, "iRC", moneyBefore, moneyAfter,
            moneyBeforeAt, moneyAfterAt, playedBefore, playedAfter, playedBeforeAt, playedAfterAt)
        -- Confirm receipt only from a rank authorized to review verification.
        -- The reporting player does not see the discrepancy notice until this
        -- acknowledgement proves that an officer actually received the report.
        if tamperAt > 0 and iRC:HasGuildPermission("verification") then
            send(IRC_ROSTER, "A:" .. tostring(tamperAt), sender)
        end
        local stamp = number(fields[7], time() + 300)
        if validBool(fields[5]) and validBool(fields[6]) and stamp and stamp > 0
            and storeOverride(name, readBool(fields[5]), readBool(fields[6]), stamp, "iRC relay", false) then
            pendingRelays[iRC:NormalizeName(name)] = nil
        else
            queueRelay(name)
        end
    elseif marker == "A:" then
        local acknowledgedAt = number(fields[1], time() + 300)
        local senderRank = iRC:GetGuildMemberRankIndex(sender)
        local db = connection()
        local allowedRank = db and db.rankPermissions.verification or 1
        local history = localHistory()
        local discrepancyAt = tonumber(history.moneyDiscrepancyAt) or 0
        if acknowledgedAt and acknowledgedAt > 0 and acknowledgedAt == discrepancyAt
            and senderRank ~= nil and senderRank <= allowedRank
            and tonumber(history.moneyDiscrepancyNoticeAt) ~= discrepancyAt then
            history.moneyDiscrepancyNoticeAt = discrepancyAt
            iRC:Print(iRC:Text("RL_MONEY_DISCREPANCY"))
        end
    elseif marker == "G:" or marker == "O:" then
        local direct = marker == "G:"
        local senderRank = iRC:GetGuildMemberRankIndex(sender)
        local allowedRank = connection().rankPermissions.verification or 1
        -- Both new decisions and relays must come from a rank currently
        -- trusted with verification management. Relays retain the original
        -- decision timestamp and cannot silently become a newer decision.
        if senderRank == nil or senderRank > allowedRank then return end
        if #fields % 4 ~= 0 then return end
        for index = 1, #fields, 4 do
            local name, stamp = fields[index], number(fields[index + 3], time() + 300)
            if validBool(fields[index + 1]) and validBool(fields[index + 2]) and stamp
                and storeOverride(name, readBool(fields[index + 1]), readBool(fields[index + 2]), stamp,
                    direct and sender or "iRC relay", direct) then
                pendingRelays[iRC:NormalizeName(name)] = nil
            end
        end
    elseif marker == "R:" then
        if #fields % 5 ~= 0 then return end
        local allowedRank = connection().rankPermissions.verification or 1
        for index = 1, #fields, 5 do
            local name, stamp, source = fields[index], number(fields[index + 3], time() + 300), fields[index + 4]
            local sourceRank = iRC:GetGuildMemberRankIndex(source)
            if validBool(fields[index + 1]) and validBool(fields[index + 2]) and stamp
                and sourceRank and sourceRank <= allowedRank
                and storeOverride(name, readBool(fields[index + 1]), readBool(fields[index + 2]), stamp, source, false) then
                pendingRelays[iRC:NormalizeName(name)] = nil
            end
        end
    else return end
    iRC:DebugMsg(iRC:Text("IRC_GF_SYNC_RECEIVED", IRC_ROSTER, sender), 3)
    refresh()
end

function Sync:RecordDeath(name)
    local db = connection()
    if not db or not iRC:IsGuildMemberName(name) then return false end
    local key, now = iRC:NormalizeName(name), time()
    if db.deathReports[key] and now - db.deathReports[key] < 30 then return false end
    db.deathReports[key] = now
    local race = iRC:GetGuildRace()
    if race == "" then local _, token = UnitRace("player"); race = iRC:NormalizeGuildRace(token) end
    db.raceDeaths[race] = (db.raceDeaths[race] or 0) + 1
    iRC:DebugMsg(iRC:Text("RL_DEATH_RECEIVED", name), 3)
    refresh()
    return true
end

function Sync:Broadcast()
    if iRC:DeferLowTraffic("traffic:guild-found-profile", function() Sync:Broadcast() end) then return false end
    local db = connection()
    if not db or not moneyReady then return end
    self:RefreshMoneyMonitoring()
    local now = GetTime()
    if lastBroadcast[db.key] and now - lastBroadcast[db.key] < 5 then return end
    lastBroadcast[db.key] = now
    local name = shortName(iRC:GetPlayerName())
    local verified, clean, tamperAt = self:GetLocalRawStatus()
    local history = localHistory()
    storeSelf(name, verified, clean, tamperAt, "iRC", history.moneyBeforeDiscrepancy, history.moneyAfterDiscrepancy,
        history.moneyBeforeDiscrepancyAt, history.moneyAfterDiscrepancyAt,
        history.playedBeforeDiscrepancy, history.playedAfterDiscrepancy,
        history.playedBeforeDiscrepancyAt, history.playedAfterDiscrepancyAt)
    if self:IsMoneyMonitoringActive() then
        local entry = entryFor(name)
        local msg = "S:" .. name .. "," .. wireBool(verified) .. "," .. wireBool(clean) .. "," .. tostring(tamperAt)
        if entry.gmTimestamp or entry.moneyBefore ~= nil or entry.moneyAfter ~= nil then
            msg = msg .. "," .. wireBool(entry.gmVerified) .. "," .. wireBool(entry.gmClean) .. "," .. tostring(entry.gmTimestamp or 0)
                .. "," .. tostring(entry.moneyBefore or "") .. "," .. tostring(entry.moneyAfter or "")
                .. "," .. tostring(entry.moneyBeforeAt or "") .. "," .. tostring(entry.moneyAfterAt or "")
                .. "," .. tostring(entry.playedBefore or "") .. "," .. tostring(entry.playedAfter or "")
                .. "," .. tostring(entry.playedBeforeAt or "") .. "," .. tostring(entry.playedAfterAt or "")
        end
        send(IRC_ROSTER, msg)
    end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_MONEY")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("UNIT_AURA")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:RegisterEvent("MAIL_SHOW")
frame:RegisterEvent("MAIL_CLOSED")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("MERCHANT_CLOSED")
frame:RegisterEvent("TRADE_SHOW")
frame:RegisterEvent("TRADE_CLOSED")
frame:RegisterEvent("LOOT_OPENED")
frame:RegisterEvent("LOOT_CLOSED")
frame:RegisterEvent("QUEST_TURNED_IN")
frame:RegisterEvent("TIME_PLAYED_MSG")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= iRC.Name then return end
        local register = C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix or RegisterAddonMessagePrefix
        if register then register(IRC_ROSTER) end
        if ChatFrame_AddMessageEventFilter then
            ChatFrame_AddMessageEventFilter("TIME_PLAYED_MSG", hideAutomaticTimePlayed)
        end
    elseif event == "PLAYER_LOGIN" then
        -- GetMoney can briefly expose an incomplete value while the character
        -- enters the world. Comparing at PLAYER_LOGIN produced a false gold
        -- discrepancy on every login for some clients.
        moneyValidationAllowedAt = (GetTime and GetTime() or 0) + 5
        C_Timer.After(5, function() Sync:ValidateMoney() end)
        if not moneyWatchdog and C_Timer.NewTicker then
            moneyWatchdog = C_Timer.NewTicker(15, function() Sync:CheckLocalMoneySnapshot() end)
        end
        C_Timer.After(6, function() Sync:RequestHiddenTimePlayed() end)
        if not playedTicker and C_Timer.NewTicker then
            playedTicker = C_Timer.NewTicker(1800, function() Sync:RequestHiddenTimePlayed() end)
        end
        C_Timer.After(iRC:GetStartupTrafficDelay(), function() Sync:Broadcast() end)
    elseif event == "PLAYER_MONEY" then
        if moneyReady then Sync:SaveCurrentMoney(event) else Sync:ValidateMoney() end
    elseif event == "PLAYER_LOGOUT" then
        Sync:SaveCurrentMoney(event)
    elseif event == "MAIL_SHOW" or event == "MAIL_CLOSED"
        or event == "MERCHANT_SHOW" or event == "MERCHANT_CLOSED"
        or event == "TRADE_SHOW" or event == "TRADE_CLOSED"
        or event == "LOOT_OPENED" or event == "LOOT_CLOSED" then
        Sync:SaveCurrentMoney(event)
        if event == "MAIL_CLOSED" or event == "MERCHANT_CLOSED" or event == "TRADE_CLOSED"
            or event == "LOOT_CLOSED" then
            C_Timer.After(0.5, function() Sync:SaveCurrentMoney(event .. "_SETTLED") end)
        end
    elseif event == "QUEST_TURNED_IN" then
        Sync:SaveCurrentMoney(event)
        C_Timer.After(1, function() Sync:SaveCurrentMoney("QUEST_TURNED_IN_SETTLED") end)
    elseif event == "TIME_PLAYED_MSG" then
        if not playedRequestToken then return end
        local totalPlayed, levelPlayed = ...
        local history, now = localHistory(), time()
        history.playedTotal = math.max(0, math.floor(tonumber(totalPlayed) or 0))
        history.playedLevel = math.max(0, math.floor(tonumber(levelPlayed) or 0))
        history.playedRecordedAt = now
        if tonumber(history.moneyDiscrepancyAt) and history.moneyDiscrepancyAt > 0
            and tonumber(history.playedDiscrepancyAt) ~= history.moneyDiscrepancyAt then
            history.playedBeforeDiscrepancy = tonumber(history.playedPreviousTotal)
            history.playedAfterDiscrepancy = history.playedTotal
            history.playedBeforeDiscrepancyAt = tonumber(history.playedPreviousRecordedAt)
            history.playedAfterDiscrepancyAt = now
            history.playedDiscrepancyAt = history.moneyDiscrepancyAt
        end
        history.playedPreviousTotal = history.playedTotal
        history.playedPreviousRecordedAt = now
        playedRequestToken = nil
        C_Timer.After(0, restorePlayedChatFrames)
    elseif event == "UNIT_AURA" or event == "PLAYER_LEVEL_UP" then
        if event == "UNIT_AURA" and ... ~= "player" then return end
        Sync:ObserveSelfFound()
        Sync:RefreshMoneyMonitoring()
    elseif event == "PLAYER_DEAD" then
        Sync:RecordDeath(iRC:GetPlayerName())
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        if (channel ~= "GUILD" and channel ~= "WHISPER") or type(msg) ~= "string" or #msg > 255 then return end
        if iRC:NormalizeName(sender) == iRC:NormalizeName(iRC:GetPlayerName()) then return end
        if prefix == IRC_ROSTER then Sync:ReceiveRoster(msg, sender) end
    end
end)
