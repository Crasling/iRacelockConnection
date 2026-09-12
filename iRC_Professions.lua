local _, private = ...
local iRC = private and private.iRC
if not iRC then return end

local Professions = {}
iRC.Professions = Professions
local ORDER = {
    { 171, "Alchemy" }, { 164, "Blacksmithing" }, { 333, "Enchanting" },
    { 202, "Engineering" }, { 182, "Herbalism" }, { 165, "Leatherworking" },
    { 186, "Mining" }, { 393, "Skinning" }, { 197, "Tailoring" },
    { 185, "Cooking" }, { 356, "Fishing" }, { 129, "First Aid" },
}
local byName, byID = {}, {}
for _, entry in ipairs(ORDER) do byName[entry[2]:lower()], byID[entry[1]] = entry[1], entry[2] end
local transfers = {}
local lastSummaryWire, lastSummaryGuild, pendingUpdate, sentCachedRecipes
local sharingReadyAt = 0
local CHUNK_SIZE, MAX_CHUNKS = 165, 64

local function localData()
    iRCCharDB = iRCCharDB or {}
    iRCCharDB.professionSnapshot = iRCCharDB.professionSnapshot or { skills = {}, recipes = {} }
    return iRCCharDB.professionSnapshot
end

local function digest(value)
    local a, b = 1, 0
    for index = 1, #value do
        a = (a + value:byte(index)) % 65521
        b = (b + a) % 65521
    end
    return string.format("%08x", b * 65536 + a)
end

local function escape(value)
    return tostring(value or ""):gsub("([^%w _%-])", function(char) return string.format("%%%02X", char:byte()) end)
end

local function unescape(value)
    return (value:gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end))
end

function Professions:GetOptions() return ORDER end
function Professions:GetName(id) return byID[tonumber(id)] or "Unknown profession" end

local function isFishingRod(itemID)
    itemID = tonumber(itemID)
    if not itemID then return false end
    if C_Item and C_Item.GetItemInfoInstant then
        local _, _, _, _, _, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
        local fishingSubclass = Enum and Enum.ItemWeaponSubclass and Enum.ItemWeaponSubclass.Fishingpole or 20
        if classID == 2 and subclassID == fishingSubclass then return true end
    end
    if GetItemInfo then
        local _, _, _, _, _, _, subclass = GetItemInfo(itemID)
        if subclass and subclass:lower():find("fishing", 1, true) then return true end
    end
    return false
end

local function carriedFishingRod()
    local equipped = GetInventoryItemID and GetInventoryItemID("player", INVSLOT_MAINHAND or 16)
    if not equipped and GetInventoryItemLink then
        local link = GetInventoryItemLink("player", INVSLOT_MAINHAND or 16)
        equipped = link and tonumber(link:match("item:(%d+)"))
    end
    if isFishingRod(equipped) then return equipped end
    if not (C_Container and C_Container.GetContainerNumSlots) and not GetContainerNumSlots then return nil end
    for bag = 0, NUM_BAG_SLOTS or 4 do
        local slots = C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bag)
            or (GetContainerNumSlots and GetContainerNumSlots(bag)) or 0
        for slot = 1, slots do
            local itemID
            if C_Container and C_Container.GetContainerItemID then itemID = C_Container.GetContainerItemID(bag, slot) end
            if not itemID and C_Container and C_Container.GetContainerItemInfo then
                local info = C_Container.GetContainerItemInfo(bag, slot)
                itemID = info and info.itemID
            end
            if not itemID and GetContainerItemLink then
                local link = GetContainerItemLink(bag, slot)
                itemID = link and tonumber(link:match("item:(%d+)"))
            end
            if isFishingRod(itemID) then return itemID end
        end
    end
end

function Professions:CollectSkills()
    local data = localData()
    local found = {}
    if GetProfessions and GetProfessionInfo then
        local indices = { GetProfessions() }
        for slot = 1, select("#", GetProfessions()) do
            local index = indices[slot]
            if index then
                local name, _, rank, _, _, _, skillLine = GetProfessionInfo(index)
                local id = tonumber(skillLine) or byName[tostring(name or ""):lower()]
                if id and byID[id] then found[id] = math.max(0, tonumber(rank) or 0) end
            end
        end
    end
    if GetNumSkillLines and GetSkillLineInfo then
        for index = 1, GetNumSkillLines() do
            local name, isHeader, _, rank = GetSkillLineInfo(index)
            local id = not isHeader and byName[tostring(name or ""):lower()]
            if id then found[id] = math.max(0, tonumber(rank) or 0) end
        end
    end
    data.skills = found
    data.fishingRodID = found[356] and carriedFishingRod() or nil
    for id in pairs(data.recipes or {}) do
        if not found[id] or id == 129 or id == 356 then
            data.recipes[id] = nil
            if data.recipeUpdatedAt then data.recipeUpdatedAt[id] = nil end
        end
    end
    data.guid = UnitGUID("player") or ""
    data.updatedAt = time()
    return data
end

function Professions:SendSummary(force)
    local data = self:CollectSkills()
    if GetTime and GetTime() < sharingReadyAt then return false end
    if not iRC:IsGuildConnectionActive() then return false end
    local fields = {}
    for _, entry in ipairs(ORDER) do
        local rank = data.skills[entry[1]]
        if rank then fields[#fields + 1] = entry[1] .. ":" .. math.floor(rank) end
    end
    local wire = table.concat(fields, ",")
    local rodID = tonumber(data.fishingRodID) or 0
    local guildKey = iRC:GetGuildKey()
    if guildKey ~= lastSummaryGuild then sentCachedRecipes = nil end
    if not force and wire .. ":" .. rodID == lastSummaryWire and guildKey == lastSummaryGuild then return false end
    local message = table.concat({ "PROF_SUM", "2", data.guid, data.updatedAt, wire, rodID }, "\t")
    if iRC:SendAddonTraffic(iRC.Prefix, message, "GUILD") then
        lastSummaryWire = wire .. ":" .. rodID
        lastSummaryGuild = guildKey
        local connection = iRC:GetConnection()
        if connection then
            connection.professionMembers = connection.professionMembers or {}
            connection.professionMembers[iRC:NormalizeName(iRC:GetPlayerName())] = data
        end
        if not sentCachedRecipes then
            sentCachedRecipes = true
            self:SendKnownRecipes()
        end
        return true
    end
    return false
end

local function sendRecipeChunks(id, data)
    if id == 129 or id == 356 then return end
    if not iRC:IsGuildConnectionActive() then return end
    local recipes = data.recipes and data.recipes[id]
    if not recipes then return end
    local encoded = {}
    for _, recipe in ipairs(recipes) do encoded[#encoded + 1] = escape(recipe) end
    local payload = table.concat(encoded, ";")
    if #payload > CHUNK_SIZE * MAX_CHUNKS then return end
    local stamp = tonumber(data.recipeUpdatedAt and data.recipeUpdatedAt[id]) or time()
    local hash = digest(data.guid .. ":" .. id .. ":" .. stamp .. ":" .. payload)
    local total = math.max(1, math.ceil(#payload / CHUNK_SIZE))
    for index = 1, total do
        local chunk = payload:sub((index - 1) * CHUNK_SIZE + 1, index * CHUNK_SIZE)
        local message = table.concat({ "PROF_REC", "1", data.guid, id, stamp, index, total, hash, chunk }, "\t")
        if index == 1 or not C_Timer or not C_Timer.After then
            iRC:SendAddonTraffic(iRC.Prefix, message, "GUILD")
        else
            C_Timer.After((index - 1) * 0.08, function()
                if iRC:IsGuildConnectionActive() then iRC:SendAddonTraffic(iRC.Prefix, message, "GUILD") end
            end)
        end
    end
end

function Professions:SendKnownRecipes()
    local data = localData()
    for id in pairs(data.recipes or {}) do sendRecipeChunks(id, data) end
end

function Professions:CollectOpenRecipes(isCraft)
    local name = isCraft and GetCraftDisplaySkillLine and GetCraftDisplaySkillLine()
        or (GetTradeSkillLine and GetTradeSkillLine())
    local id = byName[tostring(name or ""):lower()]
    if not id or id == 129 or id == 356 then return end
    local count = isCraft and GetNumCrafts and GetNumCrafts() or (GetNumTradeSkills and GetNumTradeSkills())
    if not count or count < 1 then return end
    local recipes, seen = {}, {}
    for index = 1, count do
        local recipeName, recipeType
        if isCraft and GetCraftInfo then recipeName, _, recipeType = GetCraftInfo(index)
        elseif GetTradeSkillInfo then recipeName, recipeType = GetTradeSkillInfo(index) end
        if recipeName and recipeType ~= "header" and recipeType ~= "subheader" then
            local link = not isCraft and GetTradeSkillRecipeLink and GetTradeSkillRecipeLink(index)
                or (isCraft and GetCraftItemLink and GetCraftItemLink(index))
            local spellID = link and link:match("spell:(%d+)")
            local key = spellID and ("S" .. spellID) or ("N" .. recipeName)
            if not seen[key] then seen[key] = true; recipes[#recipes + 1] = key end
        end
    end
    local data = localData()
    local old = data.recipes[id] or {}
    for _, recipe in ipairs(old) do
        if not seen[recipe] then seen[recipe] = true; recipes[#recipes + 1] = recipe end
    end
    table.sort(recipes)
    if table.concat(old, "\t") == table.concat(recipes, "\t") then return end
    data.recipes[id] = recipes
    data.recipeUpdatedAt = data.recipeUpdatedAt or {}
    data.recipeUpdatedAt[id] = time()
    data.guid = UnitGUID("player") or ""
    sendRecipeChunks(id, data)
end

local function validSender(sender, guid)
    if not iRC:IsGuildConnectionActive() or not iRC:IsGuildMemberName(sender) then return nil end
    local connection = iRC:GetConnection()
    if not connection then return nil end
    local key = iRC:NormalizeName(sender)
    local profile = connection.members and connection.members[key]
    if profile and profile.guid and profile.guid ~= "" and guid ~= "" and profile.guid ~= guid then return nil end
    return connection, key
end

function Professions:Receive(message, sender)
    local kind = message:match("^([^\t]+)")
    if kind == "PROF_SUM" then
        local version = message:match("^PROF_SUM\t([^\t]*)")
        local guid, stamp, wire, rodText
        if version == "2" then
            _, guid, stamp, wire, rodText = message:match("^PROF_SUM\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        elseif version == "1" then
            _, guid, stamp, wire = message:match("^PROF_SUM\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        end
        stamp = tonumber(stamp)
        local rodID = tonumber(rodText) or 0
        if not wire or (version ~= "1" and version ~= "2") or not guid or #guid > 80
            or not stamp or stamp > time() + 300 or #wire > 160 or rodID < 0 or rodID > 2000000 then return end
        local connection, key = validSender(sender, guid)
        if not connection then return end
        local skills = {}
        for idText, rankText in wire:gmatch("(%d+):(%d+)") do
            local id, rank = tonumber(idText), tonumber(rankText)
            if byID[id] and rank <= 1000 then skills[id] = rank end
        end
        connection.professionMembers = connection.professionMembers or {}
        local previous = connection.professionMembers[key]
        if previous and previous.guid == guid and (tonumber(previous.updatedAt) or 0) > stamp then return end
        connection.professionMembers[key] = { guid = guid, skills = skills, recipes = previous and previous.guid == guid and previous.recipes or {},
            recipeUpdatedAt = previous and previous.guid == guid and previous.recipeUpdatedAt or {},
            fishingRodID = skills[356] and rodID > 0 and rodID or nil, updatedAt = stamp }
        if iRC.MainUI and iRC.MainUI.frame and iRC.MainUI.frame.category == "Guild Members" then iRC.MainUI:RefreshIfShown() end
    elseif kind == "PROF_REC" then
        local version, guid, id, stamp, index, total, hash, chunk = message:match("^PROF_REC\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)$")
        id, stamp, index, total = tonumber(id), tonumber(stamp), tonumber(index), tonumber(total)
        if version ~= "1" or not chunk or not byID[id] or id == 129 or id == 356
            or not guid or #guid > 80 or not stamp or stamp > time() + 300
            or not index or not total or index < 1 or index > total or total > MAX_CHUNKS or #chunk > CHUNK_SIZE
            or not hash or #hash ~= 8 or not hash:match("^[0-9a-f]+$") then return end
        local key = iRC:NormalizeName(sender)
        local transferKey = key .. ":" .. id
        local transfer = transfers[transferKey]
        if not transfer or transfer.stamp ~= stamp or transfer.hash ~= hash or transfer.total ~= total or time() - transfer.startedAt > 90 then
            transfer = { stamp = stamp, hash = hash, total = total, guid = guid, chunks = {}, startedAt = time() }
            transfers[transferKey] = transfer
        end
        if transfer.guid ~= guid then return end
        transfer.chunks[index] = chunk
        for part = 1, total do if transfer.chunks[part] == nil then return end end
        transfers[transferKey] = nil
        local payload = table.concat(transfer.chunks)
        if digest(guid .. ":" .. id .. ":" .. stamp .. ":" .. payload) ~= hash then return end
        local connection = validSender(sender, guid)
        if not connection then return end
        connection.professionMembers = connection.professionMembers or {}
        local member = connection.professionMembers[key] or { guid = guid, skills = {}, recipes = {}, recipeUpdatedAt = {} }
        if member.guid ~= guid or (tonumber(member.recipeUpdatedAt and member.recipeUpdatedAt[id]) or 0) > stamp then return end
        local recipes = {}
        if payload ~= "" then
            for token in (payload .. ";"):gmatch("(.-);") do
                local recipe = unescape(token)
                if #recipe > 100 or not recipe:match("^[SN]") then return end
                recipes[#recipes + 1] = recipe
                if #recipes > 500 then return end
            end
        end
        member.recipes[id] = recipes
        member.recipeUpdatedAt[id] = stamp
        connection.professionMembers[key] = member
        if iRC.MainUI and iRC.MainUI.frame and iRC.MainUI.frame.category == "Guild Members" then iRC.MainUI:RefreshIfShown() end
    end
end

function Professions:DescribeRecipes(data)
    local lines = {}
    for _, entry in ipairs(ORDER) do
        local id = entry[1]
        if data.skills and data.skills[id] then
            if id == 129 or id == 393 then
                lines[#lines + 1] = entry[2] .. " (" .. data.skills[id] .. ")"
            elseif id == 356 then
                local rodName
                if data.fishingRodID and GetItemInfo then
                    local name, link = GetItemInfo(data.fishingRodID)
                    rodName = link or name
                end
                lines[#lines + 1] = entry[2] .. " (" .. data.skills[id] .. ") - Fishing rod: "
                    .. (rodName or (data.fishingRodID and ("Item #" .. data.fishingRodID) or "not detected"))
            else
                local recipes = data.recipes and data.recipes[id]
                lines[#lines + 1] = entry[2] .. " (" .. data.skills[id] .. ") - " .. (recipes and (#recipes .. " known recipes") or "recipes not scanned")
                for _, recipe in ipairs(recipes or {}) do
                    local name = recipe:sub(1, 1) == "S" and GetSpellInfo and GetSpellInfo(tonumber(recipe:sub(2))) or recipe:sub(2)
                    lines[#lines + 1] = "  " .. tostring(name or recipe:sub(2))
                end
            end
        end
    end
    return lines
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("SKILL_LINES_CHANGED")
eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
eventFrame:RegisterEvent("BAG_UPDATE_DELAYED")
eventFrame:RegisterEvent("TRADE_SKILL_SHOW")
eventFrame:RegisterEvent("TRADE_SKILL_UPDATE")
eventFrame:RegisterEvent("CRAFT_SHOW")
eventFrame:RegisterEvent("CRAFT_UPDATE")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" then
        Professions:CollectSkills()
        if C_Timer and C_Timer.After then
            -- Presence replies are time-sensitive. Start optional profession
            -- and recipe sharing after the initial HELLO/activation exchange.
            local delay = iRC:GetStartupTrafficDelay() + 15
            sharingReadyAt = (GetTime and GetTime() or 0) + delay
            local function sendInitialSummary()
                if Professions:SendSummary(true) then return end
                C_Timer.After(15, sendInitialSummary)
            end
            C_Timer.After(delay, sendInitialSummary)
        end
    elseif event == "SKILL_LINES_CHANGED" or event == "PLAYER_EQUIPMENT_CHANGED" or event == "BAG_UPDATE_DELAYED" then
        if pendingUpdate then return end
        pendingUpdate = true
        C_Timer.After(2, function() pendingUpdate = false; Professions:SendSummary(false) end)
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_UPDATE" or event == "CRAFT_SHOW" or event == "CRAFT_UPDATE" then
        local isCraft = event == "CRAFT_SHOW" or event == "CRAFT_UPDATE"
        if C_Timer and C_Timer.After then C_Timer.After(0.2, function() Professions:CollectOpenRecipes(isCraft) end) end
    end
end)
