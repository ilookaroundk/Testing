-- Dungeon & Dragons - Chat-Driven Adventure (Executor-Compatible LocalScript)
-- GM runs this locally. It listens to other players' chat and resolves party choices by vote.
-- Compatibility adjustments made for third-party Roblox executors:
--  - Robust chat sending (works with TextChatService and the older DefaultChatSystemChatEvents)
--  - Robust notification (StarterGui:SetCore wrapped in pcall)
--  - Safe parenting of GUI (tries PlayerGui, falls back to CoreGui when allowed)
--  - Safe use of APIs that may be absent in some exploit environments (pcall wrappers)
--  - Single-instance guard using getgenv
--  - Fallback chat listening (TextChatService.MessageReceived or Player.Chatted)
-- Save/load/persistence removed (per your prior request)

-- NOTE:
-- Paste into a LocalScript and run it as the GM (the player running this script will be the GM).
-- Players only need standard chat to vote; they do NOT need this script.

-- Services & basic env safety
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

-- Prevent running multiple copies in the same executor environment
if getgenv and getgenv().DND_ADVENTURE_RUNNING then
    pcall(function()
        -- try to notify
        if StarterGui and StarterGui.SetCore then
            pcall(function() StarterGui:SetCore("SendNotification", {Title="DND Bot", Text="Script already running", Duration=5}) end)
        end
    end)
    return
end
if getgenv then
    pcall(function() getgenv().DND_ADVENTURE_RUNNING = true end)
end

-- CONFIG
local CONFIG = {
    VOTE_PREFIX = "!vote",
    VOTE_ACCEPT_SINGLE_LETTER = true,
    VOTE_DURATION = 20,
    STARTING_GOLD = 10,
    BASE_HP = 12,
    BASE_XP_PER_GOOD = 30,
    MAX_OPTION_LABELS = 12,
    DIALOGUE_READ_TIME = 3,
}

local gmUserId = LocalPlayer.UserId -- script-runner by default is GM

-- STATE
local party = {}         -- userId -> character table
local partyOrder = {}    -- ordered list of userIds
local currentNodeId = nil
local adventureRunning = false
local nodes = {}
local currentVote = nil
local messageLog = {}
local gui = {}

-- UTILITIES

-- Safe notify (uses SetCore when available, otherwise falls back to chat)
local function SafeNotify(title, text, duration)
    duration = duration or 5
    local ok, err = pcall(function()
        if StarterGui and StarterGui.SetCore then
            StarterGui:SetCore("SendNotification", {
                Title = title,
                Text = text,
                Duration = duration
            })
            return true
        end
    end)
    if not ok or err then
        -- fallback: send to chat (best-effort)
        pcall(function() 
            if TextChatService and TextChatService.TextChannels and TextChatService.TextChannels:FindFirstChild("RBXGeneral") then
                TextChatService.TextChannels.RBXGeneral:SendAsync(("[%s] %s"):format(title, text))
            else
                local default = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
                if default and default:FindFirstChild("SayMessageRequest") then
                    default.SayMessageRequest:FireServer(("[%s] %s"):format(title, text), "All")
                end
            end
        end)
    end
end

-- Robust chat sending: supports TextChatService and legacy chat event
local function SafeChat(msg)
    if not msg then return end
    -- Try TextChatService first
    local ok, err = pcall(function()
        if TextChatService and TextChatService.TextChannels and TextChatService.TextChannels:FindFirstChild("RBXGeneral") then
            TextChatService.TextChannels.RBXGeneral:SendAsync(msg)
            return true
        end
    end)
    if ok then return end
    -- Fallback to DefaultChatSystemChatEvents
    pcall(function()
        local default = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
        if default and default:FindFirstChild("SayMessageRequest") then
            default.SayMessageRequest:FireServer(msg, "All")
            return
        end
    end)
    -- If still not possible, try SetCore or Notify as last resort
    pcall(function()
        if StarterGui and StarterGui.SetCore then
            StarterGui:SetCore("ChatMakeSystemMessage", {Text = msg})
        end
    end)
end

local function clamp(n, a, b) return math.max(a, math.min(b, n)) end
local function round(n) return math.floor(n + 0.5) end

-- Dice parser (supports "d20", "2d6+1", or plain numbers)
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

-- LOGGING & GUI append
local function appendLog(str)
    table.insert(messageLog, str)
    if #messageLog > 200 then table.remove(messageLog, 1) end
    if gui and gui.Log then
        local lines = {"Log:"}
        for i = math.max(1,#messageLog-20), #messageLog do table.insert(lines, messageLog[i]) end
        gui.Log.Text = table.concat(lines, "\n")
    end
end

-- PARTY MANAGEMENT
local function makeCharacterTemplate(player)
    local tpl = {
        UserId = player.UserId,
        Name = player.Name,
        DisplayName = player.DisplayName,
        Level = 1,
        XP = 0,
        Gold = CONFIG.STARTING_GOLD,
        MaxHP = CONFIG.BASE_HP + math.random(1,6),
        HP = CONFIG.BASE_HP,
        Inventory = {},
        Keys = {},
        MapFragments = 0,
        Alive = true
    }
    return tpl
end

local function updatePartyUI()
    if not gui or not gui.PartyList then return end
    local frame = gui.PartyList
    for _, child in pairs(frame:GetChildren()) do child:Destroy() end
    local y = 0
    for _, uid in ipairs(partyOrder) do
        local char = party[uid]
        if char then
            local item = Instance.new("Frame", frame)
            item.Size = UDim2.new(1, -8, 0, 64)
            item.Position = UDim2.new(0, 4, 0, y)
            item.BackgroundColor3 = Color3.fromRGB(40,40,40)
            local name = Instance.new("TextLabel", item)
            name.Size = UDim2.new(1, -8, 0, 24)
            name.Position = UDim2.new(0, 4, 0, 4)
            name.BackgroundTransparency = 1
            name.Font = Enum.Font.SourceSansBold
            name.TextColor3 = Color3.new(1,1,1)
            name.Text = char.DisplayName.." (Lvl "..(char.Level or 1)..")"
            local status = Instance.new("TextLabel", item)
            status.Size = UDim2.new(1, -8, 0, 30)
            status.Position = UDim2.new(0, 4, 0, 28)
            status.BackgroundTransparency = 1
            status.Font = Enum.Font.SourceSans
            status.TextColor3 = Color3.new(0.9,0.9,0.9)
            status.Text = "HP: "..char.HP.."/"..char.MaxHP.." | Gold: "..(char.Gold or 0).." | XP: "..(char.XP or 0).." | Items: "..(#(char.Inventory or {}))
            y = y + 68
        end
    end
    frame.CanvasSize = UDim2.new(0, 0, 0, math.max(1, y))
end

local function addPlayerToParty(player)
    if not player then return false, "No player" end
    if party[player.UserId] then return false, "Already in party" end
    party[player.UserId] = makeCharacterTemplate(player)
    table.insert(partyOrder, player.UserId)
    SafeChat("🧭 "..player.DisplayName.." joined the expedition! (Type !status to check your condition)")
    appendLog(player.DisplayName.." joined the party.")
    updatePartyUI()
    return true
end

local function removePlayerFromParty(player)
    if not player then return false, "No player" end
    if not party[player.UserId] then return false, "Not in party" end
    party[player.UserId] = nil
    for i,id in ipairs(partyOrder) do if id == player.UserId then table.remove(partyOrder, i); break end end
    SafeChat("⛔ "..player.DisplayName.." left the expedition.")
    appendLog(player.DisplayName.." left the party.")
    updatePartyUI()
    return true
end

local function grantXP(userId, xp)
    local char = party[userId]
    if not char then return end
    char.XP = char.XP + xp
    SafeChat("✨ "..char.DisplayName.." gains "..xp.." XP!")
    updatePartyUI()
end

local function giveGold(userId, amount)
    local char = party[userId]
    if not char then return end
    char.Gold = (char.Gold or 0) + amount
    SafeChat("💰 "..char.DisplayName.." found "..amount.." gold (total "..char.Gold..")")
    updatePartyUI()
end

local function addItem(userId, item)
    local char = party[userId]
    if not char then return end
    table.insert(char.Inventory, item)
    SafeChat("🎁 "..char.DisplayName.." obtained: "..item.Name)
    updatePartyUI()
end

local function damagePlayer(userId, amount, reason)
    local char = party[userId]
    if not char or not char.Alive then return end
    char.HP = char.HP - amount
    SafeChat("⚠️ "..char.DisplayName.." takes "..amount.." damage ("..(reason or "injury").."). HP: "..math.max(0,char.HP).."/"..char.MaxHP)
    if char.HP <= 0 then
        char.Alive = false
        SafeChat("☠️ "..char.DisplayName.." has fallen unconscious!")
    end
    updatePartyUI()
end

local function healPlayer(userId, amount)
    local char = party[userId]
    if not char then return end
    char.HP = math.min(char.MaxHP, char.HP + amount)
    SafeChat("❤ "..char.DisplayName.." healed "..amount.." HP. ("..char.HP.."/"..char.MaxHP..")")
    updatePartyUI()
end

-- LOOT
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

-- NODE UTILITIES
local function Option(label, nextNode, goodEffect, badEffect, chanceGood, note)
    return {
        label = label,
        next = nextNode,
        chanceGood = chanceGood or 75,
        good = goodEffect,
        bad = badEffect,
        note = note
    }
end

local function rewardAll_xp(amount)
    return function(ctx)
        for _, uid in ipairs(partyOrder) do if party[uid] then grantXP(uid, amount) end end
    end
end
local function rewardRandomLoot()
    return function(ctx)
        local uid = partyOrder[math.random(1, math.max(1,#partyOrder))]
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
    return function(ctx)
        for _, uid in ipairs(partyOrder) do if party[uid] and party[uid].Alive then damagePlayer(uid, amount, reason) end end
    end
end
local function loseItemRandom()
    return function(ctx)
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
        SafeChat("🗑️ "..char.DisplayName.." lost a(n) "..(removed and removed.Name or "item").." due to misfortune.")
    end
end

-- ADVENTURE NODE GRAPH (trimmed: many nodes; you can expand similarly)
nodes["crossroads"] = {
    id = "crossroads",
    title = "Crossroads",
    desc = "You stand at a weathered crossroads. A wooden sign points: Castle (north), Road (east), Forest (west), River (south).",
    options = {
        Option("Head to the Castle (north)", "castle_gate", rewardAll_xp(CONFIG.BASE_XP_PER_GOOD), damageRandom(6, "barbed gate trap"), 85),
        Option("Follow the Road (east)", "long_road", rewardRandomLoot(), damageRandom(4, "thug ambush"), 80),
        Option("Venture into the Forest (west)", "ancient_forest", rewardAll_xp(CONFIG.BASE_XP_PER_GOOD + 10), trapAll(3, "hidden thorns"), 70),
        Option("Walk to the River (south)", "riverside", rewardRandomLoot(), damageRandom(5, "slip and cut"), 75),
        Option("Ask the locals at the nearby Village", "village", rewardAll_xp(10), loseItemRandom(), 90),
    },
    onEnter = function() SafeChat("📍 Crossroads: Vote to decide where to go.") end
}

-- (Other nodes follow the same pattern as earlier script; include as many as you like)
-- For brevity in this example, a selection of nodes is included. Add more nodes using the Option(...) pattern.

nodes["castle_gate"] = {
    id = "castle_gate",
    title = "Castle Gate",
    desc = "A looming castle stands behind massive iron gates. Guards are absent, but the gate is barred and the portcullis looks unstable.",
    options = {
        Option("Try the main gate (push it open)", "great_hall", rewardAll_xp(40), damageRandom(10, "collapsing portcullis"), 70),
        Option("Sneak through the servants' entrance", "service_tunnel", rewardRandomLoot(), damageRandom(6, "suffocation"), 80),
        Option("Climb the ladder to the battlements", "battlements", rewardAll_xp(30), trapAll(5, "fall from ladder"), 65),
        Option("Scout the walls instead", "castle_walls", rewardAll_xp(20), damageRandom(4, "sharp spike"), 85),
    }
}

nodes["long_road"] = {
    id = "long_road",
    title = "Long Road",
    desc = "The road stretches for miles. You meet a traveling merchant, a broken cart, and a suspicious pair of travelers.",
    options = {
        Option("Bargain with the merchant", "merchant_deal", rewardRandomLoot(), loseItemRandom(), 80),
        Option("Help fix the cart", "fix_cart", rewardAll_xp(20), damageRandom(3, "pinched by wheel"), 90),
        Option("Follow the suspicious pair", "ambush_point", rewardRandomLoot(), damageRandom(8, "bandit ambush"), 55),
    }
}

nodes["ancient_forest"] = {
    id = "ancient_forest",
    title = "Ancient Forest",
    desc = "Old trees whisper. You find a circle of stones, a hidden cottage, and faint glyphs on the roots.",
    options = {
        Option("Investigate the stone circle", "stone_circle", rewardAll_xp(50), trapAll(6, "arcane backlash"), 65),
        Option("Knock on the cottage door", "cottage", rewardRandomLoot(), damageRandom(2, "angry badger"), 85),
        Option("Trace the glyphs deeper", "glyph_path", rewardAll_xp(30), damageRandom(7, "cursed roots"), 60),
    }
}

nodes["riverside"] = {
    id = "riverside",
    title = "Riverside",
    desc = "The river's edge glitters. Fishermen call out, a bridge crosses to an old tower, and a sunken boat is half-visible.",
    options = {
        Option("Investigate the sunken boat", "sunken_boat", rewardRandomLoot(), trapAll(4, "water trap"), 70),
        Option("Cross the old bridge", "ruined_bridge", rewardRandomLoot(), damageRandom(6, "bridge collapse"), 65),
        Option("Visit the tower across the river", "river_tower", rewardAll_xp(25), damageRandom(5, "tower collapse"), 75),
    }
}

nodes["village"] = {
    id = "village",
    title = "Village",
    desc = "A quaint village. The inn offers rest, a blacksmith can craft, and a notice board holds rumors.",
    options = {
        Option("Rest at the inn (recover HP)", "inn_rest", function() for _,id in ipairs(partyOrder) do healPlayer(id, math.random(4,10)) end end, damageRandom(2, "drunken brawl"), 90),
        Option("Ask the blacksmith for upgrades", "blacksmith", function() for _,id in ipairs(partyOrder) do addItem(id, {Key="armband", Name="Sturdy Armband", Type="gear"}) end end, loseItemRandom(), 80),
        Option("Read the notice board", "notice_board", rewardAll_xp(15), damageRandom(1, "misinformation"), 95),
    }
}

-- You can add many more nodes here following the pattern

-- VOTING SYSTEM
local function announceVote(vote)
    local list = {}
    for i,opt in ipairs(vote.options) do table.insert(list, ("[%s] %s"):format(string.char(64 + i), opt)) end
    SafeChat("🗳️ Vote: "..vote.title)
    SafeChat("Options: "..table.concat(list, " | "))
    SafeChat("Vote by chat: "..CONFIG.VOTE_PREFIX.." <letter|number> OR a single-letter message while voting is active. Voting ends in "..round(vote.endsAt - tick()).."s.")
end

local function startVote(title, optionTexts, duration, eligibleList, onComplete)
    if currentVote then
        SafeChat("⚠️ A vote is already running. Use the GM GUI to force or wait.")
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
    if gui and gui.VoteTitle then updateVoteUI() end
    spawn(function()
        while currentVote == v and tick() < v.endsAt do wait(0.5) end
        if currentVote ~= v then return end
        local highest = -1
        for i=1,#v.options do highest = math.max(highest, v.counts[i] or 0) end
        local top = {}
        for i=1,#v.options do if (v.counts[i] or 0) == highest then table.insert(top, i) end end
        local choiceIndex = (#top == 0) and 1 or top[math.random(1,#top)]
        SafeChat("🗳️ Vote ended: ["..string.char(64 + choiceIndex).."] "..v.options[choiceIndex].." ("..(v.counts[choiceIndex] or 0).." votes)")
        if v.onComplete then pcall(v.onComplete, choiceIndex, v.counts) end
        currentVote = nil
        if gui and gui.VoteTitle then updateVoteUI() end
    end)
    return v
end

local function recordVote(player, raw)
    if not currentVote then return false, "No active vote" end
    if not currentVote.eligible[player.UserId] then return false, "Not eligible to vote" end
    local s = tostring(raw)
    s = s:gsub("^%s*(.-)%s*$", "%1")
    if s:lower():sub(1, #CONFIG.VOTE_PREFIX) == CONFIG.VOTE_PREFIX then
        s = s:sub(#CONFIG.VOTE_PREFIX + 1)
        s = s:gsub("^%s*(.-)%s*$", "%1")
    end
    local idx = nil
    local num = tonumber(s)
    if num and num >= 1 and num <= #currentVote.options then idx = num end
    if not idx then
        local letter = s:match("^%a$") or s:match("([A-Za-z])")
        if letter then
            local code = string.byte(letter:upper()) - 64
            if code >= 1 and code <= #currentVote.options then idx = code end
        end
    end
    if not idx then return false, "Could not parse vote" end
    local prev = currentVote.votes[player.UserId]
    if prev then currentVote.counts[prev] = math.max(0, (currentVote.counts[prev] or 1) - 1) end
    currentVote.votes[player.UserId] = idx
    currentVote.counts[idx] = (currentVote.counts[idx] or 0) + 1
    if gui and gui.VoteTitle then updateVoteUI() end
    -- early finish if all eligible voted
    local totalEligible, totalVotes = 0, 0
    for id,_ in pairs(currentVote.eligible) do totalEligible = totalEligible + 1 end
    for uid,_ in pairs(currentVote.votes) do totalVotes = totalVotes + 1 end
    if totalVotes >= totalEligible then
        local highest = -1
        for i=1,#currentVote.options do highest = math.max(highest, currentVote.counts[i] or 0) end
        local top = {}
        for i=1,#currentVote.options do if (currentVote.counts[i] or 0) == highest then table.insert(top, i) end end
        local chosen = top[math.random(1,#top)]
        SafeChat("🗳️ All votes in. Result: ["..string.char(64 + chosen).."] "..currentVote.options[chosen].." ("..(currentVote.counts[chosen] or 0).." votes)")
        if currentVote.onComplete then pcall(currentVote.onComplete, chosen, currentVote.counts) end
        currentVote = nil
        if gui and gui.VoteTitle then updateVoteUI() end
    end
    return true
end

-- NODE PRESENTATION & RESOLUTION
local function resolveOption(node, optIndex, voteCounts)
    local option = node.options[optIndex]
    if not option then SafeChat("Choice resolution error"); return end
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
            local amount = (roll % 6) + 1
            local alive = {}
            for _, id in ipairs(partyOrder) do if party[id] and party[id].Alive then table.insert(alive, id) end end
            if #alive > 0 then
                local uid = alive[math.random(1,#alive)]
                damagePlayer(uid, amount, "misfortune")
            end
        end
    end
    if option.next then
        currentNodeId = option.next
    else
        currentNodeId = nil
        adventureRunning = false
    end
    if gui then updateAllUI() end
    -- If next exists and adventure running, present the new node
    if adventureRunning and currentNodeId then
        wait(1) -- small pause to let messages be read
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
    for _, opt in ipairs(node.options) do table.insert(opts, opt.label) end
    if #opts == 0 then adventureRunning = false; updateAllUI(); return end
    startVote(node.title, opts, CONFIG.VOTE_DURATION, partyOrder, function(choiceIndex, counts)
        resolveOption(node, choiceIndex, counts)
    end)
    if gui then updateAllUI() end
end

-- GUI CREATION (tries PlayerGui; falls back to CoreGui when needed)
function createGui()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "DnDAdventureGUI"
    screenGui.ResetOnSpawn = false

    -- Try to parent to PlayerGui first; if not available/allowed, use CoreGui (may require exploit privileges)
    local parentOk = false
    pcall(function()
        local playerGui = LocalPlayer:FindFirstChild("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui", 2)
        if playerGui then
            screenGui.Parent = playerGui
            parentOk = true
        end
    end)
    if not parentOk then
        pcall(function() screenGui.Parent = game:GetService("CoreGui") end)
        if not screenGui.Parent then
            -- As a last resort, parent to ReplicatedStorage so the GM can still inspect (no visible GUI)
            screenGui.Parent = ReplicatedStorage
            SafeChat("⚠️ GUI couldn't be parented to PlayerGui/CoreGui. It will not be visible.")
        end
    end

    gui.Root = screenGui

    local main = Instance.new("Frame", screenGui)
    main.Name = "Main"
    main.Size = UDim2.new(0,920,0,560)
    main.Position = UDim2.new(0.5,-460,0.5,-280)
    main.AnchorPoint = Vector2.new(0.5,0.5)
    main.BackgroundColor3 = Color3.fromRGB(28,28,28)
    gui.Main = main

    local title = Instance.new("TextLabel", main)
    title.Size = UDim2.new(1,0,0,32)
    title.Position = UDim2.new(0,0,0,0)
    title.BackgroundTransparency = 1
    title.Font = Enum.Font.SourceSansBold
    title.TextSize = 20
    title.TextColor3 = Color3.new(1,1,1)
    title.Text = "Dungeons & Dragons - Chat Adventure (GM)"

    -- Party frame
    local partyFrame = Instance.new("Frame", main)
    partyFrame.Size = UDim2.new(0,280,1,-60)
    partyFrame.Position = UDim2.new(0,10,0,50)
    partyFrame.BackgroundColor3 = Color3.fromRGB(22,22,22)
    gui.PartyList = Instance.new("ScrollingFrame", partyFrame)
    gui.PartyList.Size = UDim2.new(1,-10,1,-40)
    gui.PartyList.Position = UDim2.new(0,5,0,30)
    gui.PartyList.BackgroundTransparency = 1
    gui.PartyList.ScrollBarThickness = 6

    -- Center: node & vote
    local center = Instance.new("Frame", main)
    center.Size = UDim2.new(0,520,1,-60)
    center.Position = UDim2.new(0,300,0,50)
    center.BackgroundTransparency = 1
    gui.Center = center

    gui.NodeTitle = Instance.new("TextLabel", center)
    gui.NodeTitle.Size = UDim2.new(1,0,0,28)
    gui.NodeTitle.Position = UDim2.new(0,0,0,0)
    gui.NodeTitle.BackgroundTransparency = 1
    gui.NodeTitle.Font = Enum.Font.SourceSansBold
    gui.NodeTitle.TextSize = 18
    gui.NodeTitle.Text = "No active node"

    gui.NodeDesc = Instance.new("TextBox", center)
    gui.NodeDesc.Size = UDim2.new(1,0,0,150)
    gui.NodeDesc.Position = UDim2.new(0,0,0,32)
    gui.NodeDesc.MultiLine = true
    gui.NodeDesc.TextWrapped = true
    gui.NodeDesc.Text = ""
    gui.NodeDesc.ClearTextOnFocus = false
    gui.NodeDesc.ReadOnly = true
    gui.NodeDesc.BackgroundColor3 = Color3.fromRGB(38,38,38)
    gui.NodeDesc.TextColor3 = Color3.new(1,1,1)

    -- Vote area
    local voteFrame = Instance.new("Frame", center)
    voteFrame.Size = UDim2.new(1,0,0,200)
    voteFrame.Position = UDim2.new(0,0,0,200)
    voteFrame.BackgroundColor3 = Color3.fromRGB(18,18,18)
    gui.VoteFrame = voteFrame

    gui.VoteTitle = Instance.new("TextLabel", voteFrame)
    gui.VoteTitle.Size = UDim2.new(1,0,0,24)
    gui.VoteTitle.Position = UDim2.new(0,0,0,0)
    gui.VoteTitle.BackgroundTransparency = 1
    gui.VoteTitle.Font = Enum.Font.SourceSansBold
    gui.VoteTitle.TextColor3 = Color3.new(1,1,1)
    gui.VoteTitle.Text = "No active vote"

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

    gui.StartBtn = Instance.new("TextButton", right)
    gui.StartBtn.Size = UDim2.new(1, -10, 0, 30)
    gui.StartBtn.Position = UDim2.new(0,5,0,6)
    gui.StartBtn.Text = "Start Adventure"
    gui.StartBtn.BackgroundColor3 = Color3.fromRGB(70,130,70)

    gui.EndBtn = Instance.new("TextButton", right)
    gui.EndBtn.Size = UDim2.new(1, -10, 0, 30)
    gui.EndBtn.Position = UDim2.new(0,5,0,42)
    gui.EndBtn.Text = "End Adventure"
    gui.EndBtn.BackgroundColor3 = Color3.fromRGB(130,70,70)

    gui.ForceBtn = Instance.new("TextButton", right)
    gui.ForceBtn.Size = UDim2.new(1, -10, 0, 28)
    gui.ForceBtn.Position = UDim2.new(0,5,0,78)
    gui.ForceBtn.Text = "Force Vote Result"
    gui.ForceBtn.BackgroundColor3 = Color3.fromRGB(200,120,0)

    gui.Log = Instance.new("TextBox", main)
    gui.Log.Size = UDim2.new(1, -20, 0, 80)
    gui.Log.Position = UDim2.new(0,10,1,-90)
    gui.Log.MultiLine = true
    gui.Log.TextWrapped = true
    gui.Log.ReadOnly = true
    gui.Log.Text = "Log:"
    gui.Log.BackgroundColor3 = Color3.fromRGB(18,18,18)
    gui.Log.TextColor3 = Color3.new(1,1,1)

    -- Wiring buttons
    gui.StartBtn.MouseButton1Click:Connect(function()
        if adventureRunning then SafeChat("Adventure already running."); return end
        if not currentNodeId then currentNodeId = "crossroads" end
        adventureRunning = true
        SafeChat("🏁 The GM has begun the adventure!")
        presentNode(currentNodeId)
    end)

    gui.EndBtn.MouseButton1Click:Connect(function()
        adventureRunning = false
        SafeChat("🏁 The GM has ended the adventure.")
        updateAllUI()
    end)

    gui.ForceBtn.MouseButton1Click:Connect(function()
        if not currentVote then SafeChat("No active vote to force."); return end
        local highest = -1; local top = {}
        for i=1,#currentVote.options do highest = math.max(highest, currentVote.counts[i] or 0) end
        for i=1,#currentVote.options do if (currentVote.counts[i] or 0) == highest then table.insert(top,i) end end
        local chosen = top[1] or 1
        SafeChat("🛠️ GM forced result: ["..string.char(64 + chosen).."] "..currentVote.options[chosen])
        if currentVote.onComplete then pcall(currentVote.onComplete, chosen, currentVote.counts) end
        currentVote = nil
        updateAllUI()
    end)
end

-- UI UPDATES
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
    local nd = nodes[currentNodeId]
    if nd then
        gui.NodeTitle.Text = nd.title
        gui.NodeDesc.Text = nd.desc
    else
        gui.NodeTitle.Text = "Unknown node"
        gui.NodeDesc.Text = ""
    end
end

function updateAllUI()
    updatePartyUI()
    updateVoteUI()
    updateNodeUI()
    if gui and gui.Log then
        local lines = {"Log:"}
        for i = math.max(1, #messageLog - 20), #messageLog do table.insert(lines, messageLog[i]) end
        gui.Log.Text = table.concat(lines, "\n")
    end
end

-- CHAT HANDLING (compat fallback)
local function getPlayerByName(name)
    if not name then return nil end
    name = name:lower()
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Name:lower():sub(1,#name) == name or p.DisplayName:lower():sub(1,#name) == name then return p end
    end
    return nil
end

local function handleChat(player, message)
    if not player or not message then return end
    appendLog(("%s: %s"):format(player.DisplayName, message))
    local msg = tostring(message)
    local lower = msg:lower()

    -- Voting
    if currentVote then
        local ok, err = recordVote(player, msg)
        if ok then appendLog(player.DisplayName.." voted.") ; return end
    end

    -- Commands
    if lower:match("^!join") then addPlayerToParty(player); return end
    if lower:match("^!leave") then removePlayerFromParty(player); return end
    if lower:match("^!start") and player.UserId == gmUserId then
        if not adventureRunning then adventureRunning = true; if not currentNodeId then currentNodeId = "crossroads" end; SafeChat("🏁 GM starts the adventure!"); presentNode(currentNodeId) else SafeChat("Adventure already running.") end
        return
    end
    if lower:match("^!end") and player.UserId == gmUserId then adventureRunning = false; SafeChat("🏁 GM ends the adventure."); updateAllUI(); return end
    if lower:sub(1, #CONFIG.VOTE_PREFIX) == CONFIG.VOTE_PREFIX then
        local rest = msg:sub(#CONFIG.VOTE_PREFIX + 1)
        local ok, err = recordVote(player, rest)
        if ok then appendLog(player.DisplayName.." cast a vote via prefix.") else appendLog("Vote parse failed for "..player.DisplayName..": "..(err or "unknown")) end
        return
    end
    if lower:match("^!status") then
        local char = party[player.UserId]
        if not char then SafeChat(player.DisplayName..", you are not in the party. Type !join to join.") else SafeChat(("Status for %s | HP: %d/%d | Gold: %d | XP: %d | Items: %d"):format(char.DisplayName, char.HP, char.MaxHP, char.Gold, char.XP, #char.Inventory)) end
        return
    end
    if lower:match("^!roll ") then
        local notat = msg:sub(7)
        local r = rollDice(notat)
        SafeChat(("🎲 %s rolls %s -> %d"):format(player.DisplayName, notat, r))
        return
    end
end

-- Hook chat events robustly
if TextChatService and TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
    pcall(function()
        TextChatService.MessageReceived:Connect(function(textChatMessage)
            local src = textChatMessage.TextSource
            if src and src.UserId then
                local player = Players:GetPlayerByUserId(src.UserId)
                if player then handleChat(player, textChatMessage.Text) end
            end
        end)
    end)
else
    -- Fallback to .Chatted on players
    for _, p in ipairs(Players:GetPlayers()) do
        p.Chatted:Connect(function(msg) handleChat(p, msg) end)
    end
    Players.PlayerAdded:Connect(function(p) p.Chatted:Connect(function(msg) handleChat(p, msg) end) end)
end

-- Initialize GUI and seed demo party when in Studio
createGui()
updateAllUI()

if RunService:IsStudio() then
    if #partyOrder == 0 then
        addPlayerToParty(LocalPlayer)
        for i=1,2 do
            local fakeId = 900000 + i
            local fakeName = "NPC_"..i
            party[fakeId] = {UserId=fakeId, Name=fakeName, DisplayName=fakeName, Level=1, XP=0, Gold=10, MaxHP=CONFIG.BASE_HP + math.random(1,6), HP=CONFIG.BASE_HP, Inventory={}, Keys={}, MapFragments=0, Alive=true}
            table.insert(partyOrder, fakeId)
        end
        updateAllUI()
    end
end

SafeChat("📜 D&D Adventure GM script active. Players: type !join to join. Votes will be presented; cast votes with '"..CONFIG.VOTE_PREFIX.." A' or single-letter 'A' while voting.")
appendLog("Script loaded and executor-compatible adjustments applied.")

-- END OF SCRIPT
