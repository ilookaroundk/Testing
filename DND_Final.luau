-- Dungeon & Dragons - Chat-Driven Adventure (Chat-only, Expanded Choices)
-- Run this as the GM (LocalScript). All control and interaction is done through chat.
-- Players do NOT need this script. They vote using chat (e.g. "!vote A" or "A") and use "!join" to join.
-- Executor-friendly: robust chat send, safe notifications, single-instance guard.
-- This version greatly expands the adventure nodes and choices.

-- Commands:
-- Players:
--   !join                -> join the party
--   !leave               -> leave the party
--   !vote A / !vote 1    -> vote while a vote is active (single-letter "A" also accepted)
--   !status              -> show your status in chat (HP, Gold, XP, items)
--   !roll <notation>     -> roll dice, e.g. !roll d20 or !roll 2d6+1
-- GM (script runner):
--   !start               -> start the adventure (GM only)
--   !end                 -> end the adventure (GM only)
--   !force <n>           -> force the current vote to choose option n (GM only)
--   !announce <text>     -> GM announcement to chat (GM only)

-- =====================================================
-- Environment safety & compatibility
-- =====================================================
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")

local TextChatService = nil
pcall(function() TextChatService = game:GetService("TextChatService") end)

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    warn("LocalPlayer not found. This script must run as a LocalScript in a player context.")
    return
end

if getgenv and getgenv().DND_CHAT_ADVENTURE_RUNNING then
    pcall(function()
        if StarterGui and StarterGui.SetCore then
            StarterGui:SetCore("SendNotification", {Title="DND Chat Bot", Text="Script already running", Duration=5})
        end
    end)
    return
end
if getgenv then pcall(function() getgenv().DND_CHAT_ADVENTURE_RUNNING = true end) end

-- Safe chat send
local function SafeChat(msg)
    if not msg then return end
    local done = false
    pcall(function()
        if TextChatService and TextChatService.TextChannels and TextChatService.TextChannels:FindFirstChild("RBXGeneral") then
            TextChatService.TextChannels.RBXGeneral:SendAsync(msg)
            done = true
        end
    end)
    if done then return end
    pcall(function()
        local default = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
        if default and default:FindFirstChild("SayMessageRequest") then
            default.SayMessageRequest:FireServer(msg, "All")
            done = true
        end
    end)
    if done then return end
    pcall(function()
        if StarterGui and StarterGui.SetCore then
            StarterGui:SetCore("ChatMakeSystemMessage", {Text = msg})
            done = true
        end
    end)
end

local function SafeNotify(title, text, duration)
    duration = duration or 5
    pcall(function()
        if StarterGui and StarterGui.SetCore then
            StarterGui:SetCore("SendNotification", {Title = title, Text = text, Duration = duration})
        else
            SafeChat("["..(title or "Notice").."] "..(text or ""))
        end
    end)
end

-- =====================================================
-- Config and state
-- =====================================================
local CONFIG = {
    VOTE_PREFIX = "!vote",
    VOTE_ACCEPT_SINGLE_LETTER = true,
    VOTE_DURATION = 22,
    STARTING_GOLD = 12,
    BASE_HP = 14,
    BASE_XP_PER_GOOD = 30,
    MAX_OPTION_LABELS = 12
}

local GM_USER_ID = LocalPlayer.UserId

local party = {}        -- userId -> character
local partyOrder = {}   -- ordered list of userIds
local currentNodeId = nil
local adventureRunning = false
local nodes = {}
local currentVote = nil -- active vote table
local messageLog = {}

-- =====================================================
-- Helpers
-- =====================================================
local function appendLog(line)
    table.insert(messageLog, line)
    if #messageLog > 500 then table.remove(messageLog, 1) end
end

local function clamp(n,a,b) return math.max(a, math.min(b, n)) end

local function rollDice(notation)
    if type(notation) ~= "string" then return tonumber(notation) or 0 end
    local count, sides, sign, mod = notation:match("^(%d*)[dD](%d+)([%+%-]?)(%d*)$")
    if not sides then
        local n = tonumber(notation)
        return n or 0
    end
    count = tonumber(count) or 1
    sides = tonumber(sides)
    mod = tonumber(mod) or 0
    if sign == "-" then mod = -mod end
    local total = 0
    for i = 1, count do total = total + math.random(1, sides) end
    return total + mod
end

local function d20() return rollDice("d20") end

-- =====================================================
-- Party & effects
-- =====================================================
local function makeCharacterTemplate(player)
    return {
        UserId = player.UserId,
        Name = player.Name,
        DisplayName = player.DisplayName,
        Level = 1,
        XP = 0,
        Gold = CONFIG.STARTING_GOLD,
        MaxHP = CONFIG.BASE_HP + math.random(1,8),
        HP = CONFIG.BASE_HP,
        Inventory = {},
        MapFragments = 0,
        Alive = true
    }
end

local function addPlayerToParty(player)
    if not player then return false, "no player" end
    if party[player.UserId] then return false, "already in party" end
    party[player.UserId] = makeCharacterTemplate(player)
    table.insert(partyOrder, player.UserId)
    SafeChat("🧭 "..player.DisplayName.." joined the party! (Type !status)")
    appendLog(player.DisplayName.." joined")
    return true
end

local function removePlayerFromParty(player)
    if not player then return false, "no player" end
    if not party[player.UserId] then return false, "not in party" end
    party[player.UserId] = nil
    for i,id in ipairs(partyOrder) do if id == player.UserId then table.remove(partyOrder,i); break end end
    SafeChat("⛔ "..player.DisplayName.." left the party.")
    appendLog(player.DisplayName.." left")
    return true
end

local function grantXP(userId, xp)
    local c = party[userId]; if not c then return end
    c.XP = (c.XP or 0) + xp
    SafeChat("✨ "..c.DisplayName.." gains "..xp.." XP! (Total: "..(c.XP)..")")
    appendLog(c.DisplayName.." +"..xp.." XP")
end

local function giveGold(userId, amount)
    local c = party[userId]; if not c then return end
    c.Gold = (c.Gold or 0) + amount
    SafeChat("💰 "..c.DisplayName.." found "..amount.." gold (Total: "..c.Gold..")")
end

local function addItem(userId, item)
    local c = party[userId]; if not c then return end
    table.insert(c.Inventory, item)
    SafeChat("🎁 "..c.DisplayName.." obtained: "..item.Name)
end

local function damagePlayer(userId, amount, reason)
    local c = party[userId]; if not c or not c.Alive then return end
    c.HP = c.HP - amount
    SafeChat("⚠️ "..c.DisplayName.." takes "..amount.." damage ("..(reason or "injury").."). HP: "..math.max(0,c.HP).."/"..c.MaxHP)
    if c.HP <= 0 then
        c.Alive = false
        SafeChat("☠️ "..c.DisplayName.." has fallen unconscious!")
    end
end

local function healPlayer(userId, amount)
    local c = party[userId]; if not c then return end
    c.HP = math.min(c.MaxHP, c.HP + amount)
    SafeChat("❤ "..c.DisplayName.." healed "..amount.." HP. ("..c.HP.."/"..c.MaxHP..")")
end

-- =====================================================
-- Loot & consequences
-- =====================================================
local function randomLootForGoodChoice()
    local r = math.random(1,100)
    if r <= 35 then return {Key="gold", Name="Gold Coins", Type="gold", Amount=math.random(5,50)}
    elseif r <= 60 then return {Key="potion_heal", Name="Healing Potion", Type="consumable", Heal="1d8+2"}
    elseif r <= 75 then return {Key="gem", Name="Gemstone", Type="treasure", Value=math.random(25,200)}
    elseif r <= 90 then return {Key="map_frag", Name="Map Fragment", Type="map", Fragments=1}
    elseif r <= 97 then return {Key="mystic_key", Name="Mysterious Key", Type="key"}
    else return {Key="artifact", Name="Strange Artifact", Type="relic", Value=500}
    end
end

-- =====================================================
-- Node helpers & option builder
-- =====================================================
local function Option(label, nextId, goodEffect, badEffect, chanceGood, note)
    return { label = label, next = nextId, good = goodEffect, bad = badEffect, chanceGood = chanceGood or 75, note = note }
end

local function rewardAll_xp(amount)
    return function(ctx) for _, uid in ipairs(partyOrder) do if party[uid] then grantXP(uid, amount) end end end
end
local function rewardRandomLoot()
    return function(ctx)
        if #partyOrder == 0 then return end
        local uid = partyOrder[math.random(1, #partyOrder)]
        local item = randomLootForGoodChoice()
        if item.Type == "gold" then giveGold(uid, item.Amount) else addItem(uid, item) end
    end
end
local function damageRandom(amount, reason)
    return function(ctx)
        local alive = {}
        for _, uid in ipairs(partyOrder) do if party[uid] and party[uid].Alive then table.insert(alive, uid) end end
        if #alive == 0 then return end
        local uid = alive[math.random(1,#alive)]
        damagePlayer(uid, amount, reason)
    end
end
local function trapAll(amount, reason)
    return function(ctx) for _, uid in ipairs(partyOrder) do if party[uid] and party[uid].Alive then damagePlayer(uid, amount, reason) end end end
local function loseItemRandom()
    return function(ctx)
        local candidates = {}
        for _, uid in ipairs(partyOrder) do local c = party[uid] if c and #c.Inventory > 0 then table.insert(candidates, uid) end end
        if #candidates == 0 then return end
        local uid = candidates[math.random(1,#candidates)]
        local c = party[uid]
        local idx = math.random(1,#c.Inventory)
        local removed = table.remove(c.Inventory, idx)
        SafeChat("🗑️ "..c.DisplayName.." lost a(n) "..(removed and removed.Name or "item").." due to misfortune.")
    end
end

-- =====================================================
-- Expanded adventure node graph
-- =====================================================
nodes = {}

-- Start
nodes["crossroads"] = {
    id = "crossroads",
    title = "Crossroads",
    desc = "You stand at a weathered crossroads with paths leading to a Castle, Road, Forest, River, Desert trail, Mountain pass, and a Harbor pier. A signpost points to many small hamlets and dangerous places.",
    options = {
        Option("Head to the Castle (north)", "castle_gate", rewardAll_xp(CONFIG.BASE_XP_PER_GOOD), damageRandom(6,"barbed gate trap"), 85),
        Option("Follow the Road (east)", "long_road", rewardRandomLoot(), damageRandom(4,"thug ambush"), 80),
        Option("Venture into the Forest (west)", "ancient_forest", rewardAll_xp(CONFIG.BASE_XP_PER_GOOD + 10), trapAll(3,"hidden thorns"), 70),
        Option("Walk to the River & Harbor (south)", "harbor", rewardRandomLoot(), damageRandom(5,"slip and cut"), 75),
        Option("Take the Desert trail (southeast)", "desert_road", rewardRandomLoot(), trapAll(6,"heatstroke"), 60),
        Option("Climb the Mountain pass (northwest)", "mountain_path", rewardAll_xp(50), damageRandom(10,"rockslide"), 55),
        Option("Visit the Nearby hamlet for rumors", "hamlet", rewardAll_xp(12), loseItemRandom(), 90)
    },
    onEnter = function() SafeChat("📍 Crossroads: Choose a path. Vote now!") end
}

-- Castle area
nodes["castle_gate"] = {
    id = "castle_gate",
    title = "Castle Gate",
    desc = "A looming castle with barred gates. You can try main gate, servants' entrance, climb, bribe a guard, or sneak around.",
    options = {
        Option("Try the main gate (push it open)", "great_hall", rewardAll_xp(40), damageRandom(10,"collapsing portcullis"), 70),
        Option("Sneak through the servants' entrance", "service_tunnel", rewardRandomLoot(), damageRandom(6,"suffocation"), 78),
        Option("Climb to battlements", "battlements", rewardAll_xp(30), trapAll(5,"fall from ladder"), 65),
        Option("Bribe a guard for entry", "audience", function() for _,id in ipairs(partyOrder) do giveGold(id, -math.random(5,20)); grantXP(id, 15) end end, loseItemRandom(), 60),
        Option("Scout the perimeter and map a safe approach", "castle_walls", rewardAll_xp(25), damageRandom(3,"spy caught"), 85)
    }
}

nodes["great_hall"] = {
    id = "great_hall",
    title = "Great Hall",
    desc = "You enter the great hall; a chest sits under a tapestry and a lord requests an audience. The hearth is warm and a suspicious servant eyes you.",
    options = {
        Option("Accept lord's audience and bargain", "audience", rewardAll_xp(50), damageRandom(5,"lord's suspicion"), 80),
        Option("Open the chest under the tapestry", "tapestry_chest", rewardRandomLoot(), trapAll(8,"needle trap"), 62),
        Option("Bribe the servant for secrets", "secret_passage", rewardRandomLoot(), loseItemRandom(), 55),
        Option("Search for hidden doors", "hidden_passage", rewardAll_xp(30), damageRandom(4,"trapdoor"), 70)
    }
}

nodes["audience"] = {
    id = "audience",
    title = "Audience with the Lord",
    desc = "The lord is distracted by politics; he offers a quest, or you can perform a favor or steal a document.",
    options = {
        Option("Accept the lord's quest (gain renown)", "quest_start", rewardAll_xp(60), damageRandom(6,"political backlash"), 85),
        Option("Perform a favor for coin", "favor_reward", function() for _,id in ipairs(partyOrder) do giveGold(id, math.random(10,40)) end end, loseItemRandom(), 80),
        Option("Steal a secret document", "stolen_doc", rewardRandomLoot(), trapAll(9,"palace guards"), 50)
    }
}

nodes["service_tunnel"] = {
    id = "service_tunnel",
    title = "Service Tunnel",
    desc = "A cramped tunnel, locks, and a grate; you can pick, drop through the grate, or retreat.",
    options = {
        Option("Pick the lock", "cellar", rewardRandomLoot(), damageRandom(4,"lock snaps"), 74),
        Option("Drop through the grate", "dungeon_entrance", rewardAll_xp(35), trapAll(12,"spiked pit"), 60),
        Option("Retreat and scout walls", "castle_walls", rewardAll_xp(10), damageRandom(2,"slippery retreat"), 88)
    }
}

nodes["battlements"] = {
    id = "battlements",
    title = "Battlements",
    desc = "You can signal to allies, leap across walls, or descend into the kitchens.",
    options = {
        Option("Signal a watchman", "friendly_watch", rewardAll_xp(20), damageRandom(3,"misfired signal"), 80),
        Option("Leap across to another wall", "wall_leap", rewardRandomLoot(), damageRandom(10,"failed leap"), 48),
        Option("Climb down into kitchens", "kitchen", rewardRandomLoot(), damageRandom(2,"hot oil"), 82)
    }
}

nodes["castle_walls"] = {
    id = "castle_walls",
    title = "Castle Walls",
    desc = "Perimeter exploration yields a hidden key, loose stones, and a watchtower rope.",
    options = {
        Option("Search loose stones", "hidden_key", rewardRandomLoot(), damageRandom(2,"collapse"), 80),
        Option("Climb the watchtower rope", "watchtower", rewardAll_xp(20), damageRandom(6,"rope snaps"), 70),
        Option("Use found key on servants' door", "service_tunnel", rewardAll_xp(15), damageRandom(4,"wrong key trap"), 85)
    }
}

-- Road nodes
nodes["long_road"] = {
    id = "long_road",
    title = "Long Road",
    desc = "You encounter merchants, a broken cart, a mysterious shrine, and a crossroads to side paths.",
    options = {
        Option("Trade with merchant", "merchant_deal", rewardRandomLoot(), loseItemRandom(), 82),
        Option("Help fix cart", "fix_cart", rewardAll_xp(20), damageRandom(3,"pinched hand"), 92),
        Option("Explore a small shrine by the wayside", "road_shrine", rewardRandomLoot(), trapAll(5,"sudden curse"), 70),
        Option("Follow faint footprints off-road", "tracks", rewardRandomLoot(), damageRandom(7,"ambush"), 50)
    }
}

nodes["merchant_deal"] = {
    id = "merchant_deal",
    title = "Merchant Deal",
    desc = "The merchant offers strange wares and a sealed crate that may be valuable or cursed.",
    options = {
        Option("Buy the sealed crate", "mystery_box", rewardRandomLoot(), loseItemRandom(), 58),
        Option("Haggle for a discount", "haggled_price", rewardAll_xp(15), damageRandom(1,"merchant insult"), 84),
        Option("Offer a trade of items", "trade", rewardRandomLoot(), loseItemRandom(), 80)
    }
}

nodes["fix_cart"] = {
    id = "fix_cart",
    title = "Fix Cart",
    desc = "You fix the cart and are offered a reward or asked to join a caravan.",
    options = {
        Option("Accept a small reward", "cart_reward", function() for _,id in ipairs(partyOrder) do giveGold(id, math.random(8,25)) end end, damageRandom(1,"unexpected debt"), 90),
        Option("Join the caravan (temporary safety)", "caravan_route", rewardAll_xp(25), damageRandom(5,"caravan attacked"), 75)
    }
}

nodes["road_shrine"] = {
    id = "road_shrine",
    title = "Wayside Shrine",
    desc = "A statue with offerings; you may leave an offering, take a relic, or pray.",
    options = {
        Option("Leave an offering (blessing)", "blessing", function() for _,id in ipairs(partyOrder) do healPlayer(id, 4) end end, trapAll(6,"devil's tangles"), 88),
        Option("Take a relic from the shrine", "stolen_relic", rewardRandomLoot(), trapAll(10,"shrine curse"), 45),
        Option("Pray for guidance", "guided_path", rewardAll_xp(20), damageRandom(2,"false prophet"), 80)
    }
}

-- Forest & Wilderness
nodes["ancient_forest"] = {
    id = "ancient_forest",
    title = "Ancient Forest",
    desc = "Whispers, stone circles, hidden cottages, and a fey-lost glade.",
    options = {
        Option("Investigate stone circle", "stone_circle", rewardAll_xp(50), trapAll(6,"arcane backlash"), 68),
        Option("Knock on the hermit cottage", "cottage", rewardRandomLoot(), damageRandom(2,"angry badger"), 86),
        Option("Follow leaf-glow to a faerie ring", "fey_grove", rewardRandomLoot(), trapAll(8,"charmed and led astray"), 55),
        Option("Trace glyphs deeper", "glyph_path", rewardAll_xp(30), damageRandom(7,"cursed roots"), 62)
    }
}

nodes["stone_circle"] = {
    id = "stone_circle",
    title = "Stone Circle",
    desc = "Ancient stones hum; a word of power sits on your tongue. You may speak, leave, or dig.",
    options = {
        Option("Speak the ancient word", "fey_offer", function() for _,id in ipairs(partyOrder) do grantXP(id, 60); addItem(id, {Key="fey_seed", Name="Fey Seed", Type="special"}) end end, damageRandom(12,"arcane backlash"), 60),
        Option("Leave quietly", "forest_path", rewardAll_xp(10), damageRandom(1,"stumble on root"), 96),
        Option("Dig at the center", "buried_cache", rewardRandomLoot(), trapAll(6,"earth collapse"), 70)
    }
}

nodes["fey_grove"] = {
    id = "fey_grove",
    title = "Fey Grove",
    desc = "Fey laughter and riddles. The court may trade boons or trick you.",
    options = {
        Option("Accept a fey bargain", "fey_bargain", rewardRandomLoot(), trapAll(10,"trickery costs"), 50),
        Option("Refuse and leave", "forest_exit", rewardAll_xp(15), damageRandom(2,"crossed fey"), 85),
        Option("Attempt to steal fey treasure", "fey_theft", rewardRandomLoot(), trapAll(14,"fey wrath"), 35)
    }
}

-- River / Harbor / Sea
nodes["harbor"] = {
    id = "harbor",
    title = "Harbor & Pier",
    desc = "Ships rock, fishermen shout, and a merchant ship prepares to sail. Options include chartering a boat, visiting shipwrights, or exploring a hidden cove.",
    options = {
        Option("Charter a fishing boat to scout islands", "island_scout", rewardRandomLoot(), damageRandom(6,"stormy waves"), 75),
        Option("Hire on the merchant ship", "merchant_ship", rewardAll_xp(40), damageRandom(8,"sea robbers"), 70),
        Option("Investigate the hidden cove", "pirate_cove", rewardRandomLoot(), trapAll(12,"pirate ambush"), 55),
        Option("Browse the market for rare gear", "market", rewardRandomLoot(), loseItemRandom(), 80)
    }
}

nodes["pirate_cove"] = {
    id = "pirate_cove",
    title = "Pirate Cove",
    desc = "Hidden cove with smugglers. You can bargain, duel, or sneak.",
    options = {
        Option("Bargain with smugglers", "smuggler_deal", rewardRandomLoot(), loseItemRandom(), 65),
        Option("Challenge the leader (duel)", "duel_pit", rewardRandomLoot(), damageRandom(15,"duel wounds"), 40),
        Option("Sneak and steal contraband", "stolen_smuggler_goods", rewardRandomLoot(), trapAll(12,"captured"), 45)
    }
}

nodes["island_scout"] = {
    id = "island_scout",
    title = "Islands Scout",
    desc = "You find a ruined lighthouse, a jungle isle, and a lagoon with gleaming sands.",
    options = {
        Option("Explore ruined lighthouse", "lighthouse_ruins", rewardRandomLoot(), trapAll(10,"collapsing stairs"), 65),
        Option("Hunt in the jungle (risk animals)", "jungle_hunt", rewardRandomLoot(), damageRandom(9,"wild beasts"), 60),
        Option("Dive the lagoon", "lagoon", rewardRandomLoot(), trapAll(8,"drowning"), 70)
    }
}

-- Desert & Oasis
nodes["desert_road"] = {
    id = "desert_road",
    title = "Desert Trail",
    desc = "Sun beats down. Mirage shimmers. You may seek an oasis, follow a caravan, or explore ruins.",
    options = {
        Option("Seek an oasis (rest & water)", "oasis", function() for _,id in ipairs(partyOrder) do healPlayer(id, math.random(5,12)) end end, trapAll(10,"scorpion stings"), 75),
        Option("Follow a desert caravan", "caravan", rewardAll_xp(30), damageRandom(6,"caravan raid"), 70),
        Option("Explore sunken ruins", "desert_ruins", rewardRandomLoot(), trapAll(14,"sand trap"), 50)
    }
}

-- Mountain
nodes["mountain_path"] = {
    id = "mountain_path",
    title = "Mountain Path",
    desc = "Cold winds, high passes, avalanches, and a hermit monastery up high.",
    options = {
        Option("Take the high pass (faster, riskier)", "high_pass", rewardAll_xp(60), damageRandom(14,"avalanche"), 55),
        Option("Visit the monastery", "monastery", rewardRandomLoot(), damageRandom(2,"harsh welcome"), 80),
        Option("Search for rare ore veins", "mineshaft_entrance", rewardRandomLoot(), trapAll(10,"cave-in"), 65)
    }
}

nodes["mineshaft_entrance"] = {
    id = "mineshaft_entrance",
    title = "Mineshaft Entrance",
    desc = "Ropes, carts and a dark shaft. Choose to enter, camp, or recruit miners.",
    options = {
        Option("Descend into the mineshaft", "abandoned_mine", rewardRandomLoot(), trapAll(12,"gassy pocket"), 60),
        Option("Recruit miners to guide you", "mining_party", rewardAll_xp(20), loseItemRandom(), 75),
        Option("Mark the area and return later", "mountain_camp", rewardAll_xp(10), damageRandom(1,"minor slip"), 90)
    }
}

-- Ruins, dungeons, temples
nodes["dungeon_entrance"] = {
    id = "dungeon_entrance",
    title = "Dungeon Entrance",
    desc = "Dark steps downwards. Doors with runes. The smell of old magic.",
    options = {
        Option("Descend into the dark hall", "dark_hall", rewardRandomLoot(), trapAll(10,"spike corridor"), 62),
        Option("Set camp and prepare (rest)", "camp_prepare", rewardAll_xp(20), damageRandom(2,"cold night"), 88),
        Option("Search the entrance for clues", "dungeon_clues", rewardAll_xp(15), damageRandom(1,"loose rock"), 85)
    }
}

nodes["dark_hall"] = {
    id = "dark_hall",
    title = "Dark Hall",
    desc = "Three doors: one bloody, one singing music, one warm glow. Choose wisely.",
    options = {
        Option("Enter the bloody door", "blood_room", rewardRandomLoot(), trapAll(14,"blood trap"), 50),
        Option("Follow the music", "music_chamber", rewardAll_xp(40), damageRandom(4,"enchanted lull"), 68),
        Option("Investigate the warm glow", "glow_chamber", rewardRandomLoot(), damageRandom(6,"burning embers"), 72)
    }
}

-- City & market
nodes["hamlet"] = {
    id = "hamlet",
    title = "Hamlet",
    desc = "Small shops, a noticeboard, a suspicious chapel, and a traveling troupe.",
    options = {
        Option("Visit the noticeboard", "notice_board", rewardRandomLoot(), damageRandom(1,"wrong job"), 90),
        Option("Attend the traveling troupe", "troupe", rewardAll_xp(20), loseItemRandom(), 80),
        Option("Investigate the old chapel", "chapel", rewardRandomLoot(), trapAll(7,"holy backlash"), 60)
    }
}

nodes["market"] = {
    id = "market",
    title = "Market",
    desc = "Stalls of exotic goods and a black market alley. Haggling or theft - choose.",
    options = {
        Option("Buy a rare tool", "bought_tool", rewardRandomLoot(), loseItemRandom(), 75),
        Option("Slip into the black market alley", "shadow_market", rewardRandomLoot(), trapAll(10,"thugs"), 55),
        Option("Talk to a mysterious map-seller", "map_seller", rewardRandomLoot(), loseItemRandom(), 65)
    }
}

-- Special / endpoints
nodes["map_room"] = {
    id = "map_room",
    title = "Map Room",
    desc = "Map pieces assembled reveal the Lost Lighthouse, a Shadow City, and a Celestial Gate.",
    options = {
        Option("Sail to the Lost Lighthouse", "lighthouse", rewardAll_xp(100), damageRandom(10,"storm"), 70),
        Option("Explore Shadow City (darker path)", "shadow_city", rewardRandomLoot(), trapAll(16,"shadow corruption"), 45),
        Option("Seek the Celestial Gate", "celestial_gate", rewardAll_xp(200), trapAll(20,"astral backlash"), 50)
    }
}

nodes["lighthouse"] = {
    id = "lighthouse",
    title = "Lost Lighthouse",
    desc = "Tower battered by waves; a beacon puzzle and a storm-guarding guardian.",
    options = {
        Option("Solve the beacon puzzle", "beacon_solved", rewardAll_xp(200), trapAll(20,"maelstrom"), 55),
        Option("Loot the storerooms", "lighthouse_loot", rewardRandomLoot(), damageRandom(5,"stored explosives"), 75)
    }
}

nodes["beacon_solved"] = {
    id = "beacon_solved",
    title = "Beacon Restored",
    desc = "You restore the beacon and become renowned. A celebratory path or more adventure?",
    options = {
        Option("Celebrate your fame (end)", "celebration", function() for _,id in ipairs(partyOrder) do grantXP(id, 500); giveGold(id, 200) end end, damageRandom(2,"rowdy celebration"), 95),
        Option("Press onward to new mysteries", "map_room", rewardAll_xp(40), damageRandom(4,"new hazard"), 80)
    }
}

-- Many more nodes: create branching nodes for variety
nodes["shadow_city"] = {
    id = "shadow_city",
    title = "Shadow City",
    desc = "A city of dusk and bargains; alleyways hide power and prisoners.",
    options = {
        Option("Free a captive (moral choice)", "freed_captive", rewardAll_xp(80), damageRandom(6,"trap"), 70),
        Option("Seek forbidden knowledge", "forbidden_library", rewardRandomLoot(), trapAll(18,"mind rot"), 40),
        Option("Turn a blind eye and pick pockets", "pick_pockets", rewardRandomLoot(), loseItemRandom(), 60)
    }
}

nodes["celestial_gate"] = {
    id = "celestial_gate",
    title = "Celestial Gate",
    desc = "A shimmering gate that opens to other planes. You can step through (high risk), close it, or gather knowledge.",
    options = {
        Option("Step through to the Astral (epic)", "astral_plane", rewardAll_xp(500), trapAll(50,"planar backlash"), 40),
        Option("Study the gate and learn", "gate_lore", rewardAll_xp(120), damageRandom(8,"planar residue"), 70),
        Option("Seal the gate (heroic)", "seal_gate", rewardAll_xp(200), trapAll(20,"seal burns"), 60)
    }
}

-- Small endings and loops
nodes["celebration"] = {
    id = "celebration",
    title = "Celebration",
    desc = "The town celebrates you. Adventure ends — or you can return to the crossroads to keep going.",
    options = {
        Option("Return to Crossroads for new run", "crossroads", rewardAll_xp(20), damageRandom(1,"hangover"), 95),
        Option("End the campaign with glory", nil, function() adventureRunning=false; SafeChat("🏆 Adventure complete!") end, nil, 100)
    }
}

-- Add many smaller unique nodes (exploration, puzzles, social)
local function addMiniNode(id, title, desc, choices)
    nodes[id] = { id = id, title = title, desc = desc, options = choices }
end

addMiniNode("ruined_observatory", "Ruined Observatory", "A ruined observatory with star charts and a broken telescope.",
    {
        Option("Fix the telescope for a view of the stars", "star_view", rewardRandomLoot(), damageRandom(3,"falling debris"), 70),
        Option("Search the star charts for a clue", "star_clue", rewardAll_xp(30), damageRandom(2,"dust allergy"), 85)
    })

addMiniNode("star_view", "Star View", "You see a constellation map pointing to a hidden tomb.",
    {
        Option("Follow the constellation clue", "hidden_tomb", rewardRandomLoot(), trapAll(12,"tomb collapse"), 65),
        Option("Ignore and map the sky", "ancient_map", rewardAll_xp(20), damageRandom(1,"small mishap"), 90)
    })

addMiniNode("hidden_tomb", "Hidden Tomb", "A tomb of a forgotten king — curses and riches lie inside.",
    {
        Option("Take the king's crown", "cursed_crown", rewardRandomLoot(), trapAll(18,"royal curse"), 45),
        Option("Respect the tomb and leave", "forest_exit", rewardAll_xp(15), damageRandom(1,"trap dust"), 95)
    })

addMiniNode("ancient_library", "Ancient Library", "Shelves of knowledge. You may read rare tomes, copy spells, or be found by librarians.",
    {
        Option("Copy a spell (learn spell)", "learn_spell", function() for _,id in ipairs(partyOrder) do addItem(id, {Key="scroll_magic", Name="Scroll of Wisdom", Type="scroll"}) end end, trapAll(8,"magical burst"), 60),
        Option("Barter for rare knowledge", "barter_library", rewardRandomLoot(), loseItemRandom(), 75),
        Option("Leave quietly", "crossroads", rewardAll_xp(10), damageRandom(1,"shelf fall"), 95)
    })

addMiniNode("haunted_manor", "Haunted Manor", "Creaking floorboards and whispering portraits. The manor tests courage.",
    {
        Option("Investigate the basement", "manor_basement", rewardRandomLoot(), trapAll(12,"ghost grasp"), 60),
        Option("Speak to the portrait", "portrait_riddle", rewardAll_xp(30), damageRandom(3,"scare"), 75),
        Option("Burn old tapestries for warmth", "burn_tapestry", rewardRandomLoot(), loseItemRandom(), 50)
    })

addMiniNode("labyrinth", "Labyrinth", "A twisting maze full of illusions and shifting walls.",
    {
        Option("Mark your path and press on", "labyrinth_center", rewardRandomLoot(), trapAll(10,"lost time"), 65),
        Option("Call out to the maze spirit", "maze_spirit", rewardAll_xp(40), damageRandom(5,"spirit backlash"), 55)
    })

addMiniNode("gladiator_arena", "Gladiator Arena", "Crowds cheer; fights for fame. You can fight, bribe, or gamble.",
    {
        Option("Enter the arena", "arena_fight", rewardRandomLoot(), damageRandom(20,"injuries"), 50),
        Option("Place a bet", "betting", rewardRandomLoot(), loseItemRandom(), 65),
        Option("Bribe the referee for favored pairing", "arena_bribe", rewardRandomLoot(), loseItemRandom(), 40)
    })

addMiniNode("sewers", "Sewers", "Dark tunnels below the city; strange creatures and lost trinkets.",
    {
        Option("Follow squeaking", "rat_den", rewardRandomLoot(), trapAll(9,"disease"), 60),
        Option("Search for lost jewelry", "sewer_treasure", rewardRandomLoot(), damageRandom(3,"filth"), 80)
    })

addMiniNode("elemental_shrine", "Elemental Shrine", "Elemental altars test your element affinity.",
    {
        Option("Offer to the fire altar", "fire_test", rewardRandomLoot(), trapAll(12,"burn"), 60),
        Option("Offer to the water altar", "water_test", rewardRandomLoot(), trapAll(12,"drown"), 70),
        Option("Offer to the earth altar", "earth_test", rewardRandomLoot(), trapAll(12,"quake"), 70),
        Option("Offer to the air altar", "air_test", rewardRandomLoot(), trapAll(12,"gust"), 70)
    })

-- Add additional randomized nodes linking back to crossroads for replayability
for i=1,8 do
    local nid = "random_path_"..i
    nodes[nid] = {
        id = nid,
        title = "Winding Path "..i,
        desc = "A short wandering path with small surprises.",
        options = {
            Option("Find a hidden cache", "crossroads", rewardRandomLoot(), damageRandom(2,"thorns"), 80),
            Option("Encounter a traveling bard", "crossroads", rewardAll_xp(10), loseItemRandom(), 85),
            Option("Get lost then find your way back", "crossroads", rewardAll_xp(5), damageRandom(1,"lost"), 90),
        }
    }
end

-- =====================================================
-- Voting system (chat-driven)
-- =====================================================
local function announceVote(vote)
    local pieces = {}
    for i,opt in ipairs(vote.options) do table.insert(pieces, ("[%s] %s"):format(string.char(64+i), opt)) end
    SafeChat("🗳️ Vote: "..vote.title)
    SafeChat("Options: "..table.concat(pieces, " | "))
    SafeChat("Vote by chat: "..CONFIG.VOTE_PREFIX.." <letter|number> OR single-letter while voting. Voting ends in "..math.max(0, math.floor(vote.endsAt - tick())).."s.")
end

local function startVote(title, optionTexts, duration, eligibleList, onComplete)
    if currentVote then
        SafeChat("⚠️ A vote is already active. GM can force via !force <n>.")
        return nil
    end
    duration = duration or CONFIG.VOTE_DURATION
    local v = { id = "V"..tostring(math.random(100000,999999)), title = title, options = optionTexts, counts = {}, votes = {}, eligible = {}, endsAt = tick() + duration, onComplete = onComplete }
    for i=1,#optionTexts do v.counts[i] = 0 end
    if eligibleList and #eligibleList > 0 then for _, id in ipairs(eligibleList) do v.eligible[id] = true end else for _, id in ipairs(partyOrder) do v.eligible[id] = true end end
    currentVote = v
    announceVote(v)
    appendLog("Vote started: "..title)
    spawn(function()
        while currentVote == v and tick() < v.endsAt do wait(0.5) end
        if currentVote ~= v then return end
        local highest = -1
        for i=1,#v.options do highest = math.max(highest, v.counts[i] or 0) end
        local top = {}
        for i=1,#v.options do if (v.counts[i] or 0) == highest then table.insert(top, i) end end
        local choiceIndex = (#top == 0) and 1 or top[math.random(1,#top)]
        SafeChat("🗳️ Vote ended: ["..string.char(64+choiceIndex).."] "..v.options[choiceIndex].." ("..(v.counts[choiceIndex] or 0).." votes)")
        appendLog("Vote ended: "..v.title.." -> "..v.options[choiceIndex])
        if v.onComplete then pcall(v.onComplete, choiceIndex, v.counts) end
        currentVote = nil
    end)
    return v
end

local function recordVote(player, rawChoice)
    if not currentVote then return false, "No active vote" end
    if not currentVote.eligible[player.UserId] then return false, "Not eligible to vote" end
    local s = tostring(rawChoice):gsub("^%s*(.-)%s*$","%1")
    if s:lower():sub(1,#CONFIG.VOTE_PREFIX) == CONFIG.VOTE_PREFIX then s = s:sub(#CONFIG.VOTE_PREFIX+1):gsub("^%s*(.-)%s*$","%1") end
    local idx = nil
    local n = tonumber(s)
    if n and n >= 1 and n <= #currentVote.options then idx = n end
    if not idx then
        local letter = s:match("^%a$") or s:match("([A-Za-z])")
        if letter then
            local code = string.byte(letter:upper()) - 64
            if code >= 1 and code <= #currentVote.options then idx = code end
        end
    end
    if not idx then return false, "Unrecognized vote" end
    local prev = currentVote.votes[player.UserId]
    if prev then currentVote.counts[prev] = math.max(0,(currentVote.counts[prev] or 1) - 1) end
    currentVote.votes[player.UserId] = idx
    currentVote.counts[idx] = (currentVote.counts[idx] or 0) + 1
    appendLog(player.DisplayName.." voted for "..currentVote.options[idx])
    -- early finish if all eligible voted
    local totalEligible, totalVotes = 0,0
    for id,_ in pairs(currentVote.eligible) do totalEligible = totalEligible + 1 end
    for uid,_ in pairs(currentVote.votes) do totalVotes = totalVotes + 1 end
    if totalVotes >= totalEligible then
        local highest = -1; local top = {}
        for i=1,#currentVote.options do highest = math.max(highest, currentVote.counts[i] or 0) end
        for i=1,#currentVote.options do if (currentVote.counts[i] or 0) == highest then table.insert(top, i) end end
        local chosen = top[math.random(1,#top)]
        SafeChat("🗳️ All votes in. Result: ["..string.char(64+chosen).."] "..currentVote.options[chosen].." ("..(currentVote.counts[chosen] or 0).." votes)")
        if currentVote.onComplete then pcall(currentVote.onComplete, chosen, currentVote.counts) end
        currentVote = nil
    end
    return true
end

-- =====================================================
-- Node resolution (called after vote completes)
-- =====================================================
local function resolveOption(node, optIndex, voteCounts)
    local option = node.options[optIndex]
    if not option then SafeChat("Choice error: option missing"); return end
    local roll = math.random(1,100)
    local isGood = roll <= (option.chanceGood or 75)
    if isGood and option.good then
        pcall(option.good, {optionIndex=optIndex, voteCounts=voteCounts})
    elseif (not isGood) and option.bad then
        pcall(option.bad, {optionIndex=optIndex, voteCounts=voteCounts})
    else
        if isGood then
            local uid = partyOrder[math.random(1, math.max(1,#partyOrder))]
            grantXP(uid, CONFIG.BASE_XP_PER_GOOD)
            addItem(uid, randomLootForGoodChoice())
        else
            local alive = {}
            for _,uid in ipairs(partyOrder) do if party[uid] and party[uid].Alive then table.insert(alive, uid) end end
            if #alive > 0 then
                local uid = alive[math.random(1,#alive)]
                local amt = (roll % 6) + 1
                damagePlayer(uid, amt, "misfortune")
            end
        end
    end
    if option.next then
        currentNodeId = option.next
    else
        currentNodeId = nil
        adventureRunning = false
    end
    -- automatically present next node if still running
    if adventureRunning and currentNodeId then
        wait(1)
        presentNode(currentNodeId)
    end
end

function presentNode(nodeId)
    local node = nodes[nodeId]
    if not node then SafeChat("⚠️ Node not found: "..tostring(nodeId)); return end
    currentNodeId = nodeId
    if node.onEnter then pcall(node.onEnter) end
    SafeChat("📜 "..node.title)
    SafeChat(node.desc)
    local optionLabels = {}
    for _,opt in ipairs(node.options) do table.insert(optionLabels, opt.label) end
    if #optionLabels == 0 then adventureRunning = false; SafeChat("No choices here — adventure halts."); return end
    startVote(node.title, optionLabels, CONFIG.VOTE_DURATION, partyOrder, function(choiceIndex, counts)
        resolveOption(node, choiceIndex, counts)
    end)
end

-- =====================================================
-- Chat listening: votes & commands
-- =====================================================
local function getPlayerByName(name)
    if not name then return nil end
    name = name:lower()
    for _,p in ipairs(Players:GetPlayers()) do
        if p.Name:lower():sub(1,#name) == name or p.DisplayName:lower():sub(1,#name) == name then return p end
    end
    return nil
end

local function handleChat(player, message)
    if not player or not message then return end
    appendLog(player.DisplayName..": "..tostring(message))
    local txt = tostring(message)
    local lower = txt:lower()

    -- If vote active, try to record vote first (single-letter allowed)
    if currentVote then
        local ok, err = recordVote(player, txt)
        if ok then return end
        -- else continue to parse commands
    end

    -- Player commands
    if lower:match("^!join") then addPlayerToParty(player); return end
    if lower:match("^!leave") then removePlayerFromParty(player); return end
    if lower:match("^!status") then
        local c = party[player.UserId]
        if not c then SafeChat(player.DisplayName..", you are not in the party. Type !join to join.") else SafeChat(("Status %s | HP: %d/%d | Gold: %d | XP: %d | Items: %d"):format(c.DisplayName, c.HP, c.MaxHP, c.Gold, c.XP, #c.Inventory)) end
        return
    end
    if lower:match("^!roll%s+") then
        local notation = txt:match("^!roll%s+(.+)$")
        if notation then
            local r = rollDice(notation)
            SafeChat(("🎲 %s rolls %s -> %d"):format(player.DisplayName, notation, r))
        else
            SafeChat("Usage: !roll d20 or !roll 2d6+1")
        end
        return
    end

    -- GM commands
    if player.UserId == GM_USER_ID then
        if lower:match("^!start") then
            if adventureRunning then SafeChat("Adventure already running.") return end
            adventureRunning = true
            if not currentNodeId then currentNodeId = "crossroads" end
            SafeChat("🏁 GM started the adventure.")
            presentNode(currentNodeId)
            return
        end
        if lower:match("^!end") then
            adventureRunning = false
            SafeChat("🏁 GM ended the adventure.")
            return
        end
        if lower:match("^!force%s+") then
            local num = tonumber(txt:match("^!force%s+(%d+)") or "") or (txt:match("^!force%s+([A-Za-z])") and string.byte(txt:match("^!force%s+([A-Za-z])"):upper())-64)
            if not currentVote then SafeChat("No active vote to force.") else
                if not num or num < 1 or num > #currentVote.options then SafeChat("Invalid option to force.") else
                    SafeChat("🛠️ GM forced vote to option ["..string.char(64+num).."] "..currentVote.options[num])
                    if currentVote.onComplete then pcall(currentVote.onComplete, num, currentVote.counts) end
                    currentVote = nil
                end
            end
            return
        end
        if lower:match("^!announce%s+") then
            local text = txt:match("^!announce%s+(.+)$")
            if text then SafeChat("📣 GM: "..text) end
            return
        end
    end

    -- explicit vote prefix (e.g. "!vote A")
    if lower:sub(1, #CONFIG.VOTE_PREFIX) == CONFIG.VOTE_PREFIX then
        local rest = txt:sub(#CONFIG.VOTE_PREFIX + 1)
        local ok, err = recordVote(player, rest)
        if ok then return end
    end
    -- otherwise ignore regular chat
end

-- Hook chat events robustly
if TextChatService and TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
    pcall(function()
        TextChatService.MessageReceived:Connect(function(textChatMessage)
            local src = textChatMessage.TextSource
            if not src then return end
            local p = Players:GetPlayerByUserId(src.UserId)
            if p then handleChat(p, textChatMessage.Text) end
        end)
    end)
else
    for _, p in ipairs(Players:GetPlayers()) do
        p.Chatted:Connect(function(msg) handleChat(p, msg) end)
    end
    Players.PlayerAdded:Connect(function(p) p.Chatted:Connect(function(msg) handleChat(p, msg) end) end)
end

-- Initial instructions
SafeChat("📜 D&D Chat Adventure (expanded) ready. GM runs this script. Players: type !join to join. When GM starts (!start), choices are announced and you vote using '!vote A' or simply 'A' while voting. GM can force with '!force <n>'.")

-- If in Studio, add LocalPlayer as test party
if RunService:IsStudio() then
    if #partyOrder == 0 then
        addPlayerToParty(LocalPlayer)
        SafeChat("Studio test: LocalPlayer added to party")
    end
end

-- End of script
