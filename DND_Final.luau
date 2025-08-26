-- Dungeon & Dragons - Choice Adventure (LocalScript)
-- Run this as the single GM (Dungeon Master). The script listens to all players' chat to collect votes and controls the entire adventure.
-- Players do NOT need this script. They vote via chat (e.g. "!vote A" or "A") and use !join to join the party.
-- Author: Generated for ilookaroundk (2025-08-26)

-- Features:
--  - Extensive branching adventure map (many choices: Castle, Road, Forest, Cave, Ruins, Village, Swamp, Tower, Mines, Harbor, etc.)
--  - Voting system: party members vote by chat or GM GUI; votes decide each choice for the party.
--  - Consequences: good choices give loot, XP, keys, gold, map fragments; bad choices cause traps, damage, loss of items, or encounters.
--  - Inventory, gold, XP, levels, HP for each party member (generated when they join).
--  - GUI for GM: view party, current node, live vote counts, start/force decisions, spawn random events, view logs, save/load.
--  - Save to file support when writefile/readfile exist.
--  - Chat commands: !join, !leave, !start, !end, !vote <A|1>, !action <text>, !status, !roll <notation>, !save, !load
--  - All choice resolution is controlled by votes collected from party members via chat.

-- NOTE: This is a LocalScript intended to be run by the GM only.

-- Services
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

-- ----------------------------
-- Config / State
-- ----------------------------
local CONFIG = {
    VOTE_PREFIX = "!vote",
    VOTE_ACCEPT_SINGLE_LETTER = true,
    VOTE_DURATION = 20,
    STARTING_GOLD = 10,
    BASE_HP = 12,
    BASE_XP_PER_GOOD = 30,
    SAVE_FILE = "dd_adventure_save.json",
    ALLOW_SAVE = (type(writefile) == "function" and type(readfile) == "function"),
    RAILSAFE = true,
    MAX_OPTION_LABELS = 12,
    DIALOGUE_READ_TIME = 3,
}

local gmUserId = LocalPlayer.2570901688 -- the script runner is the GM
local party = {} -- map userId -> character table
local partyOrder = {} -- insertion order (used for display)
local currentNodeId = nil
local adventureRunning = false
local nodes = {} -- adventure nodes
local monsters = {} -- used only for flavor (encounters result in damage)
local currentVote = nil -- active vote object
local messageLog = {} -- recent messages for DM GUI
local gui = {} -- GUI elements (set when UI created)

-- ----------------------------
-- Utility functions
-- ----------------------------
local function notify(title, text, duration)
    StarterGui:SetCore("SendNotification", {
        Title = title or "Adventure",
        Text = text or "",
        Duration = duration or 5
    })
end

local function Chat(msg)
    -- Send chat robustly
    if TextChatService and TextChatService.TextChannels and TextChatService.TextChannels:FindFirstChild("RBXGeneral") then
        pcall(function() TextChatService.TextChannels.RBXGeneral:SendAsync(msg) end)
    else
        pcall(function() ReplicatedStorage.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(msg, "All") end)
    end
end

local function clamp(n, a, b) return math.max(a, math.min(b, n)) end
local function round(n) return math.floor(n + 0.5) end

local function rollDice(notation)
    if type(notation) ~= "string" then return tonumber(notation) or 0 end
    local c, s, sign, m = notation:match("^(%d*)[dD](%d+)([%+%-]?)(%d*)$")
    if not s then
        local n = tonumber(notation)
        return n or 0
    end
    c = tonumber(c) or 1
    s = tonumber(s)
    m = tonumber(m) or 0
    if sign == "-" then m = -m end
    local total = 0
    for i = 1, c do total = total + math.random(1, s) end
    return total + m
end

local function d20() return rollDice("d20") end

-- ----------------------------
-- Persistence
-- ----------------------------
local function canSave()
    return CONFIG.ALLOW_SAVE
end

local function saveGame()
    if not canSave() then
        notify("Save failed", "Save functions are unavailable in this environment.")
        return false
    end
    local data = {
        party = party,
        partyOrder = partyOrder,
        currentNodeId = currentNodeId,
        adventureRunning = adventureRunning,
        messageLog = messageLog
    }
    local ok, encoded = pcall(function() return game:GetService("HttpService"):JSONEncode(data) end)
    if not ok then
        notify("Save failed", "Encoding error.")
        return false
    end
    pcall(function() writefile(CONFIG.SAVE_FILE, encoded) end)
    notify("Saved", "Adventure saved to "..CONFIG.SAVE_FILE)
    return true
end

local function loadGame()
    if not canSave() then
        notify("Load failed", "Load functions are unavailable in this environment.")
        return false
    end
    if not isfile(CONFIG.SAVE_FILE) then
        notify("Load failed", "No save file found.")
        return false
    end
    local ok, content = pcall(function() return readfile(CONFIG.SAVE_FILE) end)
    if not ok then notify("Load failed", "Readfile error"); return false end
    local ok2, decoded = pcall(function() return game:GetService("HttpService"):JSONDecode(content) end)
    if not ok2 then notify("Load failed", "Decode error"); return false end
    party = decoded.party or {}
    partyOrder = decoded.partyOrder or {}
    currentNodeId = decoded.currentNodeId
    adventureRunning = decoded.adventureRunning or false
    messageLog = decoded.messageLog or {}
    notify("Loaded", "Save loaded. Use GUI to resume.")
    updateAllUI()
    return true
end

-- ----------------------------
-- Party management
-- ----------------------------
local function makeCharacterTemplate(player)
    local tpl = {}
    tpl.UserId = player.UserId
    tpl.Name = player.Name
    tpl.DisplayName = player.DisplayName
    tpl.Level = 1
    tpl.XP = 0
    tpl.Gold = CONFIG.STARTING_GOLD
    tpl.MaxHP = CONFIG.BASE_HP + math.random(1,6)
    tpl.HP = tpl.MaxHP
    tpl.Inventory = {} -- list of item tables: {Key, Name, Type, Data}
    tpl.Keys = {} -- special keys
    tpl.MapFragments = 0
    tpl.Alive = true
    return tpl
end

local function addPlayerToParty(player)
    if not player then return false, "No player" end
    if party[player.UserId] then return false, "Already in party" end
    party[player.UserId] = makeCharacterTemplate(player)
    table.insert(partyOrder, player.UserId)
    Chat("🧭 "..player.DisplayName.." joined the expedition! (Type !status to check your condition)")
    updateAllUI()
    return true
end

local function removePlayerFromParty(player)
    if not player then return false, "No player" end
    if not party[player.UserId] then return false, "Not in party" end
    party[player.UserId] = nil
    for i,id in ipairs(partyOrder) do if id == player.UserId then table.remove(partyOrder, i); break end end
    Chat("⛔ "..player.DisplayName.." left the expedition.")
    updateAllUI()
    return true
end

local function grantXP(userId, xp)
    local char = party[userId]
    if not char then return end
    char.XP = char.XP + xp
    Chat("✨ "..char.DisplayName.." gains "..xp.." XP!")
end

local function giveGold(userId, amount)
    local char = party[userId]
    if not char then return end
    char.Gold = (char.Gold or 0) + amount
    Chat("💰 "..char.DisplayName.." found "..amount.." gold (total "..char.Gold..")")
end

local function addItem(userId, item)
    local char = party[userId]
    if not char then return end
    table.insert(char.Inventory, item)
    Chat("🎁 "..char.DisplayName.." obtained: "..item.Name)
end

local function damagePlayer(userId, amount, reason)
    local char = party[userId]
    if not char or not char.Alive then return end
    char.HP = char.HP - amount
    Chat("⚠️ "..char.DisplayName.." takes "..amount.." damage ("..(reason or "injury").."). HP: "..math.max(0,char.HP).."/"..char.MaxHP)
    if char.HP <= 0 then
        char.Alive = false
        Chat("☠️ "..char.DisplayName.." has fallen unconscious!")
    end
end

local function healPlayer(userId, amount)
    local char = party[userId]
    if not char then return end
    char.HP = math.min(char.MaxHP, char.HP + amount)
    Chat("❤ "..char.DisplayName.." healed "..amount.." HP. ("..char.HP.."/"..char.MaxHP..")")
end

-- ----------------------------
-- Items / Loot templates
-- ----------------------------
local LootTemplates = {
    {Key="gold_small", Name="Small Pouch of Gold", Type="gold", Amount=rand and rand(5,20) or nil}, -- Amount set dynamically
    {Key="potion_heal", Name="Healing Potion", Type="consumable", Heal="1d8+2"},
    {Key="gem_ruby", Name="Ruby Gem", Type="treasure", Value=100},
    {Key="map_frag", Name="Map Fragment", Type="map", Fragments=1},
    {Key="mystic_key", Name="Mysterious Key", Type="key"},
    {Key="torch", Name="Torch", Type="utility"},
    {Key="old_scroll", Name="Old Scroll", Type="lore"},
    {Key="rope", Name="Rope (50ft)", Type="utility"},
    {Key="silver_ring", Name="Silver Ring", Type="treasure", Value=25},
}

local function randomLootForGoodChoice()
    local roll = math.random(1,100)
    if roll <= 40 then
        return {Key="gold", Name="Gold Coins", Type="gold", Amount=math.random(5,40)}
    elseif roll <= 60 then
        return {Key="potion_heal", Name="Healing Potion", Type="consumable", Heal="1d8+2"}
    elseif roll <= 75 then
        return {Key="gem", Name="Gemstone", Type="treasure", Value=math.random(20,150)}
    elseif roll <= 90 then
        return {Key="map_frag", Name="Map Fragment", Type="map", Fragments=1}
    else
        return {Key="key_mystic", Name="Mysterious Key", Type="key"}
    end
end

-- ----------------------------
-- Adventure nodes
-- ----------------------------
-- Node structure:
-- nodes[nodeId] = {
--   id = nodeId,
--   title = "Title",
--   desc = "Long description shown to party",
--   options = { {label="Go to Castle", next="castle_gate", goodChance=80, goodConsequence=function(context) ... end, badConsequence=function(context) ... end, note="flavor"} , ... },
--   onEnter = function(context) end, -- optional
--   autoResolve = false, -- if true, no vote, resolve automatically
-- }
-- Consequence functions receive context = {chosenOptionIndex, voters = {uid=choice,...}}
-- For simplicity, we'll implement consequence objects rather than functions for many nodes.

nodes = {}

-- Utility helper to create option
local function Option(label, nextNode, goodEffect, badEffect, chanceGood, note)
    return {
        label = label,
        next = nextNode,
        chanceGood = chanceGood or 75, -- percentage chance that choice is a "good" route (lower -> more risk)
        good = goodEffect,
        bad = badEffect,
        note = note
    }
end

-- Consequence helpers: return functions that apply effects to party members or single random member
local function rewardAll_gold(amount)
    return function(context)
        for _, uid in ipairs(partyOrder) do
            if party[uid] then giveGold(uid, amount) end
        end
    end
end
local function rewardRandomLoot()
    return function(context)
        local uid = partyOrder[math.random(1, math.max(1,#partyOrder))]
        local item = randomLootForGoodChoice()
        if item.Type == "gold" then giveGold(uid, item.Amount) else addItem(uid, item) end
    end
end
local function rewardAll_xp(amount)
    return function(context)
        for _, uid in ipairs(partyOrder) do if party[uid] then grantXP(uid, amount) end end
    end
end
local function damageRandom(amount, reason)
    return function(context)
        local alive = {}
        for _, uid in ipairs(partyOrder) do if party[uid] and party[uid].Alive then table.insert(alive, uid) end end
        if #alive == 0 then return end
        local uid = alive[math.random(1,#alive)]
        damagePlayer(uid, amount, reason)
    end
end
local function trapAll(amount, reason)
    return function(context)
        for _, uid in ipairs(partyOrder) do if party[uid] and party[uid].Alive then damagePlayer(uid, amount, reason) end end
    end
end
local function loseItemRandom()
    return function(context)
        local candidates = {}
        for _, uid in ipairs(partyOrder) do
            local char = party[uid]
            if char and #char.Inventory > 0 then table.insert(candidates, uid) end
        end
        if #candidates == 0 then return end
        local uid = candidates[math.random(1,#candidates)]
        local char = party[uid]
        local idx = math.random(1,#char.Inventory)
        local removed = table.remove(char.Inventory, idx)
        Chat("🗑️ "..char.DisplayName.." lost a(n) "..(removed and removed.Name or "item").." due to misfortune.")
    end
end

-- Build the node graph (many choices)
-- Start node
nodes["crossroads"] = {
    id = "crossroads",
    title = "Crossroads",
    desc = "You stand at a weathered crossroads. A wooden sign points in several directions: Castle (north), Road (east), Forest (west), and River (south). The air smells of rain and old magic.",
    options = {
        Option("Head to the Castle (north)", "castle_gate",
            rewardAll_xp(CONFIG.BASE_XP_PER_GOOD), damageRandom(6, "barbed gate trap"), 85, "A bold route toward power"),
        Option("Follow the Road (east)", "long_road",
            rewardRandomLoot(), damageRandom(4, "thug ambush"), 80, "Safer, but less treasure"),
        Option("Venture into the Forest (west)", "ancient_forest",
            rewardAll_xp(CONFIG.BASE_XP_PER_GOOD + 10), trapAll(3, "hidden thorns"), 70, "Mysterious, rife with secrets"),
        Option("Walk to the River (south)", "riverside",
            rewardRandomLoot(), damageRandom(5, "slip and cut"), 75, "Waterside with fishing and dangers"),
        Option("Ask the locals at the nearby Village", "village",
            rewardAll_xp(10), loseItemRandom(), 90, "People can give guidance"),
    },
    onEnter = function()
        Chat("📍 Crossroads: The party may choose where to go. Vote to decide.")
    end
}

nodes["castle_gate"] = {
    id = "castle_gate",
    title = "Castle Gate",
    desc = "A looming castle stands behind massive iron gates. Guards are absent, but the gate is barred and the portcullis looks unstable. To the left is a small servants' entrance; to the right a narrow ladder leads to the battlements.",
    options = {
        Option("Try the main gate (push it open)", "great_hall",
            rewardAll_xp(40), damageRandom(10, "collapsing portcullis"), 70, "Strength may work"),
        Option("Sneak through the servants' entrance", "service_tunnel",
            rewardRandomLoot(), damageRandom(6, "squeezing in - suffocation"), 80, "Stealthy approach"),
        Option("Climb the ladder to the battlements", "battlements",
            rewardAll_xp(30), trapAll(5, "fall from ladder"), 65, "A risky vantage"),
        Option("Leave and scout the walls instead", "castle_walls", rewardAll_xp(20), damageRandom(4, "sharp spike"), 85, "Scout for a safer entry"),
    }
}

nodes["long_road"] = {
    id = "long_road",
    title = "Long Road",
    desc = "The road stretches for miles. You meet a traveling merchant, a broken cart, and a suspicious pair of travelers. Choices: bargain, help the cart, or follow the pair.",
    options = {
        Option("Bargain with the merchant", "merchant_deal",
            rewardRandomLoot(), loseItemRandom(), 80, "Deals may yield goods"),
        Option("Help fix the cart", "fix_cart",
            rewardAll_xp(20), damageRandom(3, "pinched by wheel"), 90, "Goodwill rewards"),
        Option("Follow the suspicious pair", "ambush_point",
            rewardRandomLoot(), damageRandom(8, "bandit ambush"), 55, "Could be riches... or danger"),
    }
}

nodes["ancient_forest"] = {
    id = "ancient_forest",
    title = "Ancient Forest",
    desc = "Old trees whisper. You find a circle of stones, a hidden cottage, and faint glyphs on the roots.",
    options = {
        Option("Investigate the stone circle", "stone_circle",
            rewardAll_xp(50), trapAll(6, "arcane backlash"), 65, "Power hums in the air"),
        Option("Knock on the cottage door", "cottage",
            rewardRandomLoot(), damageRandom(2, "angry badger"), 85, "A hermit may help"),
        Option("Trace the glyphs deeper", "glyph_path",
            rewardAll_xp(30), damageRandom(7, "cursed roots"), 60, "Runes lead onward"),
    }
}

nodes["riverside"] = {
    id = "riverside",
    title = "Riverside",
    desc = "The river's edge glitters. Fishermen call out, a bridge crosses to an old tower, and a sunken boat is half-visible.",
    options = {
        Option("Investigate the sunken boat", "sunken_boat",
            rewardRandomLoot(), trapAll(4, "water trap - drowning"), 70, "Salvage wait"),
        Option("Cross the old bridge", "ruined_bridge",
            rewardRandomLoot(), damageRandom(6, "bridge collapse"), 65, "A shaky path"),
        Option("Visit the tower across the river", "river_tower",
            rewardAll_xp(25), damageRandom(5, "tower collapse"), 75, "A view reveals secrets"),
    }
}

nodes["village"] = {
    id = "village",
    title = "Village",
    desc = "A quaint village. The inn offers rest, a blacksmith can craft, and a notice board holds rumors.",
    options = {
        Option("Rest at the inn (recover HP)", "inn_rest",
            function(ctx) for _,id in ipairs(partyOrder) do healPlayer(id, math.random(4,10)) end end,
            damageRandom(2, "drunken brawl"), 90, "Comfort for the weary"),
        Option("Ask the blacksmith for upgrades", "blacksmith",
            function(ctx) for _,id in ipairs(partyOrder) do addItem(id, {Key="armband", Name="Sturdy Armband", Type="gear"}) end end,
            loseItemRandom(), 80, "New gear could help"),
        Option("Read the notice board", "notice_board",
            rewardAll_xp(15), damageRandom(1, "misinformation leads to a small mishap"), 95, "Rumors abound"),
    }
}

nodes["great_hall"] = {
    id = "great_hall",
    title = "Great Hall",
    desc = "You enter a grand hall with banners. A hushed voice invites you to an audience with the lord. A chest sits under a tapestry.",
    options = {
        Option("Accept the audience", "audience",
            rewardAll_xp(50), damageRandom(5, "lord's suspicion"), 80, "A chance for favor"),
        Option("Open the chest quietly", "tapestry_chest",
            rewardRandomLoot(), trapAll(8, "needle trap"), 60, "Greed can be dangerous"),
        Option("Search the hall for clues", "hall_search",
            rewardAll_xp(25), damageRandom(3, "loose tile"), 85, "Clues to the castle's story"),
    }
}

-- add many more nodes to enrich adventure

nodes["service_tunnel"] = {
    id = "service_tunnel",
    title = "Service Tunnel",
    desc = "A cramped tunnel smells of old oil. You see a locked door and a grate that leads downward.",
    options = {
        Option("Pick the lock", "cellar", rewardRandomLoot(), damageRandom(4, "lock snaps and slashes"), 75, "Quiet entry"),
        Option("Drop through the grate (down)", "dungeon_entrance", rewardAll_xp(35), trapAll(10, "spiked pit"), 60, "Brave or foolish"),
        Option("Retreat and try another way", "castle_walls", rewardAll_xp(10), damageRandom(2, "slippery retreat"), 90, "Safety first"),
    }
}

nodes["battlements"] = {
    id = "battlements",
    title = "Battlements",
    desc = "From the battlements you see a sprawling landscape and a glint in a distant tower.",
    options = {
        Option("Signal to a friendly face below", "friendly_watch", rewardAll_xp(20), damageRandom(3, "misfired signal startles guards"), 80, "Allies might notice"),
        Option("Leap across to another wall (risky)", "wall_leap", rewardRandomLoot(), damageRandom(10, "failed leap"), 50, "A dangerous acrobatic choice"),
        Option("Climb down the drainpipe", "kitchen", rewardRandomLoot(), damageRandom(3, "burn from kitchen fire"), 85, "Stealthy descent"),
    }
}

nodes["castle_walls"] = {
    id = "castle_walls",
    title = "Castle Walls",
    desc = "You explore the perimeter and find a hidden key, loose stones, and a watchtower access rope.",
    options = {
        Option("Search the loose stones", "hidden_key", rewardRandomLoot(), damageRandom(2, "collapse"), 80, "A hidden key might help"),
        Option("Climb the watchtower rope", "watchtower", rewardAll_xp(20), damageRandom(6, "rope snaps"), 70, "High vantage"),
        Option("Use the key on the servants' door", "service_tunnel", rewardAll_xp(15), damageRandom(4, "wrong key triggers trap"), 85, "Use what you find"),
    }
}

nodes["stone_circle"] = {
    id = "stone_circle",
    title = "Stone Circle",
    desc = "Moss-covered stones hum. A glyph offers a choice: speak the word of opening or leave the stones untouched.",
    options = {
        Option("Speak the ancient word", "fey_offer",
            function() for _,id in ipairs(partyOrder) do grantXP(id, 60); addItem(id, {Key="fey_seed", Name="Fey Seed", Type="special"}) end end,
            damageRandom(12, "arcane backlash"), 60, "Magic answers risk with reward"),
        Option("Leave silently", "forest_path", rewardAll_xp(10), damageRandom(1, "stumble on root"), 95, "Caution keeps you safe"),
    }
}

nodes["cottage"] = {
    id = "cottage",
    title = "Cottage",
    desc = "A kindly hermit offers tea, and a small puzzle to find a herb or a riddle for a reward.",
    options = {
        Option("Solve the hermit's riddle", "hermit_reward", rewardRandomLoot(), damageRandom(2,"poisonous herb"), 75, "Brains over brawn"),
        Option("Search around the cottage", "hermit_garden", rewardAll_xp(20), trapAll(3,"thorns"), 85, "Look for helpful herbs"),
    }
}

nodes["glyph_path"] = {
    id = "glyph_path",
    title = "Glyph Path",
    desc = "The path glows as you follow glyphs to a weathered altar.",
    options = {
        Option("Pray at the altar", "altar_boon", rewardAll_xp(50), trapAll(8,"sudden surge"), 65, "Faith may reward"),
        Option("Take a map from the altar", "ancient_map", rewardRandomLoot(), damageRandom(3,"trap dust"), 75, "Tools for navigation"),
    }
}

nodes["merchant_deal"] = {
    id = "merchant_deal",
    title = "Merchant Deal",
    desc = "A merchant offers a mysterious box for a bargain price or a trade.",
    options = {
        Option("Buy the mysterious box", "mystery_box", rewardRandomLoot(), loseItemRandom(), 60, "Risky purchase"),
        Option("Haggle for a discount", "haggled_price", rewardAll_xp(15), damageRandom(1,"rude insult"), 85, "Negotiation can pay"),
    }
}

nodes["fix_cart"] = {
    id = "fix_cart",
    title = "Fix Cart",
    desc = "You help rebuild a broken axle. The grateful cart-owner offers a reward.",
    options = {
        Option("Help the cart", "cart_reward", rewardAll_xp(25), damageRandom(2,"pinched hand"), 95, "Kindness brings reward"),
        Option("Take the damaged cart for spare parts", "cart_spares", rewardRandomLoot(), damageRandom(4,"collapsing axle"), 70, "Scavenging risky but useful"),
    }
}

-- A few more nodes for variety
nodes["ambush_point"] = {
    id = "ambush_point",
    title = "Ambush Point",
    desc = "Following the suspicious pair leads to a clearing. The party is surrounded by bandits. You can bluff, fight, or flee.",
    options = {
        Option("Bluff your way out", "bluff_success", rewardAll_xp(35), damageRandom(8,"bluff fails - stabbed"), 50, "A risky talk"),
        Option("Run away", "flee_route", rewardAll_xp(10), damageRandom(6,"chase wounds"), 70, "Speed vs safety"),
        Option("Try to negotiate", "negotiate", rewardRandomLoot(), damageRandom(3,"insult"), 80, "Words may work"),
    }
}

nodes["sunken_boat"] = {
    id = "sunken_boat",
    title = "Sunken Boat",
    desc = "You dive into the boat's hold. Trapped inside are old chests and a sleeping something that stirs.",
    options = {
        Option("Take the small chest", "boat_chest", rewardRandomLoot(), trapAll(7,"underwater crush"), 60, "Treasure underwater"),
        Option("Leave it to rest", "river_walk", rewardAll_xp(10), damageRandom(2,"splash"), 95, "Respect avoids trouble"),
    }
}

nodes["ruined_bridge"] = {
    id = "ruined_bridge",
    title = "Ruined Bridge",
    desc = "The bridge creaks. Midway you notice a glittering on the far side and a missing plank near your feet.",
    options = {
        Option("Carefully cross the bridge", "bridge_crossed", rewardRandomLoot(), trapAll(9,"fall into river"), 60, "Balance is key"),
        Option("Search for a safer crossing downstream", "river_crossing", rewardAll_xp(20), damageRandom(1,"slip"), 85, "A longer path might be safer"),
    }
}

nodes["river_tower"] = {
    id = "river_tower",
    title = "River Tower",
    desc = "An old tower with chained bells. Inside you may find a bell-riddle or a hidden chest.",
    options = {
        Option("Ring the bell three times", "bell_riddle", rewardAll_xp(30), trapAll(5,"alarm sparks"), 75, "Strange tolls echo"),
        Option("Search the tower", "tower_search", rewardRandomLoot(), damageRandom(3,"loose stone"), 80, "Careful search"),
    }
}

nodes["inn_rest"] = {
    id = "inn_rest",
    title = "Inn Rest",
    desc = "A warm night at the inn restores the soul. But someone leaves their room suspiciously.",
    options = {
        Option("Take a full rest", "well_rest", function() for _,id in ipairs(partyOrder) do healPlayer(id, math.random(6,12)) end end, damageRandom(4,"bedbugs and thorns"), 95, "Rest is rejuvenating"),
        Option("Investigate suspicious corridor", "inn_mystery", rewardRandomLoot(), damageRandom(6,"caught in trapdoor"), 65, "Curiosity may pay"),
    }
}

nodes["blacksmith"] = {
    id = "blacksmith",
    title = "Blacksmith",
    desc = "The blacksmith offers to improve equipment if you help source ore or pay.",
    options = {
        Option("Pay for an upgrade", "smith_upgraded", rewardRandomLoot(), loseItemRandom(), 80, "Money simplifies things"),
        Option("Fetch ore for a trade", "mine_run", rewardAll_xp(30), damageRandom(6,"rockslide"), 75, "Work yields reward"),
    }
}

nodes["notice_board"] = {
    id = "notice_board",
    title = "Notice Board",
    desc = "Wanted posters, merchant requests, and odd rumors dot the board. A map piece flutters from a pin.",
    options = {
        Option("Collect the map piece", "map_piece", rewardRandomLoot(), damageRandom(2,"caught in string"), 90, "A small clue"),
        Option("Accept a job from a poster", "job_accepted", rewardAll_xp(40), damageRandom(7,"dangerous job"), 70, "Adventure awaits"),
    }
}

-- Add extra end or special nodes
nodes["hermit_reward"] = {
    id = "hermit_reward",
    title = "Hermit's Reward",
    desc = "The hermit smiles and offers a small boon: a potion or a secret direction.",
    options = {
        Option("Take the potion", "cottage_end", function() for _,id in ipairs(partyOrder) do addItem(id, {Key="potion_heal", Name="Healing Potion", Type="consumable", Heal="1d8+2"}) end, loseItemRandom(), 95, "A small boon"),
        Option("Ask for a secret direction", "secret_path", rewardAll_xp(40), damageRandom(1,"misguided hint"), 85, "Knowledge is valuable"),
    }
}

nodes["altar_boon"] = {
    id = "altar_boon",
    title = "Altar Boon",
    desc = "You receive a blessing that fortifies the party or a curse if you took too much.",
    options = {
        Option("Accept the boon", "blessing", function() for _,id in ipairs(partyOrder) do healPlayer(id, 4) end end, trapAll(10,"overdrawn boon"), 70, "Gifts from beyond"),
        Option("Leave offering and move on", "altar_leave", rewardAll_xp(20), damageRandom(2,"small backlash"), 90, "A token of respect"),
    }
}

nodes["mystery_box"] = {
    id = "mystery_box",
    title = "Mystery Box",
    desc = "The box hums. Inside could be treasure or a cursed relic.",
    options = {
        Option("Open the box", "box_opened", rewardRandomLoot(), trapAll(10,"cursed burst"), 55, "Be bold"),
        Option("Sell the box to the merchant", "box_sold", function() for _,id in ipairs(partyOrder) do giveGold(id, 15) end end, damageRandom(1,"scammed"), 85, "Practical choice"),
    }
}

-- Final nodes and many branching terminals
nodes["secret_path"] = {
    id = "secret_path",
    title = "Secret Path",
    desc = "A hidden path leads to an overgrown shrine with a chest sealed by a riddle.",
    options = {
        Option("Solve the riddle and open the chest", "shrine_open", rewardAll_xp(80), trapAll(12,"riddle trap"), 65, "Wit opens treasure"),
        Option("Leave the shrine intact", "forest_exit", rewardAll_xp(15), damageRandom(1,"poisonous moss"), 95, "Respect avoids curses"),
    }
}

nodes["shrine_open"] = {
    id = "shrine_open",
    title = "Shrine Opened",
    desc = "The chest yields an ancient relic and a map fragment.",
    options = {
        Option("Take relic and map", "map_room", function() for _,id in ipairs(partyOrder) do addItem(id, {Key="relic", Name="Ancient Relic", Type="relic"}); party[id].MapFragments = (party[id].MapFragments or 0) + 1 end, damageRandom(6,"curse latch"), 80, "Relics carry weight"),
    }
}

nodes["forest_exit"] = {
    id = "forest_exit",
    title = "Forest Edge",
    desc = "You exit the forest, wiser and perhaps richer.",
    options = {
        Option("Head back to Crossroads", "crossroads", rewardAll_xp(10), damageRandom(1,"scrape"), 95, "Cycle of travel"),
    }
}

-- Add more nodes to cover other earlier next targets...
nodes["dungeon_entrance"] = {
    id = "dungeon_entrance",
    title = "Dungeon Entrance",
    desc = "A yawning entrance leads below. Darkness and echo suggest riches and ruin.",
    options = {
        Option("Descend into the dungeon", "dark_hall", rewardRandomLoot(), trapAll(10,"spike corridor"), 60, "The undercroft waits"),
        Option("Set up camp and prepare", "camp_prepare", rewardAll_xp(20), damageRandom(2,"night frost"), 90, "Preparation reduces risk"),
    }
}

nodes["dark_hall"] = {
    id = "dark_hall",
    title = "Dark Hall",
    desc = "The hall is lined with doors. One has blood, another faint music, a third a warm glow.",
    options = {
        Option("Enter the bloody door", "blood_room", rewardRandomLoot(), trapAll(14,"blood trap"), 50, "Dangerous curiosity"),
        Option("Follow the music", "music_chamber", rewardAll_xp(40), damageRandom(4,"enchanted lull"), 70, "Beauty or snares"),
        Option("Investigate the warm glow", "glow_chamber", rewardRandomLoot(), damageRandom(6,"burning embers"), 75, "Warmth may be treasure"),
    }
}

-- A node for when choices close adventure or loop
nodes["map_room"] = {
    id = "map_room",
    title = "Map Room",
    desc = "You piece together map fragments. A new destination is revealed: The Lost Lighthouse.",
    options = {
        Option("Sail to the Lost Lighthouse", "lighthouse", rewardAll_xp(100), damageRandom(10,"storm"), 70, "A grand destination"),
        Option("Keep exploring local paths", "crossroads", rewardAll_xp(20), damageRandom(1,"minor mishap"), 95, "More small adventures"),
    }
}

nodes["lighthouse"] = {
    id = "lighthouse",
    title = "Lost Lighthouse",
    desc = "A tower battered by waves holds a beacon and a guardian puzzle.",
    options = {
        Option("Solve the beacon puzzle", "beacon_solved", rewardAll_xp(200), trapAll(20,"maelstrom"), 55, "High reward for wit"),
        Option("Loot the lower storerooms", "lighthouse_loot", rewardRandomLoot(), damageRandom(5,"stored explosives"), 75, "Quick plunder"),
    }
}

-- A small set of terminal nodes (endings)
nodes["beacon_solved"] = {
    id = "beacon_solved",
    title = "Beacon Restored",
    desc = "You restore the beacon. Ships thank you; your names are sung. A hero's finish!",
    options = {
        Option("Celebrate your fame", "celebration", function() for _,id in ipairs(partyOrder) do grantXP(id, 500); giveGold(id, 200) end end, damageRandom(2,"rowdy celebration"), 95, "You earned renown"),
    }
}

nodes["celebration"] = {
    id = "celebration",
    title = "Celebration",
    desc = "You celebrate and the adventure ends... for now.",
    options = {
        Option("Return to town and rest (end)", "end_victory", function() adventureRunning = false; Chat("🏆 Adventure complete! You win (for now).") end, nil, 100),
    }
}

nodes["end_victory"] = {
    id = "end_victory",
    title = "Adventure Complete",
    desc = "The party basks in victory. You may save your progress or start a new run.",
    options = {
        Option("Return to Crossroads (start new run)", "crossroads", function() adventureRunning=false end, nil, 100)
    }
}

-- ----------------------------
-- Voting system
-- ----------------------------
-- currentVote structure:
-- { id, title, options = {text...}, counts = {}, votes = {userId = index}, eligible = {userId->true}, endsAt, onComplete }

local function announceVote(vote)
    local list = {}
    for i,opt in ipairs(vote.options) do
        table.insert(list, ("[%s] %s"):format(string.char(64 + i), opt))
    end
    Chat("🗳️ Vote: "..vote.title)
    Chat("Options: "..table.concat(list, " | "))
    Chat("Vote by chat: "..CONFIG.VOTE_PREFIX.." <letter|number> OR by typing a single letter (A,B,C...) while voting is active. Voting ends in "..round(vote.endsAt - tick()).."s.")
end

local function startVote(title, optionTexts, duration, eligibleList, onComplete)
    if currentVote then
        Chat("⚠️ A vote is already running. Use GM GUI to force or wait for it to end.")
        return nil
    end
    duration = duration or CONFIG.VOTE_DURATION
    local v = {
        id = "V"..tostring(math.random(100000,999999)),
        title = title,
        options = optionTexts,
        counts = {},
        votes = {},
        eligible = {},
        endsAt = tick() + duration,
        onComplete = onComplete
    }
    for i=1,#optionTexts do v.counts[i] = 0 end
    if eligibleList and #eligibleList > 0 then
        for _, id in ipairs(eligibleList) do v.eligible[id] = true end
    else
        for _, id in ipairs(partyOrder) do v.eligible[id] = true end
    end
    currentVote = v
    announceVote(v)
    updateVoteUI()
    -- spawn a watcher to complete
    spawn(function()
        while currentVote == v and tick() < v.endsAt do
            wait(0.5)
        end
        if currentVote ~= v then return end
        -- Tally results and choose winner (random tie-break)
        local highest = -1
        for i=1,#v.options do highest = math.max(highest, v.counts[i] or 0) end
        local top = {}
        for i=1,#v.options do if (v.counts[i] or 0) == highest then table.insert(top, i) end end
        local choiceIndex
        if #top == 0 then choiceIndex = 1 else choiceIndex = top[math.random(1,#top)] end
        Chat("🗳️ Vote ended: ["..string.char(64 + choiceIndex).."] "..v.options[choiceIndex].." ("..(v.counts[choiceIndex] or 0).." votes)")
        if v.onComplete then pcall(v.onComplete, choiceIndex, v.counts) end
        currentVote = nil
        updateVoteUI()
    end)
    return v
end

local function recordVote(player, raw)
    if not currentVote then return false, "No active vote" end
    if not currentVote.eligible[player.UserId] then return false, "Not eligible to vote" end
    -- parse raw input: accept prefix "!vote X" or single-letter "A" or a number
    local s = tostring(raw)
    s = s:gsub("^%s*(.-)%s*$", "%1") -- trim
    if s:lower():sub(1, #CONFIG.VOTE_PREFIX) == CONFIG.VOTE_PREFIX then
        s = s:sub(#CONFIG.VOTE_PREFIX + 1)
        s = s:gsub("^%s*(.-)%s*$", "%1")
    end
    local idx = nil
    -- number
    local num = tonumber(s)
    if num and num >= 1 and num <= #currentVote.options then idx = num end
    if not idx then
        -- letter
        local letter = s:match("^%a$")
        if not letter then letter = s:match("([A-Za-z])") end
        if letter then
            local code = string.byte(letter:upper()) - 64
            if code >=1 and code <= #currentVote.options then idx = code end
        end
    end
    if not idx then return false, "Could not parse vote" end
    -- remove previous vote
    local prev = currentVote.votes[player.UserId]
    if prev then currentVote.counts[prev] = math.max(0, (currentVote.counts[prev] or 1) - 1) end
    currentVote.votes[player.UserId] = idx
    currentVote.counts[idx] = (currentVote.counts[idx] or 0) + 1
    updateVoteUI()
    -- check if all eligible voted -> early resolution
    local totalEligible = 0
    for id,_ in pairs(currentVote.eligible) do totalEligible = totalEligible + 1 end
    local totalVotes = 0
    for uid,_ in pairs(currentVote.votes) do totalVotes = totalVotes + 1 end
    if totalVotes >= totalEligible then
        -- compute winner early
        local highest = -1
        for i=1,#currentVote.options do highest = math.max(highest, currentVote.counts[i] or 0) end
        local top = {}
        for i=1,#currentVote.options do if (currentVote.counts[i] or 0) == highest then table.insert(top, i) end end
        local chosen = top[math.random(1,#top)]
        Chat("🗳️ All votes in. Result: ["..string.char(64 + chosen).."] "..currentVote.options[chosen].." ("..(currentVote.counts[chosen] or 0).." votes)")
        if currentVote.onComplete then pcall(currentVote.onComplete, chosen, currentVote.counts) end
        currentVote = nil
        updateVoteUI()
    end
    return true
end

-- ----------------------------
-- Node navigation/resolution
-- ----------------------------
local function resolveOption(node, optIndex, voteCounts)
    local option = node.options[optIndex]
    if not option then
        Chat("Choice resolution error: option not found")
        return
    end
    -- Determine if we got the "good" path based on chanceGood and a random roll
    local roll = math.random(1,100)
    local isGood = roll <= (option.chanceGood or 75)
    if isGood and option.good then
        pcall(option.good, {optionIndex=optIndex, voteCounts=voteCounts})
    elseif (not isGood) and option.bad then
        pcall(option.bad, {optionIndex=optIndex, voteCounts=voteCounts})
    else
        -- default effects
        if isGood then
            -- give small XP and possible item to a random party member
            local uid = partyOrder[math.random(1, math.max(1,#partyOrder))]
            grantXP(uid, CONFIG.BASE_XP_PER_GOOD)
            addItem(uid, randomLootForGoodChoice())
        else
            damageRandom(roll % 6 + 1)("resolution") -- call function to apply damage
        end
    end
    -- move to next node if defined
    if option.next then
        currentNodeId = option.next
    else
        currentNodeId = nil
        adventureRunning = false
    end
    updateAllUI()
end

local function presentNode(nodeId)
    local node = nodes[nodeId]
    if not node then
        Chat("⚠️ Node not found: "..tostring(nodeId))
        return
    end
    currentNodeId = nodeId
    if node.onEnter then pcall(node.onEnter) end
    Chat("📜 "..node.title)
    Chat(node.desc)
    -- list options and start a vote if not auto-resolve
    local optionsText = {}
    for i,opt in ipairs(node.options) do
        table.insert(optionsText, opt.label)
    end
    if #optionsText == 0 then
        Chat("No choices here. Adventure may end.")
        adventureRunning = false
        updateAllUI()
        return
    end
    -- start vote among party members
    startVote(node.title, optionsText, CONFIG.VOTE_DURATION, partyOrder, function(choiceIndex, counts)
        resolveOption(node, choiceIndex, counts)
    end)
    updateAllUI()
end

-- ----------------------------
-- GUI (GM-facing)
-- ----------------------------
local function createGui()
    local screen = Instance.new("ScreenGui")
    screen.Name = "DnDAdventureGUI"
    screen.ResetOnSpawn = false
    screen.Parent = LocalPlayer:WaitForChild("PlayerGui")
    gui.Root = screen

    local main = Instance.new("Frame", screen)
    main.Name = "Main"
    main.Size = UDim2.new(0,920,0,560)
    main.Position = UDim2.new(0.5,-460,0.5,-280)
    main.BackgroundColor3 = Color3.fromRGB(28,28,28)
    gui.Main = main

    local title = Instance.new("TextLabel", main)
    title.Size = UDim2.new(1,0,0,32)
    title.Position = UDim2.new(0,0,0,0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.SourceSansBold
    title.TextSize = 20
    title.TextColor3 = Color3.new(1,1,1)
    title.Text = "Dungeons & Dragons - Chat-Driven Adventure (GM)"

    -- Left: party
    local partyFrame = Instance.new("Frame", main)
    partyFrame.Size = UDim2.new(0,280,1,-60)
    partyFrame.Position = UDim2.new(0,10,0,50)
    partyFrame.BackgroundColor3 = Color3.fromRGB(22,22,22)
    gui.PartyFrame = partyFrame

    local partyTitle = Instance.new("TextLabel", partyFrame)
    partyTitle.Size = UDim2.new(1,0,0,24)
    partyTitle.Position = UDim2.new(0,0,0,0)
    partyTitle.BackgroundTransparency = 1
    partyTitle.Text = "Party (use chat '!join' to join)"
    partyTitle.Font = Enum.Font.SourceSansSemibold
    partyTitle.TextColor3 = Color3.new(1,1,1)

    local partyList = Instance.new("ScrollingFrame", partyFrame)
    partyList.Size = UDim2.new(1,-10,1,-40)
    partyList.Position = UDim2.new(0,5,0,30)
    partyList.BackgroundTransparency = 1
    partyList.ScrollBarThickness = 6
    gui.PartyList = partyList

    -- Center: node & vote
    local center = Instance.new("Frame", main)
    center.Size = UDim2.new(0,520,1,-60)
    center.Position = UDim2.new(0,300,0,50)
    center.BackgroundTransparency = 1
    gui.Center = center

    local nodeTitle = Instance.new("TextLabel", center)
    nodeTitle.Size = UDim2.new(1,0,0,28)
    nodeTitle.Position = UDim2.new(0,0,0,0)
    nodeTitle.BackgroundTransparency = 1
    nodeTitle.Font = Enum.Font.SourceSansBold
    nodeTitle.TextSize = 18
    nodeTitle.Text = "No active node"
    gui.NodeTitle = nodeTitle

    local nodeDesc = Instance.new("TextBox", center)
    nodeDesc.Size = UDim2.new(1,0,0,150)
    nodeDesc.Position = UDim2.new(0,0,0,32)
    nodeDesc.MultiLine = true
    nodeDesc.TextWrapped = true
    nodeDesc.Text = ""
    nodeDesc.ClearTextOnFocus = false
    nodeDesc.ReadOnly = true
    nodeDesc.BackgroundColor3 = Color3.fromRGB(38,38,38)
    nodeDesc.TextColor3 = Color3.new(1,1,1)
    gui.NodeDesc = nodeDesc

    -- Vote area
    local voteFrame = Instance.new("Frame", center)
    voteFrame.Size = UDim2.new(1,0,0,200)
    voteFrame.Position = UDim2.new(0,0,0,200)
    voteFrame.BackgroundColor3 = Color3.fromRGB(18,18,18)
    gui.VoteFrame = voteFrame

    local voteTitle = Instance.new("TextLabel", voteFrame)
    voteTitle.Size = UDim2.new(1,0,0,24)
    voteTitle.Position = UDim2.new(0,0,0,0)
    voteTitle.BackgroundTransparency = 1
    voteTitle.Font = Enum.Font.SourceSansBold
    voteTitle.TextColor3 = Color3.new(1,1,1)
    voteTitle.Text = "No active vote"
    gui.VoteTitle = voteTitle

    gui.VoteOptionLabels = {}
    gui.VoteOptionCounts = {}
    for i=1, CONFIG.MAX_OPTION_LABELS do
        local y = 28 + (i-1)*28
        local lbl = Instance.new("TextLabel", voteFrame)
        lbl.Size = UDim2.new(0.78,0,0,24)
        lbl.Position = UDim2.new(0,10,0,y)
        lbl.BackgroundTransparency = 1
        lbl.TextXAlignment = Enum.TextXAlignment.Left
        lbl.Text = ""
        lbl.TextColor3 = Color3.new(1,1,1)
        gui.VoteOptionLabels[i] = lbl

        local cnt = Instance.new("TextLabel", voteFrame)
        cnt.Size = UDim2.new(0.18,0,0,24)
        cnt.Position = UDim2.new(0.82,10,0,y)
        cnt.BackgroundColor3 = Color3.fromRGB(40,40,40)
        cnt.TextColor3 = Color3.new(1,1,1)
        cnt.Text = "0"
        gui.VoteOptionCounts[i] = cnt
    end

    -- Right: controls & logs
    local right = Instance.new("Frame", main)
    right.Size = UDim2.new(0,90,1,-60)
    right.Position = UDim2.new(0,840,0,50)
    right.BackgroundColor3 = Color3.fromRGB(22,22,22)
    gui.Right = right

    local startBtn = Instance.new("TextButton", right)
    startBtn.Size = UDim2.new(1, -10, 0, 30)
    startBtn.Position = UDim2.new(0,5,0,6)
    startBtn.Text = "Start Adventure"
    startBtn.BackgroundColor3 = Color3.fromRGB(70,130,70)
    gui.StartBtn = startBtn

    local endBtn = Instance.new("TextButton", right)
    endBtn.Size = UDim2.new(1, -10, 0, 30)
    endBtn.Position = UDim2.new(0,5,0,42)
    endBtn.Text = "End Adventure"
    endBtn.BackgroundColor3 = Color3.fromRGB(130,70,70)
    gui.EndBtn = endBtn

    local forceBtn = Instance.new("TextButton", right)
    forceBtn.Size = UDim2.new(1, -10, 0, 28)
    forceBtn.Position = UDim2.new(0,5,0,78)
    forceBtn.Text = "Force Vote Result"
    forceBtn.BackgroundColor3 = Color3.fromRGB(200,120,0)
    gui.ForceBtn = forceBtn

    local saveBtn = Instance.new("TextButton", right)
    saveBtn.Size = UDim2.new(1, -10, 0, 28)
    saveBtn.Position = UDim2.new(0,5,0,112)
    saveBtn.Text = "Save"
    saveBtn.BackgroundColor3 = Color3.fromRGB(70,70,150)
    gui.SaveBtn = saveBtn

    local loadBtn = Instance.new("TextButton", right)
    loadBtn.Size = UDim2.new(1, -10, 0, 28)
    loadBtn.Position = UDim2.new(0,5,0,146)
    loadBtn.Text = "Load"
    loadBtn.BackgroundColor3 = Color3.fromRGB(70,70,150)
    gui.LoadBtn = loadBtn

    local logBox = Instance.new("TextBox", main)
    logBox.Size = UDim2.new(1, -20, 0, 80)
    logBox.Position = UDim2.new(0,10,1,-90)
    logBox.MultiLine = true
    logBox.TextWrapped = true
    logBox.ReadOnly = true
    logBox.Text = "Log:"
    logBox.BackgroundColor3 = Color3.fromRGB(18,18,18)
    logBox.TextColor3 = Color3.new(1,1,1)
    gui.Log = logBox

    -- Button wiring
    startBtn.MouseButton1Click:Connect(function()
        if adventureRunning then Chat("Adventure already running.") return end
        if currentNodeId == nil then currentNodeId = "crossroads" end
        adventureRunning = true
        Chat("🏁 The GM has begun the adventure!")
        presentNode(currentNodeId)
    end)

    endBtn.MouseButton1Click:Connect(function()
        adventureRunning = false
        Chat("🏁 The GM has ended the adventure.")
        updateAllUI()
    end)

    forceBtn.MouseButton1Click:Connect(function()
        if not currentVote then Chat("No active vote to force.") return end
        -- try to force the current highest or let GM choose using prompt
        local highest = -1
        local top = {}
        for i=1,#currentVote.options do highest = math.max(highest, currentVote.counts[i] or 0) end
        for i=1,#currentVote.options do if (currentVote.counts[i] or 0) == highest then table.insert(top, i) end end
        local chosen = top[1] or 1
        Chat("🛠️ GM forced result: ["..string.char(64 + chosen).."] "..currentVote.options[chosen])
        if currentVote.onComplete then pcall(currentVote.onComplete, chosen, currentVote.counts) end
        currentVote = nil
        updateAllUI()
    end)

    saveBtn.MouseButton1Click:Connect(function()
        saveGame()
    end)
    loadBtn.MouseButton1Click:Connect(function()
        loadGame()
    end)
end

-- ----------------------------
-- UI Update helpers
-- ----------------------------
function updatePartyUI()
    if not gui or not gui.PartyList then return end
    local frame = gui.PartyList
    for _,c in pairs(frame:GetChildren()) do c:Destroy() end
    local y = 0
    for _, uid in ipairs(partyOrder) do
        local char = party[uid]
        if char then
            local f = Instance.new("Frame", frame)
            f.Size = UDim2.new(1,-8,0,64)
            f.Position = UDim2.new(0,4,0,y)
            f.BackgroundColor3 = Color3.fromRGB(40,40,40)
            local name = Instance.new("TextLabel", f)
            name.Size = UDim2.new(1, -8, 0, 24)
            name.Position = UDim2.new(0,4,0,4)
            name.BackgroundTransparency = 1
            name.Font = Enum.Font.SourceSansBold
            name.TextColor3 = Color3.new(1,1,1)
            name.Text = char.DisplayName.." (Lvl "..(char.Level or 1)..")"
            local status = Instance.new("TextLabel", f)
            status.Size = UDim2.new(1,-8,0,30)
            status.Position = UDim2.new(0,4,0,28)
            status.BackgroundTransparency = 1
            status.Font = Enum.Font.SourceSans
            status.TextColor3 = Color3.new(0.9,0.9,0.9)
            status.Text = "HP: "..char.HP.."/"..char.MaxHP.." | Gold: "..(char.Gold or 0).." | XP: "..(char.XP or 0).." | Items: "..(#(char.Inventory or {}))
            y = y + 68
        end
    end
    frame.CanvasSize = UDim2.new(0,0,0, math.max(1,y))
end

function updateVoteUI()
    if not gui or not gui.VoteFrame then return end
    if not currentVote then
        gui.VoteTitle.Text = "No active vote"
        for i=1, CONFIG.MAX_OPTION_LABELS do
            gui.VoteOptionLabels[i].Text = ""
            gui.VoteOptionCounts[i].Text = ""
        end
        return
    end
    gui.VoteTitle.Text = "Vote: "..currentVote.title.." (ends in "..round(currentVote.endsAt - tick()).."s)"
    for i=1, CONFIG.MAX_OPTION_LABELS do
        local label = gui.VoteOptionLabels[i]
        local count = gui.VoteOptionCounts[i]
        if currentVote.options[i] then
            label.Text = ("[%s] %s"):format(string.char(64 + i), currentVote.options[i])
            count.Text = tostring(currentVote.counts[i] or 0)
        else
            label.Text = ""
            count.Text = ""
        end
    end
end

function updateNodeUI()
    if not gui or not gui.NodeTitle then return end
    if not currentNodeId then
        gui.NodeTitle.Text = "No node active"
        gui.NodeDesc.Text = ""
        return
    end
    local n = nodes[currentNodeId]
    if not n then gui.NodeTitle.Text = "Unknown node"; gui.NodeDesc.Text = "" ; return end
    gui.NodeTitle.Text = n.title
    gui.NodeDesc.Text = n.desc
end

function updateLogUI()
    if not gui or not gui.Log then return end
    local lines = {"Log:"}
    for i = math.max(1, #messageLog - 20), #messageLog do
        table.insert(lines, messageLog[i])
    end
    gui.Log.Text = table.concat(lines, "\n")
end

function updateAllUI()
    updatePartyUI()
    updateVoteUI()
    updateNodeUI()
    updateLogUI()
end

-- ----------------------------
-- Chat listening and commands
-- ----------------------------
local function appendLog(str)
    table.insert(messageLog, str)
    if #messageLog > 200 then table.remove(messageLog,1) end
    updateLogUI()
end

local function getPlayerByName(name)
    name = name:lower()
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower():sub(1,#name) == name or p.DisplayName:lower():sub(1,#name) == name then
            return p
        end
    end
    return nil
end

local function handleChat(player, message)
    if not player or not message then return end
    appendLog(("%s: %s"):format(player.DisplayName, message))
    local msg = tostring(message)
    local lower = msg:lower()

    -- Votes
    if currentVote then
        local ok, err = recordVote(player, msg)
        if ok then
            appendLog(player.DisplayName.." voted.")
            return
        end
        -- not necessarily an error; allow other commands below
    end

    -- Commands:
    -- !join
    if lower:match("^!join") then
        addPlayerToParty(player)
        updateAllUI()
        return
    end
    if lower:match("^!leave") then
        removePlayerFromParty(player)
        updateAllUI()
        return
    end
    if lower:match("^!start") and player.UserId == gmUserId then
        if not adventureRunning then
            adventureRunning = true
            if not currentNodeId then currentNodeId = "crossroads" end
            Chat("🏁 The GM starts the adventure!")
            presentNode(currentNodeId)
        else
            Chat("Adventure already running.")
        end
        return
    end
    if lower:match("^!end") and player.UserId == gmUserId then
        adventureRunning = false
        Chat("🏁 The GM ends the adventure.")
        updateAllUI()
        return
    end
    -- vote prefix
    if lower:sub(1, #CONFIG.VOTE_PREFIX) == CONFIG.VOTE_PREFIX then
        local rest = msg:sub(#CONFIG.VOTE_PREFIX + 1)
        local ok, err = recordVote(player, rest)
        if ok then
            appendLog(player.DisplayName.." cast a vote via prefix.")
        else
            appendLog("Vote parse failed for "..player.DisplayName..": "..(err or "unknown"))
        end
        return
    end
    -- quick status
    if lower:match("^!status") then
        local char = party[player.UserId]
        if not char then
            Chat(player.DisplayName..", you are not in the party. Type !join to join.")
        else
            Chat(("Status for %s | HP: %d/%d | Gold: %d | XP: %d | Items: %d"):format(char.DisplayName, char.HP, char.MaxHP, char.Gold, char.XP, #char.Inventory))
        end
        return
    end
    if lower:match("^!roll ") then
        local notat = msg:sub(7)
        local r = rollDice(notat)
        Chat(("🎲 %s rolls %s -> %d"):format(player.DisplayName, notat, r))
        return
    end
    if lower:match("^!save") and player.UserId == gmUserId then
        saveGame()
        return
    end
    if lower:match("^!load") and player.UserId == gmUserId then
        loadGame()
        return
    end

    -- If none matched, it's normal chat and may be ignored or logged
end

-- Hook chat events
if TextChatService and TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
    TextChatService.MessageReceived:Connect(function(txtMessage)
        local src = txtMessage.TextSource
        if not src then return end
        local player = Players:GetPlayerByUserId(src.UserId)
        if player then handleChat(player, txtMessage.Text) end
    end)
else
    -- fallback for older chat system
    for _, p in ipairs(Players:GetPlayers()) do
        p.Chatted:Connect(function(msg) handleChat(p, msg) end)
    end
    Players.PlayerAdded:Connect(function(p) p.Chatted:Connect(function(msg) handleChat(p, msg) end) end)
end

-- ----------------------------
-- Initialize GUI and seed party (Studio convenience)
-- ----------------------------
createGui()
updateAllUI()

-- If in Studio and party empty, create preview entries
if RunService:IsStudio() then
    if #partyOrder == 0 then
        addPlayerToParty(LocalPlayer)
        for i=1,2 do
            local fakeId = 1000000 + i
            local fakeName = "NPC_"..i
            party[fakeId] = {UserId=fakeId, Name=fakeName, DisplayName=fakeName, Level=1, XP=0, Gold=10, MaxHP=CONFIG.BASE_HP+math.random(1,6), HP=CONFIG.BASE_HP, Inventory={}, Keys={}, MapFragments=0, Alive=true}
            table.insert(partyOrder, fakeId)
        end
        updateAllUI()
    end
end

-- Final ready message and instructions
Chat("📜 The GM script is active. Players: type !join to join the party. When the GM starts the adventure, choices will be presented and you may vote using '"..CONFIG.VOTE_PREFIX.." A' or simply 'A' when voting is active. GM: use the GUI to control, force votes, and save/load.")

-- ----------------------------
-- End of script
-- ----------------------------
