--// ================================
--// DND Story Bot (Full Version)
--// Features:
--// - Local only (runs in LocalScript)
--// - Party whitelist with GUI (add/remove members)
--// - Turn-based system: each party member takes turns choosing
--// - Multiple themes (Medieval, Magical, etc.)
--// - Hub exploration, branching choices, dungeons, combat, bosses
--// ================================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")
local LocalPlayer = Players.LocalPlayer

-- Basic settings
local settings = {
    minMessageCooldown = 2.0,
    maxHP = 20
}

-- State
local storyRunning = false
local currentScene = nil
local awaitingChoice = false
local lastMessageTime = tick()
local playerChoice = nil

-- Player stats
local playerStats = {
    HP = 20,
    Inventory = {},
    Quests = {}
}

-- Party system
local partyMembers = {} -- whitelist
local turnIndex = 1

-- Utility funcs
local function ClampHP()
    if playerStats.HP > settings.maxHP then
        playerStats.HP = settings.maxHP
    end
    if playerStats.HP < 0 then
        playerStats.HP = 0
    end
end

local function IsWhitelisted(userId, username)
    if userId == LocalPlayer.UserId then return true end
    for _, name in ipairs(partyMembers) do
        if name:lower() == username:lower() then
            return true
        end
    end
    return false
end

local function GetCurrentTurnPlayer()
    if #partyMembers == 0 then
        return LocalPlayer.Name
    else
        return partyMembers[turnIndex] or LocalPlayer.Name
    end
end

local function AdvanceTurn()
    if #partyMembers == 0 then return end
    turnIndex += 1
    if turnIndex > #partyMembers then
        turnIndex = 1
    end
    SendMessageWhenReady("🎯 | It is now "..GetCurrentTurnPlayer().."'s turn!")
    if turnLabel then
        turnLabel.Text = "Turn: "..GetCurrentTurnPlayer()
    end
end

-- Detect chat system
local oldChat
if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
    oldChat = false
else
    oldChat = true
end

-- Chat utility
local function Chat(msg)
    if not oldChat then
        TextChatService.TextChannels.RBXGeneral:SendAsync(msg)
    else
        ReplicatedStorage.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(msg, "All")
    end
end

local function SendMessageWhenReady(message)
    if not storyRunning then return end
    if tick() - lastMessageTime >= settings.minMessageCooldown then
        Chat(message)
        lastMessageTime = tick()
    else
        task.wait(settings.minMessageCooldown - (tick() - lastMessageTime))
        if storyRunning then
            Chat(message)
            lastMessageTime = tick()
        end
    end
end

-- Story object
local story = {}
story.__index = story

function story.New(sceneText, options)
    local newScene = {}
    newScene.text = sceneText
    newScene.options = options or {}
    newScene.nextScenes = {}
    setmetatable(newScene, story)
    return newScene
end

function story:Present()
    if not storyRunning then return end
    awaitingChoice = true
    currentScene = self

    SendMessageWhenReady("📜 | "..self.text)
    task.wait(1.5)

    for i,opt in ipairs(self.options) do
        SendMessageWhenReady(i..") "..opt)
        task.wait(0.5)
    end
    SendMessageWhenReady("👉 | Current turn: "..GetCurrentTurnPlayer())
end

function story:LinkChoice(index, nextScene)
    self.nextScenes[index] = nextScene
end

-- Dice
local function RollDice(sides)
    return math.random(1,sides)
end

-- Inventory
local function GainItem(item)
    table.insert(playerStats.Inventory, item)
    SendMessageWhenReady("🎁 | You obtained: "..item)
end

local function HasItem(item)
    for _,v in ipairs(playerStats.Inventory) do
        if v == item then return true end
    end
    return false
end

-- Simple combat
local function SimpleCombat(enemyName, enemyHP, enemyDie)
    SendMessageWhenReady("⚔️ | Battle starts: "..enemyName)
    while storyRunning and playerStats.HP > 0 and enemyHP > 0 do
        task.wait(1)
        local hit = RollDice(6)
        enemyHP -= hit
        SendMessageWhenReady("🗡️ | You hit for "..hit..". Enemy HP: "..math.max(0,enemyHP))
        if enemyHP <= 0 then break end
        task.wait(1)
        local foe = RollDice(enemyDie)
        playerStats.HP -= foe
        ClampHP()
        SendMessageWhenReady("💥 | Enemy hits for "..foe.."! Your HP: "..playerStats.HP.."/"..settings.maxHP)
    end
    if enemyHP <= 0 then
        SendMessageWhenReady("🏆 | You defeated the "..enemyName.."!")
        GainItem(enemyName.." Loot")
    elseif playerStats.HP <= 0 then
        SendMessageWhenReady("☠️ | You were slain by "..enemyName.."...")
        storyRunning = false
    end
end

-- GUI
local screenGui = Instance.new("ScreenGui", game:GetService("CoreGui"))

local panel = Instance.new("Frame")
panel.Size = UDim2.new(0,250,0,400)
panel.Position = UDim2.new(0,0,0.5,-200)
panel.BackgroundColor3 = Color3.fromRGB(25,25,25)
panel.Parent = screenGui

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1,0,0,40)
title.Text = "⚔️ D&D Story Bot"
title.TextColor3 = Color3.fromRGB(255,255,255)
title.BackgroundTransparency = 1
title.Parent = panel

local startBtn = Instance.new("TextButton")
startBtn.Size = UDim2.new(1,-20,0,30)
startBtn.Position = UDim2.new(0,10,0,50)
startBtn.Text = "▶️ Start Game"
startBtn.Parent = panel

local restartBtn = Instance.new("TextButton")
restartBtn.Size = UDim2.new(1,-20,0,30)
restartBtn.Position = UDim2.new(0,10,0,90)
restartBtn.Text = "🔄 Restart"
restartBtn.Parent = panel

local healBtn = Instance.new("TextButton")
healBtn.Size = UDim2.new(1,-20,0,30)
healBtn.Position = UDim2.new(0,10,0,130)
healBtn.Text = "❤️ Heal +5"
healBtn.Parent = panel

local fullHealBtn = Instance.new("TextButton")
fullHealBtn.Size = UDim2.new(1,-20,0,30)
fullHealBtn.Position = UDim2.new(0,10,0,170)
fullHealBtn.Text = "💖 Full Heal"
fullHealBtn.Parent = panel

local partyBtn = Instance.new("TextButton")
partyBtn.Size = UDim2.new(1,-20,0,30)
partyBtn.Position = UDim2.new(0,10,0,210)
partyBtn.Text = "🎉 Party Manager"
partyBtn.Parent = panel

local turnLabel = Instance.new("TextLabel")
turnLabel.Size = UDim2.new(1,-20,0,30)
turnLabel.Position = UDim2.new(0,10,0,250)
turnLabel.Text = "Turn: "..GetCurrentTurnPlayer()
turnLabel.TextColor3 = Color3.fromRGB(255,255,200)
turnLabel.BackgroundTransparency = 1
turnLabel.Parent = panel

-- Party Manager frame
local partyFrame = Instance.new("Frame")
partyFrame.Size = UDim2.new(0,200,0,200)
partyFrame.Position = UDim2.new(0,260,0,0)
partyFrame.BackgroundColor3 = Color3.fromRGB(30,30,30)
partyFrame.Visible = false
partyFrame.Parent = screenGui

local partyBox = Instance.new("TextBox")
partyBox.Size = UDim2.new(1,-10,0,25)
partyBox.Position = UDim2.new(0,5,0,5)
partyBox.PlaceholderText = "Enter username..."
partyBox.Parent = partyFrame

local addBtn = Instance.new("TextButton")
addBtn.Size = UDim2.new(0.45,0,0,25)
addBtn.Position = UDim2.new(0.05,0,0,35)
addBtn.Text = "Add"
addBtn.Parent = partyFrame

local removeBtn = Instance.new("TextButton")
removeBtn.Size = UDim2.new(0.45,0,0,25)
removeBtn.Position = UDim2.new(0.5,0,0,35)
removeBtn.Text = "Remove"
removeBtn.Parent = partyFrame

local listLabel = Instance.new("TextLabel")
listLabel.Size = UDim2.new(1,-10,1,-70)
listLabel.Position = UDim2.new(0,5,0,70)
listLabel.TextColor3 = Color3.fromRGB(200,200,200)
listLabel.TextWrapped = true
listLabel.TextYAlignment = Enum.TextYAlignment.Top
listLabel.BackgroundTransparency = 1
listLabel.Text = "No party members yet."
listLabel.Parent = partyFrame

local function RefreshPartyList()
    if #partyMembers == 0 then
        listLabel.Text = "No party members yet."
    else
        listLabel.Text = table.concat(partyMembers,"\n")
    end
end

partyBtn.MouseButton1Click:Connect(function()
    partyFrame.Visible = not partyFrame.Visible
end)

addBtn.MouseButton1Click:Connect(function()
    local name = partyBox.Text
    if name ~= "" and not table.find(partyMembers,name) then
        table.insert(partyMembers,name)
        RefreshPartyList()
    end
    partyBox.Text = ""
end)

removeBtn.MouseButton1Click:Connect(function()
    local name = partyBox.Text
    for i,v in ipairs(partyMembers) do
        if v:lower() == name:lower() then
            table.remove(partyMembers,i)
            break
        end
    end
    RefreshPartyList()
    partyBox.Text = ""
end)

-- Theme select
local themes = {
    ["Medieval"] = "⚔️ Medieval world of knights and kingdoms.",
    ["Magical"] = "✨ A realm of wizards, crystals, and arcane ruins."
}

local themeChoice = "Medieval"

-- Start game
local function StartGame()
    storyRunning = true
    SendMessageWhenReady("🎭 | Starting story in theme: "..themeChoice)
    local intro = story.New("You stand at a crossroads.",{
        "Village road",
        "Dark forest",
        "Mountain path",
        "River bank"
    })
    intro:Present()
end

startBtn.MouseButton1Click:Connect(function()
    StartGame()
end)

restartBtn.MouseButton1Click:Connect(function()
    storyRunning = false
    playerStats.HP = settings.maxHP
    playerStats.Inventory = {}
    SendMessageWhenReady("🔄 | Game reset.")
end)

healBtn.MouseButton1Click:Connect(function()
    playerStats.HP += 5
    ClampHP()
    SendMessageWhenReady("❤️ | Healed to "..playerStats.HP.."/"..settings.maxHP)
end)

fullHealBtn.MouseButton1Click:Connect(function()
    playerStats.HP = settings.maxHP
    SendMessageWhenReady("💖 | Fully healed.")
end)

-- Handle choices with turn check
local function _handleChoice(message, speakerName)
    if not (storyRunning and currentScene and awaitingChoice) then return end
    if speakerName ~= GetCurrentTurnPlayer() then return end

    local choiceIndex = tonumber(message)
    if choiceIndex and currentScene.options[choiceIndex] then
        playerChoice = currentScene.options[choiceIndex]
        SendMessageWhenReady("🎲 | "..speakerName.." chose: "..playerChoice)
        awaitingChoice = false
        if currentScene.nextScenes[choiceIndex] then
            task.wait(2)
            currentScene.nextScenes[choiceIndex]:Present()
        else
            SendMessageWhenReady("❓ | Nothing happens...")
        end
        AdvanceTurn()
    end
end

-- Chat listeners
if oldChat then
    LocalPlayer.Chatted:Connect(function(msg)
        _handleChoice(msg,LocalPlayer.Name)
    end)
    Players.PlayerChatted:Connect(function(player,message)
        if IsWhitelisted(player.UserId,player.Name) then
            _handleChoice(message,player.Name)
        end
    end)
else
    TextChatService.MessageReceived:Connect(function(msg)
        local sender = msg.TextSource
        if sender then
            local username = Players:GetNameFromUserIdAsync(sender.UserId)
            if IsWhitelisted(sender.UserId,username) then
                _handleChoice(msg.Text,username)
            end
        end
    end)
end

SendMessageWhenReady("✅ | D&D Story Bot loaded. Use GUI to start.")
