-- Run from the iRC directory with: lua tests/roleplay_links.lua
local private = { iRC = {} }
function CreateFrame()
    return { RegisterEvent = function() end, SetScript = function() end }
end
assert(loadfile("iRC_Roleplay.lua"))("iRC", private)

local roleplay = private.iRC.Roleplay
local item = "|cff1eff00|Hitem:12713::::::::60:::::|h[Formula: Smoking Heart of the Mountain]|h|r"
assert(roleplay:TransformTrollTalk(item) == item, "item hyperlink must stay byte-for-byte intact")
assert(roleplay:TransformTrollTalk("The " .. item .. " is for you") == "Da " .. item .. " be fer ya",
    "only speech surrounding an item link should change")
assert(roleplay:TransformTaurenTalk("Hello " .. item) == "Greetings " .. item,
    "other RP styles must also preserve item links")
