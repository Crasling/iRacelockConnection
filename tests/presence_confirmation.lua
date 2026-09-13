-- Notification timing and handoff regression tests; all chat and clocks mocked.
local now, own = 1800000000, "Bofficer"
local timers, tickers, frames, addonMessages, notices = {}, {}, {}, {}, {}
local roster = {
    { name = "Bofficer", rank = 1, online = true },
    { name = "Aofficer", rank = 0, online = false },
    { name = "Target", rank = 5, online = true },
}
function time() return now end
function GetTime() return now end
function GetBuildInfo() return "1.15.9", "1", "", 11509 end
function GetRealmName() return "Soulseeker" end
function GetUnitName() return own .. "-Soulseeker" end
function UnitName() return own end
function UnitGUID() return "Player-1-" .. own end
function UnitLevel() return 10 end
function UnitRace() return "Troll", "Troll" end
function UnitClass() return "Warrior", "WARRIOR" end
function GetNumGuildMembers() return #roster end
function GetGuildRosterInfo(index)
    local row = roster[index]
    return row.name .. "-Soulseeker", "Rank", row.rank, 10, "Warrior", nil, nil, nil, row.online, nil, "WARRIOR", nil, nil, nil, nil, nil, "Player-1-" .. row.name
end
function GetGuildInfo()
    for _, row in ipairs(roster) do if row.name == own then return "Darkspear Tribe", "Rank", row.rank end end
end
function GetPlayerInfoByGUID() return "Warrior", "WARRIOR", "Troll", "Troll" end
function CreateFrame()
    local frame = { RegisterEvent = function() end, SetScript = function(self, key, callback) self[key] = callback end }
    frames[#frames + 1] = frame
    return frame
end
function SendChatMessage(...) notices[#notices + 1] = { at = now, ... } end
local function sendAddon(...) addonMessages[#addonMessages + 1] = { at = now, ... } end
C_ChatInfo = { SendAddonMessage = sendAddon, RegisterAddonMessagePrefix = function() end }
C_Timer = {
    After = function(delay, callback) timers[#timers + 1] = { at = now + delay, callback = callback } end,
    NewTicker = function(_, callback) tickers[#tickers + 1] = callback end,
}
local function advance(seconds)
    local finish = now + seconds
    while true do
        table.sort(timers, function(a, b) return a.at < b.at end)
        if not timers[1] or timers[1].at > finish then break end
        local timer = table.remove(timers, 1)
        now = timer.at; timer.callback()
    end
    now = finish
end
local addon, private = {}, {}
function LibStub() return { NewAddon = function() return addon end } end
assert(loadfile("iRC_Core.lua"))("iRC", private)
assert(loadfile("Localization/enUS.lua"))("iRC", private)
assert(loadfile("iRC_Guild.lua"))("iRC", private)
local guildFrame = frames[#frames]
assert(loadfile("iRC_Connection.lua"))("iRC", private)
assert(loadfile("iRC_Compatibility.lua"))("iRC", private)
local iRC = private.iRC
iRCDB, iRCCharDB = {}, {}
function iRC:DebugMsg() end
function iRC:GetSelfFoundEvidence() return { status = "UNVERIFIED" } end
local db = iRC:GetConnection()
local function reset(login)
    iRC:ResetPresenceNotificationChecks()
    timers, addonMessages, notices = {}, {}, {}
    db.active, own = true, "Bofficer"
    db.rules.raceLock = true
    db.members, db.compatibilityMembers, db.newMemberChecks, db.newMemberWelcomeNotices = {}, {}, {}, {}
    db.rosterBaselineReady = false
    roster[2].online, roster[3].online = false, true
    C_ChatInfo.SendAddonMessage = sendAddon
    iRC.ConnectionSessionStartedAt = now - (login and 0 or 1000)
end

local function respond(name)
    db.members[iRC:NormalizeName(name)] = { name = name, race = "Troll", lastSeen = now, addonVersion = "0.2.4" }
end
local function probeCount()
    local count = 0
    for _, packet in ipairs(addonMessages) do if packet[1] == "RLAddon" and packet[2]:match("^PING,") then count = count + 1 end end
    return count
end

reset(true)
db.rules.raceLock = false
db.rules.guildMapEnabled = true
assert(not iRC:IsAddonResponseRequired(db), "an active guild with only utility rules does not require addon presence")
assert(iRC:GetMemberVerification("Target", true).state == "optional", "missing addon is optional without verification rules")
iRC:CheckPresenceMismatches(); advance(360)
assert(#notices == 0 and probeCount() == 0, "optional addon presence causes no probes or warnings")
db.rules.guildMapEnabled = false

reset(true)
iRC:CheckPresenceMismatches()
assert(#notices == 0 and probeCount() == 1, "probe before warning")
advance(7); respond("Target"); advance(60)
assert(#notices == 0, "late iRC login/reload response cancels warnings")

reset(true)
local started = now
iRC:CheckPresenceMismatches(); advance(15)
assert(probeCount() == 2 and #notices == 0, "second probe then another response window")
advance(44); assert(#notices == 0, "no warnings during first 60 seconds after reload")
advance(1)
assert(#notices == 2 and notices[1].at == started + 60, "first confirmed officer/whisper notice after startup grace")
local firstNotice = now
advance(270); assert(probeCount() == 6)
advance(15); assert(probeCount() == 6 and #notices == 2)
advance(15)
assert(#notices == 5 and notices[5][2] == "GUILD" and now == firstNotice + 300, "escalation rechecks before officer/whisper/guild notice")

reset()
iRC:CheckPresenceMismatches(); advance(20)
iRC.Compatibility:StoreSelfFound("Target", true, "RaceLockedForkEU")
advance(60)
assert(#notices == 0, "late RaceLockedForkEU response cancels pending notice")

reset()
respond("Target")
iRC.Compatibility:StoreSelfFound("Target", true, "RaceLockedForkEU")
advance(136)
assert(iRC:GetMemberVerification("Target", true, db.members.target).state == "stale", "compatibility cached alongside iRC cannot outlive that iRC profile")
iRC.Compatibility:StoreSelfFound("Target", true, "RaceLockedForkEU")
assert(iRC:GetMemberVerification("Target", true, db.members.target).state == "compatible", "a newer compatibility response can take over after iRC expires")

reset()
iRC:CheckPresenceMismatches(); advance(30)
assert(#notices == 2)
advance(270); respond("Target"); advance(30)
assert(#notices == 2, "response to escalation probe prevents guild escalation")

reset()
iRC:CheckPresenceMismatches(); advance(15)
roster[3].online = false
guildFrame.OnEvent(nil, "GUILD_ROSTER_UPDATE"); advance(60)
assert(#notices == 0, "offline member is never warned")
roster[3].online = true
guildFrame.OnEvent(nil, "GUILD_ROSTER_UPDATE"); advance(1)
local reconnectedAt = now
advance(59); assert(#notices == 0)
advance(1); assert(#notices == 2 and now == reconnectedAt + 60, "relogin requires a full confirmation window")

reset()
iRC:ScheduleNewMemberAddonCheck("guid:Player-1-Target")
advance(10); respond("Target"); advance(60)
assert(#notices == 0, "new member gets a response window before welcome/missing notices")
reset()
iRC:ScheduleNewMemberAddonCheck("guid:Player-1-Target")
advance(31); assert(#notices == 0)
advance(30); assert(#notices == 0)
advance(1); assert(#notices == 3 and notices[3][2] == "GUILD", "missing new member welcome follows three probes and a full confirmation window")
iRC:CheckNewMemberAddon("guid:Player-1-Target")
assert(#notices == 3, "welcome is not repeated")

reset()
iRC:CheckPresenceMismatches(); advance(20)
roster[2].online = true; respond("Aofficer")
advance(60)
assert(#notices == 0, "old notifier cannot send when another iRC officer now wins")
roster[2].online = false
guildFrame.OnEvent(nil, "GUILD_ROSTER_UPDATE"); advance(1)
local handoffAt = now
advance(59); assert(#notices == 0)
advance(1); assert(#notices == 2 and now == handoffAt + 60, "officer logout elects next client and requires a full fresh confirmation window")

reset()
roster[2].online = true; respond("Aofficer")
guildFrame.OnEvent(nil, "PLAYER_LOGIN") -- Register the periodic leadership watchdog.
advance(136)
for _, callback in ipairs(tickers) do callback() end
advance(1)
assert(iRC:IsPresenceNotificationLeader() and probeCount() == 1, "watchdog replaces expired officer even while roster says online")
assert(#notices == 0, "handoff never bypasses confirmation")

reset()
C_ChatInfo.SendAddonMessage = nil
iRC:CheckPresenceMismatches(); advance(90)
assert(#notices == 0, "failed probe sends cannot authorize warnings")
C_ChatInfo.SendAddonMessage = sendAddon
reset()
iRC:CheckPresenceMismatches(); advance(15)
db.active = false; advance(60)
assert(#notices == 0, "guild deactivation cancels pending notices")

reset(true)
iRC.TestAdminName = "Bofficer-Soulseeker"
iRC:GetSettings().suppressPresenceWarnings = true
iRC:CheckPresenceMismatches(); advance(60)
assert(#notices == 0, "test admin warning suppression blocks officer, whisper, and guild messages")
iRC:GetSettings().suppressPresenceWarnings = false
iRC.TestAdminName = nil
print("Presence confirmation tests passed: three-probe confirmation, reload grace, late iRC/RaceLockedForkEU replies, offline/relogin, welcome, escalation, officer handoff and unavailable transport.")
