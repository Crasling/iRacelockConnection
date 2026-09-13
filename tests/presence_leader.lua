-- Run from the addon directory. No game, network or saved-variable writes.
local now, player = 1800000000, "Crasjin"
local roster = {
    { name = "Crasjin", rank = 5, online = true },
    { name = "Aleader", rank = 0, online = true },
    { name = "Aofficer", rank = 1, online = true },
    { name = "Zofficer", rank = 1, online = true },
    { name = "Member", rank = 2, online = true },
    { name = "Jujukhan", rank = 5, online = true },
}
local frames, messages, debugMessages = {}, {}, {}
function time() return now end
function GetTime() return now end
function GetBuildInfo() return "1.15.9", "1", "", 11509 end
function GetRealmName() return "Soulseeker" end
function GetUnitName() return player .. "-Soulseeker" end
function UnitName() return player end
function UnitGUID() return "Player-1-" .. player end
function UnitLevel() return 10 end
function UnitRace() return "Troll", "Troll" end
function UnitClass() return "Warrior", "WARRIOR" end
function GetNumGuildMembers() return #roster end
function GetGuildRosterInfo(index)
    local row = roster[index]
    return row.name .. "-Soulseeker", "Rank", row.rank, 10, "Warrior", nil, nil, nil, row.online, nil, "WARRIOR", nil, nil, nil, nil, nil, row.guid or ("Player-1-" .. row.name)
end
function GetGuildInfo()
    for _, row in ipairs(roster) do if row.name == player then return "Darkspear Tribe", "Rank", row.rank end end
end
function CreateFrame()
    local frame = { RegisterEvent = function() end, SetScript = function(self, event, callback) self[event] = callback end }
    frames[#frames + 1] = frame
    return frame
end
local addon = {}
function LibStub() return { NewAddon = function() return addon end } end
C_ChatInfo = { SendAddonMessage = function(...) messages[#messages + 1] = { ... } end }
local private = {}
assert(loadfile("iRC_Core.lua"))("iRC", private)
assert(loadfile("Localization/enUS.lua"))("iRC", private)
assert(loadfile("iRC_Guild.lua"))("iRC", private)
assert(loadfile("iRC_Connection.lua"))("iRC", private)
local connectionFrame, iRC = frames[#frames], private.iRC
assert(iRC:IsTestAdminName("Crasling-Soulseeker"), "Crasling is an explicit test admin")
assert(iRC:IsTestAdminName("Crasjin-Soulseeker"), "Crasjin is an explicit test admin")
assert(not iRC:IsTestAdminName("Crasling-OtherRealm"), "test admin authority is realm-locked")
iRC.TestAdminName = "Crasjin-Soulseeker"
iRCDB, iRCCharDB = {}, {}
local db = iRC:GetConnection()
db.active = true
db.rules.raceLock = true
function iRC:DebugMsg(message) debugMessages[#debugMessages + 1] = message end
function iRC:GetSelfFoundEvidence() return { status = "UNVERIFIED" } end

local beforeOversizedSend = #messages
assert(not iRC:SendAddonTraffic(iRC.Prefix, string.rep("x", 256), "GUILD"), "oversized addon traffic is rejected")
assert(#messages == beforeOversizedSend, "oversized addon traffic never reaches the WoW API")

-- A newly installed inactive client must receive a direct bootstrap response.
player = "Aleader"
local beforeBootstrap = #messages
connectionFrame.OnEvent(nil, "CHAT_MSG_ADDON", iRC.Prefix, "GUILD_ACTIVATION_REQUEST\t9", "GUILD", "Member-Soulseeker")
assert(#messages == beforeBootstrap + 5, "GM sends activation, rules, contacts, permissions and a presence request to bootstrap the member")
assert(messages[beforeBootstrap + 1][2]:match("^GUILD_ACTIVATION\t9\t1$"), "bootstrap starts with active guild state")
assert(messages[beforeBootstrap + 1][3] == "WHISPER" and messages[beforeBootstrap + 1][4] == "Member-Soulseeker", "activation targets requester")
assert(messages[beforeBootstrap + 2][2]:match("^RULES\t9\t"), "bootstrap includes current rules")
assert(messages[beforeBootstrap + 2][3] == "WHISPER" and messages[beforeBootstrap + 2][4] == "Member-Soulseeker", "rules target requester")
assert(#messages[beforeBootstrap + 2][2] <= 255, "core rules fit WoW's addon-message limit")
local ruleParts = {}
for value in (messages[beforeBootstrap + 2][2] .. "\t"):gmatch("(.-)\t") do ruleParts[#ruleParts + 1] = value end
local gmRulesTimestamp, gmRulesSource = ruleParts[14], ruleParts[15]
assert(gmRulesTimestamp and gmRulesSource == "Aleader-Soulseeker", "GM authors the rules timestamp and source")
assert(ruleParts[13] == "", "core rules leave guild contacts to their dedicated packet")
assert(messages[beforeBootstrap + 3][2]:match("^GUILD_CONTACTS\t9\t"), "guild contacts use their dedicated packet")
assert(messages[beforeBootstrap + 4][2]:match("^RANK_PERMISSIONS\t9\t"), "bootstrap includes rank permissions")
assert(messages[beforeBootstrap + 5][2] == "PRESENCE_REQUEST\t9\tREQUEST", "bootstrap asks the member to return HELLO")
local beforeImmediateRule = #messages
iRC.LowTrafficMode = true
assert(iRC:SetConnectionRule("guildMapEnabled", true), "Guild Master can change an active rule")
iRC.LowTrafficMode = false
assert(#messages > beforeImmediateRule and messages[beforeImmediateRule + 1][2]:match("^RULES\t9\t"),
    "an active rule change broadcasts immediately during low-traffic mode")
local beforeDirectHello = #messages
connectionFrame.OnEvent(nil, "CHAT_MSG_ADDON", iRC.Prefix, "PRESENCE_REQUEST\t9\tREQUEST", "WHISPER", "Member-Soulseeker")
assert(#messages == beforeDirectHello + 1 and messages[#messages][2]:match("^HELLO\t9\t"), "presence request returns HELLO")
assert(messages[#messages][3] == "WHISPER" and messages[#messages][4] == "Member-Soulseeker", "presence response targets the requester directly")

-- Rules and activation bootstrap fall through every guild rank. The lowest
-- online rank index with a fresh iRC client is authoritative.
roster[2].online = false
player = "Aofficer"
assert(iRC:IsRulesetBroadcaster(), "rank 1 takes over rules while the GM client is unavailable")
roster[3].online, roster[4].online = false, false
player = "Member"
assert(iRC:IsRulesetBroadcaster(), "an ordinary member relays rules when no higher-rank iRC client is available")
local beforeMemberBootstrap = #messages
connectionFrame.OnEvent(nil, "CHAT_MSG_ADDON", iRC.Prefix, "GUILD_ACTIVATION_REQUEST\t9", "GUILD", "Jujukhan-Soulseeker")
assert(#messages == beforeMemberBootstrap + 3, "highest available ordinary rank bootstraps a new member with activation, rules and presence")
local relayedParts = {}
for value in (messages[beforeMemberBootstrap + 2][2] .. "\t"):gmatch("(.-)\t") do relayedParts[#relayedParts + 1] = value end
local relayedTimestamp, relayedSource = relayedParts[14], relayedParts[15]
assert(relayedTimestamp == gmRulesTimestamp and relayedSource == gmRulesSource, "lower ranks relay the original GM timestamp and source unchanged")
roster[2].online, roster[3].online, roster[4].online = true, true, true
player = "Crasjin"

local function profile(name, age, override)
    db.members[iRC:NormalizeName(name)] = { name = name, addonVersion = "0.2.4", lastSeen = now - (age or 0), testGuildMasterOverride = override }
end
local function expectLeader(name)
    local elected, actual = iRC:IsPresenceNotificationLeader()
    assert(actual == name .. "-Soulseeker", "unexpected leader: " .. tostring(actual))
    assert(elected == (player == name), "clients must agree on the same winner")
end

assert(not iRC:IsPresenceNotificationLeader(), "ordinary member cannot notify")
iRC:CheckPresenceMismatches()
assert(debugMessages[#debugMessages] == iRC:Text("PRESENCE_NOTIFICATION_INELIGIBLE"), "do not claim another leader when local rank is ineligible")
iRC:GetSettings().testGuildMasterOverride = true
assert(iRC:IsTestAdminGuildMaster())
iRC:GetSettings().suppressPresenceWarnings = true
local debugBeforeSuppressedCheck = #debugMessages
iRC:CheckPresenceMismatches()
assert(#debugMessages == debugBeforeSuppressedCheck, "suppressed test clients stop presence checks without misleading debug output")
iRC:GetSettings().suppressPresenceWarnings = false
assert(not iRC:IsPresenceNotificationLeader(), "test GM cannot become the officer notification leader")
profile("Member", 0, true)
assert(not iRC:IsPresenceNotificationLeader(), "a member cannot elect another fake officer")
profile("Aleader")
assert(not iRC:IsPresenceNotificationLeader(), "ordinary members never send officer notifications")
iRC:CheckPresenceMismatches()
assert(debugMessages[#debugMessages] == iRC:Text("PRESENCE_NOTIFICATION_INELIGIBLE"), "test GM remains ineligible for officer notifications")
now = now + 200
profile("Aleader", 136)
assert(not iRC:IsPresenceNotificationLeader()) -- Expired iRC profile cannot qualify.
profile("Aleader", 201)
assert(not iRC:IsPresenceNotificationLeader()) -- Previous-session profile must not qualify.
profile("Aleader", -1)
assert(not iRC:IsPresenceNotificationLeader()) -- Future timestamps cannot qualify.
profile("Aleader")
roster[2].online = false
assert(not iRC:IsPresenceNotificationLeader()) -- Offline GM cannot qualify even with fresh iRC data.
roster[2].online = true
db.members.aleader = nil

-- Actual HELLO serialization/deserialization conveys enabled AND disabled
-- test admin state, so peers use the same effective role as the test client.
iRC:SendHello()
local packet = messages[#messages]
db.members.crasjin = nil
connectionFrame.OnEvent(nil, "CHAT_MSG_ADDON", packet[1], packet[2], "GUILD", "Crasjin-Soulseeker")
assert(db.members.crasjin == nil, "self-sent guild packets are ignored")
player = "Zofficer"
connectionFrame.OnEvent(nil, "CHAT_MSG_ADDON", packet[1], packet[2], "GUILD", "Crasjin-Soulseeker")
assert(db.members.crasjin.testGuildMasterOverride == true)
expectLeader("Zofficer") -- Test GM data never displaces a real officer.
player = "Crasjin"
iRC:GetSettings().testGuildMasterOverride = false
iRC:SendHello()
packet = messages[#messages]
db.members.crasjin = nil
player = "Zofficer"
connectionFrame.OnEvent(nil, "CHAT_MSG_ADDON", packet[1], packet[2], "GUILD", "Crasjin-Soulseeker")
assert(db.members.crasjin.testGuildMasterOverride == false)
expectLeader("Zofficer")
profile("Jujukhan")
expectLeader("Zofficer") -- An ordinary member cannot gain authority by name.
roster[6].online = false
expectLeader("Zofficer")
profile("Aofficer"); profile("Zofficer")
expectLeader("Aofficer")
player = "Aofficer"
expectLeader("Aofficer") -- Exactly the same result on the other officer client.
db.active = false
assert(not iRC:IsPresenceNotificationLeader(), "inactive guild never elects a notifier")

-- Exercise actual guild roster -> Race Overview with offline characters whose
-- races are unavailable, mixed addon sources, duplicate rows and a departed member.
assert(loadfile("iRC_RaceGrid.lua"))("iRC", private)
db.active, player = true, "Crasjin"
roster[2].online, roster[3].online, roster[6].online = false, false, false
db.members = {
    aleader = { name = "Aleader", lastSeen = now - 5000 },
    departed = { name = "Departed", lastSeen = now },
}
local compatibleMembers = {
    aleader = { presence = { source = "RaceLockedForkEU", lastSeen = now - 5000 } },
    aofficer = { presence = { source = "RaceLockedForkEU", lastSeen = now - 5000 } },
    zofficer = { presence = { source = "RaceLockedForkEU", lastSeen = now } },
}
db.compatibilityMembers = compatibleMembers
function iRC:GetCompatibilityMember(name) return compatibleMembers[self:NormalizeName(name)] end
roster[#roster + 1] = roster[2] -- Same character must still only count once.
local group = assert(iRC.RaceGrid:BuildOwnGuildReports()[1])
assert(group.members == 6 and group.activePlayers == 3 and group.verifiedMembers == 1 and group.compatibleMembers == 1,
    string.format("guild snapshot totals: %s/%s/%s/%s", group.members, group.activePlayers, group.verifiedMembers, group.compatibleMembers))
assert(group.averageLevel == 10, "averages use the same participant population")
local classTotal = 0; for _, count in pairs(group.classes) do classTotal = classTotal + count end
assert(classTotal == 6, "class breakdown uses the full guild roster")
assert(iRC:GetMemberVerification("Aofficer", false).state == "offline", "live verification behavior remains unchanged")
db.members.member = { name = "Member", guid = "Player-1-Member", race = "Troll", lastSeen = now, addonVersion = "0.2.4" }
db.compatibilityMembers.member = { guid = "Player-1-Member", presence = { source = "RaceLockedForkEU", lastSeen = now } }
local sourceRows = iRC:GetGuildRosterRows()
local sourced
for _, row in ipairs(sourceRows) do if iRC:NormalizeName(row.name) == "member" then sourced = row break end end
assert(sourced and sourced.profile and not sourced.compatibility and sourced.source == "iRC", "fresh iRC suppresses the compatible source for the same character")
db.members.member.lastSeen = now - 136
db.compatibilityMembers.member.presence.lastSeen = now - 100
sourceRows = iRC:GetGuildRosterRows()
for _, row in ipairs(sourceRows) do if iRC:NormalizeName(row.name) == "member" then sourced = row break end end
assert(sourced and not sourced.profile and sourced.compatibility and sourced.source == "RaceLockedForkEU", "newer compatible presence replaces and clears an expired iRC profile")
assert(db.members.member == nil, "expired iRC profile is removed from the connection cache after native takeover")
db.compatibilityMembers.member.presence.lastSeen = now - 136
assert(iRC:GetMemberVerification("Member", true).state == "missing", "RaceLockedForkEU compatibility expires after 135 seconds")
db.members.member = { name = "Member", guid = "Player-OLD-Member", race = "Troll", lastSeen = now }
db.compatibilityMembers.member = { guid = "Player-OLD-Member", presence = { source = "RaceLockedForkEU", lastSeen = now } }
db.guildFoundRoster = { member = { source = "RaceLocked", lastSeen = now } }
local identityRows = iRC:GetGuildRosterRows()
local recreated
for _, row in ipairs(identityRows) do if iRC:NormalizeName(row.name) == "member" then recreated = row break end end
assert(recreated and not recreated.profile and recreated.verification.state == "missing", "same-name character with a new GUID cannot inherit cached verification")
assert(db.members.member == nil and db.compatibilityMembers.member == nil and db.guildFoundRoster.member == nil, "all name-keyed identity caches are cleared after a GUID change")
assert(db.newMemberChecks["guid:Player-1-Member"], "a recreated character receives a new GUID-scoped confirmation check")
print("Race Overview population tests passed: verified + compatible, offline/unknown race, dual-source deduplication, departed/undetected exclusions and native overwrite protection.")
print("Presence leader tests passed: iRC-only officers, test overrides, fresh/session/offline checks, deterministic election and profile wire round trip.")

-- Large-guild regression: one roster read per member, constant connection
-- lookups, and no persistent cache hiding changes from subsequent passes.
assert(loadfile("iRC_RaceLockedSync.lua"))("iRC", private)
roster, db.members, db.compatibilityMembers, db.guildFoundRoster = {}, {}, {}, {}
for index = 1, 1000 do
    local name = index == 1 and "Crasjin" or string.format("Member%04d", index)
    local key = iRC:NormalizeName(name)
    roster[index] = { name = name, rank = 5, online = index % 2 == 0 or index == 1 }
    if index % 3 == 0 then db.members[key] = { name = name, race = "Troll", lastSeen = now } end
    if index % 5 == 0 then db.compatibilityMembers[key] = { presence = { source = "RaceLockedForkEU", lastSeen = now } } end
    if index % 7 == 0 then db.guildFoundRoster[key] = { source = "RaceLocked", lastSeen = now, verified = true, clean = true } end
end
local getConnection, getRoster = iRC.GetConnection, GetGuildRosterInfo
local connectionReads, rosterReads = 0, 0
function iRC:GetConnection() connectionReads = connectionReads + 1; return getConnection(self) end
function GetGuildRosterInfo(index) rosterReads = rosterReads + 1; return getRoster(index) end
local rosterRows = iRC:GetGuildRosterRows()
assert(#rosterRows == 1000 and rosterReads == 1000 and connectionReads <= 3, "large roster must use constant connection lookups")
db.compatibilityMembers.member0002 = { presence = { source = "RaceLockedForkEU", lastSeen = now } }
local refreshed = iRC:GetGuildRosterRows()
assert(refreshed[2].verification.state == "compatible", "next pass sees newly received presence immediately")
print("Large-guild test passed: 1000 members, " .. (connectionReads / 2) .. " connection lookup(s) per pass.")

-- Test the real visible-row renderer with lightweight WoW frame mocks.
unpack = table.unpack
local methods = {}
local function widget() return setmetatable({}, { __index = function(_, key) return methods[key] or function() end end }) end
function methods:CreateFontString() return widget() end
function methods:SetText(value) self.text = value end
function methods:Show() self.shown = true end
function methods:Hide() self.shown = false end
function methods:SetScript(event, callback) self[event] = callback end
function CreateFrame() return widget() end
assert(loadfile("iRC_ConnectionDashboard.lua"))("iRC", private)
local dashboard, offset, shown = iRC.ConnectionDashboard, 0, true
local view = { rows = {}, rowData = {}, content = widget(), scroll = {
    GetVerticalScroll = function() return offset end, GetHeight = function() return 360 end,
}, IsShown = function() return shown end }
dashboard.frame = view
for index = 1, 1000 do view.rowData[index] = { values = { tostring(index), "", "", "", "" } } end
dashboard:RenderVisibleRows()
assert(#view.rows == 7 and view.rows[1].columns[1].text == "1", "only visible rows plus one overscan row are created")
offset = 500 * 60
dashboard:RenderVisibleRows()
assert(#view.rows == 7 and view.rows[1].columns[1].text == "501", "scrolling reuses row frames with the correct data")
offset = 999 * 60
dashboard:RenderVisibleRows()
assert(view.rows[1].columns[1].text == "1000" and not view.rows[2].shown, "last page hides unused pooled rows")
local readsBefore = rosterReads
for _ = 1, 10 do dashboard:RenderVisibleRows() end
assert(rosterReads == readsBefore, "timer/scroll rendering never rebuilds the guild roster")

-- Exercise the full Verification Refresh, not just the renderer in isolation.
date = os.date
view.tab, view.tabs, view.filters, view.filterButtons = "Verification", {}, {}, {}
view.status, view.title, view.subtitle = widget(), widget(), widget()
view.headers, view.summaryCards = {}, {}
for index = 1, 6 do view.headers[index] = widget(); view.headers[index].text = widget() end
for index = 1, 4 do
    view.summaryCards[index] = widget()
    view.summaryCards[index].label, view.summaryCards[index].value = widget(), widget()
end
function view.scroll:SetVerticalScroll(value) offset = value end
local connectionBefore, rowsBefore = connectionReads, rosterReads
offset = 0
dashboard:Refresh()
assert(#view.rowData == 1000 and #view.rows == 7, "full verification refresh retains all data with bounded UI frames")
assert(rosterReads - rowsBefore == 1000 and connectionReads - connectionBefore <= 5, "full refresh avoids per-row connection lookups")
assert(view.rows[1].OnClick == view.rowData[1].onClick, "pooled row receives current click handler")
view.filters.Verification = "attention"
dashboard:Refresh()
assert(#view.rowData > 0 and #view.rowData < 1000, "filters still work with pooled rows")
local timerBefore, previousRosterReads = view.rows[1].columns[4].text, rosterReads
now = now + 60
dashboard:RenderVisibleRows()
assert(view.rows[1].columns[4].text ~= timerBefore and rosterReads == previousRosterReads, "attention timer advances without rebuilding the roster")

local callbacks, refreshes = {}, 0
C_Timer = { After = function(_, callback) callbacks[#callbacks + 1] = callback end }
function dashboard:Refresh() self.pendingRefresh = nil; refreshes = refreshes + 1 end
for _ = 1, 100 do dashboard:RefreshIfShown() end
assert(#callbacks == 1)
callbacks[1]()
assert(refreshes == 1, "100 rapid updates produce one dashboard redraw")
dashboard:RefreshIfShown(); dashboard:Refresh(); callbacks[2]()
assert(refreshes == 2, "manual refresh cancels the pending redraw")
dashboard:RefreshIfShown(); shown = false; callbacks[3]()
assert(refreshes == 2, "hidden windows skip queued work")
print("Dashboard performance tests passed: bounded row pool, scrolling, timer isolation and redraw coalescing.")
