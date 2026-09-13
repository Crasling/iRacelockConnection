local _, private = ...
local iRC = private and private.iRC
if not iRC then return end

local Announcements = {}
iRC.GuildAnnouncements = Announcements
local ICON_PREFIX = "iRCIconV1"
local ICON_WIRE_VERSION = "1"
local PUBLIC_ICON_TTL = 300
local PUBLIC_REQUEST_COOLDOWN = 300
local publicIcons, pendingRequests, queuedRequests, queuedNames = {}, {}, {}, {}
local lastReplyAt = {}
local lastPublicRequestAt, requestTimerPending = 0, false

Announcements.Icons = {
    death = "Interface\\AddOns\\iRC\\Images\\Icons\\Skull_Icon.blp",
    level60 = "Interface\\AddOns\\iRC\\Images\\Icons\\Sixty_Icon.blp",
    selfFound = "Interface\\AddOns\\iRC\\Images\\Icons\\SF_Icon.blp",
    guildFound = "Interface\\AddOns\\iRC\\Images\\Icons\\GF_Icon.blp",
    guildMaster = "Interface\\AddOns\\iRC\\Images\\Icons\\GM_Icon.blp",
    officer1 = "Interface\\AddOns\\iRC\\Images\\Icons\\Officer1_Icon.blp",
    violation = "Interface\\AddOns\\iRC\\Images\\Icons\\X_Icon.blp",
}

local rosterReference, rosterGuildKey, rosterRanks = nil, nil, {}

local function publicNameKey(name)
    if type(name) ~= "string" or name == "" then return nil end
    local character, realm = name:match("^([^-]+)%-(.+)$")
    if not character then character, realm = name, GetNormalizedRealmName and GetNormalizedRealmName() or GetRealmName and GetRealmName() end
    realm = tostring(realm or ""):gsub("%s+", "")
    if character == "" or realm == "" then return nil end
    return (character .. "-" .. realm):lower()
end

local function getRosterRank(name)
    local guildKey = iRC:GetGuildKey()
    if not guildKey or not iRC.GetGuildRosterSnapshot then return nil end
    local roster = iRC:GetGuildRosterSnapshot()
    if roster ~= rosterReference or guildKey ~= rosterGuildKey then
        rosterReference, rosterGuildKey, rosterRanks = roster, guildKey, {}
        for _, member in ipairs(roster) do
            local memberKey = publicNameKey(member.name)
            if memberKey then rosterRanks[memberKey] = member.rankIndex end
        end
    end
    return rosterRanks[publicNameKey(name)]
end

function Announcements:GetUnlockedIcons(name)
    local unlocked = {}
    if type(name) ~= "string" or name == "" then return unlocked end
    local rank = getRosterRank(name)
    if rank == nil then return unlocked end
    local key = iRC:NormalizeName(name)
    if rank == 0 then
        unlocked.guildMaster = true
    else
        local connection = iRC:GetConnection()
        if connection and connection.active == true then
            for permission, defaultRank in pairs(iRC.DefaultRankPermissions) do
                local delegatedRank = tonumber(connection.rankPermissions and connection.rankPermissions[permission]) or defaultRank
                if rank <= delegatedRank then
                    unlocked.officer1 = true
                    break
                end
            end
        end
    end
    local connection = iRC:GetConnection()
    local isSelf = key == iRC:NormalizeName(iRC:GetPlayerName())
    local profile = isSelf and iRC:GetLocalProfile() or connection and connection.members and connection.members[key]
    if isSelf and profile and profile.selfFound == true and profile.hideChatIcon ~= true then unlocked.selfFound = true end
    if not connection or connection.active ~= true then
        return profile and profile.hideChatIcon == true and {} or unlocked
    end
    local fresh = profile and (isSelf or time() - (tonumber(profile.lastSeen) or 0) <= 180)
    local status = iRC.RaceLockedSync and iRC.RaceLockedSync:GetStatus(name, connection)
    local rules = connection.rules or iRC.DefaultConnectionRules
    local mode = iRC:GetProgressionMode(rules)
    local guildFoundVerified = status and status.verified == true
    if status and status.clean == false then unlocked.violation = true end
    if fresh and profile.currentGroupRuleViolation then unlocked.violation = true end
    if fresh and profile.race and iRC:GetGuildMemberRaceCheck(profile.race, connection).mismatch then
        unlocked.violation = true
    end
    if fresh and not iRC:IsGuildBankException(name, connection) then
        local level = tonumber(profile.level) or 0
        if (mode == "SELF_FOUND" and level < 60 and profile.selfFound ~= true)
            or (mode == "SELF_FOUND" and level >= 60 and iRC:GetMaxLevelProgressionMode(rules) == "GUILD_FOUND" and not guildFoundVerified)
            or (mode == "GUILD_FOUND" and not guildFoundVerified)
            or (mode == "SELF_FOUND_OR_GUILD_FOUND" and profile.selfFound ~= true and not guildFoundVerified) then
            unlocked.violation = true
        end
    end
    -- A rule-violation badge is not an optional earned icon.
    if profile and profile.hideChatIcon == true then return unlocked.violation and { violation = true } or {} end
    if profile and profile.selfFound == true and fresh then
        unlocked.selfFound = true
    end
    if guildFoundVerified then unlocked.guildFound = true end
    return unlocked
end

function Announcements:SetHidden(hidden)
    iRCCharDB = iRCCharDB or {}
    iRCCharDB.hideChatIcon = hidden and true or false
    if iRC:IsGuildConnectionActive() then iRC:SendHello() end
end

function Announcements:GetDefaultChatIcon(name)
    local unlocked = self:GetUnlockedIcons(name)
    if unlocked.violation then return self.Icons.violation, "violation" end
    if unlocked.guildMaster then return self.Icons.guildMaster, "guildMaster" end
    if unlocked.officer1 then return self.Icons.officer1, "officer1" end
    if unlocked.selfFound then return self.Icons.selfFound, "selfFound" end
    if unlocked.guildFound then return self.Icons.guildFound, "guildFound" end
end

local function sendIconWire(message, target)
    return iRC:SendAddonTraffic(ICON_PREFIX, message, "WHISPER", target)
end

local function processPublicRequests()
    requestTimerPending = false
    local request = table.remove(queuedRequests, 1)
    if not request then return end
    queuedNames[request.key] = nil
    local now = GetTime and GetTime() or 0
    local delay = math.max(0, 2 - (now - lastPublicRequestAt))
    if delay > 0 and C_Timer and C_Timer.After then
        table.insert(queuedRequests, 1, request)
        queuedNames[request.key] = true
        requestTimerPending = true
        C_Timer.After(delay, processPublicRequests)
        return
    end
    lastPublicRequestAt = now
    if pendingRequests[request.key] and pendingRequests[request.key] > time() then
        sendIconWire("ICON_REQ\t" .. ICON_WIRE_VERSION, request.name)
    end
    if #queuedRequests > 0 and C_Timer and C_Timer.After then
        requestTimerPending = true
        C_Timer.After(2, processPublicRequests)
    end
end

local function requestPublicIcon(name)
    local key = publicNameKey(name)
    if not key or queuedNames[key] or #queuedRequests >= 40 then return end
    local now = time()
    if not Announcements.lastPublicCachePrune or now - Announcements.lastPublicCachePrune >= 60 then
        Announcements.lastPublicCachePrune = now
        for cachedKey, entry in pairs(publicIcons) do
            if entry.expiresAt <= now then publicIcons[cachedKey] = nil end
        end
        for pendingKey, expiresAt in pairs(pendingRequests) do
            if expiresAt <= now then pendingRequests[pendingKey] = nil end
        end
        for replyKey, repliedAt in pairs(lastReplyAt or {}) do
            if now - repliedAt > 600 then lastReplyAt[replyKey] = nil end
        end
    end
    if pendingRequests[key] and pendingRequests[key] > now then return end
    if publicIcons[key] and publicIcons[key].expiresAt > now then return end
    pendingRequests[key] = now + PUBLIC_REQUEST_COOLDOWN
    queuedNames[key] = true
    queuedRequests[#queuedRequests + 1] = { key = key, name = name }
    if not requestTimerPending then
        requestTimerPending = true
        if C_Timer and C_Timer.After then C_Timer.After(0.1, processPublicRequests) else processPublicRequests() end
    end
end

function Announcements:GetPublicChatIcon(name)
    local key = publicNameKey(name)
    local entry = key and publicIcons[key]
    if entry and entry.expiresAt > time() then
        return self.Icons[entry.kind], entry.kind
    end
    requestPublicIcon(name)
end

function Announcements:ReceiveIconWire(message, distribution, sender)
    if distribution ~= "WHISPER" or type(message) ~= "string" or not sender then return end
    local kind, version, value = strsplit("\t", message)
    if version ~= ICON_WIRE_VERSION then return end
    local key = publicNameKey(sender)
    if not key or key == publicNameKey(iRC:GetPlayerName()) then return end
    if kind == "ICON_REQ" then
        local now = time()
        if now - (lastReplyAt[key] or 0) < 10 then return end
        lastReplyAt[key] = now
        local _, ownKind = self:GetDefaultChatIcon(iRC:GetPlayerName())
        sendIconWire("ICON_STATUS\t" .. ICON_WIRE_VERSION .. "\t" .. (ownKind or "none"), sender)
    elseif kind == "ICON_STATUS" and pendingRequests[key] and pendingRequests[key] > time() then
        if value ~= "none" and not self.Icons[value] then return end
        pendingRequests[key] = nil
        publicIcons[key] = { kind = value, expiresAt = time() + PUBLIC_ICON_TTL }
    end
end

local ICON_HELP = {
    death = { "CHAT_ICON_DEATH_TITLE", "CHAT_ICON_DEATH_DESC" },
    level60 = { "CHAT_ICON_LEVEL60_TITLE", "CHAT_ICON_LEVEL60_DESC" },
    selfFound = { "CHAT_ICON_SELF_FOUND_TITLE", "CHAT_ICON_SELF_FOUND_DESC" },
    guildFound = { "CHAT_ICON_GUILD_FOUND_TITLE", "CHAT_ICON_GUILD_FOUND_DESC" },
    guildMaster = { "CHAT_ICON_GUILD_MASTER_TITLE", "CHAT_ICON_GUILD_MASTER_DESC" },
    officer1 = { "CHAT_ICON_OFFICER_TITLE", "CHAT_ICON_OFFICER_DESC" },
    violation = { "CHAT_ICON_VIOLATION_TITLE", "CHAT_ICON_VIOLATION_DESC" },
}

local function iconLink(kind, icon, size)
    return string.format("|Haddon:iRCIcon:%s|h|T%s:%d:%d|t|h", kind, icon, size, size)
end

local hookedChatFrames = {}
local activeTooltipChatFrame
local tooltipMouseWasEnabled
local function hideChatIconTooltip(chatFrame)
    if activeTooltipChatFrame ~= chatFrame then return end
    activeTooltipChatFrame = nil
    if GameTooltip and GameTooltip.iRCChatIconOwner == chatFrame then
        GameTooltip.iRCChatIconOwner = nil
        GameTooltip:Hide()
        if tooltipMouseWasEnabled ~= nil then GameTooltip:EnableMouse(tooltipMouseWasEnabled) end
    end
    tooltipMouseWasEnabled = nil
end
local function hookChatTooltip(chatFrame)
    if not chatFrame or not chatFrame.HookScript or hookedChatFrames[chatFrame] then return end
    hookedChatFrames[chatFrame] = true
    chatFrame:HookScript("OnHyperlinkEnter", function(self, link)
        local kind = type(link) == "string" and link:match("^addon:iRCIcon:(%w+)$")
        local help = kind and ICON_HELP[kind]
        if not help or not GameTooltip then
            hideChatIconTooltip(self)
            return
        end
        activeTooltipChatFrame = self
        GameTooltip.iRCChatIconOwner = self
        if tooltipMouseWasEnabled == nil and GameTooltip.IsMouseEnabled then
            tooltipMouseWasEnabled = GameTooltip:IsMouseEnabled()
        end
        GameTooltip:EnableMouse(false)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:SetText(iRC:Text(help[1]), 1, 0.72, 0.22)
        GameTooltip:AddLine(iRC:Text(help[2]), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    chatFrame:HookScript("OnHyperlinkLeave", hideChatIconTooltip)
end

local function canAnnounce(ruleKey)
    if not SendChatMessage or not iRC:IsGuildConnectionActive() then return false end
    local rules = iRC:GetConnectionRules()
    return rules and rules[ruleKey] ~= true
end

function Announcements:AnnounceDeath()
    if not canAnnounce("disableGuildDeathMessage") then return false end
    iRCCharDB = iRCCharDB or {}
    local now = time()
    if now - (tonumber(iRCCharDB.lastGuildDeathAnnouncementAt) or 0) < 30 then return false end
    iRCCharDB.lastGuildDeathAnnouncementAt = now
    return pcall(SendChatMessage, iRC:Text("CHAT_ANNOUNCE_DEATH"), "GUILD")
end

function Announcements:AnnounceLevel60(level)
    if tonumber(level) ~= 60 or not canAnnounce("disableGuildLevel60Message") then return false end
    iRCCharDB = iRCCharDB or {}
    if iRCCharDB.guildLevel60AnnouncementSent then return false end
    local sent = pcall(SendChatMessage, iRC:Text("CHAT_ANNOUNCE_LEVEL60"), "GUILD")
    if sent then iRCCharDB.guildLevel60AnnouncementSent = true end
    return sent
end

function Announcements:SendTest(kind)
    if not iRC:IsTestAdmin() or not iRC:IsGuildConnectionActive() or not SendChatMessage then return false end
    local message = kind == "death" and iRC:Text("CHAT_ANNOUNCE_TEST_DEATH") or kind == "level60" and iRC:Text("CHAT_ANNOUNCE_TEST_LEVEL60")
    if not message then return false end
    return pcall(SendChatMessage, message, "GUILD")
end

local function addGuildAnnouncementIcon(chatFrame, _, message, author, ...)
    if type(message) ~= "string" or not author or author == "" then return false end
    local icon, iconKind
    if message == iRC:Text("CHAT_ANNOUNCE_DEATH") or message == iRC:Text("CHAT_ANNOUNCE_TEST_DEATH") then icon, iconKind = Announcements.Icons.death, "death"
    elseif message == iRC:Text("CHAT_ANNOUNCE_LEVEL60") or message == iRC:Text("CHAT_ANNOUNCE_TEST_LEVEL60") then icon, iconKind = Announcements.Icons.level60, "level60" end
    local size = 16
    if chatFrame and chatFrame.GetFont then
        local _, fontSize = chatFrame:GetFont()
        size = math.max(12, math.floor((tonumber(fontSize) or 14) * 1.2))
    end
    if icon then message = message .. " " .. iconLink(iconKind, icon, size) end
    local badge, badgeKind = Announcements:GetDefaultChatIcon(author)
    if not badge and getRosterRank(author) == nil then
        badge, badgeKind = Announcements:GetPublicChatIcon(author)
    end
    if badge then message = iconLink(badgeKind, badge, size) .. " " .. message end
    if not icon and not badge then return false end
    hookChatTooltip(chatFrame)
    return false, message, author, ...
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(ICON_PREFIX)
        elseif RegisterAddonMessagePrefix then
            RegisterAddonMessagePrefix(ICON_PREFIX)
        end
        if ChatFrame_AddMessageEventFilter then
            for _, chatEvent in ipairs({
                "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
                "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
                "CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
            }) do
                ChatFrame_AddMessageEventFilter(chatEvent, addGuildAnnouncementIcon)
            end
        end
    elseif event == "PLAYER_DEAD" then
        Announcements:AnnounceDeath()
    elseif event == "PLAYER_LEVEL_UP" then
        Announcements:AnnounceLevel60(...)
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, message, distribution, sender = ...
        if prefix == ICON_PREFIX then Announcements:ReceiveIconWire(message, distribution, sender) end
    end
end)
