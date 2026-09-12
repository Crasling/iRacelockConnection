local _, private = ...
local iRC = private and private.iRC
if not iRC then return end

local AllianceRaces = { HUMAN = true, DWARF = true, NIGHTELF = true, GNOME = true, DRAENEI = true }
local HordeRaces = { ORC = true, SCOURGE = true, TAUREN = true, TROLL = true, BLOODELF = true }
local IRC_PRESENCE_TIMEOUT = 90
-- A compatible RaceLocked response is live presence evidence, not persistent
-- roster or verification data.
local COMPATIBILITY_TIMEOUT = 135
local reportedPresenceMismatches = {}
local pendingPresenceChecks = {}
local presenceConnection, reviewTicket, reviewAt, selectedOfficer
local PROBE_INTERVAL, PROBE_ATTEMPTS, CONFIRMATION_WINDOW, LOGIN_GRACE = 15, 3, 45, 60
local sessionStartedAt = time()
local guildRosterSnapshot, guildRosterSnapshotValid = {}, false

local function isFreshCompatibility(entry, profile)
    if type(entry) ~= "table" then return false end
    local lastSeen = tonumber(entry.lastSeen)
    local timeout = COMPATIBILITY_TIMEOUT
    if not lastSeen or lastSeen > time() or time() - lastSeen > timeout then return false end
    local profileLastSeen = profile and tonumber(profile.lastSeen)
    -- iRC emits compatibility mirrors next to HELLO. They must not extend the
    -- same client's presence after HELLO expires; a later native response can.
    return not profileLastSeen or lastSeen > profileLastSeen + 5
end

local function isFreshIRCProfile(profile)
    local lastSeen = profile and tonumber(profile.lastSeen)
    local startedAt = iRC.ConnectionSessionStartedAt or sessionStartedAt
    return lastSeen and lastSeen >= startedAt and lastSeen <= time() and time() - lastSeen <= IRC_PRESENCE_TIMEOUT
end

local function latestCompatibilityEntry(member)
    local latest, latestSeen
    for _, entry in pairs({ member and member.presence }) do
        local seen = type(entry) == "table" and tonumber(entry.lastSeen) or nil
        if seen and (not latestSeen or seen > latestSeen) then latest, latestSeen = entry, seen end
    end
    return latest
end

function iRC:ResetPresenceNotificationChecks()
    reportedPresenceMismatches, pendingPresenceChecks = {}, {}
    presenceConnection, reviewTicket, reviewAt, selectedOfficer = nil, nil, nil, nil
end

local function queuePresenceReview(delay)
    if not C_Timer or not C_Timer.After then return end
    local at = time() + math.max(1, delay)
    if reviewAt and reviewAt <= at then return end
    local ticket = {}
    reviewTicket, reviewAt = ticket, at
    C_Timer.After(math.max(1, delay), function()
        if reviewTicket ~= ticket then return end
        reviewTicket, reviewAt = nil, nil
        iRC:CheckPresenceMismatches()
    end)
end

local function memberKey(name, guid)
    if guid and guid ~= "" then return "guid:" .. guid end
    return "name:" .. iRC:NormalizeName(name)
end

function iRC:InvalidateGuildRosterSnapshot()
    guildRosterSnapshotValid = false
end

function iRC:GetGuildRosterSnapshot()
    if guildRosterSnapshotValid then return guildRosterSnapshot end
    local snapshot = {}
    local count = GetNumGuildMembers and GetGuildRosterInfo and GetNumGuildMembers(true) or 0
    for index = 1, count do
        local name, _, rankIndex, level, className, _, _, _, online, _, classFile, _, _, _, _, _, guid = GetGuildRosterInfo(index)
        if name then
            local lastOnlineDays
            if not online and GetGuildRosterLastOnline then
                local years, months, days, hours = GetGuildRosterLastOnline(index)
                if years ~= nil then
                    lastOnlineDays = (tonumber(years) or 0) * 365 + (tonumber(months) or 0) * 30
                        + (tonumber(days) or 0) + (tonumber(hours) or 0) / 24
                end
            end
            snapshot[#snapshot + 1] = {
                name = name,
                rankIndex = rankIndex,
                level = level,
                className = className,
                classFile = classFile,
                online = online and true or false,
                guid = guid,
                lastOnlineDays = lastOnlineDays,
            }
        end
    end
    guildRosterSnapshot = snapshot
    -- An empty result during initial guild loading is not authoritative; keep
    -- retrying until WoW supplies the roster or confirms that we have no guild.
    guildRosterSnapshotValid = #snapshot > 0 or not self:IsInGuildConnection()
    return guildRosterSnapshot
end

function iRC:GetMemberAttentionSince(name, verification, connection)
    if connection == nil then connection = self:GetConnection() end
    if not connection or connection.active ~= true then return nil end
    connection.attentionSince = connection.attentionSince or {}
    local key = self:NormalizeName(name)
    local state = verification and verification.state
    if state == "missing" or state == "stale" then
        local record = connection.attentionSince[key]
        if not record then
            record = { since = time(), state = state }
            connection.attentionSince[key] = record
        else
            record.state = state
        end
        return record.since
    end
    connection.attentionSince[key] = nil
    return nil
end

function iRC:FindConnectionProfile(name)
    local connection = self:GetConnection()
    return connection and connection.members[self:NormalizeName(name)] or nil
end

function iRC:RefreshGuildRoster()
    if SetGuildRosterShowOffline then SetGuildRosterShowOffline(true) end
    if GuildRoster then GuildRoster() end
end

function iRC:GetMemberVerification(name, online, profile, context)
    if not online then return { state = "offline", label = "Offline" } end
    local connection
    if context then connection = context.connection else connection = self:GetConnection() end
    if not connection or connection.active ~= true then return { state = "inactive", label = self:Text("GUILD_VERIFICATION_INACTIVE") } end
    local key = self:NormalizeName(name)
    if key == (context and context.selfKey or self:NormalizeName(self:GetPlayerName())) then
        return { state = "verified", label = "This client" }
    end
    local compatibilityMember = (connection.compatibilityMembers or {})[key]
    local compatiblePresence = compatibilityMember and compatibilityMember.presence
    local sessionStartedAt = self.ConnectionSessionStartedAt or 0
    if profile and profile.lastSeen and profile.lastSeen >= sessionStartedAt then
        local profileAge = time() - profile.lastSeen
        if profileAge <= IRC_PRESENCE_TIMEOUT then
            return { state = "verified", label = "Verified " .. math.max(0, math.floor(profileAge)) .. "s ago" }
        end
    end
    if compatiblePresence and isFreshCompatibility(compatiblePresence, profile) then
        local presenceAge = time() - compatiblePresence.lastSeen
        if presenceAge <= COMPATIBILITY_TIMEOUT then
            return { state = "compatible", label = (compatiblePresence.source or "RaceLocked") .. " presence " .. math.max(0, math.floor(presenceAge)) .. "s ago" }
        end
    end
    if not profile or not profile.lastSeen then
        return { state = "missing", label = "Addon not detected" }
    end
    if profile.lastSeen < sessionStartedAt then
        return { state = "missing", label = "No live iRC response" }
    end
    local age = time() - profile.lastSeen
    return { state = "stale", label = "iRC response expired " .. math.max(0, math.floor(age)) .. "s ago" }
end

function iRC:IsPresenceNotificationLeader()
    local connection = self:GetConnection()
    if not connection or connection.active ~= true then return false end
    -- Notification leadership must follow the real guild roster. Testing
    -- overrides may unlock configuration, but they cannot grant access to
    -- officer chat or displace an actual authorized iRC officer client.
    local ownRankIndex
    if GetGuildInfo then
        local _, _, playerRankIndex = GetGuildInfo("player")
        ownRankIndex = playerRankIndex
    end
    local presenceRank = tonumber(connection.rankPermissions and connection.rankPermissions.presence) or 1
    if type(ownRankIndex) ~= "number" or ownRankIndex < 0 or ownRankIndex > presenceRank then return false end
    local ownName = self:NormalizeName(self:GetPlayerName())
    local candidate = { name = self:GetPlayerName(), rankIndex = ownRankIndex }
    local now, sessionStartedAt = time(), self.ConnectionSessionStartedAt or 0
    for _, member in ipairs(self:GetGuildRosterSnapshot()) do
        local name, rankIndex, online = member.name, member.rankIndex, member.online
        if name and online and self:NormalizeName(name) ~= ownName then
            local profile = connection.members[self:NormalizeName(name)]
            local lastSeen = profile and tonumber(profile.lastSeen)
            -- Compatible presence proves RaceLockedForkEU is running, not
            -- iRC's notification handler. Only direct, current-session iRC
            -- profiles can participate in this election.
            if lastSeen and lastSeen >= sessionStartedAt and lastSeen <= now and now - lastSeen <= IRC_PRESENCE_TIMEOUT then
                if type(rankIndex) == "number" and rankIndex >= 0 and rankIndex <= presenceRank
                    and (rankIndex < candidate.rankIndex or (rankIndex == candidate.rankIndex and self:NormalizeName(name) < self:NormalizeName(candidate.name))) then
                    candidate = { name = name, rankIndex = rankIndex }
                end
            end
        end
    end
    return self:NormalizeName(candidate.name) == ownName, candidate.name
end

local function announcePresenceMismatch(member, verification, escalated)
    -- Re-elect immediately before publishing, not just when the probes began.
    if not iRC:IsPresenceNotificationLeader() or not SendChatMessage then return false end
    -- The roster row passed into this function is a snapshot. An addon reply
    -- can arrive after that row was built but before the delayed warning runs,
    -- so always consult the live caches again at the final send boundary.
    local liveProfile = iRC:FindConnectionProfile(member.name)
    local liveVerification = iRC:GetMemberVerification(member.name, true, liveProfile)
    if liveVerification.state == "verified" or liveVerification.state == "compatible" then
        local key = iRC:NormalizeName(member.name)
        reportedPresenceMismatches[key], pendingPresenceChecks[key] = nil, nil
        iRC:DebugMsg(iRC:Text("PRESENCE_RECOVERED", member.name), 3)
        return true, true
    end
    verification = liveVerification
    if iRC:SuppressesPresenceWarnings() then
        iRC:DebugMsg(iRC:Text("PRESENCE_WARNING_SUPPRESSED", member.name), 3)
        return true
    end
    local reason = verification.label or iRC:Text("PRESENCE_NO_LIVE_RESPONSE")
    local officerMessage = escalated
        and iRC:Text("PRESENCE_OFFICER_ESCALATION", member.name, reason)
        or iRC:Text("PRESENCE_OFFICER_NOTICE", member.name, reason)
    local whisperMessage = escalated
        and iRC:Text("PRESENCE_PLAYER_ESCALATION")
        or iRC:Text("PRESENCE_PLAYER_NOTICE")
    if SendChatMessage then
        if not iRC:IsAutomaticWarningDisabled("OFFICER") then SendChatMessage(officerMessage, "OFFICER") end
        if not iRC:IsAutomaticWarningDisabled("WHISPER") then SendChatMessage(whisperMessage, "WHISPER", nil, member.name) end
        if escalated then
            if not iRC:IsAutomaticWarningDisabled("GUILD") then SendChatMessage(iRC:Text("PRESENCE_GUILD_ESCALATION", member.name), "GUILD") end
            local occurredAt = time()
            iRC:StoreOfficerIncident({
                id = "presence:" .. iRC:NormalizeName(member.name) .. ":" .. occurredAt,
                reporter = member.name,
                occurredAt = occurredAt,
                instanceName = iRC:Text("PRESENCE_INCIDENT_LOCATION"),
                players = reason,
                reason = iRC:Text("PRESENCE_INCIDENT_REASON", member.name, reason),
            })
        end
    end
    return true
end

function iRC:CheckPresenceMismatches()
    local connection = self:GetConnection()
    if not connection or connection.active ~= true then self:ResetPresenceNotificationChecks(); return end
    if self:SuppressesPresenceWarnings() then
        self:ResetPresenceNotificationChecks()
        return
    end
    if presenceConnection ~= connection then
        self:ResetPresenceNotificationChecks()
        presenceConnection = connection
    end
    local isLeader, leaderName = self:IsPresenceNotificationLeader()
    local leaderKey = leaderName and self:NormalizeName(leaderName)
    if selectedOfficer ~= leaderKey then
        selectedOfficer, pendingPresenceChecks = leaderKey, {}
        if leaderName then self:DebugMsg(self:Text("PRESENCE_OFFICER_SELECTED", leaderName), 3) end
    end
    if not isLeader then
        pendingPresenceChecks, reviewTicket, reviewAt = {}, nil, nil
        self:DebugMsg(leaderName and self:Text("PRESENCE_NOTIFICATION_NOT_LEADER", leaderName)
            or self:Text("PRESENCE_NOTIFICATION_INELIGIBLE"), 3)
        return
    end
    self:DebugMsg(self:Text("PRESENCE_NOTIFICATION_LEADER"), 3)
    local now, probeBatch, currentMembers = time(), {}, {}
    local loginReadyAt = (self.ConnectionSessionStartedAt or sessionStartedAt) + LOGIN_GRACE
    connection.newMemberChecks = connection.newMemberChecks or {}
    connection.newMemberWelcomeNotices = connection.newMemberWelcomeNotices or {}
    connection.raceMismatchNotices = connection.raceMismatchNotices or {}
    for _, member in ipairs(self:GetGuildRosterRows()) do
        local key = self:NormalizeName(member.name)
        local id = memberKey(member.name, member.guid)
        currentMembers[key] = true
        local verification = member.verification or { state = "missing" }
        if member.raceMismatch and member.raceCheck then
            local signature = table.concat({ tostring(member.guid or ""), member.raceCheck.actual, member.raceCheck.expected }, ":")
            if connection.raceMismatchNotices[key] ~= signature and SendChatMessage and not self:IsAutomaticWarningDisabled("OFFICER") then
                local actualRace = self:Text("GUILD_RACE_" .. member.raceCheck.actual)
                local expectedRace = self:Text("GUILD_RACE_" .. member.raceCheck.expected)
                local sent = pcall(SendChatMessage, self:Text("RACE_MISMATCH_OFFICER_NOTICE", member.name, actualRace, expectedRace), "OFFICER")
                if sent then
                    connection.raceMismatchNotices[key] = signature
                    self:DebugMsg(self:Text("RACE_MISMATCH_DETECTED", member.name, actualRace, expectedRace), 2)
                end
            end
        else
            connection.raceMismatchNotices[key] = nil
        end
        if not member.online then
            reportedPresenceMismatches[key], pendingPresenceChecks[key] = nil, nil
        elseif verification.state == "verified" or verification.state == "compatible" then
            if reportedPresenceMismatches[key] then self:DebugMsg(self:Text("PRESENCE_RECOVERED", member.name), 3) end
            reportedPresenceMismatches[key], pendingPresenceChecks[key] = nil, nil
            connection.newMemberChecks[id] = nil
        elseif verification.state == "missing" or verification.state == "stale" then
            local report = reportedPresenceMismatches[key]
            -- Begin escalation confirmation early enough to complete a full
            -- response window without moving the five-minute escalation.
            local dueAt = report and report.reportedAt + 300 or nil
            if not report or (not report.escalated and now >= dueAt - CONFIRMATION_WINDOW) then
                local check = pendingPresenceChecks[key]
                if not check then
                    check = {
                        attempts = 0,
                        nextAt = now,
                        readyAt = report and dueAt or math.max(now + CONFIRMATION_WINDOW, loginReadyAt),
                    }
                    pendingPresenceChecks[key] = check
                    self:DebugMsg(self:Text("PRESENCE_CONFIRM_PENDING", member.name), 3)
                end
                if check.attempts < PROBE_ATTEMPTS then
                    if now >= check.nextAt then probeBatch[#probeBatch + 1] = check
                    else queuePresenceReview(check.nextAt - now) end
                else
                    local readyAt = math.max(check.nextAt, check.readyAt or 0, loginReadyAt)
                    if now < readyAt then queuePresenceReview(readyAt - now)
                    else
                        pendingPresenceChecks[key] = nil
                        if report then
                            local sent, recovered = announcePresenceMismatch(member, verification, true)
                            if not sent then queuePresenceReview(1); return end
                            if not recovered then report.escalated = true end
                        else
                            local sent, recovered = announcePresenceMismatch(member, verification, false)
                            if not sent then queuePresenceReview(1); return end
                            if not recovered then
                                reportedPresenceMismatches[key] = { reportedAt = now, escalated = false }
                                self:DebugMsg(self:Text("PRESENCE_MISMATCH", member.name, verification.label or ""), 2)
                                if connection.newMemberChecks[id] and not connection.newMemberWelcomeNotices[id] and SendChatMessage
                                    and self:IsPresenceNotificationLeader() and not self:SuppressesPresenceWarnings()
                                    and self:IsNewMemberWelcomeEnabled() then
                                    connection.newMemberWelcomeNotices[id] = now
                                    SendChatMessage(self:Text("NEW_MEMBER_WELCOME", member.name), "GUILD")
                                end
                                queuePresenceReview(300 - CONFIRMATION_WINDOW)
                            end
                            connection.newMemberChecks[id] = nil
                        end
                    end
                end
            elseif not report.escalated then
                queuePresenceReview(dueAt - CONFIRMATION_WINDOW - now)
            end
        end
    end
    for key in pairs(pendingPresenceChecks) do if not currentMembers[key] then pendingPresenceChecks[key] = nil end end
    for key in pairs(reportedPresenceMismatches) do if not currentMembers[key] then reportedPresenceMismatches[key] = nil end end
    for key in pairs(connection.raceMismatchNotices) do if not currentMembers[key] then connection.raceMismatchNotices[key] = nil end end
    if #probeBatch > 0 then
        -- One guild-wide batch covers all pending members. A poll merely
        -- received from another client is not evidence that we tried a probe.
        local ircSent = self:RequestGuildPresence(false)
        local compatibleSent = self.Compatibility and self.Compatibility.RequestPresenceCheck and self.Compatibility:RequestPresenceCheck()
        for _, check in ipairs(probeBatch) do
            if ircSent and compatibleSent then check.attempts = check.attempts + 1 end
            check.nextAt = now + PROBE_INTERVAL
        end
        self:DebugMsg(self:Text(ircSent and compatibleSent and "PRESENCE_CONFIRM_PROBE" or "PRESENCE_CONFIRM_UNAVAILABLE", #probeBatch), 3)
        queuePresenceReview(PROBE_INTERVAL)
    end
end

function iRC:CheckNewMemberAddon(memberId)
    if not self:IsGuildConnectionActive() then return true end
    local connection = self:GetConnection()
    if not connection then return true end
    if connection.newMemberWelcomeNotices and connection.newMemberWelcomeNotices[memberId] then return true end
    connection.newMemberChecks = connection.newMemberChecks or {}
    connection.newMemberChecks[memberId] = connection.newMemberChecks[memberId] or time()
    self:CheckPresenceMismatches()
    return connection.newMemberChecks[memberId] == nil
end

function iRC:ScheduleNewMemberAddonCheck(memberId)
    if not self:IsGuildConnectionActive() or not C_Timer or not C_Timer.After then return end
    local connection = self:GetConnection()
    if not connection then return end
    connection.newMemberChecks = connection.newMemberChecks or {}
    connection.newMemberChecks[memberId] = time()
    self:DebugMsg(self:Text("NEW_MEMBER_CHECK", memberId), 3)
    queuePresenceReview(2)
end

function iRC:CheckGuildRosterForNewMembers()
    if not self:IsGuildConnectionActive() then return end
    local connection = self:GetConnection()
    local roster = self:GetGuildRosterSnapshot()
    if not connection or #roster < 1 then return end
    local previous = connection.rosterMembers or {}
    local current, newMembers = {}, {}
    local hasBaseline = connection.rosterBaselineReady and true or false
    for _, member in ipairs(roster) do
        local id = memberKey(member.name, member.guid)
        current[id] = true
        if hasBaseline and not previous[id] then newMembers[#newMembers + 1] = id end
    end
    connection.rosterMembers = current
    connection.rosterBaselineReady = true
    for _, memberId in ipairs(newMembers) do self:ScheduleNewMemberAddonCheck(memberId) end
end

local function getRaceFromGuid(guid)
    if not guid or not GetPlayerInfoByGUID then return nil end
    local _, _, localizedRace, raceFile = GetPlayerInfoByGUID(guid)
    return raceFile or localizedRace
end

function iRC:GetGuildMemberRaceCheck(race, connection)
    connection = connection or self:GetConnection()
    local expected = connection and connection.active == true and connection.rules and connection.rules.raceLock == true
        and self:NormalizeGuildRace(connection.rules and connection.rules.guildRace) or ""
    local actual = self:NormalizeGuildRace(race)
    return {
        expected = expected,
        actual = actual,
        known = expected ~= "" and actual ~= "",
        mismatch = expected ~= "" and actual ~= "" and actual ~= expected,
    }
end

function iRC:GetGuildRosterRows()
    local rows, roster = {}, self:GetGuildRosterSnapshot()
    local selfName = self:GetPlayerName()
    -- Static roster data is event-cached. Live addon and verification state is
    -- still derived on every call so incoming profiles apply immediately.
    local connection = self:GetConnection()
    local active = connection and connection.active == true
    local profiles = connection and connection.members or {}
    local compatibleMembers = active and connection.compatibilityMembers or {}
    local context = { connection = connection, selfKey = self:NormalizeName(selfName) }
    for _, rosterMember in ipairs(roster) do
        local name, rankIndex, level = rosterMember.name, rosterMember.rankIndex, rosterMember.level
        local className, classFile = rosterMember.className, rosterMember.classFile
        local online, guid = rosterMember.online, rosterMember.guid
        if name then
            local lastOnlineDays = rosterMember.lastOnlineDays
            local key = self:NormalizeName(name)
            local profile = profiles[key]
            local compatibilityMember = compatibleMembers[key]
            local profileGuid = profile and profile.guid
            local compatibilityGuid = compatibilityMember and compatibilityMember.guid
            if guid and guid ~= "" and ((profileGuid and profileGuid ~= "" and profileGuid ~= guid)
                or (compatibilityGuid and compatibilityGuid ~= "" and compatibilityGuid ~= guid)) then
                profiles[key], compatibleMembers[key] = nil, nil
                if connection.guildFoundRoster then connection.guildFoundRoster[key] = nil end
                if connection.professionMembers then connection.professionMembers[key] = nil end
                if connection.attentionSince then connection.attentionSince[key] = nil end
                reportedPresenceMismatches[key], pendingPresenceChecks[key] = nil, nil
                connection.newMemberChecks = connection.newMemberChecks or {}
                connection.newMemberChecks[memberKey(name, guid)] = time()
                profile, compatibilityMember = nil, nil
                self:DebugMsg(self:Text("ROSTER_IDENTITY_RESET", name), 2)
            end
            local compatibility = compatibilityMember and compatibilityMember.presence or nil
            local syncedStatus = active and self.RaceLockedSync and self.RaceLockedSync:GetStatus(name, connection)
            if profile and key ~= context.selfKey then
                if isFreshIRCProfile(profile) then
                    -- iRC is the canonical source while its direct profile is
                    -- live. Hide the compatibility presence, but retain the
                    -- separate iRC Guild Found report and GM decision.
                    compatibilityMember, compatibility = nil, nil
                elseif isFreshCompatibility(latestCompatibilityEntry(compatibilityMember, syncedStatus), profile) then
                    -- A genuinely later native response proves that iRC is no
                    -- longer the active source for this character.
                    profiles[key], profile = nil, nil
                    self:DebugMsg(self:Text("PROFILE_REPLACED_BY_COMPATIBILITY", name), 3)
                end
            end
            local race = profile and profile.race or getRaceFromGuid(guid) or "Unknown"
            if self:NormalizeName(name) == self:NormalizeName(selfName) then
                profile = self:GetLocalProfile()
                race = profile.race
                guid = profile.guid
            end
            local verification = self:GetMemberVerification(name, online and true or false, profile, context)
            local raceCheck = self:GetGuildMemberRaceCheck(race, connection)
            local attentionSince = self:GetMemberAttentionSince(name, verification, connection or false)
            rows[#rows + 1] = {
                name = name, guid = guid or (profile and profile.guid) or "", rankIndex = rankIndex or 99,
                level = level or (profile and profile.level) or 1, class = (profile and profile.class) or classFile or className or "UNKNOWN",
                race = race, online = online and true or false, profile = profile,
                lastOnlineDays = lastOnlineDays,
                compatibility = compatibility,
                compatibilityMember = compatibilityMember,
                raceLockedStatus = syncedStatus or false,
                professionData = connection and connection.professionMembers and connection.professionMembers[key]
                    and (not guid or guid == "" or connection.professionMembers[key].guid == guid)
                    and connection.professionMembers[key] or nil,
                hasParticipationSnapshot = true,
                -- A member has exactly one canonical row. iRC is preferred when
                -- present; compatible counters only fill missing data and are
                -- never added to iRC counters.
                selfFound = profile and profile.selfFound or (compatibilityMember and compatibilityMember.selfFound) or false,
                addonVersion = profile and profile.addonVersion or nil,
                source = (profile and "iRC") or (compatibilityMember and compatibilityMember.presence and compatibilityMember.presence.source) or nil,
                verification = verification,
                raceCheck = raceCheck,
                raceMismatch = raceCheck.mismatch,
                attentionSince = attentionSince,
            }
        end
    end
    if #rows == 0 and self:IsInGuildConnection() then
        local profile = self:GetLocalProfile()
        local raceCheck = self:GetGuildMemberRaceCheck(profile.race)
        rows[1] = { name = profile.name, guid = profile.guid, rankIndex = 0, level = profile.level, class = profile.class, race = profile.race, online = true, profile = profile, selfFound = profile.selfFound, addonVersion = profile.addonVersion, verification = self:GetMemberVerification(profile.name, true, profile), raceCheck = raceCheck, raceMismatch = raceCheck.mismatch }
    end
    table.sort(rows, function(a, b) return string.lower(a.name) < string.lower(b.name) end)
    return rows
end

function iRC:GetRaceOverview()
    local groups = {}
    local connection = self:GetConnection()
    for _, row in ipairs(self:GetGuildRosterRows()) do
        local race = row.race or "Unknown"
        local group = groups[race]
        if not group then
            group = {
                race = race,
                faction = AllianceRaces[race] and "Alliance" or (HordeRaces[race] and "Horde" or "Unknown"),
                guildName = connection and connection.guildName or "No guild",
                members = 0,
                totalLevel = 0,
                addonUsers = 0,
                selfFound = 0,
                classes = {},
            }
            groups[race] = group
        end
        group.members = group.members + 1
        group.totalLevel = group.totalLevel + (row.level or 1)
        if row.profile or row.compatibility then group.addonUsers = group.addonUsers + 1 end
        if row.selfFound then group.selfFound = group.selfFound + 1 end
        group.classes[row.class or "UNKNOWN"] = (group.classes[row.class or "UNKNOWN"] or 0) + 1
    end
    local result = {}
    for _, group in pairs(groups) do
        group.averageLevel = group.members > 0 and math.floor((group.totalLevel / group.members) * 10 + 0.5) / 10 or 0
        result[#result + 1] = group
    end
    table.sort(result, function(a, b)
        if a.faction ~= b.faction then return a.faction < b.faction end
        return a.race < b.race
    end)
    return result
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(3, function() iRC:RefreshGuildRoster() end)
        if C_Timer and C_Timer.NewTicker then
            C_Timer.NewTicker(15, function()
                if iRC.ConnectionDashboard then iRC.ConnectionDashboard:RefreshIfShown() end
                -- Detect expired iRC presence even if WoW still lists the
                -- previous notifier online (for example, addon disabled).
                if iRC:IsGuildConnectionActive() and iRC:HasGuildPermission("presence") then queuePresenceReview(1) end
            end)
        end
    elseif event == "GUILD_ROSTER_UPDATE" then
        iRC:InvalidateGuildRosterSnapshot()
        if iRC.GuildMap then iRC.GuildMap:Cleanup() end
        iRC:CheckGuildRosterForNewMembers()
        if iRC:IsGuildConnectionActive() and iRC:HasGuildPermission("presence") then queuePresenceReview(1) end
        if iRC.ConnectionDashboard then iRC.ConnectionDashboard:RefreshIfShown() end
        if iRC.MainUI and iRC.MainUI.frame and iRC.MainUI.frame.category == "Guild Members" then
            iRC.MainUI:RefreshIfShown()
        end
    end
end)
