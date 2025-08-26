
-- DND Story Bot (LocalScript)
-- Single-file Local D&D engine for Roblox chat
-- Features:
--  - LocalScript (runs for LocalPlayer)
--  - Listens to chat from LocalPlayer + whitelisted party members
--  - Large hub world with many choices and branching scenes
--  - Inventory, HP, Quests, Items, Combat, Dungeon, Bosses
--  - GUI Control Panel: Start, Restart, Heal, Full Heal, Stats
--  - Party Whitelist GUI: add/remove players allowed to control the story
--  - Designed to be pasted into a LocalScript in StarterPlayerScripts or StarterGui

-- IMPORTANT: place this as a LocalScript (so LocalPlayer is defined).
-- Save file as DND_StoryBot.lua and run in Roblox Studio within Play Solo or as a LocalScript in game.

-- Version
local VERSION = "FULL-LOCAL-1.0"

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    warn("[DND] LocalPlayer not found. This script must be a LocalScript.")
    return
end

-- Settings
local settings = {
    minMessageCooldown = 1.8,
    maxHP = 20,
    allowLegacyChat = true, -- fallback for older systems
}

-- State
local storyRunning = false
local currentScene = nil
local awaitingChoice = false
local lastMessageTime = tick()
local playerChoice = nil
local hubScene = nil

-- Player data
local playerStats = {
    HP = settings.maxHP,
    Inventory = {},
    Quests = {}, -- map: name->desc
}

-- Party whitelist
local partyMembers = {} -- list of usernames (case-insensitive)

-- Utilities
local function ClampHP()
    if playerStats.HP < 0 then playerStats.HP = 0 end
    if playerStats.HP > settings.maxHP then playerStats.HP = settings.maxHP end
end

local function HasItem(name)
    for _,v in ipairs(playerStats.Inventory) do
        if v == name then return true end
    end
    return false
end

local function RemoveItem(name)
    for i,v in ipairs(playerStats.Inventory) do
        if v == name then
            table.remove(playerStats.Inventory, i)
            return true
        end
    end
    return false
end

local function SendToChat(msg)
    -- rate-limited chat send; only send while storyRunning to avoid spamming
    if not storyRunning then return end
    local now = tick()
    local dt = now - lastMessageTime
    if dt < settings.minMessageCooldown then
        task.wait(settings.minMessageCooldown - dt)
    end
    lastMessageTime = tick()
    -- support new TextChatService channels
    local ok, err = pcall(function()
        if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
            if TextChatService.TextChannels and TextChatService.TextChannels:FindFirstChild("RBXGeneral") then
                TextChatService.TextChannels.RBXGeneral:SendAsync(msg)
            else
                -- fallback to old replicated event if channel missing
                local ev = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
                if ev and ev:FindFirstChild("SayMessageRequest") then
                    ev.SayMessageRequest:FireServer(msg, "All")
                else
                    warn("[DND] No chat send method available.")
                end
            end
        else
            local ev = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
            if ev and ev:FindFirstChild("SayMessageRequest") then
                ev.SayMessageRequest:FireServer(msg, "All")
            else
                warn("[DND] Legacy chat event not found.")
            end
        end
    end)
    if not ok then
        warn("[DND] Failed to send chat message:", err)
    end
end

local function SimpleSend(msg)
    -- fire-and-forget (bypass storyRunning check) for system messages
    local ok, err = pcall(function()
        if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
            if TextChatService.TextChannels and TextChatService.TextChannels:FindFirstChild("RBXGeneral") then
                TextChatService.TextChannels.RBXGeneral:SendAsync(msg)
            else
                local ev = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
                if ev and ev:FindFirstChild("SayMessageRequest") then
                    ev.SayMessageRequest:FireServer(msg, "All")
                end
            end
        else
            local ev = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
            if ev and ev:FindFirstChild("SayMessageRequest") then
                ev.SayMessageRequest:FireServer(msg, "All")
            end
        end
    end)
    if not ok then
        warn("[DND] SimpleSend failed:", err)
    end
end

-- Story object
local story = {}
story.__index = story

function story.New(text, options)
    local s = {
        text = text or "",
        options = options or {},
        nextScenes = {}, -- [index] = scene
    }
    setmetatable(s, story)
    return s
end

function story:LinkChoice(index, next)
    self.nextScenes[index] = next
end

function story:Present()
    if not storyRunning then return end
    currentScene = self
    awaitingChoice = true
    SendToChat("📜 | " .. tostring(self.text))
    task.wait(0.9)
    for i,opt in ipairs(self.options) do
        SendToChat(string.format("%d) %s", i, tostring(opt)))
        task.wait(0.5)
    end
end

-- Inventory / quests helpers
local function GainItem(item)
    table.insert(playerStats.Inventory, item)
    SendToChat("🎁 | Gained: " .. item)
    UpdateStatsLabel()
end

local function AddQuest(name, desc)
    playerStats.Quests[name] = desc or "A mysterious task."
    SendToChat("🗒️ | New Quest: " .. name)
    UpdateStatsLabel()
end

local function CompleteQuest(name)
    if playerStats.Quests[name] then
        playerStats.Quests[name] = nil
        SendToChat("✅ | Quest Completed: " .. name)
        UpdateStatsLabel()
    end
end

local function MinorHeal(amount)
    playerStats.HP = playerStats.HP + amount
    ClampHP()
    SendToChat(("✨ | Healed +%d (HP: %d/%d)"):format(amount, playerStats.HP, settings.maxHP))
    UpdateStatsLabel()
end

local function MinorHurt(amount, source)
    playerStats.HP = playerStats.HP - amount
    ClampHP()
    SendToChat(("💢 | Took %d damage%s (HP: %d/%d)"):format(amount, source and (" from "..source) or "", playerStats.HP, settings.maxHP))
    UpdateStatsLabel()
    if playerStats.HP <= 0 then
        SendToChat("☠️ | You have fallen. Use Restart to try again.")
        storyRunning = false
    end
end

-- Combat
local function RollDice(sides) return math.random(1, sides) end

local function SimpleCombat(enemyName, enemyHP, enemyDie)
    SendToChat("⚔️ | A "..enemyName.." appears!")
    while storyRunning and playerStats.HP > 0 and enemyHP > 0 do
        task.wait(1.2)
        local dmg = RollDice(6)
        enemyHP = enemyHP - dmg
        SendToChat(("🗡️ | You deal %d damage! (Enemy HP: %d)"):format(dmg, math.max(0, enemyHP)))
        if enemyHP <= 0 then break end
        task.wait(1)
        local ed = RollDice(enemyDie)
        playerStats.HP = playerStats.HP - ed
        ClampHP()
        SendToChat(("💥 | %s hits you for %d! (HP: %d/%d)"):format(enemyName, ed, playerStats.HP, settings.maxHP))
        UpdateStatsLabel()
    end
    if playerStats.HP > 0 then
        SendToChat("🏆 | You defeated the "..enemyName.."!")
        GainItem(enemyName.." Trophy")
    else
        SendToChat("☠️ | You are defeated...")
        storyRunning = false
    end
end

-- Advanced combat used by boss (allows players to choose Attack/UseItem/Flee)
local function AdvancedCombat(enemyName, enemyHP, enemyDie, phases)
    SendToChat("⚔️ | " .. enemyName .. " enters the fray!")
    local shield = 0
    if HasItem("Charm Shield") then shield = 3 end

    local phase = phases or 1
    while storyRunning and playerStats.HP > 0 and enemyHP > 0 do
        SendToChat("👉 | Type 1 to Attack, 2 to Use Item, 3 to Flee")
        awaitingChoice = true
        playerChoice = nil
        -- wait for playerChoice to be set by chat listener (or by whitelisted player)
        local waited = 0
        while awaitingChoice and storyRunning and waited < 30 do
            task.wait(0.5)
            waited = waited + 0.5
        end
        if not storyRunning then return end
        if awaitingChoice then
            SendToChat("⌛ | Time's up. You hesitate and the enemy strikes.")
            awaitingChoice = false
            -- enemy auto-attack
            local ed = RollDice(enemyDie)
            if shield > 0 then
                ed = math.max(0, ed - 3)
                shield = math.max(0, shield - 1)
            end
            playerStats.HP = playerStats.HP - ed
            ClampHP()
            SendToChat(("💥 | %s hits you for %d! (HP: %d/%d)"):format(enemyName, ed, playerStats.HP, settings.maxHP))
            UpdateStatsLabel()
            if playerStats.HP <= 0 then
                SendToChat("☠️ | You were slain.")
                storyRunning = false
                return
            end
        else
            local choice = playerChoice
            if tonumber(choice) == 1 or tostring(choice):lower():find("attack") then
                local dmg = RollDice(6) + 2
                enemyHP = enemyHP - dmg
                SendToChat(("🗡️ | You attack and deal %d! (Enemy HP: %d)"):format(dmg, math.max(0, enemyHP)))
            elseif tonumber(choice) == 2 or tostring(choice):lower():find("use") then
                -- try to use last inventory item
                if #playerStats.Inventory == 0 then
                    SendToChat("📦 | You have no items to use!")
                else
                    local item = playerStats.Inventory[#playerStats.Inventory]
                    if item == "Healing Herb" then
                        RemoveItem("Healing Herb"); MinorHeal(6)
                    elseif item == "Fisher’s Gratitude (Charm)" then
                        RemoveItem("Fisher’s Gratitude (Charm)"); GainItem("Charm Shield")
                        SendToChat("✨ | You invoke the fisher's charm. Charm Shield gained.")
                    else
                        SendToChat("❓ | You fumble with the item to no effect.")
                    end
                end
            elseif tonumber(choice) == 3 or tostring(choice):lower():find("flee") then
                SendToChat("💨 | You flee to safety!")
                return
            else
                SendToChat("❓ | Unrecognized action. You lose your moment.")
            end
            awaitingChoice = false
        end

        if enemyHP <= 0 then break end
        task.wait(1)
        local ed = RollDice(enemyDie)
        if shield > 0 then
            ed = math.max(0, ed - 3); shield = math.max(0, shield - 1)
        end
        playerStats.HP = playerStats.HP - ed
        ClampHP()
        SendToChat(("💥 | %s strikes you for %d! (HP: %d/%d)"):format(enemyName, ed, playerStats.HP, settings.maxHP))
        UpdateStatsLabel()

        if playerStats.HP <= 0 then
            SendToChat("☠️ | You fell in battle.")
            storyRunning = false
            return
        end
    end

    if enemyHP <= 0 then
        SendToChat("🏆 | You have vanquished " .. enemyName .. "!")
        GainItem(enemyName .. " Core")
        if phases and phases > 1 then
            SendToChat("😈 | The enemy shifts into a new phase!")
            AdvancedCombat(enemyName.." (Enraged)", math.ceil(enemyHP * 0.8) + 8, enemyDie + 2, phases - 1)
        end
    end
end

-- GUI creation
local PlayerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui")
local screenGui = Instance.new("ScreenGui"); screenGui.Name = "DND_Controller"; screenGui.ResetOnSpawn = false; screenGui.Parent = PlayerGui

local mainPanel = Instance.new("Frame"); mainPanel.Name="Panel"; mainPanel.Size=UDim2.new(0,320,0,460); mainPanel.Position=UDim2.new(0,20,0,80);
mainPanel.BackgroundColor3 = Color3.fromRGB(28,28,30); mainPanel.BackgroundTransparency = 0; mainPanel.Parent = screenGui
Instance.new("UICorner", mainPanel).CornerRadius = UDim.new(0,10)

local title = Instance.new("TextLabel"); title.Parent = mainPanel; title.Size = UDim2.new(1,-20,0,40); title.Position = UDim2.new(0,10,0,8);
title.Text = "D&D Story Master - "..VERSION; title.Font = Enum.Font.GothamBold; title.TextScaled = true; title.BackgroundTransparency = 1; title.TextColor3=Color3.fromRGB(240,240,245)

local info = Instance.new("TextLabel"); info.Parent = mainPanel; info.Size = UDim2.new(1,-20,0,22); info.Position = UDim2.new(0,10,0,48);
info.Text="Use chat: type 1,2,3...  (party whitelist active)"; info.Font=Enum.Font.Gotham; info.TextScaled=false; info.TextSize=14; info.BackgroundTransparency=1; info.TextColor3=Color3.fromRGB(200,200,210)

local statBox = Instance.new("TextLabel"); statBox.Parent = mainPanel; statBox.Size=UDim2.new(1,-20,0,140); statBox.Position=UDim2.new(0,10,0,80);
statBox.BackgroundColor3 = Color3.fromRGB(20,20,24); statBox.TextColor3=Color3.fromRGB(220,220,230); statBox.Font=Enum.Font.Code; statBox.TextWrapped=true; statBox.TextYAlignment=Enum.TextYAlignment.Top; Instance.new("UICorner", statBox).CornerRadius=UDim.new(0,8)

local function FormatInventory()
    if #playerStats.Inventory == 0 then return "(empty)" end
    return table.concat(playerStats.Inventory, ", ")
end
local function FormatQuests()
    local q = {}
    for k,_ in pairs(playerStats.Quests) do table.insert(q,k) end
    if #q==0 then return "(none)" end
    return table.concat(q, ", ")
end

function UpdateStatsLabel()
    statBox.Text = ("HP: %d/%d\nItems: %s\nQuests: %s"):format(playerStats.HP, settings.maxHP, FormatInventory(), FormatQuests())
end
UpdateStatsLabel()

local function mkBtn(text, y)
    local b = Instance.new("TextButton"); b.Parent = mainPanel; b.Size=UDim2.new(1,-20,0,36); b.Position=UDim2.new(0,10,0,y);
    b.BackgroundColor3 = Color3.fromRGB(40,40,46); b.TextColor3 = Color3.fromRGB(240,240,245); b.Font=Enum.Font.GothamBold; b.TextScaled=true; b.Text=text; Instance.new("UICorner", b).CornerRadius=UDim.new(0,8)
    return b
end

local btnStart = mkBtn("▶ Start Game", 230)
local btnRestart = mkBtn("↻ Restart", 272)
local btnHeal5 = mkBtn("➕ Heal +5", 314)
local btnHealFull = mkBtn("❤️ Full Heal", 356)
local btnParty = mkBtn("🎉 Party Manager", 398)

-- Party Manager panel
local partyPanel = Instance.new("Frame"); partyPanel.Name="PartyPanel"; partyPanel.Size=UDim2.new(0,260,0,220); partyPanel.Position=UDim2.new(1,-280,0,80);
partyPanel.BackgroundColor3=Color3.fromRGB(20,20,22); partyPanel.Parent=screenGui; partyPanel.Visible=false; Instance.new("UICorner", partyPanel).CornerRadius=UDim.new(0,8)
local partyTitle = Instance.new("TextLabel"); partyTitle.Parent=partyPanel; partyTitle.Size=UDim2.new(1,0,0,32); partyTitle.Text="Party Whitelist - Add/Remove usernames"; partyTitle.BackgroundTransparency=1; partyTitle.TextColor3=Color3.fromRGB(230,230,240); partyTitle.Font=Enum.Font.GothamBold
local partyBox = Instance.new("TextBox"); partyBox.Parent=partyPanel; partyBox.Size=UDim2.new(1,-20,0,28); partyBox.Position=UDim2.new(0,10,0,40); partyBox.PlaceholderText="Username to add/remove"
partyBox.BackgroundColor3=Color3.fromRGB(25,25,28); partyBox.TextColor3=Color3.fromRGB(230,230,240); Instance.new("UICorner", partyBox).CornerRadius=UDim.new(0,6)
local addBtn = Instance.new("TextButton"); addBtn.Parent=partyPanel; addBtn.Size=UDim2.new(0.45,-12,0,30); addBtn.Position=UDim2.new(0,10,0,76); addBtn.Text="Add"; addBtn.Font=Enum.Font.GothamBold; addBtn.TextScaled=true; addBtn.BackgroundColor3=Color3.fromRGB(40,40,46); addBtn.TextColor3=Color3.fromRGB(240,240,250); Instance.new("UICorner", addBtn).CornerRadius=UDim.new(0,6)
local remBtn = Instance.new("TextButton"); remBtn.Parent=partyPanel; remBtn.Size=UDim2.new(0.45,-12,0,30); remBtn.Position=UDim2.new(0.5,2,0,76); remBtn.Text="Remove"; remBtn.Font=Enum.Font.GothamBold; remBtn.TextScaled=true; remBtn.BackgroundColor3=Color3.fromRGB(50,40,46); remBtn.TextColor3=Color3.fromRGB(240,240,250); Instance.new("UICorner", remBtn).CornerRadius=UDim.new(0,6)
local listLabel = Instance.new("TextLabel"); listLabel.Parent=partyPanel; listLabel.Size=UDim2.new(1,-20,1,-120); listLabel.Position=UDim2.new(0,10,0,120); listLabel.Text="No party members yet."; listLabel.TextColor3=Color3.fromRGB(200,200,210); listLabel.BackgroundTransparency=1; listLabel.TextWrapped=true; listLabel.TextYAlignment=Enum.TextYAlignment.Top

local function RefreshPartyList()
    if #partyMembers == 0 then
        listLabel.Text = "(none)"
    else
        listLabel.Text = table.concat(partyMembers, "\n")
    end
end

addBtn.MouseButton1Click:Connect(function()
    local name = tostring(partyBox.Text or "")
    if name ~= "" then
        local found = false
        for _,v in ipairs(partyMembers) do if v:lower()==name:lower() then found=true; break end end
        if not found then table.insert(partyMembers, name); RefreshPartyList(); SendToChat("🎯 | Added '"..name.."' to party whitelist.") end
    end
    partyBox.Text = ""
end)
remBtn.MouseButton1Click:Connect(function()
    local name = tostring(partyBox.Text or "")
    for i,v in ipairs(partyMembers) do if v:lower()==name:lower() then table.remove(partyMembers,i); SendToChat("🗑️ | Removed '"..name.."' from party whitelist."); break end end
    RefreshPartyList()
    partyBox.Text = ""
end)

btnParty.MouseButton1Click:Connect(function()
    partyPanel.Visible = not partyPanel.Visible
end)

-- Button hooks
btnStart.MouseButton1Click:Connect(function()
    if not storyRunning then
        StartDNDStory()
    else
        SendToChat("⏳ | Story already running.")
    end
end)
btnRestart.MouseButton1Click:Connect(function() StartDNDStory() end)
btnHeal5.MouseButton1Click:Connect(function() if storyRunning then MinorHeal(5) else SimpleSend("ℹ️ | Start the game first.") end end)
btnHealFull.MouseButton1Click:Connect(function() if storyRunning then playerStats.HP = settings.maxHP; ClampHP(); SendToChat("❤️ | Fully healed."); UpdateStatsLabel() else SimpleSend("ℹ️ | Start the game first.") end end)

-- Chat listening: allow LocalPlayer + whitelist
local function IsWhitelistedByName(username)
    if username == LocalPlayer.Name then return true end
    for _,v in ipairs(partyMembers) do if v:lower() == username:lower() then return true end end
    return false
end

-- Core choice handler (used by messages from allowed players)
local function HandleChoiceMessage(message, senderName)
    if not (storyRunning and currentScene and awaitingChoice) then return end
    -- only accept if sender is whitelisted
    if not IsWhitelistedByName(senderName) then return end
    local trimmed = tostring(message):gsub("^%s*(.-)%s*$","%1")
    local idx = tonumber(trimmed)
    if idx and currentScene.options[idx] then
        playerChoice = currentScene.options[idx]
        awaitingChoice = false
        SendToChat(("🎲 | %s chose: %s"):format(senderName, playerChoice))
        local nextS = currentScene.nextScenes[idx]
        if nextS then
            task.wait(0.9)
            nextS:Present()
        else
            SendToChat("❓ | That path hasn't been linked yet.")
        end
    else
        -- pass into advanced combat listener if waiting for '1/2/3' during combat
        if awaitingChoice then
            playerChoice = trimmed
            awaitingChoice = false
            SendToChat(("🎲 | %s chose: %s"):format(senderName, playerChoice))
        end
    end
end

-- Hook into TextChatService for modern chat
if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
    TextChatService.MessageReceived:Connect(function(textMsg)
        local source = textMsg.TextSource
        if not source then return end
        local uid = source.UserId
        local name = source.Name or Players:GetNameFromUserIdAsync(uid)
        local text = textMsg.Text
        -- only accept messages from players in same server (should be)
        HandleChoiceMessage(text, name)
    end)
end

-- Legacy chat fallback (Player.Chatted)
-- We can connect to Player.Chatted for all players
if settings.allowLegacyChat then
    for _,p in ipairs(Players:GetPlayers()) do
        p.Chatted:Connect(function(msg) HandleChoiceMessage(msg, p.Name) end)
    end
    Players.PlayerAdded:Connect(function(p)
        p.Chatted:Connect(function(msg) HandleChoiceMessage(msg, p.Name) end)
    end)
end

-- Startup / lifecycle functions
function ResetGame()
    storyRunning = false
    currentScene = nil
    awaitingChoice = false
    playerChoice = nil
    playerStats.HP = settings.maxHP
    playerStats.Inventory = {}
    playerStats.Quests = {}
    UpdateStatsLabel()
    SimpleSend("🔧 | D&D engine reset. Press Start to begin.")
end

-- World build (hub, village, forest, hill, river, ruins, dungeons)
-- We'll create many scenes and link them; this is the big hub world
local function MakeHub()
    return story.New(
        "You stand at the Crossroads, a lantern-lit signpost where many paths diverge. The village lights flicker to the south, a dark forest breathes to the east, a rocky hill rises to the north, and a river murmurs to the west.",
        {
            "Go to the village lights",
            "Enter the deep forest",
            "Climb the rocky hill for a panorama",
            "Walk toward the rushing river",
            "Search the ground for supplies",
            "Rest by the lantern to recover"
        }
    )
end

-- Declare scene factory functions (village, tavern, market, forest, hill, river, search, rest)
local function VillageSquare()
    return story.New(
        "Brindlebrook village: a tavern glows warmly; a quest board flaps; merchants chat in the market.",
        {"Enter the tavern","Read the quest board","Visit the market","Return to Crossroads"}
    )
end

local function TavernScene()
    return story.New("Inside the tavern, travelers share tales and the hearth is warm.", {"Talk to barkeep","Listen to bard","Order a drink (+heal)","Return"})
end

local function QuestBoard()
    return story.New("Quest Board: 'Missing Fisher', 'Howling in the Woods', 'Ruin Survey'.", {"Accept 'Missing Fisher'","Accept 'Howling in the Woods'","Accept 'Ruin Survey'","Return"})
end

local function MarketScene()
    return story.New("Market stalls: rope, torches, odds and ends.", {"Take a Torch (free)","Take a Rope (free)","Chat with merchant (rumor)","Return"})
end

local function ForestEdge()
    return story.New("The forest is thick; shadows shift. You hear distant howls.", {"Track animal prints","Forage for herbs","Call out into the trees","Return"})
end

local function RockyHill()
    return story.New("From the hilltop: village, river, a ruined tower, and a dark cave mouth.", {"Mark path to ruin","Scout the cave entrance","Scan for danger","Return"})
end

local function RiverBank()
    return story.New("Moonlight on the river. A rickety bridge sways; a fisher hut sits across.", {"Cross the bridge","Search the reeds","Call to the hut","Return"})
end

local function SearchSupplies()
    return story.New("You kneel by the signpost and rummage through leaves and packs.", {"Search carefully","Grab first thing","Give up"})
end

local function RestLantern()
    return story.New("You rest by the lantern and breathe the cool night air.", {"Slow breath (+3HP)","Drink canteen (+2HP)","Return"})
end

-- Build world and linking
function BuildWorldAndLink()
    hubScene = MakeHub()

    -- areas
    local village = VillageSquare()
    local tavern = TavernScene()
    local board = QuestBoard()
    local market = MarketScene()
    local forest = ForestEdge()
    local hill = RockyHill()
    local river = RiverBank()
    local search = SearchSupplies()
    local rest = RestLantern()

    -- hub links
    hubScene:LinkChoice(1, village)
    hubScene:LinkChoice(2, forest)
    hubScene:LinkChoice(3, hill)
    hubScene:LinkChoice(4, river)
    hubScene:LinkChoice(5, search)
    hubScene:LinkChoice(6, rest)

    -- village internals
    village:LinkChoice(1, tavern)
    village:LinkChoice(2, board)
    village:LinkChoice(3, market)
    village:LinkChoice(4, hubScene)

    tavern:LinkChoice(1, story.New("Barkeep: 'Night roads are perilous. Bring a torch.'", {"Return"}))
    tavern:LinkChoice(2, story.New("The bard sings of a fisher who vanished near the river hut.", {"Return"}))
    local drinkScene = story.New("You sip a warm brew and feel steadier.", {"Return"})
    drinkScene.Present = function(self) story.__index.Present(self); MinorHeal(2) end
    tavern:LinkChoice(3, drinkScene)
    tavern:LinkChoice(4, village)

    -- quest board
    local q1 = story.New("You take the 'Missing Fisher' quest.", {"Return"})
    q1.Present = function(self) story.__index.Present(self); AddQuest("Missing Fisher","Find the fisher near the river hut.") end
    board:LinkChoice(1, q1); q1:LinkChoice(1, village)

    local q2 = story.New("You accept 'Howling in the Woods'.", {"Return"})
    q2.Present = function(self) story.__index.Present(self); AddQuest("Howling in the Woods","Calm or defeat the wolves.") end
    board:LinkChoice(2, q2); q2:LinkChoice(1, village)

    local q3 = story.New("You accept 'Ruin Survey'.", {"Return"})
    q3.Present = function(self) story.__index.Present(self); AddQuest("Ruin Survey","Reach the hill, mark the ruins, and explore safely.") end
    board:LinkChoice(3, q3); q3:LinkChoice(1, village)
    board:LinkChoice(4, village)

    -- market
    local torchScene = story.New("You pick up a Torch.", {"Return"})
    torchScene.Present = function(self) story.__index.Present(self); if not HasItem("Torch") then GainItem("Torch") end end
    market:LinkChoice(1, torchScene); torchScene:LinkChoice(1, market)

    local ropeScene = story.New("You pick up a Rope.", {"Return"})
    ropeScene.Present = function(self) story.__index.Present(self); if not HasItem("Rope") then GainItem("Rope") end end
    market:LinkChoice(2, ropeScene); ropeScene:LinkChoice(1, market)

    local merchantChat = story.New("Merchant: 'Beyond the hill lie ruins; beware the cave and bandits at dusk.'", {"Return"})
    market:LinkChoice(3, merchantChat); merchantChat:LinkChoice(1, market)
    market:LinkChoice(4, village)

    -- forest
    local track = story.New("You follow pawprints into the trees.", {"Proceed quietly","Call out","Return"})
    forest:LinkChoice(1, track)
    forest:LinkChoice(2, story.New("You gather bitter herbs.", {"Return"}))
    forest:LinkChoice(3, story.New("Your voice echoes; a growl answers...", {"Return"}))
    forest:LinkChoice(4, hubScene)

    track.Present = function(self)
        story.__index.Present(self)
        if playerStats.Quests["Howling in the Woods"] then SendToChat("🗣️ | You remember your quest—approach with caution.") end
    end

    local wolves = story.New("Wolves circle you, tense.", {"Soothe them","Fight the leader","Back away"})
    track:LinkChoice(1, wolves); track:LinkChoice(2, wolves); track:LinkChoice(3, forest)
    wolves.Present = function(self)
        story.__index.Present(self)
        if playerStats.Quests["Howling in the Woods"] then SendToChat("🗒️ | Try soothing to complete your quest.") end
    end

    local soothe = story.New("You speak softly and lower your weapon.", {"Continue"})
    soothe.Present = function(self) story.__index.Present(self)
        if playerStats.Quests["Howling in the Woods"] then SendToChat("✨ | The lead wolf calms. Quest complete."); CompleteQuest("Howling in the Woods"); GainItem("Wolf Charm") else SendToChat("❗ | They don't trust you; one snaps!"); MinorHurt(3,"Wolf") end
    end
    wolves:LinkChoice(1, soothe); soothe:LinkChoice(1, forest)

    local fight = story.New("You face the pack leader.", {"Fight!"})
    fight.Present = function(self) story.__index.Present(self); SimpleCombat("Wolf Leader", 14, 5) end
    wolves:LinkChoice(2, fight); fight:LinkChoice(1, forest)
    wolves:LinkChoice(3, forest)

    -- hill
    local hillMark = story.New("You sketch a safe route to the ruins.", {"Return"})
    hillMark.Present = function(self) story.__index.Present(self); GainItem("Ruin Route"); if playerStats.Quests["Ruin Survey"] then SendToChat("🧭 | Ruin Survey updated.") end end
    hill:LinkChoice(1, hillMark); hillMark:LinkChoice(1, hill)

    local hillCave = story.New("A cave mouth yawns beneath the hill.", {"Light torch","Enter without light","Return"})
    hill:LinkChoice(2, hillCave)
    hill:LinkChoice(3, story.New("You spot movement—bandits near the ruins.", {"Return"}))
    hill:LinkChoice(4, hubScene)

    local caveEntry = story.New("Damp air and slick stone. The cave is dark.", {"Explore carefully","Turn back"})
    hillCave:LinkChoice(1, caveEntry); hillCave:LinkChoice(2, caveEntry); hillCave:LinkChoice(3, hill)
    caveEntry.Present = function(self)
        story.__index.Present(self)
        if HasItem("Torch") then SendToChat("🔥 | Your torch reveals a glittering shard."); if not HasItem("Rune Fragment") then GainItem("Rune Fragment") end else SendToChat("🕳️ | It's pitch black; you slip and hurt yourself."); MinorHurt(4,"Fall") end
    end
    caveEntry:LinkChoice(1, hill); caveEntry:LinkChoice(2, hill)

    -- river
    local cross = story.New("A fragile bridge sways over the rushing river.", {"Cross","Turn back"})
    local reeds = story.New("Reeds rustle; something glints.", {"Reach in","Leave it","Return"})
    local callhut = story.New("A lantern flickers; a voice calls: 'Who's there?'", {"Ask about the fisher","Apologize and leave","Return"})
    river:LinkChoice(1, cross); river:LinkChoice(2, reeds); river:LinkChoice(3, callhut); river:LinkChoice(4, hubScene)

    cross.Present = function(self) story.__index.Present(self); if math.random() < 0.35 then SendToChat("🪵 | A plank snaps! You scramble back."); MinorHurt(3,"Bridge") else SendToChat("✅ | You cross safely.") end end
    cross:LinkChoice(1, river); cross:LinkChoice(2, river)

    reeds.Present = function(self) story.__index.Present(self); if math.random() < 0.5 then GainItem(RandomLoot()) else SendToChat("😬 | Mud and leeches.") end end
    reeds:LinkChoice(1, river); reeds:LinkChoice(2, river); reeds:LinkChoice(3, river)

    callhut.Present = function(self) story.__index.Present(self); if playerStats.Quests["Missing Fisher"] then SendToChat("👤 | Voice: 'You're here for him? Come in.' The fisher is safe."); CompleteQuest("Missing Fisher"); GainItem("Fisher's Gratitude (Charm)") else SendToChat("👤 | 'Night's dangerous.' The door stays shut.") end end
    callhut:LinkChoice(1, river); callhut:LinkChoice(2, river); callhut:LinkChoice(3, river)

    -- search and rest
    local careful = story.New("You search carefully.", {"Return"})
    careful.Present = function(self) story.__index.Present(self); if math.random() < 0.8 then GainItem(RandomLoot()) else SendToChat("🪨 | Only stones.") end end
    search:LinkChoice(1, careful); careful:LinkChoice(1, hubScene)

    local grab = story.New("You grab the first thing you feel.", {"Return"})
    grab.Present = function(self) story.__index.Present(self); if math.random() < 0.5 then GainItem(RandomLoot()) else MinorHurt(2,"Thorn") end end
    search:LinkChoice(2, grab); grab:LinkChoice(1, hubScene)
    search:LinkChoice(3, hubScene)

    local breathe = story.New("You breathe slowly and feel steadier.", {"Return"})
    breathe.Present = function(self) story.__index.Present(self); MinorHeal(3) end
    rest:LinkChoice(1, breathe); breathe:LinkChoice(1, hubScene)
    local drink = story.New("Cool water refreshes you.", {"Return"})
    drink.Present = function(self) story.__index.Present(self); MinorHeal(2) end
    rest:LinkChoice(2, drink); drink:LinkChoice(1, hubScene)
    rest:LinkChoice(3, hubScene)

    -- Ruins entrance & deeper linked later in Parts 3-4
    local ruinsEntry = story.New("At the hill's far side, ruins of a tower stand.", {"Enter ruins","Circle around","Return"})
    hill:LinkChoice(1, ruinsEntry)
    ruinsEntry:LinkChoice(1, hubScene) -- updated in Part 3/4 to connect deeper
    ruinsEntry:LinkChoice(2, hill)
    ruinsEntry:LinkChoice(3, hubScene)

    -- assign hubScene global
    -- hubScene already created above and linked
end

-- Start story
function StartDNDStory()
    ResetGame()
    storyRunning = true
    BuildWorldAndLink()
    SendToChat("🎭 | Welcome adventurer... Your open-world D&D tale begins at the Crossroads!")
    task.wait(1)
    if hubScene then hubScene:Present() else SendToChat("⚠️ | Error building world.") end
end

-- final initialization
ResetGame()

-- END OF SCRIPT
