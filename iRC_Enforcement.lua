local _, private = ...
local iRC = private and private.iRC
if not iRC then return end

local Enforcement = {}
iRC.Enforcement = Enforcement

local LANGUAGE_BY_RACE = {
    Human = 7, Orc = 1, Dwarf = 6, NightElf = 2, Scourge = 33, Tauren = 3, Gnome = 13, Troll = 14,
    BloodElf = 10, Draenei = 35,
}

local languageHooksInstalled = false
local applyingLanguage = false
local groupLeaving = false
local groupSafety = { sameRace = false, guildOnly = false }
local pendingUnsafeGroupReason
local pendingGroupViolation
local pendingGroupViolationKey
local pendingGroupLeaveConfirmation
local observedGroupRestrictions
local initialGroupProtectionPending = true
local restrictedTradeCancelled = false
local lastMailRestrictionReason
local originalSendMail, originalTakeInboxItem, originalTakeInboxMoney, originalAutoLootMailItem
local originalAcceptTrade
local CONJURED_ITEMS = { [5350]=true,[2288]=true,[2136]=true,[3772]=true,[8077]=true,[8078]=true,[8079]=true,[5349]=true,[1113]=true,[1114]=true,[1487]=true,[8075]=true,[8076]=true,[22895]=true }
local HEALTHSTONE_ITEMS = { [5512]=true,[19004]=true,[19005]=true,[5511]=true,[19006]=true,[19007]=true,[5509]=true,[19008]=true,[19009]=true,[5510]=true,[19010]=true,[19011]=true,[9421]=true,[19012]=true,[19013]=true }
local QUEST_ITEMS = { [7740]=true,[7741]=true }
local LOCKBOX_ITEMS = { [16882]=true,[16883]=true,[16884]=true,[16885]=true,[4632]=true,[4633]=true,[4634]=true,[4636]=true,[4637]=true,[4638]=true,[5758]=true,[5759]=true,[5760]=true,[6354]=true,[6355]=true,[6712]=true,[12033]=true,[13875]=true,[13918]=true }

local warningFrame = CreateFrame("Frame", "iRCSelfFoundWarning", UIParent)
warningFrame:SetSize(620, 32)
warningFrame:SetPoint("TOP", UIParent, "TOP", 0, -170)
warningFrame.text = warningFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
warningFrame.text:SetAllPoints(warningFrame)
warningFrame.text:SetJustifyH("CENTER")
warningFrame.text:SetTextColor(1, 0.10, 0.10)
warningFrame:Hide()

local groupWarningFrame = CreateFrame("Frame", "iRCUnsafeGroupWarning", UIParent)
groupWarningFrame:SetSize(760, 42)
groupWarningFrame:SetPoint("TOP", warningFrame, "BOTTOM", 0, -8)
groupWarningFrame.text = groupWarningFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
groupWarningFrame.text:SetAllPoints(groupWarningFrame)
groupWarningFrame.text:SetJustifyH("CENTER")
groupWarningFrame.text:SetTextColor(1, 0.10, 0.10)
groupWarningFrame:Hide()

local function isRuleEnabled(key)
    local rules = iRC:GetConnectionRules()
    if (key == "nativeTongueOnly" or key == "sameRaceGroupsOnly" or key == "allowLevel60MixedRaceGroups")
        and rules.raceLock ~= true then return false end
    return iRC:IsGuildConnectionActive() and rules[key] == true
end

local function isGuildFoundEconomyActive()
    local progressionMode = iRC:GetProgressionMode()
    local eligible = progressionMode == "SELF_FOUND_OR_GUILD_FOUND" or progressionMode == "GUILD_FOUND"
        or (UnitLevel("player") or 0) >= 60 or iRC:IsGuildBankException(iRC:GetPlayerName())
    return iRC:IsGuildFoundRequired() and eligible and not iRC:GetSelfFoundState()
end

local function getNativeLanguage()
    local _, raceFile, raceId = UnitRace("player")
    local languageId = LANGUAGE_BY_RACE[raceFile]
    if not languageId or not GetNumLanguages or not GetLanguageByIndex then return nil, nil end
    for index = 1, GetNumLanguages() do
        local languageName, knownLanguageId = GetLanguageByIndex(index)
        if knownLanguageId == languageId then return languageName, languageId end
    end
    return nil, nil
end

function Enforcement:ApplyNativeLanguage()
    if applyingLanguage or not isRuleEnabled("nativeTongueOnly") or not NUM_CHAT_WINDOWS then return end
    local languageName, languageId = getNativeLanguage()
    if not languageName then return end
    applyingLanguage = true
    for index = 1, NUM_CHAT_WINDOWS do
        local editBox = _G["ChatFrame" .. index .. "EditBox"]
        if editBox then
            editBox.language = languageName
            editBox.languageID = languageId
        end
    end
    applyingLanguage = false
end

local function scheduleLanguageApply()
    if C_Timer and C_Timer.After then C_Timer.After(0, function() Enforcement:ApplyNativeLanguage() end) else Enforcement:ApplyNativeLanguage() end
end

local function installLanguageHooks()
    if languageHooksInstalled or type(hooksecurefunc) ~= "function" then return end
    for _, functionName in ipairs({ "ChatEdit_OnLanguageChanged", "ChatFrame_ChatEdit_OnLanguageChanged" }) do
        if type(_G[functionName]) == "function" then hooksecurefunc(functionName, scheduleLanguageApply) end
    end
    languageHooksInstalled = true
end

function Enforcement:UpdateSelfFoundWarning()
    local rules = iRC:GetConnectionRules()
    local level60OrAbove = (UnitLevel("player") or 0) >= 60
    local exemptAtLevel60 = level60OrAbove and (rules.level60GuildFound or rules.allowLevel60WithoutSelfFound)
    local guildBankException = iRC:IsGuildBankException(iRC:GetPlayerName())
    local violation = iRC:IsGuildConnectionActive() and iRC:GetProgressionMode(rules) == "SELF_FOUND"
        and not exemptAtLevel60 and not guildBankException and not iRC:GetSelfFoundState()
    warningFrame:SetShown(violation)
    if violation then
        warningFrame.text:SetText(iRC:Text("SELF_FOUND_REQUIRED_WARNING"))
    end
end

function Enforcement:ShowGuildFoundRestriction(message)
    iRC:Print(iRC.Colors.Red .. iRC:Text("GUILD_FOUND_RESTRICTION", message) .. iRC.Colors.Reset)
end

local function getTradePartnerName()
    local partnerName = GetUnitName and (GetUnitName("NPC", true) or GetUnitName("npc", true))
    if not partnerName and TradeFrameRecipientNameText and TradeFrameRecipientNameText.GetText then
        partnerName = TradeFrameRecipientNameText:GetText()
    end
    return partnerName
end

local function itemIdFromLink(link)
    return type(link) == "string" and tonumber(link:match("item:(%d+)")) or nil
end

local function externalTradeExceptionAllowed(partnerName)
    local rules = iRC:GetConnectionRules()
    if not rules.guildFoundTradeExceptions then return false, nil end
    local settings = iRC:GetGuildFoundTradeExceptionSettings()
    local selectedItems = settings.items or {}
    if (GetPlayerTradeMoney and GetPlayerTradeMoney() or 0) > 0
        or (GetTargetTradeMoney and GetTargetTradeMoney() or 0) > 0 then return false, nil end
    local playerItems, targetItems, itemCount = {}, {}, 0
    local serviceSlot = TRADE_ENCHANT_SLOT or MAX_TRADE_ITEMS or 7
    local transferableSlots = math.max(1, serviceSlot - 1)
    for slot = 1, transferableSlots do
        local playerId = itemIdFromLink(GetTradePlayerItemLink and GetTradePlayerItemLink(slot))
        local targetId = itemIdFromLink(GetTradeTargetItemLink and GetTradeTargetItemLink(slot))
        if playerId then playerItems[#playerItems + 1], itemCount = playerId, itemCount + 1 end
        if targetId then targetItems[#targetItems + 1], itemCount = targetId, itemCount + 1 end
    end
    local playerServiceId = itemIdFromLink(GetTradePlayerItemLink and GetTradePlayerItemLink(serviceSlot))
    local targetServiceId = itemIdFromLink(GetTradeTargetItemLink and GetTradeTargetItemLink(serviceSlot))
    if playerServiceId then itemCount = itemCount + 1 end
    if targetServiceId then itemCount = itemCount + 1 end
    if itemCount == 0 then return false, nil end
    local _, playerClass = UnitClass("player")
    local usedCategories, usedCategoryLookup = {}, {}
    local function useCategory(label)
        if not usedCategoryLookup[label] then
            usedCategoryLookup[label] = true
            usedCategories[#usedCategories + 1] = label
        end
    end
    local function allowedTransferItem(itemId)
        if settings.conjured and CONJURED_ITEMS[itemId] and selectedItems.conjured and selectedItems.conjured[itemId] then
            useCategory("Conjured Food / Water"); return true
        end
        if settings.healthstones and HEALTHSTONE_ITEMS[itemId] and selectedItems.healthstones and selectedItems.healthstones[itemId] then
            useCategory("Healthstones"); return true
        end
        if settings.questItems and QUEST_ITEMS[itemId] and selectedItems.questItems and selectedItems.questItems[itemId] then
            useCategory("Quest Items"); return true
        end
        return false
    end
    for _, itemId in ipairs(playerItems) do if not allowedTransferItem(itemId) then return false, nil end end
    for _, itemId in ipairs(targetItems) do if not allowedTransferItem(itemId) then return false, nil end end
    local selectedLockboxes = selectedItems.lockboxes or {}
    if playerServiceId and not (settings.lockpickIncoming and LOCKBOX_ITEMS[playerServiceId]
        and selectedLockboxes[playerServiceId]) then return false, nil end
    if playerServiceId then useCategory("Lockpicking (Incoming)") end
    if targetServiceId and not (settings.lockpickOutgoing and playerClass == "ROGUE"
        and LOCKBOX_ITEMS[targetServiceId] and selectedLockboxes[targetServiceId]) then return false, nil end
    if targetServiceId then useCategory("Lockpicking (Outgoing)") end
    return true, table.concat(usedCategories, ", ")
end

local function getMailRecipient()
    local field = _G.SendMailNameEditBox
        or (_G.MailFrame and _G.MailFrame.SendMailFrame and _G.MailFrame.SendMailFrame.RecipientEditBox)
    if not field or not field.GetText then return nil end
    local recipient = field:GetText()
    if type(recipient) ~= "string" then return nil end
    recipient = recipient:gsub("^%s+", ""):gsub("%s+$", "")
    return recipient ~= "" and recipient or nil
end

local function getSendMailButton()
    return _G.SendMailMailButton
        or (_G.MailFrame and _G.MailFrame.SendMailFrame and _G.MailFrame.SendMailFrame.SendMailButton)
end

function Enforcement:CheckTradeRestriction()
    if not isGuildFoundEconomyActive() or restrictedTradeCancelled then return end
    local partnerName = getTradePartnerName()
    if not partnerName then return end
    local allowed, reason = iRC:GetGuildFoundTradeStatus(partnerName)
    if allowed then return end
    if iRC:GetConnectionRules().guildFoundTradeExceptions and not iRC:IsGuildMemberName(partnerName) then
        -- Keep the trade window open so approved exception items can be
        -- inspected. The protected accept path performs the final check.
        return
    end

    restrictedTradeCancelled = true
    iRC:RecordGuildFoundAudit("TRADE_BLOCKED", partnerName)
    self:ShowGuildFoundRestriction(iRC:Text("GUILD_FOUND_TRADE_CANCELLED", partnerName, reason or iRC:Text("GUILD_FOUND_TRADE_REASON")))
    if CancelTrade then CancelTrade() end
end

function Enforcement:InstallTradeAPIGuard()
    if originalAcceptTrade or type(_G.AcceptTrade) ~= "function" then return end
    originalAcceptTrade = _G.AcceptTrade
    _G.AcceptTrade = function(...)
        if isGuildFoundEconomyActive() then
            local partnerName = getTradePartnerName()
            local allowed, reason = partnerName and iRC:GetGuildFoundTradeStatus(partnerName)
            local exceptionNote
            if not allowed and partnerName and not iRC:IsGuildMemberName(partnerName)
                then
                local exceptionAllowed
                exceptionAllowed, exceptionNote = externalTradeExceptionAllowed(partnerName)
                if exceptionAllowed then allowed, reason = true, nil end
            end
            if not allowed then
                iRC:RecordGuildFoundAudit("TRADE_BLOCKED", partnerName)
                Enforcement:ShowGuildFoundRestriction(iRC:Text("GUILD_FOUND_TRADE_BLOCKED", partnerName or iRC:Text("GUILD_FOUND_UNKNOWN_PLAYER"), reason or iRC:Text("GUILD_FOUND_TRADE_REASON")))
                return
            end
            if exceptionNote then
                iRC:RecordGuildFoundAudit("TRADE_EXCEPTION_APPROVED",
                    (partnerName or iRC:Text("GUILD_FOUND_UNKNOWN_PLAYER")) .. " - " .. exceptionNote)
            end
        end
        return originalAcceptTrade(...)
    end
end

function Enforcement:UpdateMailRestriction()
    local button = getSendMailButton()
    if not button or not button.SetEnabled then return end
    if not isGuildFoundEconomyActive() then
        if button.iRCMailRestricted then button:SetEnabled(true) end
        button.iRCMailRestricted = nil
        lastMailRestrictionReason = nil
        return
    end

    local recipient = getMailRecipient()
    if not recipient then
        if button.iRCMailRestricted then button:SetEnabled(true) end
        button.iRCMailRestricted = nil
        lastMailRestrictionReason = nil
        return
    end
    local allowed, reason = iRC:GetGuildFoundTradeStatus(recipient, true)
    if allowed then
        if button.iRCMailRestricted then button:SetEnabled(true) end
        button.iRCMailRestricted = nil
    else
        button.iRCMailRestricted = true
        button:SetEnabled(false)
    end
    if not allowed and reason ~= lastMailRestrictionReason then
        lastMailRestrictionReason = reason
        iRC:RecordGuildFoundAudit("MAIL_BLOCKED", recipient)
        self:ShowGuildFoundRestriction(iRC:Text("GUILD_FOUND_MAIL_BLOCKED", recipient, reason or iRC:Text("GUILD_FOUND_MAIL_REASON")))
    elseif allowed then
        lastMailRestrictionReason = nil
    end
end

function Enforcement:InstallMailRecipientGuard()
    local field = _G.SendMailNameEditBox
        or (_G.MailFrame and _G.MailFrame.SendMailFrame and _G.MailFrame.SendMailFrame.RecipientEditBox)
    if not field or field.iRCMailGuardHooked or not field.HookScript then return end
    field.iRCMailGuardHooked = true
    field:HookScript("OnTextChanged", function()
        Enforcement:UpdateMailRestriction()
    end)
end

local function getInboxRestriction(index)
    if not isGuildFoundEconomyActive() or not GetInboxHeaderInfo then return false end
    local packageIcon, _, sender, _, money, codAmount, _, hasItem, _, _, _, canReply, isGameMaster = GetInboxHeaderInfo(index)
    if not sender or sender == "" then return false end

    -- Auction House proceeds and purchases are external economy even though
    -- their sender is a system entity rather than a player character.
    if packageIcon == 134939 then return true, sender end
    if GetInboxInvoiceInfo then
        local invoiceType = GetInboxInvoiceInfo(index)
        if invoiceType then return true, sender end
    end

    local allowed = iRC:GetGuildFoundTradeStatus(sender, true)
    if allowed then return false end
    local containsValue = (tonumber(money) or 0) > 0 or (tonumber(codAmount) or 0) > 0 or hasItem
    if not containsValue then return false end

    -- Quest rewards and other game-generated deliveries remain usable. They
    -- cannot be replied to; ordinary player mail can.
    if canReply == false or isGameMaster then return false end
    return true, sender
end

function Enforcement:IsInboxMailRestricted(index)
    return getInboxRestriction(index)
end

function Enforcement:ShowInboxRestriction(index, sender)
    iRC:RecordGuildFoundAudit("INBOX_BLOCKED", sender)
    self:ShowGuildFoundRestriction(iRC:Text("GUILD_FOUND_INBOX_BLOCKED", sender and iRC:FormatPlayerName(sender) or iRC:Text("GUILD_FOUND_UNKNOWN_SENDER")))
end

function Enforcement:InstallMailAPIGuards()
    if not originalSendMail and type(_G.SendMail) == "function" then
        originalSendMail = _G.SendMail
        _G.SendMail = function(recipient, ...)
            if isGuildFoundEconomyActive() then
                local allowed, reason = iRC:GetGuildFoundTradeStatus(recipient, true)
                if not allowed then
                    iRC:RecordGuildFoundAudit("MAIL_BLOCKED", recipient)
                    Enforcement:ShowGuildFoundRestriction(iRC:Text("GUILD_FOUND_MAIL_BLOCKED", recipient or "", reason or iRC:Text("GUILD_FOUND_MAIL_REASON")))
                    return
                end
            end
            return originalSendMail(recipient, ...)
        end
    end
    if not originalTakeInboxItem and type(_G.TakeInboxItem) == "function" then
        originalTakeInboxItem = _G.TakeInboxItem
        _G.TakeInboxItem = function(index, ...)
            local blocked, sender = getInboxRestriction(index)
            if blocked then Enforcement:ShowInboxRestriction(index, sender); return end
            return originalTakeInboxItem(index, ...)
        end
    end
    if not originalTakeInboxMoney and type(_G.TakeInboxMoney) == "function" then
        originalTakeInboxMoney = _G.TakeInboxMoney
        _G.TakeInboxMoney = function(index, ...)
            local blocked, sender = getInboxRestriction(index)
            if blocked then Enforcement:ShowInboxRestriction(index, sender); return end
            return originalTakeInboxMoney(index, ...)
        end
    end
    if not originalAutoLootMailItem and type(_G.AutoLootMailItem) == "function" then
        originalAutoLootMailItem = _G.AutoLootMailItem
        _G.AutoLootMailItem = function(index, ...)
            local blocked, sender = getInboxRestriction(index)
            if blocked then Enforcement:ShowInboxRestriction(index, sender); return end
            return originalAutoLootMailItem(index, ...)
        end
    end
end

function Enforcement:CloseRestrictedAuctionHouse()
    if not isGuildFoundEconomyActive() then return end
    iRC:RecordGuildFoundAudit("AUCTION_HOUSE_BLOCKED", "")
    self:ShowGuildFoundRestriction(iRC:Text("GUILD_FOUND_AUCTION_HOUSE_CLOSED"))
    local closeAuctionHouse = function()
        if not isGuildFoundEconomyActive() then return end
        if CloseAuctionHouse then
            CloseAuctionHouse()
        elseif AuctionHouseFrame and AuctionHouseFrame:IsShown() then
            AuctionHouseFrame:Hide()
        elseif AuctionFrame and AuctionFrame:IsShown() then
            AuctionFrame:Hide()
        end
    end
    if C_Timer and C_Timer.After then C_Timer.After(0.1, closeAuctionHouse) else closeAuctionHouse() end
end

local function canSafelyLeaveGroup()
    if InCombatLockdown and InCombatLockdown() then return false end
    if UnitAffectingCombat and UnitAffectingCombat("player") then return false end
    if IsInInstance then
        local inInstance = IsInInstance()
        if inInstance then return false end
    end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return false end
    if UnitOnTaxi and UnitOnTaxi("player") then return false end
    return true
end

local function clearUnsafeGroupWarning()
    local wasActive = pendingUnsafeGroupReason ~= nil
    pendingUnsafeGroupReason = nil
    pendingGroupViolationKey = nil
    pendingGroupLeaveConfirmation = nil
    groupWarningFrame:Hide()
    if wasActive and iRC.SendHello then iRC:SendHello() end
end

function Enforcement:IsCurrentGroupViolation()
    return pendingUnsafeGroupReason ~= nil
end

local function reportPendingGroupViolation()
    if not pendingGroupViolation or pendingGroupViolation.reported then return end
    if (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player")) then return end
    if iRC.SendGroupViolation and iRC:SendGroupViolation(pendingGroupViolation) then
        pendingGroupViolation.reported = true
    elseif C_Timer and C_Timer.After then
        C_Timer.After(30, reportPendingGroupViolation)
    end
end

function iRC:MarkGroupViolationReported(violationId)
    if not violationId or violationId == "" then return end
    local connection = self:GetConnection()
    for _, record in ipairs(connection and connection.groupViolations or {}) do
        if record.id == violationId then record.reported = true end
    end
    if pendingGroupViolation and pendingGroupViolation.id == violationId then
        pendingGroupViolation.reported = true
    end
end

local function recordGroupViolation(reason, players)
    local names = {}
    for _, name in ipairs(players or {}) do if name and name ~= "" then names[#names + 1] = name end end
    if #names == 0 then names[1] = iRC:Text("GROUP_VIOLATION_UNKNOWN_PLAYER") end
    table.sort(names)
    local key = reason .. "|" .. table.concat(names, ",")
    if pendingGroupViolationKey == key then reportPendingGroupViolation(); return end
    local instanceName = GetInstanceInfo and GetInstanceInfo() or nil
    if not instanceName or instanceName == "" then instanceName = GetZoneText and GetZoneText() or iRC:Text("GROUP_VIOLATION_UNKNOWN_LOCATION") end
    local record = {
        occurredAt = time(), instanceName = instanceName, players = names,
        reason = reason, reported = false,
    }
    local connection = iRC:GetConnection()
    if connection then
        connection.groupViolations = connection.groupViolations or {}
        connection.groupViolations[#connection.groupViolations + 1] = record
        while #connection.groupViolations > 100 do table.remove(connection.groupViolations, 1) end
    end
    pendingGroupViolation, pendingGroupViolationKey = record, key
    reportPendingGroupViolation()
end

local function leaveCurrentGroup(reason)
    if groupLeaving then return true end
    if not canSafelyLeaveGroup() then return false end
    groupLeaving = true
    local channel = IsInRaid and IsInRaid() and "RAID" or "PARTY"
    if SendChatMessage then SendChatMessage(reason, channel) end
    iRC:Print(iRC.Colors.Red .. iRC:Text("GROUP_AUTO_LEFT_LOCAL", reason) .. iRC.Colors.Reset)
    if C_PartyInfo and C_PartyInfo.LeaveParty then
        C_PartyInfo.LeaveParty()
    elseif LeaveParty then
        LeaveParty()
    end
    clearUnsafeGroupWarning()
    if C_Timer and C_Timer.After then C_Timer.After(1, function() groupLeaving = false end) else groupLeaving = false end
    return true
end

local function handleInvalidGroup(reason, players)
    local confirmationPlayers = {}
    for _, name in ipairs(players or {}) do
        if name and name ~= "" then confirmationPlayers[#confirmationPlayers + 1] = name end
    end
    table.sort(confirmationPlayers)
    local confirmationKey = reason .. "|" .. table.concat(confirmationPlayers, ",")
    local now = time()

    -- Never leave on the first roster reading. Group data can be incomplete
    -- immediately after login, reload, zoning, invites, or roster updates.
    -- The same violation must still exist after the confirmation window.
    if not pendingGroupLeaveConfirmation or pendingGroupLeaveConfirmation.key ~= confirmationKey then
        pendingGroupLeaveConfirmation = { key = confirmationKey, readyAt = now + 5 }
        groupWarningFrame.text:SetText(iRC:Text("GROUP_CONFIRMING_WARNING"))
        groupWarningFrame:Show()
        iRC:Print(iRC.Colors.Red .. iRC:Text("GROUP_CONFIRMING_NOTICE") .. iRC.Colors.Reset)
        if C_Timer and C_Timer.After then
            C_Timer.After(5, function()
                if pendingGroupLeaveConfirmation and pendingGroupLeaveConfirmation.key == confirmationKey then
                    Enforcement:CheckGroup()
                end
            end)
        end
        return
    end
    if now < pendingGroupLeaveConfirmation.readyAt then return end

    -- Record and report only after the second reading confirmed the violation.
    recordGroupViolation(reason, players)
    if leaveCurrentGroup(reason) then return end
    if pendingUnsafeGroupReason ~= reason then
        iRC:Print(iRC.Colors.Red .. iRC:Text("GROUP_UNSAFE_DEFERRED") .. iRC.Colors.Reset)
    end
    local becameActive = pendingUnsafeGroupReason == nil
    pendingUnsafeGroupReason = reason
    groupWarningFrame.text:SetText(iRC:Text("GROUP_UNSAFE_WARNING"))
    groupWarningFrame:Show()
    if becameActive and iRC.SendHello then iRC:SendHello() end
end

local function getCurrentGroupSize()
    if IsInRaid and IsInRaid() then return GetNumGroupMembers and GetNumGroupMembers() or 0 end
    return GetNumSubgroupMembers and GetNumSubgroupMembers() or 0
end

local function clearGroupSafety()
    groupSafety.sameRace, groupSafety.guildOnly = false, false
    clearUnsafeGroupWarning()
end

local function protectExistingGroup(allRules, newLevel)
    if getCurrentGroupSize() < 1 then return end
    local rules, protected = iRC:GetConnectionRules(), false
    local previousLevel = newLevel and math.max(0, newLevel - 1) or nil
    local sameRaceLevel = math.max(1, math.min(60, math.floor(tonumber(rules.sameRaceMinimumLevel) or 1)))
    local guildOnlyLevel = math.max(1, math.min(60, math.floor(tonumber(rules.guildGroupsMinimumLevel) or 1)))
    if (allRules and rules.sameRaceGroupsOnly)
        or (rules.sameRaceGroupsOnly and previousLevel < sameRaceLevel and newLevel >= sameRaceLevel) then
        groupSafety.sameRace, protected = true, true
    end
    if (allRules and rules.guildGroupsOnly)
        or (rules.guildGroupsOnly and previousLevel < guildOnlyLevel and newLevel >= guildOnlyLevel) then
        groupSafety.guildOnly, protected = true, true
    end
    if protected then iRC:Print(iRC.Colors.Yellow .. iRC:Text("GROUP_SAFETY_ACTIVE") .. iRC.Colors.Reset) end
end

local function protectNewlyActivatedRestrictions()
    local rules, level = iRC:GetConnectionRules(), UnitLevel("player") or 0
    local sameRaceLevel = math.max(1, math.min(60, math.floor(tonumber(rules.sameRaceMinimumLevel) or 1)))
    local guildOnlyLevel = math.max(1, math.min(60, math.floor(tonumber(rules.guildGroupsMinimumLevel) or 1)))
    local current = {
        sameRace = isRuleEnabled("sameRaceGroupsOnly") and level >= sameRaceLevel
            and not (rules.allowLevel60MixedRaceGroups and level >= 60),
        guildOnly = isRuleEnabled("guildGroupsOnly") and level >= guildOnlyLevel,
    }
    local protected = false
    if observedGroupRestrictions and getCurrentGroupSize() > 0 then
        for key, active in pairs(current) do
            if active and not observedGroupRestrictions[key] and not groupSafety[key] then
                groupSafety[key], protected = true, true
            end
        end
    end
    observedGroupRestrictions = current
    if protected then iRC:Print(iRC.Colors.Yellow .. iRC:Text("GROUP_SAFETY_ACTIVE") .. iRC.Colors.Reset) end
end

function Enforcement:CheckGroup()
    if groupLeaving then return end
    local _, playerRace = UnitRace("player")
    if not playerRace then return end
    local inRaid = IsInRaid and IsInRaid()
    local memberCount = inRaid and (GetNumGroupMembers and GetNumGroupMembers() or 0) or (GetNumSubgroupMembers and GetNumSubgroupMembers() or 0)
    if memberCount < 1 then clearGroupSafety(); return end
    local rules = iRC:GetConnectionRules()
    local playerLevel = UnitLevel("player") or 0
    local sameRaceMinimumLevel = math.max(1, math.min(60, math.floor(tonumber(rules.sameRaceMinimumLevel) or 1)))
    local level60SameRaceException = rules.allowLevel60MixedRaceGroups and (UnitLevel("player") or 0) >= 60
    if isRuleEnabled("sameRaceGroupsOnly") and playerLevel >= sameRaceMinimumLevel and not level60SameRaceException and not groupSafety.sameRace then
        local wrongRacePlayers = {}
        for index = 1, memberCount do
            local unit = inRaid and "raid" .. index or "party" .. index
            if not UnitIsUnit or not UnitIsUnit(unit, "player") then
                local _, memberRace = UnitRace(unit)
                if memberRace and memberRace ~= playerRace then
                    wrongRacePlayers[#wrongRacePlayers + 1] = GetUnitName and GetUnitName(unit, true) or UnitName(unit)
                end
            end
        end
        if #wrongRacePlayers > 0 then
            handleInvalidGroup(iRC:Text("SAME_RACE_GROUP_LEAVE"), wrongRacePlayers)
            return
        end
    end
    local guildGroupsMinimumLevel = math.max(1, math.min(60, math.floor(tonumber(rules.guildGroupsMinimumLevel) or 1)))
    if isRuleEnabled("guildGroupsOnly") and playerLevel >= guildGroupsMinimumLevel and not groupSafety.guildOnly and not iRC:IsGuildOnlyGroup() then
        local nonGuildPlayers = {}
        for index = 1, memberCount do
            local unit = inRaid and "raid" .. index or "party" .. index
            if (not UnitIsUnit or not UnitIsUnit(unit, "player")) then
                local name = GetUnitName and GetUnitName(unit, true) or UnitName(unit)
                if name and not iRC:IsGuildMemberName(name) then nonGuildPlayers[#nonGuildPlayers + 1] = name end
            end
        end
        handleInvalidGroup(iRC:Text("GUILD_GROUP_ONLY_LEAVE"), nonGuildPlayers)
        return
    end
    clearUnsafeGroupWarning()
end

function Enforcement:Refresh()
    if iRC.RaceLockedSync then iRC.RaceLockedSync:RefreshMoneyMonitoring() end
    installLanguageHooks()
    iRC:RecordSelfFoundState()
    scheduleLanguageApply()
    self:UpdateSelfFoundWarning()
    protectNewlyActivatedRestrictions()
    if C_Timer and C_Timer.After then C_Timer.After(0, function() Enforcement:CheckGroup() end) else self:CheckGroup() end
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("LANGUAGE_LIST_CHANGED")
frame:RegisterEvent("UNIT_AURA")
frame:RegisterEvent("PLAYER_LEVEL_UP")
frame:RegisterEvent("GROUP_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_ALIVE")
frame:RegisterEvent("PLAYER_CONTROL_GAINED")
frame:RegisterEvent("TRADE_SHOW")
frame:RegisterEvent("TRADE_UPDATE")
frame:RegisterEvent("TRADE_CLOSED")
frame:RegisterEvent("AUCTION_HOUSE_SHOW")
frame:RegisterEvent("MAIL_SHOW")
frame:RegisterEvent("MAIL_INBOX_UPDATE")
frame:RegisterEvent("MAIL_SEND_INFO_UPDATE")
frame:RegisterEvent("MAIL_CLOSED")
frame:RegisterEvent("MAIL_SEND_SUCCESS")
frame:SetScript("OnEvent", function(_, event, unit)
    if event == "PLAYER_LOGIN" then
        initialGroupProtectionPending = true
        protectExistingGroup(true)
        Enforcement:InstallTradeAPIGuard()
        Enforcement:InstallMailAPIGuards()
        Enforcement:Refresh()
        local connection = iRC:GetConnection()
        for index = #(connection and connection.groupViolations or {}), 1, -1 do
            local record = connection.groupViolations[index]
            if not record.reported then pendingGroupViolation = record; break end
        end
        reportPendingGroupViolation()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- A full login can expose the saved group one event later than
        -- PLAYER_LOGIN. Protect it once here as well. Do not repeat this on
        -- later zone/instance transitions, which could otherwise grandfather
        -- a newly formed invalid group.
        if initialGroupProtectionPending then
            initialGroupProtectionPending = false
            protectExistingGroup(true)
        end
        iRC.SelfFoundAuraReady = false
        Enforcement:Refresh()
        if C_Timer and C_Timer.After then
            C_Timer.After(3, function()
                iRC.SelfFoundAuraReady = true
                Enforcement:Refresh()
            end)
        else
            iRC.SelfFoundAuraReady = true
        end
    elseif event == "TRADE_CLOSED" then
        restrictedTradeCancelled = false
        pendingGuildFoundTradePartners = {}
    elseif event == "TRADE_SHOW" or event == "TRADE_UPDATE" then
        Enforcement:InstallTradeAPIGuard()
        Enforcement:CheckTradeRestriction()
    elseif event == "AUCTION_HOUSE_SHOW" then
        Enforcement:CloseRestrictedAuctionHouse()
    elseif event == "MAIL_SHOW" then
        Enforcement:InstallMailAPIGuards()
        Enforcement:InstallMailRecipientGuard()
        Enforcement:UpdateMailRestriction()
    elseif event == "MAIL_INBOX_UPDATE" then
        Enforcement:InstallMailAPIGuards()
    elseif event == "MAIL_SEND_INFO_UPDATE" then
        Enforcement:InstallMailAPIGuards()
        Enforcement:UpdateMailRestriction()
    elseif event == "MAIL_SEND_SUCCESS" then
        Enforcement:UpdateMailRestriction()
    elseif event == "MAIL_CLOSED" then
        lastMailRestrictionReason = nil
    elseif event == "UNIT_AURA" and unit ~= "player" then
        return
    elseif event == "PLAYER_LEVEL_UP" then
        protectExistingGroup(false, tonumber(unit) or UnitLevel("player") or 0)
        Enforcement:Refresh()
    elseif event == "GROUP_ROSTER_UPDATE" then
        if getCurrentGroupSize() < 1 then clearGroupSafety() end
        if C_Timer and C_Timer.After then C_Timer.After(0, function() Enforcement:CheckGroup() end) else Enforcement:CheckGroup() end
    elseif event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_ALIVE" or event == "PLAYER_CONTROL_GAINED" then
        reportPendingGroupViolation()
        Enforcement:CheckGroup()
    else
        Enforcement:Refresh()
    end
end)

if C_Timer and C_Timer.NewTicker then C_Timer.NewTicker(0.20, function()
    if (MailFrame and MailFrame:IsShown()) or (MailFrameTab2 and MailFrameTab2:IsShown()) then
        Enforcement:UpdateMailRestriction()
    end
end) end
