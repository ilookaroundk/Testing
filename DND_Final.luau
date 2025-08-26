-- Dungeon & Dragons - Chat-Driven Adventure (Chat-only, GUI removed)
-- Run this as the GM (LocalScript). All control and interaction is done through chat.
-- Players do NOT need this script. They vote using chat (e.g. "!vote A" or "A") and use "!join" to join.
-- Compatible with many third-party executors: safe chat/send, safe notifications, pcall-wrapped APIs, single-instance guard.

-- Usage (chat commands):
--   Players:
--     !join                -> join the party
--     !leave               -> leave the party
--     !vote A / !vote 1    -> vote while a vote is active (single-letter "A" also accepted)
--     !status              -> show your status in chat (HP, Gold, XP, items)
--     !roll 1d20 / !roll d6 -> roll dice in chat
--   GM (script runner):
--     !start               -> start the adventure (GM only)
--     !end                 -> end the adventure (GM only)
--     !force <n>           -> force the current vote to choose option n (GM only)
--     !announce <text>     -> send a GM announcement to chat (GM only)
-- Notes:
--   - All choices are presented as votes; the script announces options in chat.
--   - Good choices yield loot/XP; bad choices cause traps/damage/etc.
--   - No GUI, all info shown in chat.

-- =====================================================
-- Executor compatibility and environment safety
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

-- Single-instance guard (prevent running twice)
if getgenv and getgenv().DND_CHAT_ADVENTURE_RUNNING then
    pcall(function()
        if StarterGui and StarterGui.SetCore then
            pcall(function() StarterGui:SetCore("SendNotification", {Title="DND Chat Bot", Text="Script already running", Duration=5}) end)
        end
    end)
    return
end
if getgenv then pcall(function() getgenv().DND_CHAT_ADVENTURE_RUNNING = true end) end

-- Safe chat send (tries TextChatService then legacy)
local function SafeChat(msg)
    if not msg then return end
    local ok = false
    pcall(function()
        if TextChatService and TextChatService.TextChannels and TextChatService.TextChannels:FindFirstChild("RBXGeneral") then
            TextChatService.TextChannels.RBXGeneral:SendAsync(msg)
            ok = true
        end
    end)
    if ok then return end
    pcall(function()
        local default = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
        if default and default:FindFirstChild("SayMessageRequest") then
            default.SayMessageRequest:FireServer(msg, "All")
            ok = true
        end
    end)
    if ok then return end
    -- fallback to notification if chat not available
    pcall(function()
        if StarterGui and StarterGui.SetCore then
            StarterGui:SetCore("ChatMakeSystemMessage", {Text = msg})
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
-- Config / State
-- =====================================================
local CONFIG = {
    VOTE_PREFIX = "!vote",
    VOTE_ACCEPT_SINGLE_LETTER = true,
    VOTE_DURATION = 18,         -- seconds per vote
    STARTING_GOLD = 10,
    BASE_HP = 12,
    BASE_XP_PER_GOOD = 30,
    MAX_OPTION_LABELS = 12
}

local GM_USER_ID = LocalPlayer.UserId -- script-runner is GM by default

-- runtime state
local party = {}        -- userId -> character
local partyOrder = {}   -- ordered list of userIds
local currentNodeId = nil
local adventureRunning = false
local nodes = {}
local currentVote = nil -- active vote table
local messageLog = {}   -- for optional debug/logging in memory

-- =====================================================
-- Utility helpers
-- =====================================================
local function appendLog(line)
    table.insert(messageLog, line)
    if #messageLog > 500 then table.remove(messageLog, 1) end
end

local function clamp(n,a,b) return math.max(a, math.min(b, n)) end
local function rollDice(notation)
    if type(notation) ~= "string" then return tonumber(notation) or 0 end
    local c,s,sign,m = notation:match("^(%d*)[dD](%d+)([%+%-]?)(%d*)$")
    if not s then
        local n = tonumber(notation)
        return n or 0
    end
    c = tonumber(c) or 1
    s = tonumber(s)
    m = tonumber(m) or 0
    if sign == "-" then m = -m end
    local total = 0
    for i=1,c do total = total + math.random(1,s) end
    return total + m
end
local function d20() return rollDice("d20") end

-- =====================================================
-- Party management & effects
-- =====================================================
local function makeCharacterTemplate(player)
    return {
        UserId = player.UserId,
        Name = player.Name,
        DisplayName = player.DisplayName,
        Level = 1,
        XP = 0,
        Gold = CONFIG.STARTING_GOLD,
        MaxHP = CONFIG.BASE_HP + math.random(1,6),
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
    SafeChat("🧭 "..player.DisplayName.." joined the party! Type !status to check your stats.")
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
    c.XP = c.XP + xp
    SafeChat("✨ "..c.DisplayName.." gains "..xp.." XP! (Total: "..c.XP..")")
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
    SafeChat("🎁 "..c.DisplayName.." obtained "..item.Name)
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
-- Loot helpers & simple effects
-- =====================================================
local function randomLootForGoodChoice()
    local r = math.random(1,100)
    if r <= 40 then return {Key="gold", Name="Gold Coins", Type="gold", Amount=math.random(5,40)}
    elseif r <= 60 then return {Key="potion_heal", Name="Healing Potion", Type="consumable", Heal="1d8+2"}
    elseif r <= 75 then return {Key="gem", Name="Gemstone", Type="treasure", Value=math.random(20,150)}
    elseif r <= 90 then return {Key="map_frag", Name="Map Fragment", Type="map", Fragments=1}
    else return {Key="mystic_key", Name="Mysterious Key", Type="key"} end
end

-- =====================================================
-- Adventure node system (branching choices)
-- Node format:
-- nodes[id] = { id, title, desc, options = { Option(...) ... }, onEnter = function() end }
-- Option(label, nextId, goodEffectFunc, badEffectFunc, chanceGood)
-- =====================================================
local function Option(label, nextId, goodEffect, badEffect, chanceGood)
    return { label = label, next = nextId, good = goodEffect, bad = badEffect, chanceGood = chanceGood or 75 }
end

local function rewardAll_xp(amount)
    return function(ctx) for _, uid in ipairs(partyOrder) do if party[uid] then grantXP(uid, amount) end end end
end
local function rewardRandomLoot()
    return function(ctx) local uid = partyOrder[math.random(1, math.max(1,#partyOrder))]; local item = randomLootForGoodChoice(); if item.Type == "gold" then giveGold(uid, item.Amount) else addItem(uid, item) end end
local end
local function damageRandom(amount, reason)
    return function(ctx) local alive = {}; for _, uid in ipairs(partyOrder) do if party[uid] and party[uid].Alive then table.insert(alive, uid) end end if #alive==0 then return end local uid = alive[math.random(1,#alive)]; damagePlayer(uid, amount, reason) end
local end
local function trapAll(amount, reason)
    return function(ctx) for _, uid in ipairs(partyOrder) do if party[uid] and party[uid].Alive then damagePlayer(uid, amount, reason) end end end
local end
local function loseItemRandom()
    return function(ctx) local candidates = {} for _, uid in ipairs(partyOrder) do local c = party[uid] if c and #c.Inventory>0 then table.insert(candidates, uid) end end if #candidates==0 then return end local uid = candidates[math.random(1,#candidates)]; local c = party[uid]; local idx = math.random(1,#c.Inventory); local removed = table.remove(c.Inventory, idx); SafeChat("🗑️ "..c.DisplayName.." lost a(n) "..(removed and removed.Name or "item").." due to misfortune.") end
local end

-- Note: The above helper definitions use concise inline multi-line forms. They are intentionally short for clarity.

-- Build nodes (a rich sample of branching nodes; extend as desired)
nodes["crossroads"] = {
    id = "crossroads",
    title = "Crossroads",
    desc = "You stand at a weathered crossroads. A sign points: Castle (north), Road (east), Forest (west), River (south).",
    options = {
        Option("Head to the Castle (north)", "castle_gate", rewardAll_xp(CONFIG.BASE_XP_PER_GOOD), damageRandom(6, "barbed gate trap"), 85),
        Option("Follow the Road (east)", "long_road", rewardRandomLoot(), damageRandom(4, "thug ambush"), 80),
        Option("Venture into the Forest (west)", "ancient_forest", rewardAll_xp(CONFIG.BASE_XP_PER_GOOD + 10), trapAll(3, "hidden thorns"), 70),
        Option("Walk to the River (south)", "riverside", rewardRandomLoot(), damageRandom(5, "slip and cut"), 75),
        Option("Ask the locals at the Village", "village", rewardAll_xp(10), loseItemRandom(), 90)
    },
    onEnter = function() SafeChat("📍 Crossroads: Vote which path to take.") end
}

nodes["castle_gate"] = {
    id = "castle_gate",
    title = "Castle Gate",
    desc = "A looming castle stands behind iron gates. There's a servants' door and a ladder to the battlements.",
    options = {
        Option("Try the main gate (push it open)", "great_hall", rewardAll_xp(40), damageRandom(10,"collapsing portcullis"), 70),
        Option("Sneak through the servants' entrance", "service_tunnel", rewardRandomLoot(), damageRandom(6,"suffocation"), 80),
        Option("Climb the ladder to battlements", "battlements", rewardAll_xp(30), trapAll(5,"fall from ladder"), 65),
        Option("Scout the walls instead", "castle_walls", rewardAll_xp(20), damageRandom(4,"sharp spike"), 85)
    }
}

nodes["long_road"] = {
    id = "long_road",
    title = "Long Road",
    desc = "You meet a merchant, a broken cart, and suspicious travelers.",
    options = {
        Option("Bargain with merchant", "merchant_deal", rewardRandomLoot(), loseItemRandom(), 80),
        Option("Help fix the cart", "fix_cart", rewardAll_xp(20), damageRandom(3,"pinched hand"), 90),
        Option("Follow the suspicious pair", "ambush_point", rewardRandomLoot(), damageRandom(8,"bandit ambush"), 55)
    }
}

nodes["ancient_forest"] = {
    id = "ancient_forest",
    title = "Ancient Forest",
    desc = "Old trees whisper. You find a stone circle and a hidden cottage.",
    options = {
        Option("Investigate the stone circle", "stone_circle", rewardAll_xp(50), trapAll(6,"arcane backlash"), 65),
        Option("Knock on the cottage door", "cottage", rewardRandomLoot(), damageRandom(2,"angry badger"), 85),
        Option("Trace the glyphs deeper", "glyph_path", rewardAll_xp(30), damageRandom(7,"cursed roots"), 60)
    }
}

nodes["riverside"] = {
    id = "riverside",
    title = "Riverside",
    desc = "The river glitters. A bridge crosses to a tower; a sunken boat waits.",
    options = {
        Option("Investigate sunken boat", "sunken_boat", rewardRandomLoot(), trapAll(4,"water trap"), 70),
        Option("Cross the old bridge", "ruined_bridge", rewardRandomLoot(), damageRandom(6,"bridge collapse"), 65),
        Option("Visit the tower across the river", "river_tower", rewardAll_xp(25), damageRandom(5,"tower collapse"), 75)
    }
}

nodes["village"] = {
    id = "village",
    title = "Village",
    desc = "A quaint village. Inn, blacksmith, notice board.",
    options = {
        Option("Rest at the inn", "inn_rest", function(ctx) for _,id in ipairs(partyOrder) do healPlayer(id, math.random(4,10)) end end, damageRandom(2,"drunken brawl"), 90),
        Option("Ask the blacksmith", "blacksmith", function(ctx) for _,id in ipairs(partyOrder) do addItem(id, {Key="armband", Name="Sturdy Armband", Type="gear"}) end end, loseItemRandom(), 80),
        Option("Read the notice board", "notice_board", rewardAll_xp(15), damageRandom(1,"misinformation"), 95)
    }
}

-- Terminal / special nodes (examples)
nodes["sunken_boat"] = {
    id = "sunken_boat",
    title = "Sunken Boat",
    desc = "Diving into the hold finds a small chest and a sleeping something.",
    options = {
        Option("Take the chest", "boat_chest", rewardRandomLoot(), trapAll(7,"underwater crush"), 60),
        Option("Leave it to rest", "crossroads", rewardAll_xp(10), damageRandom(2,"splash"), 95)
    }
}

nodes["great_hall"] = {
    id = "great_hall",
    title = "Great Hall",
    desc = "A grand hall with banners and a chest under a tapestry.",
    options = {
        Option("Accept audience with lord", "audience", rewardAll_xp(50), damageRandom(5,"lord's suspicion"), 80),
        Option("Open the chest quietly", "tapestry_chest", rewardRandomLoot(), trapAll(8,"needle trap"), 60),
        Option("Search the hall", "hall_search", rewardAll_xp(25), damageRandom(3,"loose tile"), 85)
    }
}

-- You can extend nodes table as needed using the Option(...) pattern above.

-- =====================================================
-- Voting system (chat-driven)
-- currentVote = { id, title, options = {}, counts = {}, votes = {}, eligible = {}, endsAt, onComplete }
-- =====================================================
local function announceVote(vote)
    local pieces = {}
    for i,opt in ipairs(vote.options) do table.insert(pieces, ("[%s] %s"):format(string.char(64+i), opt)) end
    SafeChat("🗳️ Vote: "..vote.title)
    SafeChat("Options: "..table.concat(pieces, " | "))
    SafeChat("Vote by chat: "..CONFIG.VOTE_PREFIX.." <letter|number> OR a single-letter message while voting. Voting ends in "..math.max(0, math.floor(vote.endsAt - tick())).."s.")
end

local function startVote(title, optionTexts, duration, eligibleList, onComplete)
    if currentVote then
        SafeChat("⚠️ A vote is already active. GM can force via !force <n>.")
        return nil
    end
    duration = duration or CONFIG.VOTE_DURATION
    local v = { id = "V"..tostring(math.random(100000,999999)), title = title, options = optionTexts, counts = {}, votes = {}, eligible = {}, endsAt = tick() + duration, onComplete = onComplete }
    for i=1,#optionTexts do v.counts[i]=0 end
    if eligibleList and #eligibleList>0 then for _,id in ipairs(eligibleList) do v.eligible[id]=true end else for _,id in ipairs(partyOrder) do v.eligible[id]=true end end
    currentVote = v
    announceVote(v)
    appendLog("Vote started: "..title)
    -- watcher to finish vote
    spawn(function()
        while currentVote == v and tick() < v.endsAt do wait(0.5) end
        if currentVote ~= v then return end
        -- finalize
        local highest = -1
        for i=1,#v.options do highest = math.max(highest, v.counts[i] or 0) end
        local top = {}
        for i=1,#v.options do if (v.counts[i] or 0) == highest then table.insert(top,i) end end
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
    if n and n>=1 and n<=#currentVote.options then idx = n end
    if not idx then
        local letter = s:match("^%a$") or s:match("([A-Za-z])")
        if letter then
            local code = string.byte(letter:upper()) - 64
            if code >=1 and code <= #currentVote.options then idx = code end
        end
    end
    if not idx then return false, "Unrecognized vote" end
    local prev = currentVote.votes[player.UserId]
    if prev then currentVote.counts[prev] = math.max(0, (currentVote.counts[prev] or 1) - 1) end
    currentVote.votes[player.UserId] = idx
    currentVote.counts[idx] = (currentVote.counts[idx] or 0) + 1
    appendLog(player.DisplayName.." voted for "..currentVote.options[idx])
    -- update quick early-complete if all eligible voted
    local totalEligible, totalVotes = 0,0
    for id,_ in pairs(currentVote.eligible) do totalEligible = totalEligible + 1 end
    for uid,_ in pairs(currentVote.votes) do totalVotes = totalVotes + 1 end
    if totalVotes >= totalEligible then
        local highest = -1; local top={}
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
-- Node presentation and resolution (invoked after vote)
-- =====================================================
local function resolveOption(node, optIndex, voteCounts)
    local option = node.options[optIndex]
    if not option then SafeChat("Choice error. No such option.") return end
    local roll = math.random(1,100)
    local isGood = roll <= (option.chanceGood or 75)
    if isGood and option.good then pcall(option.good, {optionIndex=optIndex, voteCounts=voteCounts})
    elseif (not isGood) and option.bad then pcall(option.bad, {optionIndex=optIndex, voteCounts=voteCounts})
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
    -- If there's a next node and adventure is still running, present it after a short pause
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
    local opts = {}
    for _,opt in ipairs(node.options) do table.insert(opts, opt.label) end
    if #opts == 0 then adventureRunning = false; SafeChat("No options — adventure stops."); return end
    startVote(node.title, opts, CONFIG.VOTE_DURATION, partyOrder, function(choiceIndex, counts)
        resolveOption(node, choiceIndex, counts)
    end)
end

-- =====================================================
-- Chat handling (listening to votes and commands)
-- =====================================================
local function getPlayerByName(name)
    if not name then return nil end
    local lower = name:lower()
    for _,p in ipairs(Players:GetPlayers()) do
        if p.Name:lower():sub(1,#lower) == lower or p.DisplayName:lower():sub(1,#lower) == lower then return p end
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
        -- if not voteable, continue to parse commands
    end

    -- Commands for players and GM
    if lower:match("^!join") then
        addPlayerToParty(player); return
    end
    if lower:match("^!leave") then
        removePlayerFromParty(player); return
    end
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
            SafeChat("Usage: !roll 1d20 or !roll d6")
        end
        return
    end

    -- GM commands
    if player.UserId == GM_USER_ID then
        if lower:match("^!start") then
            if adventureRunning then SafeChat("Adventure already running."); return end
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
            local n = tonumber(txt:match("^!force%s+(%d+)") or "") or tonumber(txt:match("^!force%s+([A-Za-z])") and (string.byte(txt:match("^!force%s+([A-Za-z])"):upper())-64))
            if not currentVote then SafeChat("No active vote to force.") else
                if not n or n < 1 or n > #currentVote.options then SafeChat("Invalid option number to force.") else
                    SafeChat("🛠️ GM forced vote to option ["..string.char(64+n).."] "..currentVote.options[n])
                    if currentVote.onComplete then pcall(currentVote.onComplete, n, currentVote.counts) end
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

    -- explicit vote prefix (e.g., "!vote A" or "!vote 1")
    if lower:sub(1, #CONFIG.VOTE_PREFIX) == CONFIG.VOTE_PREFIX then
        local rest = txt:sub(#CONFIG.VOTE_PREFIX + 1)
        local ok, err = recordVote(player, rest)
        if ok then return end
    end
    -- otherwise ignore or treat as normal conversation
end

-- Hook chat events (TextChatService preferred, fallback to Player.Chatted)
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
    -- Legacy fallback
    for _, p in ipairs(Players:GetPlayers()) do
        p.Chatted:Connect(function(msg) handleChat(p, msg) end)
    end
    Players.PlayerAdded:Connect(function(p) p.Chatted:Connect(function(msg) handleChat(p, msg) end) end)
end

-- =====================================================
-- Initial instructions
-- =====================================================
SafeChat("📜 D&D Chat Adventure ready. GM runs this script locally. Players: type !join to join the party. When the GM starts the adventure (!start), choices will be announced and you vote using '!vote A' or simply 'A' while voting is active. GM can force a result with '!force <n>'.")

-- If in Studio, seed the LocalPlayer so GM can test quickly
if RunService:IsStudio() then
    if #partyOrder == 0 then
        addPlayerToParty(LocalPlayer)
        SafeChat("Studio test: LocalPlayer added to party")
    end
end

-- End of script
