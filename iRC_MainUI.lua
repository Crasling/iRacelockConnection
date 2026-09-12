local _, private = ...
local iRC = private and private.iRC
if not iRC then return end

local UI = {}
iRC.MainUI = UI
local expandedGuildCards = {}
local guildStatsFilter = "ALL"

local function getGuildCardTag(group)
    local rules = group and group.rulesKnown and group.rules
    if not rules then return nil end
    if rules.raceLock == true then return "Race-Locked", { 0.25, 0.85, 1 } end
    local progression = iRC:GetProgressionMode(rules)
    if progression == "GUILD_FOUND" or progression == "SELF_FOUND_OR_GUILD_FOUND" then
        return "Guild-Found", { 0.30, 1, 0.35 }
    end
    if progression == "SELF_FOUND" and iRC:GetMaxLevelProgressionMode(rules) == "SELF_FOUND" then
        return "Self-Found", { 1.00, 0.55, 0.55 }
    end
    return "Normal", { 0.72, 0.72, 0.72 }
end

local function getCurrentGuildStatsFilter()
    if not iRC:IsGuildConnectionActive() then return "ALL" end
    local rules = iRC:GetConnectionRules()
    if rules.raceLock == true then return "RACE_LOCKED" end
    local progression = iRC:GetProgressionMode(rules)
    if progression == "GUILD_FOUND" or progression == "SELF_FOUND_OR_GUILD_FOUND" then return "GUILD_FOUND" end
    if progression == "SELF_FOUND" and iRC:GetMaxLevelProgressionMode(rules) == "SELF_FOUND" then return "SELF_FOUND" end
    return "ALL"
end

local COLORS = {
    gold = iRC.ColorValues.Orange,
    green = iRC.ColorValues.Green,
    muted = iRC.ColorValues.Gray,
    parchment = iRC.ColorValues.Orange,
}

local RACE_ICONS = {
    HUMAN = "Interface\\Icons\\Achievement_Character_Human_Male",
    DWARF = "Interface\\Icons\\Achievement_Character_Dwarf_Male",
    NIGHTELF = "Interface\\Icons\\Achievement_Character_Nightelf_Male",
    GNOME = "Interface\\Icons\\Achievement_Character_Gnome_Male",
    DRAENEI = "Interface\\Icons\\Achievement_Character_Draenei_Male",
    ORC = "Interface\\Icons\\Achievement_Character_Orc_Male",
    SCOURGE = "Interface\\Icons\\Achievement_Character_Undead_Male",
    TAUREN = "Interface\\Icons\\Achievement_Character_Tauren_Male",
    TROLL = "Interface\\Icons\\Achievement_Character_Troll_Male",
    BLOODELF = "Interface\\Icons\\Achievement_Character_Bloodelf_Male",
}
local NO_DATA_ICON = "Interface\\Icons\\Achievement_General"

local function getGuildCardIcon(group)
    local rules = group and group.rulesKnown and group.rules
    if rules and rules.raceLock == true then return RACE_ICONS[group.race] or NO_DATA_ICON end
    local index = math.floor(tonumber(group and group.guildHomepageIcon) or 0)
    return iRC.GuildHomepageIcons[index] or NO_DATA_ICON
end

local RACE_COLORS = {
    HUMAN = { 0.82, 0.62, 0.25 }, DWARF = { 0.74, 0.43, 0.18 }, NIGHTELF = { 0.56, 0.30, 0.78 }, GNOME = { 0.35, 0.68, 0.95 }, DRAENEI = { 0.45, 0.46, 0.90 },
    ORC = { 0.62, 0.18, 0.14 }, SCOURGE = { 0.43, 0.63, 0.50 }, TAUREN = { 0.56, 0.32, 0.18 }, TROLL = { 0.12, 0.62, 0.88 }, BLOODELF = { 0.84, 0.22, 0.24 },
    Unknown = { 0.45, 0.45, 0.45 },
}

local RACE_LABELS = {
    HUMAN = "Human", DWARF = "Dwarf", NIGHTELF = "Night Elf", GNOME = "Gnome", DRAENEI = "Draenei",
    ORC = "Orc", SCOURGE = "Undead", TAUREN = "Tauren", TROLL = "Troll", BLOODELF = "Blood Elf",
}

local FACTION_STYLES = {
    Horde = { border = { 0.72, 0.18, 0.15, 1 }, background = { 0.13, 0.035, 0.03, 0.92 } },
    Alliance = { border = { 0.18, 0.42, 0.80, 1 }, background = { 0.025, 0.07, 0.16, 0.92 } },
}

local PODIUM_COLORS = {
    [1] = { 0.95, 0.72, 0.18, 1 },
    [2] = { 0.72, 0.74, 0.78, 1 },
    [3] = { 0.68, 0.38, 0.17, 1 },
}

local FALLBACK_CLASS_COLORS = {
    WARRIOR = { 0.78, 0.61, 0.43 }, PALADIN = { 0.96, 0.55, 0.73 }, HUNTER = { 0.67, 0.83, 0.45 }, ROGUE = { 1, 0.96, 0.41 },
    PRIEST = { 0.95, 0.95, 0.95 }, SHAMAN = { 0, 0.44, 0.87 }, MAGE = { 0.25, 0.78, 0.92 }, WARLOCK = { 0.53, 0.53, 0.93 }, DRUID = { 1, 0.49, 0.04 },
}

local function createBackdrop(frame, color, border)
    frame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    frame:SetBackdropColor(unpack(color))
    frame:SetBackdropBorderColor(unpack(border))
end

local function makeMemberRow(parent, index)
    local row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetHeight(54)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -((index - 1) * 60))
    row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -((index - 1) * 60))
    createBackdrop(row, { 0.10, 0.085, 0.07, 0.96 }, { 0.28, 0.25, 0.20, 1 })
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    row.name:SetPoint("TOPLEFT", 14, -10)
    row.name:SetWidth(220)
    row.name:SetJustifyH("LEFT")
    row.tag = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.tag:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
    row.detail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.detail:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -5)
    row.detail:SetPoint("RIGHT", row, "RIGHT", -14, 0)
    row.detail:SetJustifyH("LEFT")
    return row
end

local function makeRaceCard(parent)
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetHeight(158)
    createBackdrop(card, { 0.045, 0.055, 0.075, 0.98 }, { 0.30, 0.31, 0.34, 1 })

    card.accent = card:CreateTexture(nil, "ARTWORK")
    card.accent:SetWidth(4)
    card.accent:SetPoint("TOPLEFT", 4, -5)
    card.accent:SetPoint("BOTTOMLEFT", 4, 5)

    card.iconFrame = CreateFrame("Frame", nil, card, "BackdropTemplate")
    card.iconFrame:SetSize(46, 46)
    card.iconFrame:SetPoint("TOPLEFT", 13, -12)
    createBackdrop(card.iconFrame, { 0.03, 0.03, 0.03, 1 }, { 0.58, 0.49, 0.25, 1 })
    card.icon = card.iconFrame:CreateTexture(nil, "ARTWORK")
    card.icon:SetPoint("CENTER")
    card.icon:SetSize(38, 38)

    card.race = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    card.race:SetPoint("TOPLEFT", card.iconFrame, "TOPRIGHT", 9, -1)
    card.race:SetTextColor(unpack(COLORS.gold))
    card.tag = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    card.tag:SetPoint("LEFT", card.race, "RIGHT", 9, 0)
    card.rank = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    card.rank:SetPoint("TOPRIGHT", -14, -16)
    card.rank:SetTextColor(unpack(COLORS.gold))
    card.freshness = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    card.freshness:SetPoint("TOPLEFT", card.iconFrame, "TOPRIGHT", 9, -27)
    card.freshness:SetPoint("RIGHT", card, "RIGHT", -14, 0)
    card.freshness:SetJustifyH("LEFT")
    card.guildLabel = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.guildLabel:SetPoint("TOP", card, "TOP", -35, -43)
    card.guildLabel:SetText(iRC:Text("GUILD_STATS_RACE"))
    card.guildLabel:SetTextColor(unpack(COLORS.gold))
    card.guild = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    card.guild:SetPoint("LEFT", card.guildLabel, "RIGHT", 7, 0)
    card.guild:SetWidth(180)
    card.guild:SetJustifyH("LEFT")
    card.guildLabel:Hide()
    card.guild:Hide()

    card.averageLabel = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.averageLabel:SetPoint("TOP", card, "TOP", -240, -58)
    card.averageLabel:SetWidth(145)
    card.averageLabel:SetText(iRC:Text("GUILD_STATS_ACTIVE_LEVEL_60"))
    card.membersLabel = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.membersLabel:SetPoint("TOP", card, "TOP", -80, -58)
    card.membersLabel:SetWidth(145)
    card.membersLabel:SetText(iRC:Text("GUILD_STATS_ONLINE_PEAK"))
    card.totalLabel = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.totalLabel:SetPoint("TOP", card, "TOP", 80, -58)
    card.totalLabel:SetWidth(145)
    card.totalLabel:SetText(iRC:Text("GUILD_STATS_ACTIVE_MEMBERS"))
    card.totalMembersLabel = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.totalMembersLabel:SetPoint("TOP", card, "TOP", 240, -58)
    card.totalMembersLabel:SetWidth(145)
    card.totalMembersLabel:SetText(iRC:Text("GUILD_STATS_TOTAL_MEMBERS"))
    card.average = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    card.average:SetPoint("TOP", card.averageLabel, "BOTTOM", 0, -3)
    card.members = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    card.members:SetPoint("TOP", card.membersLabel, "BOTTOM", 0, -3)
    card.total = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    card.total:SetPoint("TOP", card.totalLabel, "BOTTOM", 0, -3)
    card.totalMembers = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    card.totalMembers:SetPoint("TOP", card.totalMembersLabel, "BOTTOM", 0, -3)

    card.classesTitle = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.classesTitle:SetPoint("TOP", card, "TOP", 0, -97)
    card.classesTitle:SetText(iRC:Text("GUILD_STATS_CLASS_BREAKDOWN"))
    card.classText = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    card.classText:SetPoint("TOPLEFT", 15, -109)
    card.classText:SetPoint("TOPRIGHT", -15, -109)
    card.classText:SetJustifyH("CENTER")
    card.classText:SetWordWrap(false)
    card.classBar = CreateFrame("Frame", nil, card, "BackdropTemplate")
    card.classBar:SetPoint("TOPLEFT", 16, -123)
    card.classBar:SetPoint("TOPRIGHT", -16, -123)
    card.classBar:SetHeight(12)
    createBackdrop(card.classBar, { 0.015, 0.015, 0.015, 1 }, { 0.48, 0.42, 0.30, 1 })
    card.classSegments = {}
    card.classLabels = {}
    card.expandHint = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    card.expandHint:SetPoint("TOPRIGHT", -16, -138)
    card.expandHint:SetWidth(630)
    card.expandHint:SetJustifyH("RIGHT")
    card.rulesSeparator = card:CreateTexture(nil, "ARTWORK")
    card.rulesSeparator:SetColorTexture(0.35, 0.29, 0.16, 0.8)
    card.rulesSeparator:SetPoint("TOPLEFT", 16, -159)
    card.rulesSeparator:SetPoint("TOPRIGHT", -16, -159)
    card.rulesSeparator:SetHeight(1)
    card.rulesTitle = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    card.rulesTitle:SetPoint("TOPLEFT", 16, -169)
    card.rulesTitle:SetText(iRC:Text("GUILD_STATS_GUILD_PROFILE"))
    card.rulesTitle:SetTextColor(unpack(COLORS.gold))
    card.rulesText = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.rulesText:SetPoint("TOPLEFT", 20, -188)
    card.rulesText:SetPoint("TOPRIGHT", -20, -188)
    card.rulesText:SetJustifyH("LEFT")
    card.rulesText:SetJustifyV("TOP")
    card.rulesText:SetWordWrap(true)
    card.contactsLabel = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    card.contactsLabel:SetPoint("TOPLEFT", 20, -202)
    card.contactsLabel:SetText(iRC:Text("GUILD_CONTACTS_LABEL") .. ":")
    card.contactsLabel:SetTextColor(unpack(COLORS.gold))
    card.contactButtons = {}
    card:EnableMouse(true)
    card:SetScript("OnEnter", function(self)
        if not GameTooltip or not self.report then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(self.report.guildName or "—")
        if self.report.timestamp and self.report.timestamp > 0 then GameTooltip:AddLine(iRC:Text("RL_GRID_UPDATED", date("%Y-%m-%d %H:%M", self.report.timestamp))) end
        if self.report.source then GameTooltip:AddLine(iRC:Text("RL_GRID_SOURCE", self.report.source)) end
        GameTooltip:AddLine(iRC:Text("GUILD_STATS_POPULATION", self.report.activeLevel60 or 0,
            self.report.activePlayers or 0, self.report.activeMembers or 0, self.report.members or 0), 1, 1, 1, true)
        if self.report.cached then GameTooltip:AddLine(iRC:Text("RL_GRID_CACHED"), 1, 0.65, 0) end
        for class, average in pairs(self.report.classAverageLevels or {}) do
            GameTooltip:AddLine(iRC:Text("RL_GRID_CLASS_LEVEL", class, average))
        end
        GameTooltip:Show()
    end)
    card:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    card:SetScript("OnMouseUp", function(self, button)
        if button ~= "LeftButton" or not self.guildKey then return end
        expandedGuildCards[self.guildKey] = not expandedGuildCards[self.guildKey]
        if GameTooltip then GameTooltip:Hide() end
        if UI.frame and UI.frame.scroll then UI.preservedRaceScroll = UI.frame.scroll:GetVerticalScroll() end
        UI:Refresh()
    end)
    return card
end

local function makeFactionSection(parent, faction)
    local style = FACTION_STYLES[faction]
    local section = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    createBackdrop(section, style.background, style.border)
    section.title = section:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    section.title:SetPoint("TOPLEFT", 14, -10)
    section.title:SetText(faction)
    section.title:SetTextColor(unpack(style.border))
    return section
end

local function makeRacePodium(parent)
    local podium = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    createBackdrop(podium, { 0.075, 0.06, 0.04, 0.98 }, { 0.55, 0.41, 0.17, 1 })
    podium.title = podium:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    podium.title:SetPoint("TOP", 0, -7)
    podium.title:SetText(iRC:Text("GUILD_STATS_TOP_THREE"))
    podium.title:SetTextColor(unpack(COLORS.gold))
    podium.entries = {}

    for rank = 1, 3 do
        local entry = CreateFrame("Frame", nil, podium, "BackdropTemplate")
        createBackdrop(entry, { 0.045, 0.055, 0.075, 0.98 }, PODIUM_COLORS[rank])
        entry.icon = entry:CreateTexture(nil, "ARTWORK")
        entry.icon:SetSize(30, 30)
        entry.icon:SetPoint("LEFT", 8, 0)
        entry.rank = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        entry.rank:SetPoint("LEFT", entry.icon, "RIGHT", 7, 0)
        entry.rank:SetTextColor(unpack(PODIUM_COLORS[rank]))
        entry.race = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        entry.race:SetPoint("LEFT", entry.rank, "RIGHT", 5, 0)
        entry.race:SetPoint("RIGHT", entry, "RIGHT", -8, 0)
        entry.race:SetJustifyH("LEFT")
        entry.tag = entry:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        entry.tag:SetPoint("TOPLEFT", entry.race, "BOTTOMLEFT", 0, -1)
        entry.tag:SetPoint("RIGHT", entry, "RIGHT", -8, 0)
        entry.tag:SetJustifyH("LEFT")
        entry.tag:Hide()
        podium.entries[rank] = entry
    end
    return podium
end

local MAIN_NAVIGATION = {
    { id = "Current Server", header = true },
    { id = "Race Overview", label = iRC:Text("GUILD_STATS_TITLE") },
    { id = "Current Guild", header = true },
    { id = "Guild Members", label = "Guild Members", child = true },
    { id = "Guild Bank", label = "Guild Bank", child = true },
}

local function currentServerNavigationName()
    local name = GetRealmName and GetRealmName()
    if not name or name == "" then return "Current Server" end
    return #name > 24 and (name:sub(1, 21) .. "...") or name
end

local function currentGuildNavigationName()
    local name = GetGuildInfo and GetGuildInfo("player")
    if not name or name == "" then return "Current Guild" end
    return #name > 24 and (name:sub(1, 21) .. "...") or name
end

local function canUseGuildBankSnapshot()
    return iRC:IsGuildBankSnapshotPublisher(iRC:GetPlayerName())
end

local function getContainerSlots(bag)
    if C_Container and C_Container.GetContainerNumSlots then return C_Container.GetContainerNumSlots(bag) or 0 end
    return GetContainerNumSlots and GetContainerNumSlots(bag) or 0
end

local function getContainerEntry(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info then
            local link = info.hyperlink or (C_Container.GetContainerItemLink and C_Container.GetContainerItemLink(bag, slot))
            return link or (info.itemID and "Item #" .. info.itemID), info.stackCount or 1, info.itemID
        end
    elseif GetContainerItemLink then
        local link = GetContainerItemLink(bag, slot)
        if link then
            local _, count = GetContainerItemInfo(bag, slot)
            return link, count or 1, tonumber(link:match("item:(%d+)"))
        end
    end
end

local function captureGuildBankSnapshot()
    if not canUseGuildBankSnapshot() then return false, "Only a character configured as a Guild Bank can save a snapshot." end
    local lastSaved = iRCCharDB and iRCCharDB.guildBankSnapshot
    if lastSaved and lastSaved.guildKey == iRC:GetGuildKey() and time() - (tonumber(lastSaved.savedAt) or 0) < 60 then
        return false, "Wait 60 seconds between Guild Bank snapshots."
    end
    if not BankFrame or not BankFrame:IsShown() then return false, "Open your bank before saving a snapshot." end
    local snapshot = { guildKey = iRC:GetGuildKey(), bankType = "GUILD", savedAt = time(), money = GetMoney() or 0, items = {} }
    local itemsByID = {}
    local function scanContainer(bag)
        for slot = 1, getContainerSlots(bag) do
            local link, count, itemID = getContainerEntry(bag, slot)
            itemID = tonumber(itemID) or (link and tonumber(link:match("item:(%d+)")))
            if itemID then
                local item = itemsByID[itemID]
                if not item then
                    item = { itemID = itemID, link = link, count = 0 }
                    itemsByID[itemID] = item
                    snapshot.items[#snapshot.items + 1] = item
                end
                item.count = item.count + (tonumber(count) or 1)
            end
        end
    end
    scanContainer(BANK_CONTAINER or -1)
    for bag = (NUM_BAG_SLOTS or 4) + 1, (NUM_BAG_SLOTS or 4) + (NUM_BANKBAGSLOTS or 7) do scanContainer(bag) end
    for bag = 0, NUM_BAG_SLOTS or 4 do scanContainer(bag) end
    iRCCharDB = iRCCharDB or {}
    iRCCharDB.guildBankSnapshot = snapshot
    return true
end

local function getProfile(frame)
    if not frame.subjectName or iRC:NormalizeName(frame.subjectName) == iRC:NormalizeName(iRC:GetPlayerName()) then
        return iRC:GetLocalProfile()
    end
    local connection = iRC:GetConnection()
    local profile = connection and connection.members[iRC:NormalizeName(frame.subjectName)]
    return profile
end

local function setTabAppearance(button, active)
    button:SetBackdropColor(active and 0.24 or 0.08, active and 0.16 or 0.065, active and 0.04 or 0.05, 0.96)
    button:SetBackdropBorderColor(active and 1 or 0.34, active and 0.72 or 0.28, active and 0.18 or 0.20, 1)
    button.label:SetTextColor(unpack(active and COLORS.gold or COLORS.parchment))
end

local applyMemberSearch

local function updateMemberSuggestions(frame)
    local search = frame.memberProfessionSearch
    if not search then return end
    local query = search.edit:GetText():lower():gsub("^%s+", ""):gsub("%s+$", "")
    local matches = {}
    if query ~= "" then
        for _, entry in ipairs(frame.memberSearchIndex or {}) do
            local position = entry.lower:find(query, 1, true)
            if position then
                matches[#matches + 1] = { entry = entry, starts = position == 1 }
            end
        end
        table.sort(matches, function(a, b)
            if a.entry.kind ~= b.entry.kind then return a.entry.kind == "profession" end
            if a.starts ~= b.starts then return a.starts end
            return a.entry.lower < b.entry.lower
        end)
    end
    for index, button in ipairs(search.buttons) do
        local match = matches[index]
        button.entry = match and match.entry or nil
        button:SetShown(match ~= nil)
        if match then button.text:SetText(match.entry.label) end
    end
    search.suggestions:SetShown(query ~= "" and matches[1] ~= nil and search.edit:HasFocus())
end

local function createMemberProfessionSearch(main, frame)
    local search = CreateFrame("Frame", nil, main)
    search:SetSize(235, 28)
    search:SetPoint("TOPRIGHT", main, "TOPRIGHT", -18, -11)
    search.edit = CreateFrame("EditBox", nil, search, "InputBoxTemplate")
    search.edit:SetSize(222, 22)
    search.edit:SetPoint("RIGHT", search, "RIGHT", 0, 0)
    search.edit:SetAutoFocus(false)
    search.edit:SetMaxLetters(80)
    search.edit:SetTextInsets(5, 5, 0, 0)
    search.edit:SetText("")
    search.hint = search:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    search.hint:SetPoint("LEFT", search.edit, "LEFT", 6, 0)
    search.hint:SetText("Search professions or recipes")
    search.suggestions = CreateFrame("Frame", nil, search, "BackdropTemplate")
    search.suggestions:SetSize(235, 128)
    search.suggestions:SetPoint("TOPLEFT", search.edit, "BOTTOMLEFT", 0, -2)
    search.suggestions:SetFrameStrata("DIALOG")
    search.suggestions:SetFrameLevel(main:GetFrameLevel() + 20)
    search.suggestions:SetBackdrop({ bgFile = "Interface\\BUTTONS\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10,
        insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    search.suggestions:SetBackdropColor(0.03, 0.03, 0.03, 0.98)
    search.suggestions:SetBackdropBorderColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3], 0.85)
    search.buttons = {}
    for index = 1, 5 do
        local button = CreateFrame("Button", nil, search.suggestions)
        button:SetSize(217, 23)
        button:SetPoint("TOPLEFT", search.suggestions, "TOPLEFT", 7, -6 - (index - 1) * 23)
        button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        button.text:SetPoint("LEFT", button, "LEFT", 7, 0)
        button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
        button.highlight:SetAllPoints()
        button.highlight:SetColorTexture(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3], 0.18)
        button:SetScript("OnClick", function(self)
            if not self.entry then return end
            frame.memberSearchSelection = self.entry
            search.edit.settingSelection = true
            search.edit:SetText(self.entry.label)
            search.edit.settingSelection = nil
            search.edit:ClearFocus()
            search.suggestions:Hide()
            applyMemberSearch(frame)
        end)
        search.buttons[index] = button
    end
    search.edit:SetScript("OnTextChanged", function(self)
        search.hint:SetShown(self:GetText() == "")
        if self.settingSelection then return end
        frame.memberSearchSelection = nil
        updateMemberSuggestions(frame)
        if frame.allMemberData then applyMemberSearch(frame) end
    end)
    search.edit:SetScript("OnEditFocusGained", function() updateMemberSuggestions(frame) end)
    search.edit:SetScript("OnEscapePressed", function(self) self:ClearFocus(); search.suggestions:Hide() end)
    search.edit:SetScript("OnEnterPressed", function(self)
        local first = search.buttons[1]
        if first.entry and search.suggestions:IsShown() then first:Click() else self:ClearFocus() end
    end)
    search:Hide()
    search.suggestions:Hide()
    return search
end

function UI:Create()
    if self.frame then return self.frame end

    local frame = CreateFrame("Frame", "iRCMainFrame", UIParent, "BackdropTemplate")
    local settings = iRC:GetSettings()
    frame:SetSize(980, 650)
    frame:SetScale(settings.mainWindowScale or 1)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    createBackdrop(frame, { 0.025, 0.022, 0.018, 0.98 }, { 0.42, 0.35, 0.19, 1 })
    frame:Hide()
    tinsert(UISpecialFrames, frame:GetName())
    self.frame = frame

    local resize = CreateFrame("Button", nil, frame)
    resize:SetSize(20, 20); resize:SetPoint("BOTTOMRIGHT", -3, 3)
    resize:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resize:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resize:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resize:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        local x, y = GetCursorPosition()
        self.dragging, self.startX, self.startY, self.startScale = true, x, y, frame:GetScale()
    end)
    resize:SetScript("OnUpdate", function(self)
        if not self.dragging then return end
        local x, y = GetCursorPosition()
        local delta = ((x - self.startX) - (y - self.startY)) / (2 * (UIParent:GetEffectiveScale() or 1))
        frame:SetScale(math.max(0.6, math.min(1.2, self.startScale + delta / 815)))
    end)
    resize:SetScript("OnMouseUp", function(self)
        self.dragging = false
        settings.mainWindowScale = math.floor(frame:GetScale() * 20 + 0.5) / 20
        frame:SetScale(settings.mainWindowScale)
    end)
    frame.resizeHandle = resize
    iRC:EnableIdleWindowFade(frame)

    frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    frame.close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 4, 4)
    -- UIPanelCloseButton's default handler routes through Blizzard's panel
    -- manager, which can refuse a close while in combat. This is a normal
    -- addon frame, so hiding it directly is safe in and out of combat.
    frame.close:SetScript("OnClick", function() frame:Hide() end)

    local header = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    header:SetPoint("TOPLEFT", 15, -14)
    header:SetPoint("TOPRIGHT", -15, -14)
    header:SetHeight(78)
    createBackdrop(header, { 0.10, 0.07, 0.035, 0.98 }, { 0.55, 0.41, 0.17, 1 })

    frame.title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.title:SetPoint("TOPLEFT", header, "TOPLEFT", 18, -11)
    frame.title:SetText(iRC.DisplayName)
    frame.title:SetTextColor(unpack(COLORS.gold))
    frame.player = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.player:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 17, 13)
    local sidebar = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    sidebar:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -106)
    sidebar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 17)
    sidebar:SetWidth(210)
    createBackdrop(sidebar, { 0.18, 0.11, 0.045, 0.98 }, { 0.58, 0.43, 0.18, 1 })
    frame.sidebar = sidebar

    local sidebarTitle = sidebar:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sidebarTitle:SetPoint("TOPLEFT", 14, -13)
    sidebarTitle:SetText(iRC:Text("IRC_MAIN_NAV_TITLE"))
    sidebarTitle:SetTextColor(unpack(COLORS.gold))
    frame.tabs = {}
    local visibleTabIndex = 0
    for _, item in ipairs(MAIN_NAVIGATION) do
        if not item.hidden then
            visibleTabIndex = visibleTabIndex + 1
            local y = -((visibleTabIndex - 1) * 35 + 41)
            if item.header then
                local heading = sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                heading:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 18, y - 7)
                heading:SetWidth(180)
                heading:SetJustifyH("LEFT")
                heading:SetWordWrap(false)
                heading:SetTextColor(unpack(COLORS.gold))
                if item.id == "Current Server" then
                    heading:SetText(currentServerNavigationName())
                    frame.serverNameHeader = heading
                else
                    heading:SetText(currentGuildNavigationName())
                    frame.guildNameHeader = heading
                end
            else
                local tab = CreateFrame("Button", nil, sidebar, "BackdropTemplate")
                tab:SetSize(item.child and 166 or 180, 31)
                tab:SetPoint("TOPLEFT", item.child and 28 or 14, y)
                createBackdrop(tab, { 0.08, 0.065, 0.05, 0.96 }, { 0.34, 0.28, 0.20, 1 })
                tab:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                tab.label = tab:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                tab.label:SetPoint("LEFT", 12, 0)
                tab.label:SetText(item.child and "- " .. item.label or item.label)
                tab.category = item.id
                tab:SetScript("OnClick", function(self)
                    frame.category = self.category
                    if self.category == "Race Overview" then
                        guildStatsFilter = getCurrentGuildStatsFilter()
                        UI.preservedRaceScroll = 0
                    end
                    if self.category == "Guild Members" then iRC:RefreshGuildRoster() end
                    if self.category ~= "Guild Members" and self.category ~= "Race Overview" then frame.subjectName = iRC:GetPlayerName() end
                    UI:Refresh()
                end)
                frame.tabs[item.id] = tab
            end
        end
    end

    local main = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    main:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 13, 0)
    main:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 17)
    createBackdrop(main, { 0.055, 0.047, 0.038, 0.98 }, { 0.46, 0.37, 0.21, 1 })
    frame.main = main
    frame.contentTitle = main:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.contentTitle:SetPoint("TOPLEFT", 15, -14)
    frame.contentTitle:SetTextColor(unpack(COLORS.gold))
    frame.raceRefresh = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    frame.raceRefresh:SetSize(125, 23)
    frame.raceRefresh:SetPoint("TOPRIGHT", -14, -9)
    frame.raceRefresh:SetText(iRC:Text("RL_GRID_REFRESH"))
    frame.raceRefresh:SetScript("OnClick", function()
        if frame.category == "Race Overview" and frame.scroll then
            UI.preservedRaceScroll = frame.scroll:GetVerticalScroll()
        end
        if iRC.RaceGrid then iRC.RaceGrid:PublishFromClick() end
        UI:Refresh()
    end)
    frame.raceRefresh:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(iRC:Text("RL_GRID_REFRESH"))
        GameTooltip:AddLine(iRC:Text("RL_GRID_REFRESH_TIP"), 1, 1, 1, true)
        GameTooltip:Show()
    end)
    frame.raceRefresh:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    frame.raceRefresh:SetScript("OnUpdate", function(self, elapsed)
        self.cooldownElapsed = (self.cooldownElapsed or 0) + elapsed
        if frame.cacheUpdating then
            local updating = iRC.RaceGrid and iRC.RaceGrid:IsCacheUpdating()
            frame.cacheUpdating:SetShown(updating and true or false)
            if updating then
                frame.cacheUpdating.rotation = ((frame.cacheUpdating.rotation or 0) + elapsed * 5) % (math.pi * 2)
                if frame.cacheUpdating.spinner.SetRotation then
                    frame.cacheUpdating.spinner:SetRotation(frame.cacheUpdating.rotation)
                end
            end
        end
        if self.cooldownElapsed < 0.25 then return end
        self.cooldownElapsed = 0
        local remaining = iRC.RaceGrid and iRC.RaceGrid:GetRefreshCooldownRemaining() or 0
        self:SetEnabled(remaining <= 0)
        self:SetText(remaining > 0 and iRC:Text("RL_GRID_REFRESH_COOLDOWN", math.ceil(remaining)) or iRC:Text("RL_GRID_REFRESH"))
    end)
    frame.raceRefresh:Hide()
    frame.cacheUpdating = CreateFrame("Frame", nil, main)
    frame.cacheUpdating:SetSize(130, 20)
    frame.cacheUpdating:SetPoint("RIGHT", frame.raceRefresh, "LEFT", -10, 0)
    frame.cacheUpdating.spinner = frame.cacheUpdating:CreateTexture(nil, "ARTWORK")
    frame.cacheUpdating.spinner:SetSize(16, 16)
    frame.cacheUpdating.spinner:SetPoint("LEFT", 0, 0)
    frame.cacheUpdating.spinner:SetTexture("Interface\\COMMON\\Indicator-Yellow")
    frame.cacheUpdating.text = frame.cacheUpdating:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.cacheUpdating.text:SetPoint("LEFT", frame.cacheUpdating.spinner, "RIGHT", 5, 0)
    frame.cacheUpdating.text:SetText(iRC:Text("RACEGRID_CACHE_UPDATING"))
    frame.cacheUpdating:Hide()
    frame.contentSubtitle = main:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.contentSubtitle:SetPoint("TOPLEFT", frame.contentTitle, "BOTTOMLEFT", 0, -5)
    frame.contentSubtitle:SetPoint("RIGHT", main, "RIGHT", -22, 0)
    frame.contentSubtitle:SetJustifyH("LEFT")
    frame.contentSubtitle:SetWordWrap(true)
    frame.memberProfessionSearch = createMemberProfessionSearch(main, frame)

    frame.guildStatsFilters = {}
    for index, filter in ipairs({
        { key = "ALL", label = "All" },
        { key = "RACE_LOCKED", label = "Race-Locked" },
        { key = "GUILD_FOUND", label = "Guild-Found" },
        { key = "SELF_FOUND", label = "Self-Found" },
    }) do
        local filterKey, filterLabel = filter.key, filter.label
        local button = CreateFrame("Button", nil, main, "BackdropTemplate")
        button:SetSize(160, 27)
        button:SetPoint("TOPLEFT", main, "TOPLEFT", 15 + (index - 1) * 166, -50)
        createBackdrop(button, { 0.055, 0.045, 0.035, 0.96 }, { 0.28, 0.23, 0.16, 0.9 })
        button.activeGlow = button:CreateTexture(nil, "BACKGROUND")
        button.activeGlow:SetPoint("TOPLEFT", button, "TOPLEFT", 3, -3)
        button.activeGlow:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -3, 3)
        button.activeGlow:SetColorTexture(0, 0, 0, 0)
        button.text = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        button.text:SetPoint("CENTER")
        button.text:SetText(filterLabel)
        button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
        button.highlight:SetAllPoints(button)
        button.highlight:SetColorTexture(1, 0.72, 0.22, 0.10)
        button:SetScript("OnClick", function()
            guildStatsFilter = filterKey
            UI.preservedRaceScroll = 0
            UI:Refresh()
        end)
        button.filterKey = filterKey
        frame.guildStatsFilters[index] = button
    end

    local scroll = CreateFrame("ScrollFrame", nil, main, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", main, "TOPLEFT", 15, -78)
    scroll:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -31, 14)
    frame.scroll = scroll
    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(675)
    content:SetHeight(1)
    scroll:SetScrollChild(content)
    scroll:HookScript("OnVerticalScroll", function()
        if frame.category == "Guild Members" then UI:RenderMemberRows() end
    end)
    frame.scrollContent = content
    frame.bankSave = CreateFrame("Button", nil, main, "UIPanelButtonTemplate")
    frame.bankSave:SetSize(145, 24)
    frame.bankSave:SetPoint("TOPRIGHT", main, "TOPRIGHT", -15, -47)
    frame.bankSave:SetText("Save snapshot")
    frame.bankSave:SetScript("OnClick", function()
        local saved, reason = captureGuildBankSnapshot()
        if not saved then iRC:Print(reason); return end
        local shared = iRC.GuildBankSnapshot and iRC.GuildBankSnapshot:Send()
        local connection = iRC:GetConnection()
        local snapshot = iRCCharDB and iRCCharDB.guildBankSnapshot
        if connection and snapshot then
            snapshot.owner = iRC:GetPlayerName()
            local latest = iRC.GuildBankSnapshot:GetLatest(connection)
            if iRC.GuildBankSnapshot:IsNewer(snapshot, latest) then
                connection.guildBankSnapshots = { [iRC:NormalizeName(snapshot.owner)] = snapshot }
            end
        end
        iRC:Print(shared and "Guild Bank snapshot saved and shared with the guild." or "Guild Bank snapshot saved locally; guild sharing is currently unavailable.")
        UI:Refresh()
    end)
    frame.bankSave:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = (self.elapsed or 0) + elapsed
        if self.elapsed < 0.5 then return end
        self.elapsed = 0
        local saved = iRCCharDB and iRCCharDB.guildBankSnapshot
        local remaining = saved and saved.guildKey == iRC:GetGuildKey() and math.max(0, 60 - (time() - (tonumber(saved.savedAt) or 0))) or 0
        self:SetEnabled(remaining == 0)
        self:SetText(remaining > 0 and ("Save snapshot (" .. remaining .. "s)") or "Save snapshot")
    end)
    frame.bankSave:Hide()
    frame.bankSearch = CreateFrame("EditBox", nil, main, "InputBoxTemplate")
    frame.bankSearch:SetSize(260, 22)
    frame.bankSearch:SetPoint("TOPLEFT", main, "TOPLEFT", 20, -84)
    frame.bankSearch:SetAutoFocus(false)
    frame.bankSearch:SetMaxLetters(80)
    frame.bankSearch:SetTextInsets(5, 5, 0, 0)
    frame.bankSearch.hint = main:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    frame.bankSearch.hint:SetPoint("LEFT", frame.bankSearch, "LEFT", 7, 0)
    frame.bankSearch.hint:SetText("Search bank items")
    frame.bankSearch:SetScript("OnTextChanged", function(self)
        self.hint:SetShown(self:GetText() == "")
        if frame.category == "Guild Bank" then
            frame.scroll:SetVerticalScroll(0)
            UI:Refresh()
        end
    end)
    frame.bankSearch:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame.bankSearch:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    frame.bankSearch:Hide()
    frame.bankItemInfoEvents = CreateFrame("Frame")
    frame.bankItemInfoEvents:SetScript("OnEvent", function()
        if frame:IsShown() and frame.category == "Guild Bank" then UI:RefreshIfShown() end
    end)
    frame.bankSnapshotText = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.bankSnapshotText:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    frame.bankSnapshotText:SetWidth(650)
    frame.bankSnapshotText:SetJustifyH("LEFT")
    frame.bankSnapshotText:SetJustifyV("TOP")
    frame.bankSnapshotText:SetWordWrap(true)
    frame.bankSnapshotText:Hide()
    frame.bankSnapshotRows = {}
    local professionReport = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    professionReport:SetSize(560, 470)
    professionReport:SetPoint("CENTER", frame, "CENTER", 0, 0)
    professionReport:SetFrameLevel(frame:GetFrameLevel() + 20)
    createBackdrop(professionReport, { 0.025, 0.022, 0.018, 1 }, { 0.75, 0.48, 0.13, 1 })
    professionReport.title = professionReport:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    professionReport.title:SetPoint("TOPLEFT", 16, -15)
    local reportClose = CreateFrame("Button", nil, professionReport, "UIPanelCloseButton")
    reportClose:SetPoint("TOPRIGHT", 2, 2)
    reportClose:SetScript("OnClick", function() professionReport:Hide() end)
    local reportScroll = CreateFrame("ScrollFrame", nil, professionReport, "UIPanelScrollFrameTemplate")
    reportScroll:SetPoint("TOPLEFT", 17, -48)
    reportScroll:SetPoint("BOTTOMRIGHT", -31, 17)
    local reportContent = CreateFrame("Frame", nil, reportScroll)
    reportContent:SetWidth(490)
    reportContent:SetHeight(1)
    reportScroll:SetScrollChild(reportContent)
    professionReport.text = reportContent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    professionReport.text:SetPoint("TOPLEFT", 0, 0)
    professionReport.text:SetWidth(490)
    professionReport.text:SetJustifyH("LEFT")
    professionReport.text:SetJustifyV("TOP")
    professionReport.content = reportContent
    professionReport.scroll = reportScroll
    professionReport:Hide()
    frame.professionReport = professionReport
    local memberMenu = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    memberMenu:SetSize(270, 132)
    memberMenu:SetFrameStrata("DIALOG")
    memberMenu:SetClampedToScreen(true)
    createBackdrop(memberMenu, { 0.035, 0.028, 0.02, 0.99 }, { COLORS.gold[1], COLORS.gold[2], COLORS.gold[3], 1 })
    memberMenu.title = memberMenu:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    memberMenu.title:SetPoint("TOPLEFT", 14, -10)
    memberMenu.title:SetPoint("TOPRIGHT", -34, -10)
    memberMenu.title:SetJustifyH("LEFT")
    local menuClose = CreateFrame("Button", nil, memberMenu, "UIPanelCloseButton")
    menuClose:SetPoint("TOPRIGHT", 4, 4)
    memberMenu.view = CreateFrame("Button", nil, memberMenu, "BackdropTemplate")
    memberMenu.view:SetSize(238, 29)
    memberMenu.view:SetPoint("TOPLEFT", 16, -48)
    createBackdrop(memberMenu.view, { 0.07, 0.055, 0.04, 0.98 }, { 0.30, 0.24, 0.16, 1 })
    memberMenu.view.text = memberMenu.view:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    memberMenu.view.text:SetPoint("LEFT", 12, 0)
    memberMenu.view.text:SetText("View professions & recipes")
    memberMenu.view:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    memberMenu.view:SetScript("OnClick", function()
        local profile = memberMenu.profile
        memberMenu:Hide()
        if not profile then return end
        professionReport.title:SetText(iRC:FormatPlayerName(profile.name) .. " - Professions & Recipes")
        local data = profile.professionData
        local lines = data and iRC.Professions:DescribeRecipes(data) or {}
        professionReport.text:SetText(#lines > 0 and table.concat(lines, "\n") or "No profession data received from this member.")
        professionReport.content:SetHeight(math.max(1, professionReport.text:GetStringHeight() + 12))
        professionReport.scroll:SetVerticalScroll(0)
        professionReport:Show()
    end)
    memberMenu.whisper = CreateFrame("Button", nil, memberMenu, "BackdropTemplate")
    memberMenu.whisper:SetSize(238, 29)
    memberMenu.whisper:SetPoint("TOPLEFT", 16, -82)
    createBackdrop(memberMenu.whisper, { 0.07, 0.055, 0.04, 0.98 }, { 0.30, 0.24, 0.16, 1 })
    memberMenu.whisper.text = memberMenu.whisper:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    memberMenu.whisper.text:SetPoint("LEFT", 12, 0)
    memberMenu.whisper.text:SetText("Whisper")
    memberMenu.whisper:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    memberMenu.whisper:SetScript("OnClick", function()
        local profile = memberMenu.profile
        memberMenu:Hide()
        if profile and ChatFrame_SendTell then ChatFrame_SendTell(profile.name) end
    end)
    memberMenu:Hide()
    frame.memberMenu = memberMenu
    frame:HookScript("OnHide", function() memberMenu:Hide(); professionReport:Hide() end)
    local outsideClickWatcher = CreateFrame("Frame")
    outsideClickWatcher:RegisterEvent("GLOBAL_MOUSE_DOWN")
    outsideClickWatcher:SetScript("OnEvent", function()
        if memberMenu:IsShown() and not MouseIsOver(memberMenu) then memberMenu:Hide() end
        if professionReport:IsShown() and not MouseIsOver(professionReport) then professionReport:Hide() end
    end)
    frame.memberRows, frame.memberData, frame.raceCards, frame.factionSections = {}, {}, {}, {}
    frame.racePodium = makeRacePodium(content)
    frame.racePodium:Hide()
    frame.category = "Race Overview"
    return frame
end

function UI:RenderMemberRows()
    local frame = self.frame
    if not frame or frame.category ~= "Guild Members" then return end
    local profiles = frame.memberData or {}
    local first = math.floor((frame.scroll:GetVerticalScroll() or 0) / 60) + 1
    local scrollHeight = frame.scroll:GetHeight() or 0
    if scrollHeight < 1 then scrollHeight = 480 end
    local visible = math.max(0, math.min(#profiles - first + 1, math.ceil(scrollHeight / 60) + 1))
    for slot = 1, visible do
        local index, profile = first + slot - 1, profiles[first + slot - 1]
        local row = frame.memberRows[slot]
        if not row then
            row = makeMemberRow(frame.scrollContent, index)
            frame.memberRows[slot] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame.scrollContent, "TOPLEFT", 0, -((index - 1) * 60))
        row:SetPoint("TOPRIGHT", frame.scrollContent, "TOPRIGHT", 0, -((index - 1) * 60))
        local memberTag, tagColor
        if profile.selfFound == true then
            memberTag, tagColor = "Self-Found", { 1.00, 0.55, 0.55 }
        elseif profile.raceLockedStatus and profile.raceLockedStatus.verified == true then
            memberTag, tagColor = "Guild-Found", { 0.30, 1, 0.35 }
        end
        row.name:SetText(iRC:FormatPlayerName(profile.name))
        row.name:SetWidth(math.min(300, row.name:GetStringWidth() + 3))
        row.tag:SetText(memberTag and ("[" .. memberTag .. "]") or "")
        if tagColor then row.tag:SetTextColor(tagColor[1], tagColor[2], tagColor[3]) end
        row.tag:SetShown(memberTag ~= nil)
        row.name:SetTextColor(unpack(iRC:NormalizeName(profile.name) == iRC:NormalizeName(iRC:GetPlayerName()) and COLORS.green or COLORS.gold))
        row.detail:SetText((profile.race or "Unknown") .. " · " .. (profile.class or "Unknown") .. " · Level " .. (profile.level or 1))
        row.profileName = profile.name
        local professionData = profile.professionData
        local professionNames = {}
        for _, option in ipairs(iRC.Professions:GetOptions()) do
            local rank = professionData and professionData.skills and professionData.skills[option[1]]
            if rank then professionNames[#professionNames + 1] = option[2] .. " " .. rank end
        end
        if #professionNames > 0 then
            row.detail:SetText(row.detail:GetText() .. " | " .. table.concat(professionNames, ", "))
        end
        row:SetScript("OnClick", nil)
        row:SetScript("OnEnter", function(self)
            if not GameTooltip then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(iRC:FormatPlayerName(profile.name))
            if professionData and professionData.skills then
                local lines = iRC.Professions:DescribeRecipes(professionData)
                for index = 1, math.min(#lines, 18) do GameTooltip:AddLine(lines[index], 1, 1, 1) end
                if #lines > 18 then GameTooltip:AddLine("Click to view all known recipes.", 1, 0.7, 0.2) end
            else
                GameTooltip:AddLine("No profession data received from this member.", 0.7, 0.7, 0.7)
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        row:SetScript("OnClick", function(_, mouseButton)
            if mouseButton ~= "RightButton" then return end
            local menu = frame.memberMenu
            local cursorX, cursorY = GetCursorPosition()
            menu.profile = profile
            menu.title:SetText(iRC:FormatPlayerName(profile.name))
            menu:ClearAllPoints()
            menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cursorX / UIParent:GetEffectiveScale(), cursorY / UIParent:GetEffectiveScale())
            menu:Show()
        end)
        row:Show()
    end
    for slot = visible + 1, #frame.memberRows do frame.memberRows[slot]:Hide() end
end

applyMemberSearch = function(frame)
    local profiles = frame.allMemberData or {}
    local selection = frame.memberSearchSelection
    local query = frame.memberProfessionSearch.edit:GetText():lower():gsub("^%s+", ""):gsub("%s+$", "")
    if selection or query ~= "" then
        local members = {}
        if selection then
            for profile in pairs(selection.members) do members[profile] = true end
        else
            for _, entry in ipairs(frame.memberSearchIndex or {}) do
                if entry.lower:find(query, 1, true) then
                    for profile in pairs(entry.members) do members[profile] = true end
                end
            end
        end
        local filtered = {}
        for _, profile in ipairs(profiles) do
            if members[profile] then filtered[#filtered + 1] = profile end
        end
        profiles = filtered
    end
    frame.memberData = profiles
    frame.scrollContent:SetHeight(math.max(1, #profiles * 60))
    frame.scroll:SetVerticalScroll(0)
    UI:RenderMemberRows()
end

local function updateMemberRows(frame)
    -- Index the current roster once per refresh; typing only filters these rows.
    local profiles = iRC:GetGuildRosterRows()
    local entries, byKey = {}, {}
    local function add(kind, label, profile)
        if not label or label == "" then return end
        local key = kind .. ":" .. label:lower()
        local entry = byKey[key]
        if not entry then
            entry = { kind = kind, label = label, lower = label:lower(), members = {} }
            byKey[key] = entry
            entries[#entries + 1] = entry
        end
        entry.members[profile] = true
    end
    for _, profile in ipairs(profiles) do
        local data = profile.professionData
        if data then
            for _, option in ipairs(iRC.Professions:GetOptions()) do
                if data.skills and data.skills[option[1]] then add("profession", option[2], profile) end
            end
            for _, recipes in pairs(data.recipes or {}) do
                for _, recipe in ipairs(recipes) do
                    if type(recipe) == "string" then
                        local name = recipe:sub(1, 1) == "S" and GetSpellInfo and GetSpellInfo(tonumber(recipe:sub(2))) or recipe:sub(2)
                        add("recipe", name, profile)
                    end
                end
            end
        end
    end
    frame.allMemberData, frame.memberSearchIndex = profiles, entries
    -- A selected suggestion may have been rebuilt with new roster data.
    local selection = frame.memberSearchSelection
    if selection then frame.memberSearchSelection = byKey[selection.kind .. ":" .. selection.lower] end
    for _, card in ipairs(frame.raceCards) do card:Hide() end
    for _, section in pairs(frame.factionSections) do section:Hide() end
    frame.racePodium:Hide()
    applyMemberSearch(frame)
    updateMemberSuggestions(frame)
    frame.contentTitle:SetText("Guild Members")
    frame.contentSubtitle:SetText("Current guild roster and live addon information.")
end

local BANK_CATEGORY_ORDER = {
    "Consumable", "Reagent", "Trade Goods", "Recipe", "Gem", "Container", "Weapon", "Armor", "Quest", "Key", "Miscellaneous", "Other",
}
local BANK_CATEGORY_BY_ID = {
    [0] = "Consumable", [1] = "Container", [2] = "Weapon", [3] = "Gem", [4] = "Armor",
    [5] = "Reagent", [7] = "Trade Goods", [9] = "Recipe", [12] = "Quest", [13] = "Key", [15] = "Miscellaneous",
}

local function bankItemCategory(itemID)
    if GetItemInfo then
        local _, _, _, _, _, itemType = GetItemInfo(itemID)
        if itemType and itemType ~= "" then return itemType end
    end
    if C_Item and C_Item.GetItemInfoInstant then
        local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
        return BANK_CATEGORY_BY_ID[classID] or "Other"
    end
    return "Other"
end

local function groupedBankItems(snapshot)
    local byID, groups, totalCount = {}, {}, 0
    local sources = snapshot.items and { snapshot.items } or { snapshot.bank or {}, snapshot.bags or {} }
    for _, source in ipairs(sources) do
        for _, entry in ipairs(source) do
            local itemID = tonumber(entry.itemID) or tonumber(tostring(entry.link or ""):match("item:(%d+)"))
            if itemID then
                local item = byID[itemID]
                if not item then
                    item = { itemID = itemID, count = 0, link = entry.link }
                    byID[itemID] = item
                end
                item.count = item.count + (tonumber(entry.count) or 1)
                if not item.link then item.link = entry.link end
                totalCount = totalCount + (tonumber(entry.count) or 1)
            end
        end
    end
    for _, item in pairs(byID) do
        local category = bankItemCategory(item.itemID)
        groups[category] = groups[category] or {}
        local name, link
        if GetItemInfo then name, link = GetItemInfo(item.itemID) end
        item.name = name or (item.link and item.link:match("%[(.-)%]")) or ("Item #" .. item.itemID)
        item.link = link or item.link
        groups[category][#groups[category] + 1] = item
    end
    for _, items in pairs(groups) do
        table.sort(items, function(a, b) return a.name:lower() < b.name:lower() end)
    end
    return groups, totalCount
end

local function updateGuildBankSnapshot(frame)
    local previousScroll = frame.scroll:GetVerticalScroll() or 0
    local query = frame.bankSearch:GetText():lower():gsub("^%s+", ""):gsub("%s+$", "")
    for _, card in ipairs(frame.raceCards) do card:Hide() end
    for _, section in pairs(frame.factionSections) do section:Hide() end
    for _, row in ipairs(frame.memberRows) do row:Hide() end
    frame.racePodium:Hide()
    frame.contentTitle:SetText("Guild Bank")
    frame.contentSubtitle:SetText("Guild Banks: stand with your bank open, then save. Bank and bag items are combined; equipped items are excluded.")
    local connection = iRC:GetConnection()
    local snapshots = {}
    local ownSnapshot = canUseGuildBankSnapshot() and iRCCharDB and iRCCharDB.guildBankSnapshot
    if ownSnapshot and ownSnapshot.guildKey == iRC:GetGuildKey() then
        ownSnapshot.owner = iRC:GetPlayerName()
    end
    local latest = iRC.GuildBankSnapshot and iRC.GuildBankSnapshot:GetLatest(connection)
    if latest and not iRC:IsGuildBankSnapshotPublisher(latest.owner, connection) then latest = nil end
    if ownSnapshot and (not latest or iRC.GuildBankSnapshot:IsNewer(ownSnapshot, latest)) then
        latest = ownSnapshot
    end
    if latest then snapshots[1] = latest end
    local rows = frame.bankSnapshotRows
    for _, row in ipairs(rows) do row:Hide() end
    frame.bankSnapshotText:Hide()
    local rowIndex, yOffset = 0, 0
    local function addLine(value, height, fontObject, inset)
        rowIndex = rowIndex + 1
        local row = rows[rowIndex]
        if not row then
            row = CreateFrame("Button", nil, frame.scrollContent)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
            row.label:SetJustifyH("LEFT")
            row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
            row.label:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            row:SetScript("OnEnter", function(self)
                if not self.itemID then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(self.itemLink or ("item:" .. self.itemID))
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            rows[rowIndex] = row
        end
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", frame.scrollContent, "TOPLEFT", inset or 0, -yOffset)
        row:SetSize(650 - (inset or 0), height)
        row.label:SetFontObject(fontObject or GameFontHighlightLarge)
        row.label:SetText(value)
        row.label:ClearAllPoints()
        row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
        row.label:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        row.icon:Hide()
        row.itemID, row.itemLink = nil, nil
        row:Show()
        yOffset = yOffset + height
        return row
    end
    for _, snapshot in ipairs(snapshots) do
        if rowIndex > 0 then yOffset = yOffset + 12 end
        addLine(iRC:FormatPlayerName(snapshot.owner or "Guild Bank") .. " - saved " .. (date and date("%Y-%m-%d %H:%M", snapshot.savedAt or 0) or tostring(snapshot.savedAt or 0)), 26)
        addLine("Money: " .. (GetCoinTextureString and GetCoinTextureString(snapshot.money or 0) or tostring(snapshot.money or 0) .. " copper"), 24)
        local groups, totalCount = groupedBankItems(snapshot)
        addLine("Items: " .. totalCount .. " total", 24)
        local shown = {}
        local matchCount = 0
        local function addCategory(category)
            local items = groups[category]
            if not items then return end
            shown[category] = true
            local matching = {}
            for _, item in ipairs(items) do
                if query == "" or item.name:lower():find(query, 1, true) then
                    matching[#matching + 1] = item
                end
            end
            if #matching == 0 then return end
            matchCount = matchCount + #matching
            yOffset = yOffset + 8
            addLine("|cffffd100" .. category .. "|r (" .. #matching .. " types)", 24, GameFontNormalLarge)
            for _, item in ipairs(matching) do
                local row = addLine("x" .. item.count .. "  " .. item.name, 27, GameFontHighlightLarge, 16)
                row.itemID, row.itemLink = item.itemID, item.link
                local icon = (GetItemIcon and GetItemIcon(item.itemID)) or (C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(item.itemID))
                row.icon:SetSize(22, 22)
                row.icon:ClearAllPoints()
                row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
                row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                row.icon:Show()
                row.label:ClearAllPoints()
                row.label:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
                row.label:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            end
        end
        for _, category in ipairs(BANK_CATEGORY_ORDER) do addCategory(category) end
        local otherCategories = {}
        for category in pairs(groups) do if not shown[category] then otherCategories[#otherCategories + 1] = category end end
        table.sort(otherCategories)
        for _, category in ipairs(otherCategories) do addCategory(category) end
        if query ~= "" and matchCount == 0 then
            addLine("No matching items found.", 26, GameFontHighlightLarge, 16)
        elseif totalCount == 0 then
            addLine("Empty", 24, GameFontHighlightLarge, 16)
        end
    end
    if #snapshots == 0 then addLine("No Guild Bank snapshot has been received yet.", 26) end
    frame.scrollContent:SetHeight(math.max(1, yOffset + 12))
    local maxScroll = math.max(0, frame.scrollContent:GetHeight() - frame.scroll:GetHeight())
    frame.scroll:SetVerticalScroll(math.min(previousScroll, maxScroll))
end

local function formatNumber(value)
    local number = math.floor(tonumber(value) or 0)
    local sign = number < 0 and "-" or ""
    local digits = tostring(math.abs(number)):reverse():gsub("(%d%d%d)", "%1,")
    return sign .. digits:reverse():gsub("^,", "")
end

local function getClassColor(class)
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] or FALLBACK_CLASS_COLORS[class]
    if not color then color = FALLBACK_CLASS_COLORS[class] or { 0.50, 0.50, 0.50 } end
    return color.r or color[1], color.g or color[2], color.b or color[3]
end

local CLASS_SHORT_NAMES = {
    WARRIOR = "War", PALADIN = "Pal", HUNTER = "Hun", ROGUE = "Rog", PRIEST = "Pri", SHAMAN = "Sha", MAGE = "Mag", WARLOCK = "Lock", DRUID = "Dru",
}
local CLASS_BREAKDOWN_ORDER = {
    "WARRIOR", "PALADIN", "ROGUE", "HUNTER", "SHAMAN", "MAGE", "DRUID", "WARLOCK", "PRIEST",
}

local function updateClassBreakdown(card, classes, totalMembers)
    local classGroups = {}
    totalMembers = 0
    for _, class in ipairs(CLASS_BREAKDOWN_ORDER) do
        local count = tonumber((classes or {})[class]) or 0
        if count > 0 then
            classGroups[#classGroups + 1] = { class = class, count = count }
            totalMembers = totalMembers + count
        end
    end
    local usedWidth = 0
    local availableWidth = math.max(1, (card:GetWidth() or 651) - 36)
    for index, group in ipairs(classGroups) do
        local share = totalMembers > 0 and group.count / totalMembers or 0
        local percent = math.floor(share * 100 + 0.5)
        local segment = card.classSegments[index]
        if not segment then
            segment = CreateFrame("Frame", nil, card.classBar, "BackdropTemplate")
            segment:SetHeight(8)
            segment:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                edgeSize = 1,
            })
            card.classSegments[index] = segment
        end
        segment:ClearAllPoints()
        segment:SetPoint("LEFT", card.classBar, "LEFT", 2 + usedWidth, 0)
        local width = index == #classGroups and availableWidth - usedWidth or math.floor(availableWidth * share)
        segment:SetWidth(math.max(1, width))
        local red, green, blue = getClassColor(group.class)
        segment:SetBackdropColor(red, green, blue, 1)
        segment:SetBackdropBorderColor(0.02, 0.02, 0.02, 1)
        segment:Show()
        local label = card.classLabels[index]
        if not label then
            label = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
            label:SetJustifyH("CENTER")
            card.classLabels[index] = label
        end
        label:ClearAllPoints()
        label:SetPoint("BOTTOM", segment, "TOP", 0, 2)
        label:SetText((CLASS_SHORT_NAMES[group.class] or group.class) .. " " .. percent .. "%")
        label:Show()
        usedWidth = usedWidth + width
    end
    for index = #classGroups + 1, #card.classSegments do card.classSegments[index]:Hide() end
    for index = #classGroups + 1, #card.classLabels do card.classLabels[index]:Hide() end
    card.classText:SetText(#classGroups == 0 and iRC:Text("GUILD_STATS_NO_DATA") or "")
end

local function guildCardKey(group)
    return string.lower(tostring(group.guildName or "")) .. "@" .. tostring(group.race or "")
end

local function getActiveRuleLines(group)
    if not group.rulesKnown or type(group.rules) ~= "table" then return { iRC:Text("GUILD_STATS_RULES_UNKNOWN") } end
    local rules, lines = group.rules, {}
    if rules.raceLock then lines[#lines + 1] = iRC:Text("GUILD_STATS_RULE_RACE_LOCK") end
    if rules.raceLock and rules.nativeTongueOnly then lines[#lines + 1] = iRC:Text("GUILD_STATS_RULE_NATIVE_TONGUE") end
    local progressionMode = iRC:GetProgressionMode(rules)
    if progressionMode == "GUILD_FOUND" then
        lines[#lines + 1] = iRC:Text("GUILD_STATS_RULE_GUILD_FOUND")
    elseif progressionMode == "SELF_FOUND_OR_GUILD_FOUND" then
        lines[#lines + 1] = iRC:Text("GUILD_STATS_RULE_HYBRID")
    elseif progressionMode == "SELF_FOUND" then
        local maxMode = iRC:GetMaxLevelProgressionMode(rules)
        if maxMode == "GUILD_FOUND" then lines[#lines + 1] = iRC:Text("GUILD_STATS_RULE_SELF_FOUND_TO_GF")
        elseif maxMode == "UNRESTRICTED" then lines[#lines + 1] = iRC:Text("GUILD_STATS_RULE_SELF_FOUND_TO_FREE")
        else lines[#lines + 1] = iRC:Text("GUILD_STATS_RULE_SELF_FOUND_REMAIN") end
    else
        lines[#lines + 1] = iRC:Text("GUILD_STATS_RULE_NO_PROGRESSION")
    end
    if rules.raceLock and rules.sameRaceGroupsOnly then lines[#lines + 1] = iRC:Text("GUILD_STATS_RULE_SAME_RACE", rules.sameRaceMinimumLevel or 1) end
    if rules.raceLock and rules.allowLevel60MixedRaceGroups then lines[#lines + 1] = iRC:Text("GUILD_STATS_RULE_MIXED_RACE_60") end
    if rules.guildGroupsOnly then lines[#lines + 1] = iRC:Text("GUILD_STATS_RULE_GUILD_ONLY", rules.guildGroupsMinimumLevel or 1) end
    if rules.guildFoundTradeExceptions then lines[#lines + 1] = iRC:Text("GUILD_STATS_RULE_TRADE_EXCEPTIONS") end
    if rules.guildMapEnabled then lines[#lines + 1] = iRC:Text("GUILD_STATS_RULE_GUILD_MAP") end
    if #lines == 0 then lines[1] = iRC:Text("GUILD_STATS_NO_ACTIVE_RULES") end
    for index, line in ipairs(lines) do lines[index] = "- " .. line end
    return lines
end

local function getGuildProfileLines(group)
    local description = tostring(group.guildDescription or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if description == "" then description = iRC:Text("GUILD_STATS_NO_DESCRIPTION") end
    local lines = {
        description,
    }
    if (tonumber(group.guildDescriptionTimestamp) or 0) > 0 and tostring(group.guildDescriptionEditedBy or "") ~= "" then
        lines[#lines + 1] = iRC.Colors.Gray
            .. iRC:Text("GUILD_STATS_DESCRIPTION_META", iRC:FormatPlayerName(group.guildDescriptionEditedBy),
                date("%Y-%m-%d %H:%M", group.guildDescriptionTimestamp))
            .. iRC.Colors.Reset
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = iRC:Text("GUILD_STATS_ACTIVE_RULES") .. ":"
    for _, line in ipairs(getActiveRuleLines(group)) do lines[#lines + 1] = line end
    return lines
end

local function guildCardHeight(group)
    if not expandedGuildCards[guildCardKey(group)] then return 158 end
    local descriptionLines = math.max(1, math.ceil(#tostring(group.guildDescription or "") / 72))
    return 230 + #getGuildProfileLines(group) * 14 + (descriptionLines - 1) * 14
end

local function setRaceCard(card, group, rank)
    local rules = group and group.rulesKnown and group.rules
    local progression = rules and iRC:GetProgressionMode(rules) or "NONE"
    local accent = rules and rules.raceLock == true and (RACE_COLORS[group.race] or RACE_COLORS.Unknown)
        or (progression == "GUILD_FOUND" or progression == "SELF_FOUND_OR_GUILD_FOUND")
            and { 0.30, 1, 0.35 } or RACE_COLORS.Unknown
    card.accent:SetColorTexture(accent[1], accent[2], accent[3], 1)
    card.icon:SetTexture(getGuildCardIcon(group))
    card.race:SetText(group.guildName or iRC:Text("GUILD_STATS_UNKNOWN_GUILD"))
    card.rank:SetText("#" .. rank)
    local tag, tagColor = getGuildCardTag(group)
    card.tag:SetText(tag and ("[" .. tag .. "]") or "")
    if tagColor then card.tag:SetTextColor(tagColor[1], tagColor[2], tagColor[3]) end
    card.tag:SetShown(tag ~= nil)
    card.average:SetText(group.activeLevel60 ~= nil and formatNumber(group.activeLevel60) or "—")
    card.members:SetText(formatNumber(group.activePlayers or 0))
    card.total:SetText(group.activeMembers ~= nil and formatNumber(group.activeMembers) or "—")
    card.totalMembers:SetText(formatNumber(group.members or 0))
    card.report = group
    card.guildKey = guildCardKey(group)
    local expanded = expandedGuildCards[card.guildKey]
    card.freshness:SetText(group.source and iRC:Text(group.cached and "RL_GRID_CACHED" or "RL_GRID_RECENT") or "")
    card.expandHint:SetText(iRC:Text(expanded and "GUILD_STATS_COLLAPSE_RULES" or "GUILD_STATS_EXPAND_RULES"))
    card.rulesSeparator:SetShown(expanded and true or false)
    card.rulesTitle:SetShown(expanded and true or false)
    card.rulesText:SetShown(expanded and true or false)
    card.contactsLabel:SetShown(expanded and true or false)
    if expanded then
        card.rulesText:SetText(table.concat(getGuildProfileLines(group), "\n"))
        card.contactsLabel:ClearAllPoints()
        card.contactsLabel:SetPoint("TOPLEFT", card.rulesText, "BOTTOMLEFT", 0, -10)
        local contacts, originalIndex = {}, 0
        local onlineMask = math.floor(tonumber(group.guildContactsOnlineMask) or 0)
        local onlineSnapshotFresh = tonumber(group.timestamp) and time() - tonumber(group.timestamp) <= 1800
        for name in tostring(group.guildContacts or ""):gmatch("[^,]+") do
            name = name:gsub("^%s+", ""):gsub("%s+$", "")
            if name ~= "" and #contacts < 5 then
                originalIndex = originalIndex + 1
                contacts[#contacts + 1] = {
                    name = name, order = originalIndex,
                    online = onlineSnapshotFresh and math.floor(onlineMask / (2 ^ (originalIndex - 1))) % 2 == 1,
                }
            end
        end
        table.sort(contacts, function(a, b)
            if a.online ~= b.online then return a.online end
            return a.order < b.order
        end)
        card.contactsLabel:SetText(#contacts > 0 and (iRC:Text("GUILD_CONTACTS_LABEL") .. ":") or iRC:Text("GUILD_STATS_NO_CONTACTS"))
        local previousButton
        for index, contact in ipairs(contacts) do
            local button = card.contactButtons[index]
            if not button then
                button = CreateFrame("Button", nil, card)
                button:SetHeight(18)
                button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                button.text:SetAllPoints(); button.text:SetJustifyH("LEFT")
                button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
                button.highlight:SetAllPoints(); button.highlight:SetColorTexture(1, 0.55, 0, 0.15)
                card.contactButtons[index] = button
            end
            local contactName = contact.name
            local displayName = iRC:FormatPlayerName(contact.name)
            button:ClearAllPoints()
            if previousButton then button:SetPoint("LEFT", previousButton, "RIGHT", 6, 0)
            else button:SetPoint("LEFT", card.contactsLabel, "RIGHT", 8, 0) end
            button.text:SetText(contact.online
                and ("|TInterface\\FriendsFrame\\StatusIcon-Online:10:10:0:0|t " .. displayName) or displayName)
            button:SetWidth(math.max(55, button.text:GetStringWidth() + 14))
            button:SetScript("OnClick", function()
                local playerFaction = UnitFactionGroup and UnitFactionGroup("player")
                if playerFaction and group.faction and playerFaction ~= group.faction then
                    iRC:Print(iRC:Text("GUILD_CONTACT_CROSS_FACTION"))
                    return
                end
                if ChatFrame_SendTell then ChatFrame_SendTell(contactName) end
            end)
            button:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP"); GameTooltip:SetText(iRC:Text("GUILD_CONTACT_WHISPER", displayName)); GameTooltip:Show()
            end)
            button:SetScript("OnLeave", function() GameTooltip:Hide() end)
            button:Show(); previousButton = button
        end
        for index = #contacts + 1, #card.contactButtons do card.contactButtons[index]:Hide() end
    else
        for _, button in ipairs(card.contactButtons) do button:Hide() end
    end
    updateClassBreakdown(card, group.classes, group.members)
    card:Show()
end

local function updateRacePodium(frame, rankedGroups)
    local placementOrder = { 2, 1, 3 }
    frame.racePodium:ClearAllPoints()
    frame.racePodium:SetSize(675, 86)
    frame.racePodium:SetPoint("TOPLEFT", frame.scrollContent, "TOPLEFT", 0, 0)
    for _, rank in ipairs(placementOrder) do
        local entry = frame.racePodium.entries[rank]
        local group = rankedGroups[rank]
        entry:ClearAllPoints()
        entry:SetSize(207, 48)
        if rank == 1 then
            entry:SetPoint("TOP", frame.racePodium, "TOP", 0, -22)
        elseif rank == 2 then
            entry:SetPoint("TOPLEFT", frame.racePodium, "TOPLEFT", 10, -31)
        else
            entry:SetPoint("TOPRIGHT", frame.racePodium, "TOPRIGHT", -10, -31)
        end
        entry.rank:SetText("#" .. rank)
        if group then
            entry.icon:SetTexture(getGuildCardIcon(group))
            entry.race:SetText(group.guildName or iRC:Text("GUILD_STATS_UNKNOWN_GUILD"))
            local tag, tagColor = getGuildCardTag(group)
            local showTag = guildStatsFilter == "ALL" and tag ~= nil
            entry.race:ClearAllPoints()
            entry.race:SetPoint("LEFT", entry.rank, "RIGHT", 5, showTag and 7 or 0)
            entry.race:SetPoint("RIGHT", entry, "RIGHT", -8, showTag and 7 or 0)
            entry.tag:SetText(showTag and ("[" .. tag .. "]") or "")
            if tagColor then entry.tag:SetTextColor(tagColor[1], tagColor[2], tagColor[3]) end
            entry.tag:SetShown(showTag)
        else
            entry.icon:SetTexture("Interface\\Icons\\Achievement_General")
            entry.race:SetText(iRC:Text("GUILD_STATS_NO_DATA"))
            entry.race:ClearAllPoints()
            entry.race:SetPoint("LEFT", entry.rank, "RIGHT", 5, 0)
            entry.race:SetPoint("RIGHT", entry, "RIGHT", -8, 0)
            entry.tag:Hide()
        end
        entry:Show()
    end
    frame.racePodium:Show()
end

local function updateRaceOverview(frame)
    local allGroups = iRC:GetRaceGridOverview()
    if guildStatsFilter == "RACE_LOCKED" then
        local filtered = {}
        for _, group in ipairs(allGroups) do
            if group.rulesKnown and group.rules and group.rules.raceLock == true then filtered[#filtered + 1] = group end
        end
        allGroups = filtered
    elseif guildStatsFilter == "GUILD_FOUND" then
        local filtered = {}
        for _, group in ipairs(allGroups) do
            if group.rulesKnown and group.rules and group.rules.raceLock == false
                and (iRC:GetProgressionMode(group.rules) == "GUILD_FOUND"
                    or iRC:GetProgressionMode(group.rules) == "SELF_FOUND_OR_GUILD_FOUND") then
                filtered[#filtered + 1] = group
            end
        end
        allGroups = filtered
    elseif guildStatsFilter == "SELF_FOUND" then
        local filtered = {}
        for _, group in ipairs(allGroups) do
            if group.rulesKnown and group.rules and group.rules.raceLock ~= true
                and iRC:GetProgressionMode(group.rules) == "SELF_FOUND"
                and iRC:GetMaxLevelProgressionMode(group.rules) == "SELF_FOUND" then
                filtered[#filtered + 1] = group
            end
        end
        allGroups = filtered
    end
    local ranks = {}
    for index, group in ipairs(allGroups) do ranks[group.guildName] = index end

    local gap, contentWidth = 9, 675
    updateRacePodium(frame, allGroups)
    local usedCards, yOffset = 0, 95

    local playerFaction = UnitFactionGroup and UnitFactionGroup("player") or "Horde"
    local factionOrder = playerFaction == "Alliance" and { "Alliance", "Horde" } or { "Horde", "Alliance" }
    for _, faction in ipairs(factionOrder) do
        local section = frame.factionSections[faction]
        if not section then
            section = makeFactionSection(frame.scrollContent, faction)
            frame.factionSections[faction] = section
        end
        local guilds = {}
        for _, group in ipairs(allGroups) do if group.faction == faction then guilds[#guilds + 1] = group end end
        local cardsHeight = 0
        for index, group in ipairs(guilds) do cardsHeight = cardsHeight + guildCardHeight(group) + (index > 1 and gap or 0) end
        local sectionHeight = 44 + cardsHeight + 10
        section:ClearAllPoints()
        section:SetSize(contentWidth, sectionHeight)
        section:SetPoint("TOPLEFT", frame.scrollContent, "TOPLEFT", 0, -yOffset)
        section:Show()
        local cardWidth = contentWidth - 24
        local cardOffset = 36
        for _, group in ipairs(guilds) do
            usedCards = usedCards + 1
            local card = frame.raceCards[usedCards]
            if not card then
                card = makeRaceCard(section)
                frame.raceCards[usedCards] = card
            elseif card:GetParent() ~= section then
                card:SetParent(section)
            end
            local cardHeight = guildCardHeight(group)
            card:ClearAllPoints()
            card:SetSize(cardWidth, cardHeight)
            card:SetPoint("TOPLEFT", section, "TOPLEFT", 12, -cardOffset)
            setRaceCard(card, group, ranks[group.guildName] or usedCards)
            cardOffset = cardOffset + cardHeight + gap
        end
        yOffset = yOffset + sectionHeight + gap
    end
    for index = usedCards + 1, #frame.raceCards do frame.raceCards[index]:Hide() end
    for _, row in ipairs(frame.memberRows) do row:Hide() end
    frame.scrollContent:SetHeight(math.max(1, yOffset - gap))
    frame.scroll:SetVerticalScroll(UI.preservedRaceScroll or 0)
    UI.preservedRaceScroll = nil
    frame.contentTitle:SetText(iRC:Text("GUILD_STATS_TITLE"))
    frame.contentSubtitle:SetText(iRC:Text("RL_GRID_OVERVIEW_DESC"))
    return #allGroups
end

function UI:Refresh()
    self.pendingRefresh = nil
    local frame = self:Create()
    if frame.category ~= "Guild Members" then
        frame.professionReport:Hide()
        frame.memberMenu:Hide()
    end
    frame.serverNameHeader:SetText(currentServerNavigationName())
    frame.guildNameHeader:SetText(currentGuildNavigationName())
    local bankAccess = canUseGuildBankSnapshot()
    frame.raceRefresh:SetShown(frame.category == "Race Overview")
    frame.memberProfessionSearch:SetShown(frame.category == "Guild Members")
    if frame.category ~= "Guild Members" then frame.memberProfessionSearch.suggestions:Hide() end
    frame.bankSave:SetShown(frame.category == "Guild Bank" and bankAccess)
    frame.bankSearch:SetShown(frame.category == "Guild Bank")
    if frame.category == "Guild Bank" then
        frame.bankItemInfoEvents:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    else
        frame.bankItemInfoEvents:UnregisterEvent("GET_ITEM_INFO_RECEIVED")
    end
    frame.bankSnapshotText:Hide()
    if frame.category ~= "Guild Bank" then
        for _, row in ipairs(frame.bankSnapshotRows) do row:Hide() end
    end
    for _, button in ipairs(frame.guildStatsFilters or {}) do
        local shown = frame.category == "Race Overview"
        button:SetShown(shown)
        if shown then
            local active = button.filterKey == guildStatsFilter
            button.activeGlow:SetColorTexture(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3], active and 0.18 or 0)
            button:SetBackdropColor(active and 0.18 or 0.055, active and 0.09 or 0.045, active and 0.025 or 0.035, 0.98)
            button:SetBackdropBorderColor(active and COLORS.gold[1] or 0.28, active and COLORS.gold[2] or 0.23,
                active and COLORS.gold[3] or 0.16, active and 1 or 0.9)
            button.text:SetFontObject(active and GameFontHighlight or GameFontNormal)
            button.text:SetTextColor(active and 1 or 0.78, active and 0.82 or 0.72, active and 0.36 or 0.62)
        end
    end
    frame.scroll:ClearAllPoints()
    frame.scroll:SetPoint("TOPLEFT", frame.main, "TOPLEFT", 15, frame.category == "Race Overview" and -82 or (frame.category == "Guild Bank" and -120 or -78))
    frame.scroll:SetPoint("BOTTOMRIGHT", frame.main, "BOTTOMRIGHT", -31, 14)
    frame.cacheUpdating:SetShown(frame.category == "Race Overview" and iRC.RaceGrid and iRC.RaceGrid:IsCacheUpdating())
    local profile = getProfile(frame)
    local name = iRC:FormatPlayerName(profile and profile.name or frame.subjectName or iRC:GetPlayerName())
    local race, class, level = profile and profile.race or "Unknown", profile and profile.class or "Unknown", profile and profile.level or 1
    frame.player:SetText(name .. "  " .. iRC.Colors.Gray .. race .. " " .. class .. " · Level " .. level .. iRC.Colors.Reset)
    for category, tab in pairs(frame.tabs) do setTabAppearance(tab, frame.category == category) end
    if frame.category == "Guild Members" then
        updateMemberRows(frame)
    elseif frame.category == "Guild Bank" then
        updateGuildBankSnapshot(frame)
    elseif frame.category == "Race Overview" then
        local connection = iRC:GetConnection()
        frame.player:SetText((connection and connection.guildName or "No guild") .. iRC.Colors.Gray .. "  " .. iRC:Text("GUILD_STATS_HEADER_DESC") .. iRC.Colors.Reset)
        updateRaceOverview(frame)
    end
end

function UI:Open(subjectName, publishFromClick)
    local frame = self:Create()
    if iRC.CloseWindowsExcept then iRC:CloseWindowsExcept(frame) end
    frame.subjectName = subjectName or iRC:GetPlayerName()
    if not frame.category or not frame.tabs[frame.category] then frame.category = "Race Overview" end
    if frame.category == "Race Overview" then
        guildStatsFilter = getCurrentGuildStatsFilter()
        self.preservedRaceScroll = 0
    end
    if frame.category == "Guild Members" then iRC:RefreshGuildRoster() end
    frame:SetScale(iRC:GetSettings().mainWindowScale or 1)
    self:Refresh()
    frame:Show()
    frame:Raise()
    if publishFromClick and iRC.RaceGrid then iRC.RaceGrid:PublishFromClick() end
end

function UI:Toggle(publishFromClick)
    local frame = self:Create()
    if frame:IsShown() then
        frame:Hide()
    else
        self:Open(nil, publishFromClick)
    end
end

function UI:RefreshIfShown()
    if not self.frame or not self.frame:IsShown() or self.pendingRefresh then return end
    if not C_Timer or not C_Timer.After then
        if self.frame.category == "Race Overview" and self.frame.scroll then
            self.preservedRaceScroll = self.frame.scroll:GetVerticalScroll()
        end
        self:Refresh()
        return
    end
    local ticket = {}
    self.pendingRefresh = ticket
    C_Timer.After(0.2, function()
        if UI.pendingRefresh ~= ticket then return end
        UI.pendingRefresh = nil
        if UI.frame and UI.frame:IsShown() then
            if UI.frame.category == "Race Overview" and UI.frame.scroll then
                UI.preservedRaceScroll = UI.frame.scroll:GetVerticalScroll()
            end
            UI:Refresh()
        end
    end)
end
