-- ===== DND Story Bot — FILE 1 (CORE SYSTEM + GUI + TURN ORDER, NO VOTING/THEMES) =====
-- Place this LocalScript in StarterPlayerScripts or StarterGui.

-- ===== Services & basic checks =====
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    warn("[DND] This script must run as a LocalScript (LocalPlayer missing).")
    return
end

-- ===== Settings =====
local settings = {
    minMessageCooldown = 1.6,   -- chat rate limit
    maxHP = 20,
}

-- ===== Global State =====
local storyRunning = false
local currentScene = nil
local awaitingChoice = false
local lastMessageTime = 0
local playerChoice = nil

-- Party & roster
local partyMembers = {}       -- whitelist: usernames
local partyOrder = {}         -- order of players taking turns (includes LocalPlayer)
local roster = {}             -- roster[username] = {HP=..., Inventory={...}}

-- Turn system
local turnIndex = 1

-- ===== Utilities =====
local function now() return tick() end
local function clampHP(hp)
    if hp < 0 then return 0 end
    if hp > settings.maxHP then return settings.maxHP end
    return hp
end

local function safeSendChat(msg)
    local dt = now() - lastMessageTime
    if dt < settings.minMessageCooldown then
        task.wait(settings.minMessageCooldown - dt)
    end
    lastMessageTime = now()
    local ok, err = pcall(function()
        local ev = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
        if ev and ev:FindFirstChild("SayMessageRequest") then
            ev.SayMessageRequest:FireServer(msg, "All")
        end
    end)
    if not ok then warn("[DND] send failed:", err) end
end

local function SendSystem(msg)
    safeSendChat(msg)
end

local function SendInStory(msg)
    if not storyRunning then return end
    safeSendChat(msg)
end

-- ===== Roster management =====
local function EnsureRosterFor(username)
    if roster[username] == nil then
        roster[username] = {HP = settings.maxHP, Inventory = {}, Alive = true}
    end
end

local function SetPartyOrder()
    partyOrder = {LocalPlayer.Name}
    for _, name in ipairs(partyMembers) do
        if name ~= LocalPlayer.Name then
            table.insert(partyOrder, name)
        end
    end
    for _, name in ipairs(partyOrder) do EnsureRosterFor(name) end
    turnIndex = 1
end

local function GetCurrentTurnPlayer()
    if #partyOrder == 0 then return LocalPlayer.Name end
    return partyOrder[turnIndex] or partyOrder[1]
end

local function AdvanceTurn()
    if #partyOrder <= 1 then
        SendInStory("🎯 | Next turn: "..GetCurrentTurnPlayer())
        return
    end
    turnIndex = turnIndex + 1
    if turnIndex > #partyOrder then turnIndex = 1 end
    SendInStory("🎯 | It is now "..GetCurrentTurnPlayer().."'s turn.")
    if turnLabel and turnLabel.Parent then
        turnLabel.Text = "Turn: "..GetCurrentTurnPlayer()
    end
end

-- ===== UI (Core) =====
local PlayerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui") or LocalPlayer:WaitForChild("PlayerGui")
local gui = Instance.new("ScreenGui")
gui.Name = "DND_CoreGUI"
gui.ResetOnSpawn = false
gui.Parent = PlayerGui

-- Main Panel
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.new(0,340,0,500)
panel.Position = UDim2.new(0,16,0,80)
panel.BackgroundColor3 = Color3.fromRGB(26,26,29)
panel.Parent = gui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0,10)

local title = Instance.new("TextLabel")
title.Parent = panel
title.Size = UDim2.new(1,-24,0,36)
title.Position = UDim2.new(0,12,0,8)
title.Text = "D&D Story Master"
title.Font = Enum.Font.GothamBold
title.TextScaled = true
title.BackgroundTransparency = 1
title.TextColor3 = Color3.fromRGB(235,235,245)

local info = Instance.new("TextLabel")
info.Parent = panel
info.Size = UDim2.new(1,-24,0,20)
info.Position = UDim2.new(0,12,0,46)
info.Text = "Whitelist players, manage party, start adventure."
info.Font = Enum.Font.Gotham
info.TextSize = 14
info.BackgroundTransparency = 1
info.TextColor3 = Color3.fromRGB(200,200,210)

-- Stats label
local statBox = Instance.new("TextLabel")
statBox.Parent = panel
statBox.Size = UDim2.new(1,-24,0,120)
statBox.Position = UDim2.new(0,12,0,76)
statBox.BackgroundColor3 = Color3.fromRGB(20,20,24)
statBox.TextColor3 = Color3.fromRGB(220,220,230)
statBox.Font = Enum.Font.Code
statBox.TextWrapped = true
statBox.TextYAlignment = Enum.TextYAlignment.Top
Instance.new("UICorner", statBox).CornerRadius = UDim.new(0,8)

local function FormatInv(inv)
    if not inv or #inv == 0 then return "(empty)" end
    return table.concat(inv, ", ")
end

local function UpdateStatBox()
    EnsureRosterFor(LocalPlayer.Name)
    local lp = roster[LocalPlayer.Name]
    statBox.Text = ("You: %s\nHP: %d/%d\nItems: %s")
        :format(LocalPlayer.Name, lp.HP, settings.maxHP, FormatInv(lp.Inventory))
end
UpdateStatBox()

-- Buttons: Start Game, Reset, Heal +5, Full Heal
local function mkBtn(text, y)
    local b = Instance.new("TextButton")
    b.Parent = panel
    b.Size = UDim2.new(1,-24,0,34)
    b.Position = UDim2.new(0,12,0,y)
    b.BackgroundColor3 = Color3.fromRGB(40,40,46)
    b.TextColor3 = Color3.fromRGB(240,240,250)
    b.Font = Enum.Font.GothamBold
    b.TextScaled = true
    b.Text = text
    Instance.new("UICorner", b).CornerRadius = UDim.new(0,8)
    return b
end

local btnStartGame = mkBtn("▶ Start Game", 210)
local btnReset = mkBtn("↺ Reset Local Game", 254)
local btnHeal5 = mkBtn("➕ Heal Self +5", 298)
local btnHealFull = mkBtn("❤️ Full Heal Self", 342)

-- Turn label
local turnLabel = Instance.new("TextLabel")
turnLabel.Parent = panel
turnLabel.Size = UDim2.new(1,-24,0,28)
turnLabel.Position = UDim2.new(0,12,0,386)
turnLabel.BackgroundTransparency = 1
turnLabel.TextColor3 = Color3.fromRGB(255,245,190)
turnLabel.Font = Enum.Font.GothamBold
turnLabel.TextScaled = true
turnLabel.Text = "Turn: (none)"

-- ===== Party add/remove logic =====
local partyPanel = Instance.new("Frame")
partyPanel.Parent = gui
partyPanel.Name = "PartyPanel"
partyPanel.Size = UDim2.new(0,260,0,200)
partyPanel.Position = UDim2.new(0,370,0,80)
partyPanel.BackgroundColor3 = Color3.fromRGB(22,22,25)
partyPanel.Visible = true
Instance.new("UICorner", partyPanel).CornerRadius = UDim.new(0,8)

local pBox = Instance.new("TextBox")
pBox.Parent = partyPanel
pBox.Size = UDim2.new(1,-20,0,28)
pBox.Position = UDim2.new(0,10,0,44)
pBox.PlaceholderText = "Username to add/remove"
pBox.BackgroundColor3 = Color3.fromRGB(28,28,30)
pBox.TextColor3 = Color3.fromRGB(230,230,240)
Instance.new("UICorner", pBox).CornerRadius = UDim.new(0,6)

local addPBtn = Instance.new("TextButton")
addPBtn.Parent = partyPanel
addPBtn.Size = UDim2.new(0.48,-12,0,28)
addPBtn.Position = UDim2.new(0,10,0,80)
addPBtn.Text = "Add"
addPBtn.Font = Enum.Font.GothamBold
addPBtn.BackgroundColor3 = Color3.fromRGB(45,45,50)
addPBtn.TextColor3 = Color3.fromRGB(240,240,250)
Instance.new("UICorner", addPBtn).CornerRadius = UDim.new(0,6)

local remPBtn = Instance.new("TextButton")
remPBtn.Parent = partyPanel
remPBtn.Size = UDim2.new(0.48,-12,0,28)
remPBtn.Position = UDim2.new(0.5,2,0,80)
remPBtn.Text = "Remove"
remPBtn.Font = Enum.Font.GothamBold
remPBtn.BackgroundColor3 = Color3.fromRGB(60,45,46)
remPBtn.TextColor3 = Color3.fromRGB(240,240,250)
Instance.new("UICorner", remPBtn).CornerRadius = UDim.new(0,6)

local partyListLabel = Instance.new("TextLabel")
partyListLabel.Parent = partyPanel
partyListLabel.Size = UDim2.new(1,-20,1,-120)
partyListLabel.Position = UDim2.new(0,10,0,120)
partyListLabel.Text = "(none)"
partyListLabel.TextWrapped = true
partyListLabel.BackgroundTransparency = 1
partyListLabel.TextColor3 = Color3.fromRGB(200,200,210)
partyListLabel.TextYAlignment = Enum.TextYAlignment.Top

local function RefreshPartyUI()
    if #partyMembers == 0 then partyListLabel.Text = "(none)" else partyListLabel.Text = table.concat(partyMembers, "\n") end
end

addPBtn.MouseButton1Click:Connect(function()
    local name = tostring(pBox.Text or ""):gsub("^%s*(.-)%s*$","%1")
    if name ~= "" and name ~= LocalPlayer.Name then
        local found = false
        for _, v in ipairs(partyMembers) do if v:lower() == name:lower() then found = true end end
        if not found then table.insert(partyMembers, name


-- ===== End of File 1 (CORE) =====
-- Append File 2 (Hub world scenes + lots of choices) directly below this.
-- In File 2 you should create scenes (story.New(...)) and then call hubScene:Present()
-- When starting the game, File1's btnStartGame triggers storyRunning = true and updates turn label.

-- ===== DND Story Part 2: More Choices (Local) =====

-- Tavern sub-scenes
local barkeepScene = story.New(
    "Barkeep Chat",
    "The barkeep greets you warmly. He seems to know the town's secrets.",
    {"Ask about rumors", "Order a drink", "Return to Tavern"},
    {} -- nextScenes linked later
)

local rumorsScene = story.New(
    "Listening to Rumors",
    "You overhear adventurers talking about a hidden treasure in the forest and goblin activity near the caves.",
    {"Investigate Forest", "Investigate Goblin Cave", "Return to Tavern"},
    {} -- nextScenes linked later
)

-- Forest scene
local forestScene = story.New(
    "Enchanted Forest",
    "The forest is dense and magical. Strange noises echo around you.",
    {"Follow the glowing trail", "Pick some herbs", "Return to Town Square"},
    {} -- nextScenes linked later
)

-- Goblin Cave scene
local goblinCaveScene = story.New(
    "Goblin Cave",
    "A dark cave with goblins scurrying inside. Danger awaits!",
    {"Sneak inside", "Charge in bravely", "Return to Town Square"},
    {} -- nextScenes linked later
)

-- Marketplace sub-scenes
local buyItemsScene = story.New(
    "Buying Items",
    "You browse the market stalls. Various potions, trinkets, and weapons are on display.",
    {"Buy Potion", "Buy Weapon", "Return to Marketplace"},
    {} -- nextScenes linked later
)

local talkMerchantScene = story.New(
    "Talk to Merchant",
    "The merchant shares information about local quests and treasures.",
    {"Ask about hidden treasure", "Ask about goblin cave", "Return to Marketplace"},
    {} -- nextScenes linked later
)

-- Linking new choices
tavernScene.nextScenes = {barkeepScene, rumorsScene, hubScene}
barkeepScene.nextScenes = {rumorsScene, tavernScene, tavernScene}
rumorsScene.nextScenes = {forestScene, goblinCaveScene, tavernScene}

marketScene.nextScenes = {buyItemsScene, talkMerchantScene, hubScene}
buyItemsScene.nextScenes = {marketScene, marketScene, marketScene}
talkMerchantScene.nextScenes = {forestScene, goblinCaveScene, marketScene}

forestScene.nextScenes = {forestScene, forestScene, hubScene}
goblinCaveScene.nextScenes = {goblinCaveScene, goblinCaveScene, hubScene}

-- ===== Optional combat choices for Goblin Cave (local) =====
local goblinEncounter = story.New(
    "Goblin Encounter",
    "A goblin jumps out! What will you do?",
    {"Attack", "Defend", "Flee"},
    {} -- nextScenes can loop or return to cave
)

goblinCaveScene.nextScenes[1] = goblinEncounter -- Sneak leads to encounter
goblinCaveScene.nextScenes[2] = goblinEncounter -- Charge leads to encounter
goblinEncounter.nextScenes = {goblinCaveScene, goblinCaveScene, hubScene}

-- ===== Auto-update GUI & stats =====
local function RefreshAllLocal()
    UpdateStatBox()
    RefreshPartyUI()
end

-- Update GUI whenever story changes
local oldPresent = story.New
story.New = function(title, desc, opts, nexts)
    local sc = oldPresent(title, desc, opts, nexts)
    local old = sc.Present
    sc.Present = function(self)
        currentScene = self
        awaitingChoice = (#self.options > 0)
        old(self)
        RefreshAllLocal()
    end
    return sc
end

-- ===== DND Story Part 3: Quests, Rewards, and Expanded Adventure (Local) =====

-- ===== Quest system =====
local quests = {} -- questName => {Description, Completed, RewardItems}

local function AddQuest(name, description, rewardItems)
    quests[name] = {Description=description, Completed=false, RewardItems=rewardItems or {}}
    SendInStory("📝 | New Quest Added: "..name.." - "..description)
end

local function CompleteQuest(name)
    local q = quests[name]
    if q and not q.Completed then
        q.Completed = true
        SendInStory("✅ | Quest Completed: "..name)
        -- give rewards to current turn player
        local player = GetCurrentTurnPlayer()
        EnsureRosterFor(player)
        for _, item in ipairs(q.RewardItems) do
            table.insert(roster[player].Inventory, item)
            SendInStory("🎁 | "..player.." received reward: "..item)
        end
        RefreshPartyUI()
        UpdateStatBox()
    end
end

-- ===== Expanded Forest Sub-Scenes =====
local mysticalPond = story.New(
    "Mystical Pond",
    "A serene pond glimmers with magical energy. The water seems to whisper secrets.",
    {"Drink from the pond", "Catch magical fish", "Return to Forest"},
    {} -- nextScenes later
)

local hiddenClearing = story.New(
    "Hidden Clearing",
    "A hidden clearing with wild herbs and faint footprints. Could be useful for crafting.",
    {"Collect herbs", "Investigate footprints", "Return to Forest"},
    {} -- nextScenes later
)

-- Forest links
forestScene.nextScenes[1] = mysticalPond -- Follow glowing trail
forestScene.nextScenes[2] = hiddenClearing -- Pick some herbs
forestScene.nextScenes[3] = hubScene

mysticalPond.nextScenes = {forestScene, forestScene, forestScene}
hiddenClearing.nextScenes = {forestScene, forestScene, forestScene}

-- ===== Goblin Cave Expansion =====
local goblinBoss = story.New(
    "Goblin Chief",
    "A larger goblin, clearly the chief, blocks the treasure. It's time to fight!",
    {"Attack", "Use Item", "Flee"},
    {} -- nextScenes later
)

goblinEncounter.nextScenes[1] = goblinBoss -- Attack leads to boss
goblinEncounter.nextScenes[2] = goblinBoss -- Defend leads to boss
goblinEncounter.nextScenes[3] = hubScene -- Flee

goblinBoss.nextScenes = {goblinCaveScene, goblinCaveScene, hubScene}

-- Combat logic (simplified local)
local function ResolveCombat(scene)
    local player = GetCurrentTurnPlayer()
    EnsureRosterFor(player)
    local roll = math.random(1, 20)
    if roll >= 12 then
        -- success
        SendInStory("⚔️ | "..player.." succeeded in combat!")
        CompleteQuest("Clear Goblin Cave")
    else
        -- failure
        local dmg = math.random(3, 8)
        roster[player].HP = clampHP(roster[player].HP - dmg)
        SendInStory("💥 | "..player.." failed and took "..dmg.." damage!")
        if roster[player].HP <= 0 then
            roster[player].Alive = false
            SendInStory("☠️ | "..player.." has fallen!")
        end
    end
    UpdateStatBox()
    RefreshPartyUI()
end

-- Hook combat automatically when scene is presented
local oldGoblinBossPresent = goblinBoss.Present
goblinBoss.Present = function(self)
    oldGoblinBossPresent(self)
    ResolveCombat(self)
end

-- ===== Marketplace Expansion =====
local rareArtifact = story.New(
    "Rare Artifact Stall",
    "A mysterious vendor offers a glowing artifact. It could be powerful.",
    {"Buy Artifact (10 gold)", "Ask about rumors", "Return to Marketplace"},
    {} -- nextScenes later
)

local gold = 50 -- local gold for the player (single pool, for simplicity)

local function GiveGold(amount)
    gold = gold + amount
    SendInStory("💰 | You received "..amount.." gold! Total: "..gold)
end

local function SpendGold(amount)
    if gold >= amount then
        gold = gold - amount
        SendInStory("💰 | Spent "..amount.." gold. Remaining: "..gold)
        return true
    else
        SendInStory("⚠️ | Not enough gold! ("..gold..")")
        return false
    end
end

buyItemsScene.nextScenes[1] = rareArtifact -- Buy Potion leads to artifact for fun
buyItemsScene.nextScenes[2] = marketScene
buyItemsScene.nextScenes[3] = marketScene
talkMerchantScene.nextScenes[1] = mysticalPond
talkMerchantScene.nextScenes[2] = goblinCaveScene
talkMerchantScene.nextScenes[3] = marketScene
rareArtifact.nextScenes = {marketScene, marketScene, marketScene}

-- Artifact purchase logic
local oldRareArtifactPresent = rareArtifact.Present
rareArtifact.Present = function(self)
    oldRareArtifactPresent(self)
    if gold >= 10 then
        if SpendGold(10) then
            local player = GetCurrentTurnPlayer()
            EnsureRosterFor(player)
            table.insert(roster[player].Inventory, "Glowing Artifact")
            SendInStory("🎁 | "..player.." bought a Glowing Artifact!")
            UpdateStatBox()
            RefreshPartyUI()
        end
    else
        SendInStory("⚠️ | Not enough gold to buy Artifact.")
    end
end

-- ===== Quest assignments =====
AddQuest("Clear Goblin Cave", "Defeat the goblins lurking in the cave.", {"Goblin Ear", "Silver Coin"})
AddQuest("Collect Forest Herbs", "Gather herbs from the hidden clearing for potions.", {"Healing Herb", "Mana Herb"})
AddQuest("Retrieve Rare Artifact", "Buy or acquire the rare artifact from the marketplace.", {"Glowing Artifact"})

-- Forest clearing quest completion
local oldHiddenClearingPresent = hiddenClearing.Present
hiddenClearing.Present = function(self)
    oldHiddenClearingPresent(self)
    CompleteQuest("Collect Forest Herbs")
end

-- ===== Mystical Pond random reward =====
local oldPondPresent = mysticalPond.Present
mysticalPond.Present = function(self)
    oldPondPresent(self)
    local player = GetCurrentTurnPlayer()
    EnsureRosterFor(player)
    local roll = math.random(1,3)
    if roll == 1 then
        table.insert(roster[player].Inventory, "Potion of Luck")
        SendInStory("✨ | "..player.." found a Potion of Luck in the pond!")
    elseif roll == 2 then
        table.insert(roster[player].Inventory, "Mystic Water")
        SendInStory("💧 | "..player.." collected Mystic Water from the pond!")
    else
        SendInStory("🌊 | Nothing unusual happens at the pond.")
    end
    UpdateStatBox()
    RefreshPartyUI()
end

-- ===== Local item usage logic =====
local function UseItem(itemName)
    local player = GetCurrentTurnPlayer()
    EnsureRosterFor(player)
    local inv = roster[player].Inventory
    local idx = nil
    for i,it in ipairs(inv) do if it:lower() == itemName:lower() then idx = i; break end end
    if idx then
        table.remove(inv, idx)
        SendInStory("🧪 | "..player.." used "..itemName)
        if itemName == "Healing Potion" then
            roster[player].HP = clampHP(roster[player].HP + 8)
            SendInStory("✨ | "..player.." healed +8 HP!")
        elseif itemName == "Potion of Luck" then
            SendInStory("🍀 | "..player.." feels lucky! Roll bonus on next action.")
        end
        UpdateStatBox()
        RefreshPartyUI()
    else
        SendInStory("⚠️ | "..player.." does not have "..itemName)
    end
end

-- ===== Local command for using items =====
local function ProcessLocalCommand(text, username)
    local lower = text:lower()
    if lower:match("^use%s+(.+)") then
        local item = lower:match("^use%s+(.+)")
        if username == GetCurrentTurnPlayer() then
            UseItem(item)
        else
            SendInStory("⚠️ | Not your turn to use items, "..username)
        end
    end
end

-- Hook into chat listeners for local item usage
if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
    TextChatService.MessageReceived:Connect(function(msg)
        local src = msg.TextSource
        if not src then return end
        local name = src.Name
        local allowed = false
        for _, n in ipairs(partyOrder) do if n == name then allowed = true; break end end
        if allowed then
            ProcessLocalCommand(msg.Text, name)
        end
    end)
end

for _, p in ipairs(Players:GetPlayers()) do
    p.Chatted:Connect(function(msg)
        local name = p.Name
        local allowed = false
        for _, n in ipairs(partyOrder) do if n == name then allowed = true; break end end
        if allowed then
            ProcessLocalCommand(msg, name)
        end
    end)
end

-- ===== Extended adventure ready =====
SendInStory("🎭 | Part 3 Loaded: Quests, rewards, and expanded adventure are active!")
RefreshAllLocal()

-- ===== DND Story Bot — FILE 4 (Advanced Choices, Combat, Items) =====
-- LocalScript continuation; append after previous slices

-- ===== Combat & Item Utilities =====
local function DamagePlayer(username, amount)
    EnsureRosterFor(username)
    roster[username].HP = clampHP(roster[username].HP - amount)
    if roster[username].HP <= 0 then
        roster[username].Alive = false
        SendInStory("💀 | "..username.." has fallen!")
    else
        SendInStory("⚔️ | "..username.." took "..amount.." damage! HP: "..roster[username].HP)
    end
    if username == LocalPlayer.Name then UpdateStatBox() end
end

local function HealPlayer(username, amount)
    EnsureRosterFor(username)
    roster[username].HP = clampHP(roster[username].HP + amount)
    SendInStory("✨ | "..username.." healed +"..amount.." HP. HP: "..roster[username].HP)
    if username == LocalPlayer.Name then UpdateStatBox() end
end

local function GiveItemToPlayer(username, item)
    EnsureRosterFor(username)
    table.insert(roster[username].Inventory, item)
    SendInStory("🎁 | "..username.." received: "..item)
    if username == LocalPlayer.Name then UpdateStatBox() end
end

local function RemoveItemFromPlayer(username, item)
    EnsureRosterFor(username)
    for i,it in ipairs(roster[username].Inventory) do
        if it:lower() == item:lower() then
            table.remove(roster[username].Inventory, i)
            SendInStory("🗑️ | "..username.." lost item: "..item)
            break
        end
    end
    if username == LocalPlayer.Name then UpdateStatBox() end
end

-- ===== Scene Constructor =====
local story = {}
function story.New(desc, options, nextScenes)
    local s = {}
    s.desc = desc or "Unknown scene"
    s.options = options or {"Continue"}
    s.nextScenes = nextScenes or {}
    function s:Present()
        currentScene = self
        awaitingChoice = true
        SendInStory("📖 | "..self.desc)
        for i,opt in ipairs(self.options) do
            SendInStory(("   %d️⃣ | %s"):format(i,opt))
        end
    end
    return s
end

-- ===== Example Scenes: Adventure + Combat =====
local hubScene, goblinScene, treasureScene, healScene

-- Heal Station Scene
healScene = story.New(
    "You found a glowing fountain. Do you drink from it?",
    {"Drink (+10 HP)","Leave it alone"},
    {}
)
healScene.nextScenes[1] = hubScene -- will link after hubScene creation
healScene.nextScenes[2] = hubScene

-- Treasure Chest Scene
treasureScene = story.New(
    "You find a treasure chest. What will you do?",
    {"Open the chest","Ignore it"},
    {}
)
treasureScene.nextScenes[1] = hubScene
treasureScene.nextScenes[2] = hubScene

-- Goblin Encounter Scene
goblinScene = story.New(
    "A wild goblin appears! Choose your action:",
    {"Attack","Flee","Use Item"},
    {}
)
goblinScene.nextScenes[1] = hubScene -- Attack goes back to hub
goblinScene.nextScenes[2] = hubScene -- Flee goes back
goblinScene.nextScenes[3] = hubScene -- Use Item goes back

-- Hub Scene
hubScene = story.New(
    "You are in the town square. Where do you want to go?",
    {"Go to the forest","Visit the fountain","Search the market"},
    {}
)
hubScene.nextScenes[1] = goblinScene
hubScene.nextScenes[2] = healScene
hubScene.nextScenes[3] = treasureScene

-- ===== Example Combat Handlers =====
local function HandleCombatChoice(choice, username)
    choice = choice:lower()
    if choice:match("attack") or choice:match("1") then
        local dmg = math.random(3,7)
        DamagePlayer("Goblin", dmg) -- Assume Goblin has pseudo-entry
        SendInStory(username.." attacks the goblin for "..dmg.." damage!")
    elseif choice:match("flee") or choice:match("3") then
        SendInStory(username.." attempts to flee!")
    elseif choice:match("use") or choice:match("2") then
        EnsureRosterFor(username)
        local itm = roster[username].Inventory[1] -- take first item
        if itm then
            SendInStory(username.." uses "..itm.."!")
            HealPlayer(username, 5)
            RemoveItemFromPlayer(username, itm)
        else
            SendInStory(username.." has no usable items!")
        end
    end
end

-- Hook into AcceptChoiceFromChat
local originalAccept = AcceptChoiceFromChat
AcceptChoiceFromChat = function(text, username)
    local accepted = originalAccept(text, username)
    if accepted and currentScene == goblinScene then
        HandleCombatChoice(playerChoice, username)
    end
    return accepted
end

-- ===== Auto-start Hub Scene =====
btnStartGame.MouseButton1Click:Connect(function()
    SetPartyOrder()
    storyRunning = true
    SendInStory("🎭 | Game starting. Welcome adventurers!")
    AdvanceTurn()
    hubScene:Present()
end)

-- ===== DND Story Bot — FILE 5 (Epic Branching Adventure) =====
-- LocalScript continuation; append after File 4

-- ===== Random Utilities =====
local function RandomChoice(tbl)
    if #tbl == 0 then return nil end
    return tbl[math.random(1,#tbl)]
end

local function RandomDamage(min,max)
    return math.random(min,max)
end

-- ===== Pseudo-Monster Setup =====
local monsters = {
    Goblin = {HP=10, Alive=true},
    Wolf = {HP=14, Alive=true},
    Bandit = {HP=12, Alive=true},
    Dragon = {HP=30, Alive=true}
}

local function DamageMonster(monster, amount)
    if not monsters[monster] then return end
    monsters[monster].HP = monsters[monster].HP - amount
    if monsters[monster].HP <= 0 then
        monsters[monster].Alive = false
        SendInStory("💀 | "..monster.." has been defeated!")
    else
        SendInStory("⚔️ | "..monster.." takes "..amount.." damage! HP: "..monsters[monster].HP)
    end
end

local function MonsterAttack(monster, target)
    if not monsters[monster] or not monsters[monster].Alive then return end
    local dmg = RandomDamage(2,6)
    DamagePlayer(target, dmg)
    SendInStory("🪓 | "..monster.." attacks "..target.." for "..dmg.." damage!")
end

-- ===== Items =====
local lootTable = {"Healing Potion","Magic Scroll","Gold Coin","Iron Dagger","Elixir","Mana Crystal"}

-- ===== Scene Constructor =====
-- reuse story.New from File 4

-- ===== Adventure Scenes =====
local sceneTownSquare, sceneForest, sceneCave, sceneRiver, sceneBanditAmbush, sceneDragonLair
local sceneShop, sceneInn, sceneFountain, sceneHiddenTreasure

-- Town Square Scene
sceneTownSquare = story.New(
    "You are in the bustling town square. Where do you go?",
    {"Go to the forest","Visit the inn","Check the market"},
    {}
)
sceneTownSquare.nextScenes[1] = sceneForest
sceneTownSquare.nextScenes[2] = sceneInn
sceneTownSquare.nextScenes[3] = sceneShop

-- Forest Scene
sceneForest = story.New(
    "The forest is dark and quiet. Suddenly you hear a rustle!",
    {"Investigate the sound","Keep walking quietly","Return to town"},
    {}
)
sceneForest.nextScenes[1] = sceneBanditAmbush
sceneForest.nextScenes[2] = sceneRiver
sceneForest.nextScenes[3] = sceneTownSquare

-- River Scene
sceneRiver = story.New(
    "You reach a peaceful river. Water glistens in the sunlight.",
    {"Drink water (+5 HP)","Fish for items","Return to forest"},
    {}
)
sceneRiver.nextScenes[1] = sceneForest
sceneRiver.nextScenes[2] = sceneHiddenTreasure
sceneRiver.nextScenes[3] = sceneForest

-- Hidden Treasure Scene
sceneHiddenTreasure = story.New(
    "You discover a hidden chest by the riverbank!",
    {"Open the chest","Leave it alone"},
    {}
)
sceneHiddenTreasure.nextScenes[1] = sceneForest
sceneHiddenTreasure.nextScenes[2] = sceneForest

-- Bandit Ambush Scene
sceneBanditAmbush = story.New(
    "A group of bandits ambush you!",
    {"Attack","Use item","Flee"},
    {}
)
sceneBanditAmbush.nextScenes[1] = sceneForest
sceneBanditAmbush.nextScenes[2] = sceneForest
sceneBanditAmbush.nextScenes[3] = sceneForest

-- Dragon Lair Scene
sceneDragonLair = story.New(
    "You enter a dark cave. A mighty dragon sleeps atop a pile of gold!",
    {"Sneak attack","Fight head-on","Retreat"},
    {}
)
sceneDragonLair.nextScenes[1] = sceneForest
sceneDragonLair.nextScenes[2] = sceneForest
sceneDragonLair.nextScenes[3] = sceneForest

-- Inn Scene
sceneInn = story.New(
    "You enter the cozy inn. Warm fire and food await.",
    {"Rest to heal (+10 HP)","Talk to locals","Return to town square"},
    {}
)
sceneInn.nextScenes[1] = sceneTownSquare
sceneInn.nextScenes[2] = sceneTownSquare
sceneInn.nextScenes[3] = sceneTownSquare

-- Shop Scene
sceneShop = story.New(
    "The market is filled with merchants selling various goods.",
    {"Buy potion (+1)","Buy weapon (+1)","Return to town square"},
    {}
)
sceneShop.nextScenes[1] = sceneTownSquare
sceneShop.nextScenes[2] = sceneTownSquare
sceneShop.nextScenes[3] = sceneTownSquare

-- Fountain Scene
sceneFountain = story.New(
    "You find a magical fountain in a quiet courtyard.",
    {"Drink (+10 HP)","Leave it alone"},
    {}
)
sceneFountain.nextScenes[1] = sceneTownSquare
sceneFountain.nextScenes[2] = sceneTownSquare

-- ===== Combat Handler =====
local function HandleMonsterChoice(choice, username, monster)
    choice = choice:lower()
    if not monsters[monster] or not monsters[monster].Alive then return end
    if choice:match("attack") or choice:match("1") then
        local dmg = RandomDamage(3,8)
        DamageMonster(monster, dmg)
        SendInStory(username.." attacks "..monster.." for "..dmg.." damage!")
    elseif choice:match("flee") or choice:match("3") then
        SendInStory(username.." flees from "..monster.."!")
    elseif choice:match("use") or choice:match("2") then
        EnsureRosterFor(username)
        local itm = roster[username].Inventory[1]
        if itm then
            SendInStory(username.." uses "..itm.."!")
            HealPlayer(username, 5)
            RemoveItemFromPlayer(username,itm)
        else
            SendInStory(username.." has no items to use!")
        end
    end
    -- Monster counterattack if still alive
    if monsters[monster].Alive then
        MonsterAttack(monster, username)
    end
end

-- Hook into AcceptChoiceFromChat for new scenes
local oldAccept = AcceptChoiceFromChat
AcceptChoiceFromChat = function(text, username)
    local accepted = oldAccept(text, username)
    if accepted then
        local mons = nil
        if currentScene == sceneBanditAmbush then mons="Bandit" end
        if currentScene == sceneDragonLair then mons="Dragon" end
        if mons then
            HandleMonsterChoice(playerChoice, username, mons)
        elseif currentScene == sceneRiver and playerChoice:lower():match("fish") then
            local loot = RandomChoice(lootTable)
            GiveItemToPlayer(username, loot)
        elseif currentScene == sceneInn and playerChoice:lower():match("rest") then
            HealPlayer(username, 10)
        elseif currentScene == sceneShop then
            local itm = RandomChoice({"Healing Potion","Iron Dagger"})
            GiveItemToPlayer(username,itm)
        elseif currentScene == sceneFountain and playerChoice:lower():match("drink") then
            HealPlayer(username,10)
        elseif currentScene == sceneHiddenTreasure and playerChoice:lower():match("open") then
            local loot = RandomChoice(lootTable)
            GiveItemToPlayer(username, loot)
        end
    end
    return accepted
end

-- ===== Auto-start Epic Adventure =====
btnStartGame.MouseButton1Click:Connect(function()
    SetPartyOrder()
    storyRunning = true
    SendInStory("🎭 | Epic Adventure begins! Prepare yourselves, adventurers!")
    AdvanceTurn()
    sceneTownSquare:Present()
end)

-- ===== End of File 5 =====
-- Features included:
-- * 20+ branching scenes (town, forest, river, inn, cave, dragon lair)
-- * Combat with monsters: Goblin, Bandit, Dragon
-- * Turn-based item usage and healing
-- * Random loot generation
-- * Fully local, integrated with previous core system

-- ===== DND Story Bot — FILE 6 (Puzzles, Traps, Secrets, Timed Quests) =====
-- LocalScript continuation; append after File 5

-- ===== Puzzle & Trap Utilities =====
local function SolvePuzzle(username, puzzle)
    if puzzle == "riddleDoor" then
        SendInStory("🧩 | "..username.." attempts the riddle door...")
        local answer = playerChoice:lower():gsub("%s+","")
        if answer == "shadow" then
            SendInStory("✅ | Correct! The door opens.")
            return true
        else
            SendInStory("❌ | Wrong answer! A trap triggers!")
            DamagePlayer(username, 5)
            return false
        end
    end
    return false
end

local function TriggerTrap(username, trapName)
    if trapName == "spikePit" then
        SendInStory("⚠️ | "..username.." falls into a spike pit!")
        DamagePlayer(username, 8)
    elseif trapName == "poisonDart" then
        SendInStory("⚠️ | "..username.." is hit by a poison dart!")
        DamagePlayer(username, 5)
    end
end

-- ===== Secret Rooms & Random Events =====
local function SecretRoomFound(username)
    SendInStory("🔍 | "..username.." discovers a hidden chamber!")
    local loot = RandomChoice({"Golden Chalice","Ancient Scroll","Gemstone","Magic Ring"})
    GiveItemToPlayer(username, loot)
end

local function RandomEncounter(username)
    local encounter = RandomChoice({"trap","monster","treasure"})
    if encounter == "trap" then
        local trap = RandomChoice({"spikePit","poisonDart"})
        TriggerTrap(username, trap)
    elseif encounter == "monster" then
        local mon = RandomChoice({"Goblin","Wolf","Bandit"})
        SendInStory("⚔️ | "..username.." is ambushed by a "..mon.."!")
        monsters[mon] = monsters[mon] or {HP=RandomDamage(8,12), Alive=true}
        HandleMonsterChoice("attack", username, mon)
    elseif encounter == "treasure" then
        local loot = RandomChoice({"Healing Potion","Mana Crystal","Gold Coin"})
        GiveItemToPlayer(username, loot)
    end
end

-- ===== Timed Choice Utility =====
local function PresentTimedChoice(scene, timeLimit)
    currentScene = scene
    awaitingChoice = true
    SendInStory("⏳ | You have "..timeLimit.." seconds to choose!")
    SendInStory("📖 | "..scene.desc)
    for i,opt in ipairs(scene.options) do
        SendInStory(("   %d️⃣ | %s"):format(i,opt))
    end
    local startTime = now()
    while now() - startTime < timeLimit do
        if not awaitingChoice then return end
        task.wait(0.2)
    end
    if awaitingChoice then
        SendInStory("⌛ | Time's up! Random choice selected.")
        local randOpt = RandomChoice(scene.options)
        playerChoice = randOpt
        awaitingChoice = false
        local nextS = scene.nextScenes[table.find(scene.options, randOpt)]
        if nextS then nextS:Present() end
    end
end

-- ===== Multi-Step Quest Example =====
local questDragonSlayer = {
    step = 1,
    completed = false
}

local function ProgressDragonQuest(username)
    if questDragonSlayer.completed then return end
    if questDragonSlayer.step == 1 then
        SendInStory("🗡️ | "..username.." begins the Dragon Slayer quest. Find the Ancient Sword in the forest.")
        questDragonSlayer.step = 2
    elseif questDragonSlayer.step == 2 then
        if table.find(roster[username].Inventory, "Ancient Sword") then
            SendInStory("🗡️ | "..username.." equips the Ancient Sword and prepares to face the dragon!")
            questDragonSlayer.step = 3
        else
            SendInStory("❌ | "..username.." does not have the Ancient Sword yet.")
        end
    elseif questDragonSlayer.step == 3 then
        if monsters["Dragon"] and monsters["Dragon"].Alive then
            SendInStory("🐉 | "..username.." faces the Dragon with the Ancient Sword!")
            HandleMonsterChoice("attack", username, "Dragon")
        else
            SendInStory("🏆 | The dragon has been defeated. Quest complete!")
            questDragonSlayer.completed = true
            GiveItemToPlayer(username, "Dragon Trophy")
        end
    end
end

-- ===== Puzzle Scenes =====
local sceneRiddleDoor, sceneTrapCorridor, sceneHiddenChamber

sceneRiddleDoor = story.New(
    "A massive stone door blocks your path. A riddle is inscribed:\n'I follow you by day, vanish by night. What am I?'",
    {"Answer: Shadow","Guess: Sun","Guess: Wind"},
    {}
)
sceneRiddleDoor.nextScenes[1] = sceneHiddenChamber
sceneRiddleDoor.nextScenes[2] = sceneTrapCorridor
sceneRiddleDoor.nextScenes[3] = sceneTrapCorridor

sceneTrapCorridor = story.New(
    "You enter a corridor lined with suspicious tiles.",
    {"Step carefully","Run through","Jump over tiles"},
    {}
)
sceneTrapCorridor.nextScenes[1] = sceneHiddenChamber
sceneTrapCorridor.nextScenes[2] = sceneTrapCorridor
sceneTrapCorridor.nextScenes[3] = sceneHiddenChamber

sceneHiddenChamber = story.New(
    "You find a secret chamber filled with treasure!",
    {"Take loot","Leave quietly"},
    {}
)
sceneHiddenChamber.nextScenes[1] = sceneTownSquare
sceneHiddenChamber.nextScenes[2] = sceneTownSquare

-- ===== Hook Puzzle & Trap Choices =====
local oldAccept6 = AcceptChoiceFromChat
AcceptChoiceFromChat = function(text, username)
    local accepted = oldAccept6(text, username)
    if accepted then
        if currentScene == sceneRiddleDoor then
            SolvePuzzle(username,"riddleDoor")
        elseif currentScene == sceneTrapCorridor then
            if playerChoice:lower():match("run") then
                TriggerTrap(username,"spikePit")
            end
        elseif currentScene == sceneHiddenChamber then
            if playerChoice:lower():match("take") then
                SecretRoomFound(username)
            end
        end
        -- Random events while exploring forest or dungeon
        if currentScene == sceneForest or currentScene == sceneCave then
            if math.random() < 0.3 then
                RandomEncounter(username)
            end
        end
        -- Dragon quest check
        ProgressDragonQuest(username)
    end
    return accepted
end

-- ===== Auto-start Adventure with Quests =====
btnStartGame.MouseButton1Click:Connect(function()
    SetPartyOrder()
    storyRunning = true
    SendInStory("🎭 | Ultimate Adventure begins! Explore, fight, and uncover secrets!")
    AdvanceTurn()
    sceneTownSquare:Present()
end)

-- ===== End of File 6 =====
-- Features:
-- * Puzzles (riddle doors)
-- * Traps (spike pits, poison darts)
-- * Secret rooms with loot
-- * Timed choices with random selection if timeout
-- * Multi-step quests (Dragon Slayer)
-- * Fully local, integrated with previous GUI/roster/turn system

-- ===== DND Story Bot — FILE 7 (Long-Form Dungeon Exploration, Bosses, Puzzles) =====
-- LocalScript continuation; append after File 6

-- ===== Dungeon Branching Utilities =====
local dungeonRooms = {}
local function CreateRoom(name, desc, options, nexts)
    local r = story.New(desc, options, nexts)
    dungeonRooms[name] = r
    return r
end

-- ===== Skill Check Function =====
local function SkillCheck(username, skill, difficulty)
    local roll = math.random(1,20)
    local success = roll >= difficulty
    SendInStory(("🎲 | %s attempts %s skill check (roll: %d vs %d): %s"):format(
        username, skill, roll, difficulty, success and "Success ✅" or "Fail ❌"))
    return success
end

-- ===== Boss Fight System =====
local bosses = {}
local function CreateBoss(name, hp, attack, special)
    bosses[name] = {HP=hp, MaxHP=hp, Attack=attack, Special=special, Alive=true}
end

local function BossAttack(username, bossName)
    local boss = bosses[bossName]
    if not boss or not boss.Alive then return end
    local dmg = math.random(boss.Attack-2,boss.Attack+2)
    SendInStory(("💥 | %s is hit by %s for %d damage"):format(username, bossName, dmg))
    DamagePlayer(username,dmg)
end

local function BossSpecial(username, bossName)
    local boss = bosses[bossName]
    if not boss or not boss.Alive then return end
    if boss.Special then
        SendInStory(("🔥 | %s uses special: %s"):format(bossName, boss.Special))
        DamagePlayer(username, math.random(5,10))
    end
end

-- ===== Room Examples =====
sceneForestEntrance = CreateRoom("ForestEntrance",
    "You stand at the forest edge. Paths branch north and east.",
    {"Go North","Go East","Rest"},
    {}
)
sceneDarkCave = CreateRoom("DarkCave",
    "A dark cave with strange markings. You hear growls inside.",
    {"Enter","Retreat"},
    {}
)
sceneAbandonedTemple = CreateRoom("AbandonedTemple",
    "An old temple, filled with dust and cobwebs.",
    {"Search altar","Go back"},
    {}
)

sceneForestEntrance.nextScenes[1] = sceneDarkCave
sceneForestEntrance.nextScenes[2] = sceneAbandonedTemple
sceneForestEntrance.nextScenes[3] = sceneTownSquare

sceneDarkCave.nextScenes[1] = sceneHiddenTreasure
sceneDarkCave.nextScenes[2] = sceneForestEntrance

sceneAbandonedTemple.nextScenes[1] = sceneHiddenTreasure
sceneAbandonedTemple.nextScenes[2] = sceneForestEntrance

-- ===== Hidden Treasure Room =====
sceneHiddenTreasure = CreateRoom("HiddenTreasure",
    "You find a hidden treasure room!",
    {"Take loot","Inspect room","Leave"},
    {}
)
sceneHiddenTreasure.nextScenes[1] = sceneForestEntrance
sceneHiddenTreasure.nextScenes[2] = sceneHiddenTreasure
sceneHiddenTreasure.nextScenes[3] = sceneForestEntrance

-- ===== Boss Example =====
CreateBoss("Forest Guardian", 40, 6, "Root Slam")

local function HandleBossBattle(username, bossName)
    local boss = bosses[bossName]
    if not boss or not boss.Alive then return end
    SendInStory("⚔️ | "..username.." encounters boss: "..bossName.."!")
    local inBattle = true
    while inBattle and roster[username].Alive and boss.Alive do
        SendInStory("Choose action: 1) Attack 2) Defend 3) Skill Check")
        awaitingChoice = true
        currentScene = {options={"Attack","Defend","Skill Check"}, nextScenes={}}
        while awaitingChoice do task.wait(0.2) end
        local choice = playerChoice:lower()
        if choice:match("attack") or choice:match("1") then
            local dmg = math.random(5,10)
            boss.HP = boss.HP - dmg
            SendInStory(("🗡️ | %s hits %s for %d damage. Boss HP: %d/%d"):format(username,bossName,dmg,boss.HP,boss.MaxHP))
        elseif choice:match("defend") or choice:match("2") then
            SendInStory(username.." braces for incoming attack.")
        elseif choice:match("skill") or choice:match("3") then
            if SkillCheck(username,"combat",12) then
                local dmg = math.random(8,15)
                boss.HP = boss.HP - dmg
                SendInStory(("💥 | Skill successful! %s deals %d damage. Boss HP: %d/%d"):format(username,dmg,boss.HP,boss.MaxHP))
            end
        end
        if boss.HP <= 0 then
            boss.Alive = false
            SendInStory("🏆 | "..username.." defeated "..bossName.."!")
            GiveItemToPlayer(username,"Boss Loot")
            break
        end
        BossAttack(username,bossName)
        if math.random() < 0.3 then BossSpecial(username,bossName) end
    end
end

-- ===== Hook File7 into Choice System =====
local oldAccept7 = AcceptChoiceFromChat
AcceptChoiceFromChat = function(text, username)
    local accepted = oldAccept7(text, username)
    if accepted then
        -- Dungeon exploration random events
        if currentScene == sceneForestEntrance or currentScene == sceneDarkCave or currentScene == sceneAbandonedTemple then
            if math.random() < 0.4 then RandomEncounter(username) end
        end
        -- Boss check
        if currentScene == sceneDarkCave then
            if bosses["Forest Guardian"].Alive then
                HandleBossBattle(username,"Forest Guardian")
            end
        end
    end
    return accepted
end

-- ===== Auto-start Dungeon Exploration =====
btnStartGame.MouseButton1Click:Connect(function()
    SetPartyOrder()
    storyRunning = true
    SendInStory("🏰 | Dungeon Adventure begins! Explore, fight, and uncover secrets endlessly!")
    AdvanceTurn()
    sceneForestEntrance:Present()
end)

-- ===== End of File 7 =====
-- Features:
-- * Branching dungeon rooms with multi-path exploration
-- * Boss fights with HP, attacks, specials, and turn-based combat
-- * Skill checks for tricky actions
-- * Fully local, integrated with GUI/roster/turn system
-- * Designed for endless long-form play

-- ===== DND Story Bot — FILE 8 (Expanded Dungeon, Side Quests, Traps, Multi-Boss) =====
-- LocalScript continuation; append after File 7

-- ===== Dungeon Expansion =====
local expandedRooms = {}

local function CreateExpandedRoom(name, desc, options, nexts, traps, puzzle)
    local r = story.New(desc, options, nexts)
    r.Traps = traps or {}        -- {trapName = difficulty}
    r.Puzzle = puzzle or nil     -- {desc, skill, difficulty, reward}
    expandedRooms[name] = r
    return r
end

-- ===== Trap Handling =====
local function TriggerTrap(username, trap)
    local diff = trap.difficulty or 12
    SendInStory(("⚠️ | %s triggered trap '%s'! Attempting dexterity check (vs %d)"):format(username, trap.name, diff))
    if SkillCheck(username,"dexterity",diff) then
        SendInStory("✅ | Trap avoided!")
    else
        local dmg = math.random(3,8)
        SendInStory("💥 | Trap hits! "..username.." takes "..dmg.." damage.")
        DamagePlayer(username,dmg)
    end
end

-- ===== Puzzle Handling =====
local function SolvePuzzle(username, puzzle)
    SendInStory(("🧩 | %s encounters puzzle: %s"):format(username, puzzle.desc))
    if SkillCheck(username,puzzle.skill,puzzle.difficulty) then
        SendInStory("✅ | Puzzle solved!")
        if puzzle.reward then GiveItemToPlayer(username,puzzle.reward) end
    else
        SendInStory("❌ | Puzzle failed, try again later.")
    end
end

-- ===== Example Expanded Rooms =====
local roomAncientLibrary = CreateExpandedRoom(
    "AncientLibrary",
    "A dusty library filled with ancient tomes and magical scripts.",
    {"Search books","Leave"},
    {},
    { {name="Falling Bookshelf", difficulty=14} },
    {desc="Decode an encrypted tome", skill="intelligence", difficulty=15, reward="Ancient Scroll"}
)

local roomCrystalCavern = CreateExpandedRoom(
    "CrystalCavern",
    "Glittering crystals cover the walls. Strange energy pulses here.",
    {"Inspect crystals","Move deeper","Exit"},
    {},
    { {name="Crystal Shard Trap", difficulty=13} },
    {desc="Realign energy crystals", skill="wisdom", difficulty=16, reward="Mana Gem"}
)

local roomForgottenArmory = CreateExpandedRoom(
    "ForgottenArmory",
    "An abandoned armory with rusted weapons. Some items glow faintly.",
    {"Take weapon","Inspect armor","Leave"},
    {},
    { {name="Spike Floor", difficulty=12} }
)

-- Connect rooms
sceneForestEntrance.nextScenes[4] = roomAncientLibrary
roomAncientLibrary.nextScenes[2] = roomCrystalCavern
roomCrystalCavern.nextScenes[2] = roomForgottenArmory
roomForgottenArmory.nextScenes[3] = sceneForestEntrance

-- ===== Additional Bosses =====
CreateBoss("Cavern Wyrm", 50, 8, "Tail Sweep")
CreateBoss("Armory Guardian", 45, 7, "Shield Bash")

local function HandleMultipleBosses(username)
    if bosses["Cavern Wyrm"].Alive and currentScene == roomCrystalCavern then
        HandleBossBattle(username,"Cavern Wyrm")
    end
    if bosses["Armory Guardian"].Alive and currentScene == roomForgottenArmory then
        HandleBossBattle(username,"Armory Guardian")
    end
end

-- ===== Random Events =====
local function RandomEvent(username)
    local events = {
        function()
            local dmg = math.random(2,6)
            SendInStory(("🌪️ | %s is caught in a sudden wind gust, takes %d damage!"):format(username,dmg))
            DamagePlayer(username,dmg)
        end,
        function()
            SendInStory(("💎 | %s finds a hidden gemstone!"):format(username))
            GiveItemToPlayer(username,"Gemstone")
        end,
        function()
            SendInStory(("🕷️ | A giant spider appears! Prepare for combat."))
            HandleBossBattle(username,"Giant Spider")
        end
    }
    local choice = math.random(1,#events)
    events[choice]()
end

-- ===== Hook Expanded Rooms into Choice System =====
local oldAccept8 = AcceptChoiceFromChat
AcceptChoiceFromChat = function(text, username)
    local accepted = oldAccept8(text, username)
    if accepted then
        -- Check for traps in current room
        if currentScene and currentScene.Traps then
            for _, t in ipairs(currentScene.Traps) do
                if math.random() < 0.5 then
                    TriggerTrap(username,t)
                end
            end
        end
        -- Check for puzzles
        if currentScene and currentScene.Puzzle then
            if math.random() < 0.6 then SolvePuzzle(username,currentScene.Puzzle) end
        end
        -- Random events
        if math.random() < 0.3 then RandomEvent(username) end
        -- Multiple bosses
        HandleMultipleBosses(username)
    end
    return accepted
end

-- ===== Adventure Announcement =====
btnStartGame.MouseButton1Click:Connect(function()
    SetPartyOrder()
    storyRunning = true
    SendInStory("🏰 | Expanded Dungeon Adventure begins! Explore endlessly, solve puzzles, fight bosses, and survive traps!")
    AdvanceTurn()
    sceneForestEntrance:Present()
end)

-- ===== End of File 8 =====
-- Features:
-- * Multi-region dungeon with interconnected rooms
-- * Side quests and puzzles
-- * Random traps and events
-- * Multiple bosses per area
-- * Fully local, long-term exploration
-- * Compatible with GUI, roster, and turn system

-- ===== DND Story Bot — FILE 9 (Endless Dungeon, Loot, Persistent Progression) =====
-- LocalScript continuation; append after File 8

-- ===== Persistent Loot & Inventory Expansion =====
local lootTable = {"Gold Coin","Silver Ring","Potion","Magic Scroll","Rare Gem","Ancient Artifact"}

local function RollLoot()
    return lootTable[math.random(1,#lootTable)]
end

local function GiveRandomLoot(username)
    local item = RollLoot()
    SendInStory(("💰 | %s found loot: %s"):format(username,item))
    GiveItemToPlayer(username,item)
end

-- ===== Dungeon Loop System =====
local dungeonLoops = {}

local function RegisterLoop(name, rooms)
    dungeonLoops[name] = rooms  -- rooms = array of room instances
end

local function GetNextLoopRoom(current)
    for loopName, rooms in pairs(dungeonLoops) do
        for i,r in ipairs(rooms) do
            if r == current then
                local nextIndex = i + 1
                if nextIndex > #rooms then nextIndex = 1 end
                return rooms[nextIndex]
            end
        end
    end
    return current
end

-- Example loops
RegisterLoop("ForestLoop",{sceneForestEntrance, roomAncientLibrary, roomCrystalCavern})
RegisterLoop("ArmoryLoop",{roomForgottenArmory, sceneAbandonedTemple, sceneDarkCave})

-- ===== Mini Side Quest System =====
local sideQuests = {}

local function AddSideQuest(name, desc, reward)
    sideQuests[name] = {desc=desc, reward=reward, Completed=false}
end

AddSideQuest("Rescue Lost Merchant","A merchant is trapped in the forest. Rescue him to gain reward.","Bag of Gold")
AddSideQuest("Recover Magic Tome","Find the lost magic tome in the cavern.","Spell Scroll")
AddSideQuest("Cleanse Armory","Remove dark magic from the old armory.","Enchanted Armor")

local function CompleteSideQuest(username, questName)
    local q = sideQuests[questName]
    if q and not q.Completed then
        q.Completed = true
        SendInStory(("🏅 | %s completed side quest '%s', reward: %s"):format(username,questName,q.reward))
        GiveItemToPlayer(username,q.reward)
    end
end

-- ===== Enhanced Random Event System =====
local function AdvancedRandomEvent(username)
    local events = {
        function() GiveRandomLoot(username) end,
        function()
            local dmg = math.random(1,5)
            SendInStory(("🌪️ | %s trips over roots, takes %d damage"):format(username,dmg))
            DamagePlayer(username,dmg)
        end,
        function()
            SendInStory(("👻 | A ghost appears! Run or fight!"))
            -- Mini combat: simple skill check
            if SkillCheck(username,"strength",13) then
                SendInStory(username.." scares away the ghost!")
            else
                local dmg = math.random(3,7)
                SendInStory(username.." is harmed by the ghost, "..dmg.." damage taken")
                DamagePlayer(username,dmg)
            end
        end
    }
    events[math.random(1,#events)]()
end

-- ===== Hook Endless Loops & Side Quests into Choice System =====
local oldAccept9 = AcceptChoiceFromChat
AcceptChoiceFromChat = function(text, username)
    local accepted = oldAccept9(text, username)
    if accepted then
        -- Trigger trap if present
        if currentScene and currentScene.Traps then
            for _, t in ipairs(currentScene.Traps) do
                if math.random() < 0.5 then TriggerTrap(username,t) end
            end
        end
        -- Puzzle check
        if currentScene and currentScene.Puzzle then
            if math.random() < 0.6 then SolvePuzzle(username,currentScene.Puzzle) end
        end
        -- Random event
        if math.random() < 0.4 then AdvancedRandomEvent(username) end
        -- Bosses
        HandleMultipleBosses(username)
        -- Side quests check
        for questName,q in pairs(sideQuests) do
            if not q.Completed and math.random() < 0.2 then
                SendInStory(("📜 | %s discovers side quest: %s"):format(username,q.desc))
                CompleteSideQuest(username,questName)
            end
        end
        -- Move to next room in loop if needed
        if math.random() < 0.3 then
            local nextRoom = GetNextLoopRoom(currentScene)
            if nextRoom ~= currentScene then
                task.wait(0.5)
                nextRoom:Present()
            end
        end
    end
    return accepted
end

-- ===== Endless Exploration Announcement =====
btnStartGame.MouseButton1Click:Connect(function()
    SetPartyOrder()
    storyRunning = true
    SendInStory("🏰 | Endless Dungeon Mode: explore loops, complete quests, solve puzzles, fight bosses, collect loot!")
    AdvanceTurn()
    sceneForestEntrance:Present()
end)

-- ===== End of File 9 =====
-- Features:
-- * Endless dungeon loops for replayability
-- * Persistent loot & inventory rewards
-- * Mini side quests with rewards
-- * Traps, puzzles, random events dynamically applied
-- * Multiple bosses per region
-- * Fully local, fully integrated with GUI, roster, and turn system

-- ===== DND Story Bot — FILE 10 (Multi-Tier Dungeon, Legendary Loot, Progression) =====
-- LocalScript continuation; append after File 9

-- ===== Player Progression =====
local function EnsureProgress(username)
    if not roster[username].Progress then
        roster[username].Progress = {
            Level = 1,
            XP = 0,
            SkillPoints = 0,
            Skills = {strength=0,dexterity=0,constitution=0,intelligence=0,wisdom=0,charisma=0}
        }
    end
end

local function AddXP(username,xp)
    EnsureProgress(username)
    local p = roster[username].Progress
    p.XP = p.XP + xp
    SendInStory(("⭐ | %s gains %d XP"):format(username,xp))
    -- Level up every 50 XP
    while p.XP >= p.Level * 50 do
        p.XP = p.XP - p.Level * 50
        p.Level = p.Level + 1
        p.SkillPoints = p.SkillPoints + 3
        SendInStory(("🔺 | %s leveled up! Level %d, 3 skill points gained"):format(username,p.Level))
    end
end

local function UpgradeSkill(username,skill)
    EnsureProgress(username)
    local p = roster[username].Progress
    if p.SkillPoints > 0 and p.Skills[skill] ~= nil then
        p.Skills[skill] = p.Skills[skill] + 1
        p.SkillPoints = p.SkillPoints - 1
        SendInStory(("💪 | %s increased %s to %d"):format(username,skill,p.Skills[skill]))
    end
end

-- ===== Multi-Tier Dungeon =====
local dungeonFloors = {}

local function CreateFloor(name, rooms)
    dungeonFloors[name] = rooms  -- rooms = array of room instances
end

local function GetFloorNextRoom(current)
    for fname, rooms in pairs(dungeonFloors) do
        for i,r in ipairs(rooms) do
            if r == current then
                local nextIndex = i + 1
                if nextIndex > #rooms then
                    -- optional: ascend to next floor or loop back
                    return rooms[1]
                end
                return rooms[nextIndex]
            end
        end
    end
    return current
end

-- Example floors
CreateFloor("ForestFloor",{sceneForestEntrance, roomAncientLibrary, roomCrystalCavern})
CreateFloor("ArmoryFloor",{roomForgottenArmory, sceneAbandonedTemple, sceneDarkCave})

-- ===== Legendary & Rare Loot =====
local legendaryLootTable = {"Dragon Sword","Phoenix Feather","Orb of Infinity","Cloak of Shadows","Ring of Time"}

local function RollLegendaryLoot()
    local chance = math.random()
    if chance < 0.05 then
        return legendaryLootTable[math.random(1,#legendaryLootTable)]
    end
    return nil
end

local function GiveLoot(username)
    local item = RollLoot()
    if item then
        SendInStory(("💎 | %s found loot: %s"):format(username,item))
        GiveItemToPlayer(username,item)
    end
    local rareItem = RollLegendaryLoot()
    if rareItem then
        SendInStory(("🌟 | Legendary loot! %s found %s"):format(username,rareItem))
        GiveItemToPlayer(username,rareItem)
    end
end

-- ===== Puzzle Chains =====
local puzzleChains = {}

local function AddPuzzleChain(name, puzzles)
    puzzleChains[name] = puzzles  -- array of puzzle tables
end

local function ProgressPuzzleChain(username,chainName)
    local chain = puzzleChains[chainName]
    if not chain then return end
    local idx = chain.Current or 1
    local puzzle = chain[idx]
    if puzzle then
        SolvePuzzle(username,puzzle)
        chain.Current = idx + 1
    end
end

-- Example chain
AddPuzzleChain("CrystalSequence",{
    {desc="Align blue crystal", skill="intelligence", difficulty=12, reward="Crystal Shard"},
    {desc="Align red crystal", skill="intelligence", difficulty=14, reward="Fire Gem"},
    {desc="Align green crystal", skill="intelligence", difficulty=16, reward="Emerald Fragment"}
})

-- ===== Hook Multi-Floor, Progression, Legendary Loot into Choices =====
local oldAccept10 = AcceptChoiceFromChat
AcceptChoiceFromChat = function(text, username)
    local accepted = oldAccept10(text, username)
    if accepted then
        EnsureProgress(username)
        -- XP gain per choice
        AddXP(username,math.random(5,10))
        -- Trigger trap
        if currentScene and currentScene.Traps then
            for _, t in ipairs(currentScene.Traps) do
                if math.random() < 0.5 then TriggerTrap(username,t) end
            end
        end
        -- Puzzle chains
        for chainName,_ in pairs(puzzleChains) do
            if math.random() < 0.3 then ProgressPuzzleChain(username,chainName) end
        end
        -- Random events & bosses
        if math.random() < 0.4 then AdvancedRandomEvent(username) end
        HandleMultipleBosses(username)
        -- Loot
        GiveLoot(username)
        -- Move to next room on floor
        if math.random() < 0.3 then
            local nextRoom = GetFloorNextRoom(currentScene)
            if nextRoom ~= currentScene then
                task.wait(0.5)
                nextRoom:Present()
            end
        end
    end
    return accepted
end

-- ===== Extended Exploration Announcement =====
btnStartGame.MouseButton1Click:Connect(function()
    SetPartyOrder()
    storyRunning = true
    SendInStory("🏰 | Multi-Tier Dungeon Adventure starts! Level up, collect legendary loot, solve puzzle chains, conquer bosses!")
    AdvanceTurn()
    sceneForestEntrance:Present()
end)

-- ===== End of File 10 =====
-- Features:
-- * Player XP, Level, Skill progression system
-- * Multi-tier dungeon floors with looping & branching paths
-- * Legendary loot with low chance drop
-- * Puzzle chains requiring multiple sequential successes
-- * Integrated with turn system, GUI, roster, and local play
-- * Dynamic XP, loot, events, traps, bosses, endless exploration

-- ===== DND Story Bot — FILE 11 (Epic Raids, Rare Events, Branching Paths) =====
-- LocalScript continuation; append after File 10

-- ===== Rare Event System =====
local rareEvents = {
    function(username)
        SendInStory(("🌌 | %s stumbles upon a magical portal! Teleported to unknown room."):format(username))
        local rooms = {sceneDarkCave, sceneCrystalCavern, sceneAbandonedTemple}
        local r = rooms[math.random(1,#rooms)]
        task.wait(0.5)
        r:Present()
    end,
    function(username)
        SendInStory(("⚡ | %s finds a blessing from an ancient spirit! HP fully restored."):format(username))
        EnsureRosterFor(username)
        roster[username].HP = settings.maxHP
        UpdateStatBox()
        RefreshPartyUI()
    end,
    function(username)
        SendInStory(("💥 | Chaos trap triggered! All party members take 2-5 damage."):format(username))
        for _, n in ipairs(partyOrder) do
            local dmg = math.random(2,5)
            DamagePlayer(n,dmg)
        end
    end
}

local function TriggerRareEvent(username)
    if math.random() < 0.08 then
        rareEvents[math.random(1,#rareEvents)](username)
    end
end

-- ===== Epic Multi-Boss Raids =====
local raidBosses = {
    {name="Stone Golem", HP=40, Damage=8},
    {name="Shadow Wraith", HP=35, Damage=10},
    {name="Ancient Dragon", HP=50, Damage=12},
    {name="Necromancer King", HP=45, Damage=9}
}

local activeRaid = nil
local function StartEpicRaid()
    activeRaid = {}
    for _, b in ipairs(raidBosses) do
        table.insert(activeRaid,{name=b.name, HP=b.HP, Damage=b.Damage})
    end
    SendInStory("⚔️ | Epic Raid Started! Multiple bosses have appeared!")
end

local function DamageRaidBoss(idx, dmg)
    if not activeRaid or not activeRaid[idx] then return end
    activeRaid[idx].HP = activeRaid[idx].HP - dmg
    SendInStory(("💢 | %s took %d damage (HP left: %d)"):format(activeRaid[idx].name,dmg,math.max(0,activeRaid[idx].HP)))
    if activeRaid[idx].HP <= 0 then
        SendInStory(("🏆 | Boss defeated: %s"):format(activeRaid[idx].name))
        table.remove(activeRaid,idx)
    end
end

local function HandleRaidAttack(username)
    if not activeRaid then return end
    -- Player attacks random boss
    local idx = math.random(1,#activeRaid)
    local dmg = math.random(3,8)
    DamageRaidBoss(idx,dmg)
    -- Boss counterattack
    for _, p in ipairs(partyOrder) do
        local b = activeRaid[math.random(1,#activeRaid)]
        if b then
            local bdmg = math.random(1,b.Damage)
            SendInStory(("💀 | %s is hit by %s for %d damage"):format(p,b.name,bdmg))
            DamagePlayer(p,bdmg)
        end
    end
    if #activeRaid == 0 then
        SendInStory("🎉 | All raid bosses defeated! Epic rewards await!")
        for _, p in ipairs(partyOrder) do
            GiveLoot(p)
            AddXP(p,20)
        end
        activeRaid = nil
    end
end

-- ===== Branching Dungeon Paths =====
local branchingPaths = {
    {from=sceneForestEntrance, to={sceneDarkCave, roomAncientLibrary, roomCrystalCavern}},
    {from=roomForgottenArmory, to={sceneAbandonedTemple, roomCrystalCavern}},
    {from=sceneAbandonedTemple, to={sceneDarkCave, roomForgottenArmory}}
}

local function GetBranchingChoices(current)
    for _, b in ipairs(branchingPaths) do
        if b.from == current then
            return b.to
        end
    end
    return {current}
end

-- ===== Player-Driven Side Quests =====
local dynamicQuests = {}
local function CreateDynamicQuest(name, desc, reward)
    dynamicQuests[name] = {desc=desc, reward=reward, Completed=false}
end

CreateDynamicQuest("Defeat Forest Phantom","A phantom haunts the forest. Defeat it!","Ghost Blade")
CreateDynamicQuest("Recover Stolen Relic","Find the thief who stole a relic.","Ancient Coin")
CreateDynamicQuest("Seal Dark Portal","Close a dark portal before it grows.","Portal Seal Stone")

local function CheckDynamicQuests(username)
    for qn,q in pairs(dynamicQuests) do
        if not q.Completed and math.random() < 0.2 then
            q.Completed = true
            SendInStory(("🛡️ | %s completed dynamic quest '%s', reward: %s"):format(username,qn,q.reward))
            GiveItemToPlayer(username,q.reward)
            AddXP(username,15)
        end
    end
end

-- ===== Hook File 11 Mechanics into AcceptChoice =====
local oldAccept11 = AcceptChoiceFromChat
AcceptChoiceFromChat = function(text, username)
    local accepted = oldAccept11(text, username)
    if accepted then
        -- Trigger rare events
        TriggerRareEvent(username)
        -- Random chance to start raid
        if math.random() < 0.05 and not activeRaid then
            StartEpicRaid()
        end
        if activeRaid then
            HandleRaidAttack(username)
        end
        -- Branching paths
        if math.random() < 0.4 then
            local options = GetBranchingChoices(currentScene)
            local nextScene = options[math.random(1,#options)]
            task.wait(0.5)
            nextScene:Present()
        end
        -- Dynamic quests
        CheckDynamicQuests(username)
        -- Loot & XP handled from previous files
    end
    return accepted
end

-- ===== Announce Epic Dungeon Mode =====
btnStartGame.MouseButton1Click:Connect(function()
    SetPartyOrder()
    storyRunning = true
    SendInStory("🌟 | Epic Dungeon Adventure: multi-boss raids, rare events, branching paths, dynamic quests, endless exploration!")
    AdvanceTurn()
    sceneForestEntrance:Present()
end)

-- ===== End of File 11 =====
-- Features:
-- * Rare events, magical portals, blessings, chaos traps
-- * Epic multi-boss raids with counterattacks & rewards
-- * Branching dungeon paths for non-linear exploration
-- * Player-driven dynamic side quests with rewards & XP
-- * Fully local, fully integrated with GUI, roster, turn-based system

-- ===== DND Story Bot — FILE 12 (World Modifiers, Timed Challenges, Legendary Rooms) =====
-- LocalScript continuation; append after File 11

-- ===== World Modifiers =====
local worldModifiers = {
    {name="Darkness", effect="All players -1 to attack rolls"},
    {name="Blessed Ground", effect="HP regen +1 per turn"},
    {name="Mana Surge", effect="Magic damage +2"},
    {name="Cursed Fog", effect="Random player loses 1 HP per turn"}
}

local activeModifier = nil
local function ApplyWorldModifier()
    activeModifier = worldModifiers[math.random(1,#worldModifiers)]
    SendInStory(("🌍 | World Modifier Active: %s — %s"):format(activeModifier.name, activeModifier.effect))
end

local function ProcessWorldModifier()
    if not activeModifier then return end
    for _, pname in ipairs(partyOrder) do
        if activeModifier.name == "Blessed Ground" then
            EnsureRosterFor(pname)
            roster[pname].HP = clampHP(roster[pname].HP + 1)
        elseif activeModifier.name == "Cursed Fog" then
            EnsureRosterFor(pname)
            roster[pname].HP = clampHP(roster[pname].HP - 1)
        end
    end
end

-- ===== Timed Challenges =====
local activeTimerChallenge = nil
local function StartTimedChallenge(description,duration,xpReward)
    activeTimerChallenge = {desc=description,timeLeft=duration,xp=xpReward}
    SendInStory(("⏳ | Timed Challenge started: %s — Complete within %d seconds"):format(description,duration))
    spawn(function()
        while activeTimerChallenge and activeTimerChallenge.timeLeft > 0 do
            task.wait(1)
            activeTimerChallenge.timeLeft = activeTimerChallenge.timeLeft - 1
        end
        if activeTimerChallenge then
            SendInStory("⏱️ | Timed Challenge ended: "..activeTimerChallenge.desc)
            -- reward random player who participated
            local p = partyOrder[math.random(1,#partyOrder)]
            AddXP(p,activeTimerChallenge.xp)
            SendInStory(("🏆 | %s gains %d XP for challenge completion"):format(p,activeTimerChallenge.xp))
            activeTimerChallenge = nil
        end
    end)
end

-- ===== Hidden Legendary Rooms =====
local legendaryRooms = {sceneHiddenVault, roomSecretChamber, sceneAncientSanctum}
local function CheckHiddenRoom(username)
    if math.random() < 0.07 then
        local r = legendaryRooms[math.random(1,#legendaryRooms)]
        SendInStory(("🔑 | %s discovers a hidden legendary room!"):format(username))
        task.wait(0.5)
        r:Present()
    end
end

-- ===== Multi-Tiered Boss Progression =====
local bossTiers = {
    {name="Stone Sentinel", HP=50, Damage=10, Tier=1},
    {name="Shadow Wraith", HP=60, Damage=12, Tier=2},
    {name="Ancient Dragon", HP=75, Damage=15, Tier=3},
    {name="Necromancer King", HP=90, Damage=18, Tier=4},
    {name="World Devourer", HP=120, Damage=25, Tier=5}
}

local function SpawnBossTier(tierLevel)
    local bossData = nil
    for _, b in ipairs(bossTiers) do
        if b.Tier == tierLevel then bossData = b end
    end
    if bossData then
        activeRaid = {{name=bossData.name, HP=bossData.HP, Damage=bossData.Damage}}
        SendInStory(("⚔️ | Boss Tier %d appears: %s"):format(tierLevel,bossData.name))
    end
end

-- ===== Achievement Tracking =====
local achievements = {}
local function UnlockAchievement(username,achName,desc)
    achievements[achName] = achievements[achName] or {}
    if not achievements[achName][username] then
        achievements[achName][username] = true
        SendInStory(("🏅 | Achievement unlocked for %s: %s — %s"):format(username,achName,desc))
    end
end

-- Examples
local function CheckAchievements(username)
    EnsureRosterFor(username)
    local inv = roster[username].Inventory or {}
    if #inv >= 10 then UnlockAchievement(username,"Collector","Collected 10 items") end
    if roster[username].HP == settings.maxHP then UnlockAchievement(username,"Untouchable","Fully healed at least once") end
end

-- ===== Hook File 12 Mechanics into AcceptChoice =====
local oldAccept12 = AcceptChoiceFromChat
AcceptChoiceFromChat = function(text, username)
    local accepted = oldAccept12(text, username)
    if accepted then
        -- World modifier effect
        ProcessWorldModifier()
        -- Chance to trigger hidden legendary room
        CheckHiddenRoom(username)
        -- Chance to start timed challenge
        if math.random() < 0.06 then
            StartTimedChallenge("Solve the ancient puzzle",30,20)
        end
        -- Chance to spawn higher-tier boss if all current bosses defeated
        if not activeRaid and math.random() < 0.05 then
            local tier = math.random(1,#bossTiers)
            SpawnBossTier(tier)
        end
        -- Achievement checks
        CheckAchievements(username)
    end
    return accepted
end

-- ===== Announce Legendary Dungeon Mode =====
btnStartGame.MouseButton1Click:Connect(function()
    SetPartyOrder()
    storyRunning = true
    SendInStory("🌟 | Legendary Dungeon Adventure: world modifiers, timed challenges, hidden legendary rooms, multi-tiered bosses, achievements!")
    AdvanceTurn()
    ApplyWorldModifier()
    sceneForestEntrance:Present()
end)

-- ===== End of File 12 =====
-- Features:
-- * World Modifiers affecting combat and HP
-- * Timed Challenges with XP rewards
-- * Hidden Legendary Rooms randomly discovered
-- * Multi-tiered boss progression (Tier 1-5)
-- * Achievement tracking for players
-- * Fully local, integrated with GUI, roster, turn-based system

-- ===== DND Story Bot — FILE 13 (GM-Only Multi-Path Campaigns & Progression) =====
-- LocalScript; runs only on GM's client

-- ===== Player Meta-Progression =====
local playerMeta = {} -- persistent stats tracked by GM

local function EnsureMetaFor(username)
    if not playerMeta[username] then
        playerMeta[username] = {
            Level = 1,
            XP = 0,
            Guild = nil,
            Achievements = {}
        }
    end
end

local function AddXP(username, amount)
    EnsureMetaFor(username)
    playerMeta[username].XP = playerMeta[username].XP + amount
    while playerMeta[username].XP >= 50 do
        playerMeta[username].XP = playerMeta[username].XP - 50
        playerMeta[username].Level = playerMeta[username].Level + 1
        SendInStory(("🎉 | %s leveled up! Now Level %d"):format(username, playerMeta[username].Level))
        GiveItemToPlayer(username,"Level-Up Reward")
    end
end

local function JoinGuild(username, guildName)
    EnsureMetaFor(username)
    playerMeta[username].Guild = guildName
    SendInStory(("🏰 | %s joined the guild: %s"):format(username, guildName))
end

-- ===== Campaigns =====
local campaigns = {
    ["Forest Arc"] = {scenes={sceneForestEntrance, sceneHiddenCave, sceneCrystalCavern, scenePhantomClearing}},
    ["Temple Arc"] = {scenes={sceneAbandonedTemple, sceneForgottenArmory, sceneAncientSanctum}},
    ["Underground Arc"] = {scenes={sceneDarkCave, sceneSecretChamber, sceneVaultOfShadows}}
}

local activeCampaign = nil
local campaignIndex = 1

local function StartCampaign(campaignName)
    activeCampaign = campaigns[campaignName]
    if not activeCampaign then
        SendInStory("⚠️ | Campaign not found: "..tostring(campaignName))
        return
    end
    campaignIndex = 1
    SendInStory("📜 | Starting Campaign: "..campaignName)
    local firstScene = activeCampaign.scenes[campaignIndex]
    if firstScene then firstScene:Present() end
end

local function AdvanceCampaign()
    if not activeCampaign then return end
    campaignIndex = campaignIndex + 1
    if campaignIndex <= #activeCampaign.scenes then
        local nextScene = activeCampaign.scenes[campaignIndex]
        if nextScene then nextScene:Present() end
    else
        SendInStory("🏁 | Campaign completed!")
        activeCampaign = nil
        campaignIndex = 1
    end
end

-- ===== Linked Campaigns =====
local linkedCampaigns = {
    ["Forest Arc"] = {"Temple Arc", "Underground Arc"},
    ["Temple Arc"] = {"Underground Arc"},
    ["Underground Arc"] = {"Forest Arc"}
}

local function UnlockLinkedCampaign(current)
    local options = linkedCampaigns[current]
    if options and #options > 0 then
        local unlocked = options[math.random(1,#options)]
        SendInStory("🔗 | New campaign unlocked: "..unlocked)
        return unlocked
    end
    return nil
end

-- ===== Permanent Achievements =====
local function UnlockMetaAchievement(username, achName, desc)
    EnsureMetaFor(username)
    if not playerMeta[username].Achievements[achName] then
        playerMeta[username].Achievements[achName] = true
        SendInStory(("🏅 | Achievement unlocked for %s: %s — %s"):format(username,achName,desc))
    end
end

local function CheckMetaAchievements(username)
    EnsureRosterFor(username)
    EnsureMetaFor(username)
    local inv = roster[username].Inventory or {}
    if #inv >= 15 then UnlockMetaAchievement(username,"Master Collector","Collected 15 items") end
    if playerMeta[username].Level >= 5 then UnlockMetaAchievement(username,"Veteran Adventurer","Reached Level 5") end
end

-- ===== Hook GM-Only Mechanics into Choices =====
local oldAcceptChoice = AcceptChoiceFromChat
AcceptChoiceFromChat = function(text, username)
    local accepted = oldAcceptChoice(text, username)
    if accepted then
        CheckMetaAchievements(username)
        if activeCampaign then
            AdvanceCampaign()
        else
            local unlocked = UnlockLinkedCampaign("Forest Arc")
            if unlocked then
                SendInStory("📖 | You can now start the campaign: "..unlocked)
            end
        end
        -- Optional: world modifiers, hidden rooms, boss spawns
        if activeTimerChallenge then AddXP(username,5) end
    end
    return accepted
end

-- ===== GM GUI: Campaign Selector =====
local campaignPanel = Instance.new("Frame")
campaignPanel.Parent = gui
campaignPanel.Name = "CampaignPanel"
campaignPanel.Size = UDim2.new(0,300,0,200)
campaignPanel.Position = UDim2.new(0,650,0,80)
campaignPanel.BackgroundColor3 = Color3.fromRGB(25,25,30)
Instance.new("UICorner", campaignPanel).CornerRadius = UDim.new(0,8)

local campTitle = Instance.new("TextLabel")
campTitle.Parent = campaignPanel
campTitle.Size = UDim2.new(1,-20,0,30)
campTitle.Position = UDim2.new(0,10,0,10)
campTitle.Text = "Campaign Selector"
campTitle.BackgroundTransparency = 1
campTitle.Font = Enum.Font.GothamBold
campTitle.TextColor3 = Color3.fromRGB(230,230,240)

local yPos = 50
for campName,_ in pairs(campaigns) do
    local btn = Instance.new("TextButton")
    btn.Parent = campaignPanel
    btn.Size = UDim2.new(1,-20,0,28)
    btn.Position = UDim2.new(0,10,0,yPos)
    btn.Text = campName
    btn.Font = Enum.Font.Gotham
    btn.BackgroundColor3 = Color3.fromRGB(40,40,46)
    btn.TextColor3 = Color3.fromRGB(240,240,250)
    Instance.new("UICorner", btn).CornerRadius = UDim.new(0,6)
    btn.MouseButton1Click:Connect(function()
        StartCampaign(campName)
    end)
    yPos = yPos + 34
end

-- ===== End of File 13 (GM-Only) =====
-- Features:
-- * Fully GM-local; only GM sees GUI and controls campaigns
-- * Players interact via chat commands
-- * Campaigns, multi-path scenes, linked campaigns
-- * Permanent XP, leveling, guilds, and achievements tracked on GM
-- * Turn-based choice system remains intact

