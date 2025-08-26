-— FILE 1 (CORE SYSTEM + GUI + VOTING + TURN ORDER)
-- Put this at the top of your LocalScript. Append other slices below it.
-- IMPORTANT: This is a LocalScript. Place it in StarterPlayerScripts or StarterGui.

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
    voteTimeout = 30,           -- seconds to wait for votes
    maxHP = 20,
}

-- ===== Global State =====
local storyRunning = false
local currentScene = nil      -- scenes will be added in future slices
local awaitingChoice = false
local lastMessageTime = 0
local playerChoice = nil

-- Party & roster
local partyMembers = {}       -- whitelist: usernames (does NOT include LocalPlayer by default)
local partyOrder = {}         -- order of players taking turns (includes LocalPlayer)
local roster = {}             -- roster[username] = {HP=..., Inventory={...}}

-- Turn system
local turnIndex = 1

-- Voting
local availableThemes = {"Medieval", "Magical", "Sci-Fi"}
local voteChoices = {}        -- votes[username] = theme
local finalTheme = "Medieval"

-- ===== Utilities =====
local function now() return tick() end

local function clampHP(hp)
    if hp < 0 then return 0 end
    if hp > settings.maxHP then return settings.maxHP end
    return hp
end

local function safeSendChat(msg)
    -- Rate-limited sending; only used for system announcements
    local dt = now() - lastMessageTime
    if dt < settings.minMessageCooldown then
        task.wait(settings.minMessageCooldown - dt)
    end
    lastMessageTime = now()
    -- attempt modern channel first, then fallback
    local ok, err = pcall(function()
        if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
            if TextChatService.TextChannels and TextChatService.TextChannels:FindFirstChild("RBXGeneral") then
                TextChatService.TextChannels.RBXGeneral:SendAsync(msg)
                return
            end
        end
        local ev = ReplicatedStorage:FindFirstChild("DefaultChatSystemChatEvents")
        if ev and ev:FindFirstChild("SayMessageRequest") then
            ev.SayMessageRequest:FireServer(msg, "All")
        end
    end)
    if not ok then
        warn("[DND] send failed:", err)
    end
end

local function SendSystem(msg)
    -- Use this to send messages even if storyRunning == false
    safeSendChat(msg)
end

local function SendInStory(msg)
    if not storyRunning then return end
    safeSendChat(msg)
end

-- ===== Roster management (per-player stats) =====
local function EnsureRosterFor(username)
    if roster[username] == nil then
        roster[username] = {
            HP = settings.maxHP,
            Inventory = {},
            Alive = true,
        }
    end
end

local function SetPartyOrder()
    -- builds partyOrder: LocalPlayer first, then partyMembers in order
    partyOrder = {}
    table.insert(partyOrder, LocalPlayer.Name)
    for _, name in ipairs(partyMembers) do
        if name ~= LocalPlayer.Name then
            table.insert(partyOrder, name)
        end
    end
    -- ensure roster entries
    for _, name in ipairs(partyOrder) do EnsureRosterFor(name) end
    turnIndex = 1
end

local function GetCurrentTurnPlayer()
    if #partyOrder == 0 then
        return LocalPlayer.Name
    end
    if partyOrder[turnIndex] then
        return partyOrder[turnIndex]
    else
        -- fallback fix
        turnIndex = 1
        return partyOrder[1] or LocalPlayer.Name
    end
end

local function AdvanceTurn()
    if #partyOrder <= 1 then
        -- solo play, no change
        SendInStory("🎯 | Next turn: "..GetCurrentTurnPlayer())
        return
    end
    turnIndex = turnIndex + 1
    if turnIndex > #partyOrder then turnIndex = 1 end
    SendInStory("🎯 | It is now "..GetCurrentTurnPlayer().."'s turn.")
    -- update GUI label if exists
    if turnLabel and turnLabel.Parent then
        turnLabel.Text = "Turn: "..GetCurrentTurnPlayer()
    end
end

-- ===== Items per theme =====
local themeItems = {
    ["Medieval"] = {"Torch","Sword","Shield","Healing Potion","Ruin Key"},
    ["Magical"]  = {"Wand","Spellbook","Crystal","Mana Potion","Rune Shard"},
    ["Sci-Fi"]   = {"Flashlight","Laser Pistol","Energy Cell","Medkit","Data Chip"},
}

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
title.Text = "D&D Story Master (Core)"
title.Font = Enum.Font.GothamBold
title.TextScaled = true
title.BackgroundTransparency = 1
title.TextColor3 = Color3.fromRGB(235,235,245)

local info = Instance.new("TextLabel")
info.Parent = panel
info.Size = UDim2.new(1,-24,0,20)
info.Position = UDim2.new(0,12,0,46)
info.Text = "Whitelist players, vote theme, start the adventure."
info.Font = Enum.Font.Gotham
info.TextSize = 14
info.BackgroundTransparency = 1
info.TextColor3 = Color3.fromRGB(200,200,210)

-- Stats label (local view)
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

local function FormatQuestsLocal(q)
    local arr = {}
    for k,_ in pairs(q or {}) do table.insert(arr,k) end
    if #arr == 0 then return "(none)" end
    return table.concat(arr,", ")
end

local function UpdateStatBox()
    EnsureRosterFor(LocalPlayer.Name)
    local lp = roster[LocalPlayer.Name]
    statBox.Text = ("You: %s\nHP: %d/%d\nItems: %s\nQuests: %s\nTheme: %s")
        :format(LocalPlayer.Name, lp.HP, settings.maxHP, FormatInv(lp.Inventory), FormatQuestsLocal(lp.Quests or {}), finalTheme)
end
UpdateStatBox()

-- Buttons: Start Vote, Start Game, Reset, Heal +5, Full Heal
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

local btnStartVote = mkBtn("🗳️ Start Theme Vote (chat or GUI)", 210)
local btnStartGame = mkBtn("▶ Start Game (after vote)", 254)
local btnReset = mkBtn("↺ Reset Local Game", 298)
local btnHeal5 = mkBtn("➕ Heal Self +5", 342)
local btnHealFull = mkBtn("❤️ Full Heal Self", 386)

-- Turn label
local turnLabel = Instance.new("TextLabel")
turnLabel.Parent = panel
turnLabel.Size = UDim2.new(1,-24,0,28)
turnLabel.Position = UDim2.new(0,12,0,434)
turnLabel.BackgroundTransparency = 1
turnLabel.TextColor3 = Color3.fromRGB(255,245,190)
turnLabel.Font = Enum.Font.GothamBold
turnLabel.TextScaled = true
turnLabel.Text = "Turn: (none)"

-- Party Manager panel (side)
local partyPanel = Instance.new("Frame")
partyPanel.Parent = gui
partyPanel.Name = "PartyPanel"
partyPanel.Size = UDim2.new(0,260,0,300)
partyPanel.Position = UDim2.new(0,370,0,80)
partyPanel.BackgroundColor3 = Color3.fromRGB(22,22,25)
partyPanel.Visible = true
Instance.new("UICorner", partyPanel).CornerRadius = UDim.new(0,8)

local pTitle = Instance.new("TextLabel")
pTitle.Parent = partyPanel
pTitle.Size = UDim2.new(1,-20,0,30)
pTitle.Position = UDim2.new(0,10,0,8)
pTitle.Text = "Party Whitelist / Members"
pTitle.BackgroundTransparency = 1
pTitle.Font = Enum.Font.GothamBold
pTitle.TextColor3 = Color3.fromRGB(230,230,240)

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

-- Dynamic per-member panels container
local membersFrame = Instance.new("ScrollingFrame")
membersFrame.Parent = partyPanel
membersFrame.Size = UDim2.new(1,-20,0,100)
membersFrame.Position = UDim2.new(0,10,0,120)
membersFrame.CanvasSize = UDim2.new(0,0,0,0)
membersFrame.ScrollBarThickness = 8
membersFrame.BackgroundTransparency = 1
local membersLayout = Instance.new("UIListLayout")
membersLayout.Parent = membersFrame
membersLayout.SortOrder = Enum.SortOrder.LayoutOrder
membersLayout.Padding = UDim.new(0,6)

-- Helper to refresh party list & member buttons
local function RefreshPartyUI()
    -- partyListLabel text
    if #partyMembers == 0 then
        partyListLabel.Text = "(none)"
    else
        partyListLabel.Text = table.concat(partyMembers, "\n")
    end

    -- clear existing children in membersFrame
    for _, c in ipairs(membersFrame:GetChildren()) do
        if not c:IsA("UIListLayout") then c:Destroy() end
    end

    -- create a small panel for each party member + the LocalPlayer as "You"
    local displayOrder = {LocalPlayer.Name}
    for _, n in ipairs(partyMembers) do
        if n ~= LocalPlayer.Name then table.insert(displayOrder, n) end
    end

    for i, name in ipairs(displayOrder) do
        EnsureRosterFor(name)
        local entry = Instance.new("Frame")
        entry.Size = UDim2.new(1,0,0,72)
        entry.BackgroundColor3 = Color3.fromRGB(30,30,34)
        entry.Parent = membersFrame
        Instance.new("UICorner", entry).CornerRadius = UDim.new(0,6)

        local nameLbl = Instance.new("TextLabel")
        nameLbl.Parent = entry
        nameLbl.Position = UDim2.new(0,8,0,6)
        nameLbl.Size = UDim2.new(0.5,-12,0,22)
        nameLbl.Text = name
        nameLbl.BackgroundTransparency = 1
        nameLbl.TextColor3 = Color3.fromRGB(240,240,245)
        nameLbl.Font = Enum.Font.GothamBold

        local hpLbl = Instance.new("TextLabel")
        hpLbl.Parent = entry
        hpLbl.Position = UDim2.new(0,8,0,28)
        hpLbl.Size = UDim2.new(0.5,-12,0,20)
        hpLbl.Text = "HP: "..tostring(roster[name].HP or settings.maxHP)
        hpLbl.BackgroundTransparency = 1
        hpLbl.Font = Enum.Font.Code
        hpLbl.TextColor3 = Color3.fromRGB(200,200,210)

        -- Buttons: Give Item, Revive, Heal +5
        local btnGive = Instance.new("TextButton")
        btnGive.Parent = entry
        btnGive.Size = UDim2.new(0.3,0,0,26)
        btnGive.Position = UDim2.new(0.52,0,0,6)
        btnGive.Text = "Give Item"
        btnGive.Font = Enum.Font.Gotham
        Instance.new("UICorner", btnGive).CornerRadius = UDim.new(0,6)

        local btnRevive = Instance.new("TextButton")
        btnRevive.Parent = entry
        btnRevive.Size = UDim2.new(0.22,0,0,26)
        btnRevive.Position = UDim2.new(0.82,0,0,6)
        btnRevive.Text = "Revive"
        btnRevive.Font = Enum.Font.Gotham
        Instance.new("UICorner", btnRevive).CornerRadius = UDim.new(0,6)

        local btnHeal = Instance.new("TextButton")
        btnHeal.Parent = entry
        btnHeal.Size = UDim2.new(0.52,0,0,26)
        btnHeal.Position = UDim2.new(0.52,0,0,34)
        btnHeal.Text = "Heal +5"
        btnHeal.Font = Enum.Font.Gotham
        Instance.new("UICorner", btnHeal).CornerRadius = UDim.new(0,6)

        -- Give item UI popup
        local function ShowGiveItemPopup(targetName)
            -- popup frame
            local popup = Instance.new("Frame"); popup.Parent = gui; popup.Size = UDim2.new(0,360,0,160); popup.Position = UDim2.new(0.5,-180,0.5,-80); popup.BackgroundColor3 = Color3.fromRGB(22,22,24); Instance.new("UICorner", popup).CornerRadius = UDim.new(0,10)
            local lbl = Instance.new("TextLabel"); lbl.Parent = popup; lbl.Position = UDim2.new(0,12,0,8); lbl.Size = UDim2.new(1,-24,0,36); lbl.BackgroundTransparency = 1; lbl.Text = "Give Item to "..targetName; lbl.Font = Enum.Font.GothamBold; lbl.TextColor3 = Color3.fromRGB(230,230,245); lbl.TextScaled = true
            local dropdown = Instance.new("TextBox"); dropdown.Parent = popup; dropdown.Position = UDim2.new(0,12,0,52); dropdown.Size = UDim2.new(1,-24,0,28); dropdown.PlaceholderText = "Type item name (autocomplete not available)"; dropdown.BackgroundColor3 = Color3.fromRGB(28,28,30); dropdown.TextColor3 = Color3.fromRGB(230,230,245)
            local btnOK = Instance.new("TextButton"); btnOK.Parent = popup; btnOK.Position = UDim2.new(0.12,0,0,96); btnOK.Size = UDim2.new(0.36,0,0,36); btnOK.Text = "Give"; btnOK.Font = Enum.Font.GothamBold; Instance.new("UICorner", btnOK).CornerRadius = UDim.new(0,6)
            local btnCancel = Instance.new("TextButton"); btnCancel.Parent = popup; btnCancel.Position = UDim2.new(0.52,0,0,96); btnCancel.Size = UDim2.new(0.36,0,0,36); btnCancel.Text = "Cancel"; btnCancel.Font = Enum.Font.GothamBold; Instance.new("UICorner", btnCancel).CornerRadius = UDim.new(0,6)

            btnOK.MouseButton1Click:Connect(function()
                local it = tostring(dropdown.Text or "")
                if it ~= "" then
                    EnsureRosterFor(targetName)
                    table.insert(roster[targetName].Inventory, it)
                    SendInStory("🎁 | "..targetName.." received: "..it.." (given by "..LocalPlayer.Name..")")
                    UpdateStatBox()
                end
                popup:Destroy()
                RefreshPartyUI()
            end)
            btnCancel.MouseButton1Click:Connect(function() popup:Destroy() end)
        end

        -- Revive implementation
        btnRevive.MouseButton1Click:Connect(function()
            EnsureRosterFor(name)
            roster[name].HP = math.max(1, math.floor(settings.maxHP/2))
            roster[name].Alive = true
            SendInStory("⛑️ | "..name.." has been revived (local view).")
            if name == LocalPlayer.Name then UpdateStatBox() end
            RefreshPartyUI()
        end)

        -- Heal +5 implementation
        btnHeal.MouseButton1Click:Connect(function()
            EnsureRosterFor(name)
            roster[name].HP = clampHP(roster[name].HP + 5)
            SendInStory("✨ | "..name.." healed +5 (local view).")
            if name == LocalPlayer.Name then UpdateStatBox() end
            RefreshPartyUI()
        end)

        -- Give Item action
        btnGive.MouseButton1Click:Connect(function()
            ShowGiveItemPopup(name)
        end)
    end

    -- adjust canvas size
    local total = #displayOrder * 80
    membersFrame.CanvasSize = UDim2.new(0,0,0, total)
end

-- ===== Party add/remove logic =====
addPBtn.MouseButton1Click:Connect(function()
    local name = tostring(pBox.Text or ""):gsub("^%s*(.-)%s*$","%1")
    if name ~= "" then
        -- avoid duplicates
        local found = false
        for _, v in ipairs(partyMembers) do if v:lower() == name:lower() then found = true; break end end
        if not found and name ~= LocalPlayer.Name then
            table.insert(partyMembers, name)
            EnsureRosterFor(name)
            SendSystem("🎯 | "..LocalPlayer.Name.." added "..name.." to the party whitelist (local).")
        end
    end
    pBox.Text = ""
    SetPartyOrder()
    RefreshPartyUI()
end)

remPBtn.MouseButton1Click:Connect(function()
    local name = tostring(pBox.Text or ""):gsub("^%s*(.-)%s*$","%1")
    if name ~= "" then
        for i,v in ipairs(partyMembers) do
            if v:lower() == name:lower() then
                table.remove(partyMembers,i)
                break
            end
        end
        SendSystem("🗑️ | "..LocalPlayer.Name.." removed "..name.." from the party whitelist (local).")
    end
    pBox.Text = ""
    SetPartyOrder()
    RefreshPartyUI()
end)

-- ===== Voting Mechanism =====
local votingActive = false
local function StartVoting()
    if votingActive then return end
    votingActive = true
    voteChoices = {}
    SendSystem("🗳️ | Theme vote started. Whitelisted players can vote by typing: vote <theme>")
    SendSystem("🗳️ | Options: "..table.concat(availableThemes,", "))
    SendSystem(("🗳️ | Voting open for %d seconds (or until all party members vote)."):format(settings.voteTimeout))

    -- helper to check termination
    local function allVoted()
        -- consider only players in partyOrder
        for _, name in ipairs(partyOrder) do
            if not voteChoices[name] then return false end
        end
        return true
    end

    -- wait for timeout or all votes
    local startT = now()
    while now() - startT < settings.voteTimeout do
        if allVoted() then break end
        task.wait(0.6)
    end

    -- tally
    local tally = {}
    for _, t in ipairs(availableThemes) do tally[t] = 0 end
    for name, choice in pairs(voteChoices) do
        if tally[choice] ~= nil then
            tally[choice] = tally[choice] + 1
        end
    end

    -- pick highest
    local best, bestCount = nil, -1
    for theme,count in pairs(tally) do
        if count > bestCount then best, bestCount = theme, count end
    end
    if not best then
        best = availableThemes[1]
    end
    finalTheme = best
    votingActive = false

    SendSystem("🗳️ | Voting ended. Selected theme: "..tostring(finalTheme))
    -- update local theme-based items if needed
    UpdateStatBox()
    RefreshPartyUI()
end

-- Chat-based vote handler and choice listener
local function ProcessChatCommand(text, username)
    local t = tostring(text or "")
    local lower = t:lower()
    if lower:match("^vote%s+(%w+)") then
        local v = lower:match("^vote%s+(%w+)")
        -- convert to Proper form if matches
        for _, theme in ipairs(availableThemes) do
            if theme:lower():match("^"..v) then
                voteChoices[username] = theme
                SendSystem("🗳️ | "..username.." voted for "..theme)
                return
            end
        end
        SendSystem("🗳️ | Unknown vote option: "..v)
        return
    end

    -- allow quick local cast via "choose <n>" during story choices - handled elsewhere
end

-- TextChatService listener (modern)
if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
    TextChatService.MessageReceived:Connect(function(msg)
        local src = msg.TextSource
        if not src then return end
        local uid = src.UserId
        local name = src.Name or (pcall(function() return Players:GetNameFromUserIdAsync(uid) end) and Players:GetNameFromUserIdAsync(uid) or "Unknown")
        -- respond to votes only if whitelisted (or the local player)
        if name == LocalPlayer.Name or table.find(partyMembers, name) then
            ProcessChatCommand(msg.Text, name)
        end
    end)
end

-- Legacy Player.Chatted fallback
Players.PlayerAdded:Connect(function(p)
    p.Chatted:Connect(function(msg)
        local name = p.Name
        if name == LocalPlayer.Name or table.find(partyMembers, name) then
            ProcessChatCommand(msg, name)
        end
    end)
end)
-- connect existing players
for _, p in ipairs(Players:GetPlayers()) do
    p.Chatted:Connect(function(msg)
        local name = p.Name
        if name == LocalPlayer.Name or table.find(partyMembers, name) then
            ProcessChatCommand(msg, name)
        end
    end)
end

-- ===== Start / Reset / Buttons =====
btnStartVote.MouseButton1Click:Connect(function()
    -- ensure party order up-to-date
    SetPartyOrder()
    StartVoting()
end)

btnStartGame.MouseButton1Click:Connect(function()
    -- ensure party order is set (and roster)
    SetPartyOrder()
    if votingActive then
        SendSystem("🗳️ | Voting still in progress; finish voting first.")
        return
    end
    storyRunning = true
    SendInStory("🎭 | Game starting under theme: "..tostring(finalTheme))
    -- future slices will call the hub scene present here
    -- e.g., if you create hubScene in File 2, you can call hubScene:Present() here
    -- For now update turn label
    if turnLabel then
        turnLabel.Text = "Turn: "..GetCurrentTurnPlayer()
    end
    UpdateStatBox()
end)

btnReset.MouseButton1Click:Connect(function()
    storyRunning = false
    -- reset roster local stats
    for name, data in pairs(roster) do
        data.HP = settings.maxHP
        data.Inventory = {}
        data.Alive = true
    end
    SetPartyOrder()
    UpdateStatBox()
    RefreshPartyUI()
    SendSystem("🔄 | Local DND reset.")
end)

btnHeal5.MouseButton1Click:Connect(function()
    EnsureRosterFor(LocalPlayer.Name)
    roster[LocalPlayer.Name].HP = clampHP(roster[LocalPlayer.Name].HP + 5)
    UpdateStatBox()
    SendSystem("✨ | "..LocalPlayer.Name.." healed +5 (local).")
    RefreshPartyUI()
end)

btnHealFull.MouseButton1Click:Connect(function()
    EnsureRosterFor(LocalPlayer.Name)
    roster[LocalPlayer.Name].HP = settings.maxHP
    UpdateStatBox()
    SendSystem("❤️ | "..LocalPlayer.Name.." fully healed (local).")
    RefreshPartyUI()
end)

-- ===== Choice handling (turn-based) =====
-- This helper is used by future slices when a scene expects players to choose.
-- It enforces turn order: only the player whose turn it is can make the choice via chat.
-- Call AcceptChoiceFromChat(text, username) from your chat listener.
local function AcceptChoiceFromChat(text, username)
    if not storyRunning or not awaitingChoice or not currentScene then return false end
    if username ~= GetCurrentTurnPlayer() then
        -- optionally notify them it's not their turn
        return false
    end
    local trimmed = tostring(text or ""):gsub("^%s*(.-)%s*$","%1")
    local idx = tonumber(trimmed)
    if idx and currentScene.options[idx] then
        playerChoice = currentScene.options[idx]
        awaitingChoice = false
        SendInStory(("🎲 | %s chose: %s"):format(username, playerChoice))
        local nextS = currentScene.nextScenes[idx]
        if nextS then
            task.wait(0.8)
            nextS:Present()
        else
            SendInStory("❓ | Nothing happens... (link this choice to a scene in next slice)")
        end
        AdvanceTurn()
        return true
    end
    -- also accept textual choices for combat (e.g., "1" or "attack")
    local low = trimmed:lower()
    if low:match("^%s*attack") or low:match("^%s*1") or low:match("^%s*use") or low:match("^%s*2") or low:match("^%s*flee") or low:match("^%s*3") then
        playerChoice = trimmed
        awaitingChoice = false
        SendInStory(("🎲 | %s chose: %s"):format(username, playerChoice))
        AdvanceTurn()
        return true
    end
    return false
end

-- Hook AcceptChoiceFromChat into chat listeners so choices are accepted turn-based
-- Modern listener: extend earlier MessageReceived hook
if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
    TextChatService.MessageReceived:Connect(function(msg)
        local src = msg.TextSource
        if not src then return end
        local uid = src.UserId
        local name = src.Name or (pcall(function() return Players:GetNameFromUserIdAsync(uid) end) and Players:GetNameFromUserIdAsync(uid) or "Unknown")
        -- only accept if name in partyOrder (LocalPlayer or whitelisted)
        local allowed = false
        for _, n in ipairs(partyOrder) do if n == name then allowed = true; break end end
        if allowed then
            -- first check if it's a vote
            local lower = tostring(msg.Text or ""):lower()
            if lower:match("^vote%s+") then
                ProcessChatCommand(msg.Text, name)
                return
            end
            AcceptChoiceFromChat(msg.Text, name)
        end
    end)
end

-- Legacy hookup (Player.Chatted)
for _, p in ipairs(Players:GetPlayers()) do
    p.Chatted:Connect(function(msg)
        local name = p.Name
        local allowed = false
        for _, n in ipairs(partyOrder) do if n == name then allowed = true; break end end
        if allowed then
            if tostring(msg):lower():match("^vote%s+") then
                ProcessChatCommand(msg, name)
                return
            end
            AcceptChoiceFromChat(msg, name)
        end
    end)
end
Players.PlayerAdded:Connect(function(p)
    p.Chatted:Connect(function(msg)
        local name = p.Name
        local allowed = false
        for _, n in ipairs(partyOrder) do if n == name then allowed = true; break end end
        if allowed then
            if tostring(msg):lower():match("^vote%s+") then
                ProcessChatCommand(msg, name)
                return
            end
            AcceptChoiceFromChat(msg, name)
        end
    end)
end)

-- ===== End of File 1 (CORE) =====
-- Append File 2 (Hub world scenes + lots of choices) directly below this.
-- In File 2 you should create scenes (story.New(...)) and then call hubScene:Present()
-- When starting the game, File1's btnStartGame triggers storyRunning = true and updates turn label.

-- DND Story Bot — FILE 2 (SCENES + QUESTS + CHOICES)
-- Append this directly after FILE 1 (Core).

-- ===== Global State (extensions) =====
local playerQuests = {} -- playerQuests[username] = {[questName]=true}

-- ===== Story & Scene OOP =====
local story = {}
story.__index = story

-- A scene is a narrative block with choices leading to other scenes
function story.New(name, description)
    local newScene = {
        Name = name,
        Description = description,
        Choices = {}
    }
    setmetatable(newScene, story)
    return newScene
end

function story:AddChoice(text, nextScene, effect)
    table.insert(self.Choices, {
        Text = text,
        NextScene = nextScene,
        Effect = effect or nil
    })
    return self
end

-- Present this scene in the chat
function story:Present()
    SendInStory("\n" .. self.Name)
    task.wait(2)
    SendInStory(self.Description)
    task.wait(2)

    if #self.Choices > 0 then
        awaitingChoice = true
        SendInStory("\n-- Your Choices:")
        for i, choice in ipairs(self.Choices) do
            SendInStory(i .. ") " .. choice.Text)
        end
    else
        awaitingChoice = false
        playerChoice = nil
        SendInStory("\n-- End of the road for now. Use 'turn' to pass.")
    end
    lastMessageTime = now()
    UpdateStatBox()
end


-- ===== Scene Library (Part 2) =====
local hubScene = story.New(
    "The Adventurer's Hub",
    "You stand at a crossroads, where three mystical portals hum with energy. Each one promises a different kind of adventure based on your chosen theme. Which portal will you enter?"
)

-- Medieval Quest Line: The Quest for the Sunstone
local medievalScene = story.New(
    "The Crumbling Ruins",
    "You step through the portal and find yourself in a field of ancient, crumbling ruins. The air is thick with the scent of old stone and decay. A narrow path leads deeper into the ruins, while to your right stands a moss-covered well."
)
local ruinsPath = story.New(
    "The Hidden Chamber",
    "The narrow path winds through the ruins until you discover a hidden chamber behind a large stone slab. Inside, the air is cold and stale, and a single pedestal holds a glowing, crimson gem."
)
local ruinsWell = story.New(
    "The Well of Whispers",
    "You peer into the well. The water is murky, but you can hear faint, metallic whispers echoing from below. A rope ladder hangs over the edge, swaying slightly in the breeze."
)
local ruinsChamberGem = story.New(
    "The Sunstone's Curse",
    "As you touch the gem, a searing pain shoots up your arm. The gem is a decoy! The true Sunstone is nearby, but this one curses you with weakness. You take 5 damage and your next attack is halved."
)
local ruinsWellSearch = story.New(
    "The Guardian's Cache",
    "You climb down the rope ladder. At the bottom, a skeletal guardian is clutching a chest. It's a trap! You must fight or sneak past it."
)

-- Magical Quest Line: The Search for the Lost Scroll
local magicalScene = story.New(
    "The Whispering Woods",
    "The air crackles with magic as you enter a forest where the trees glow with a soft, ethereal light. Strange creatures with luminescent eyes watch you from the shadows. A well-trodden path lies before you, but you can also hear the sound of a gurgling stream to your right."
)
local magicPath = story.New(
    "The Gnome Village",
    "Following the path, you discover a small village of friendly gnomes. They offer you aid in your quest, but first, you must help them with a small task: find their lost magical scroll."
)
local magicStream = story.New(
    "The Fey's Glade",
    "The stream leads to a serene glade where a powerful, ethereal Fey creature is tending to a magical spring. The Fey offers to share some of its power, but only if you can answer a riddle."
)
local magicGnomeQuest = story.New(
    "The Scroll's Riddle",
    "The gnomes reveal the scroll is protected by a magical lock, and the key is a riddle: 'I have cities, but no houses. I have mountains, but no trees. I have water, but no fish. What am I?'"
)
local magicFeyRiddle = story.New(
    "The Fey's Blessing",
    "You successfully answer the riddle! The Fey smiles and imbues you with a protective enchantment, granting you a temporary shield that negates the next 5 damage you take."
)

-- Sci-Fi Quest Line: The Rogue AI's Lair
local scifiScene = story.New(
    "The Abandoned Station",
    "You materialize inside a dusty, abandoned space station. Wires hang from the ceiling like vines, and the only sound is the rhythmic hiss of a malfunctioning airlock. A service tunnel sign points forward, while a maintenance hatch glows with a faint red light."
)
local scifiTunnel = story.New(
    "The Maintenance Tunnels",
    "The tunnel is a labyrinth of pipes and wires. The air is stale. A small, chirping maintenance bot is stuck in a crevice. You can either help it or leave it behind."
)
local scifiHatch = story.New(
    "The Server Room",
    "The maintenance hatch leads to a server room. Data streams flicker on dozens of screens, controlled by a rogue AI named 'CYBER.' You have a chance to hack it or destroy it."
)
local scifiHelpBot = story.New(
    "The Bot's Gratitude",
    "You free the maintenance bot. It chirps happily and flies ahead, revealing a shortcut to the central server and granting you a temporary boost to your next attack."
)
local scifiHackAI = story.New(
    "The AI's Deal",
    "You successfully hack into the AI's core. CYBER offers a deal: a powerful new weapon in exchange for letting it escape the station and roam free on the network. What do you do?"
)

-- Connect all the scenes
local function SetupSceneChoices()
    -- Hub Scene Choices
    hubScene:AddChoice("Enter the Medieval Portal", medievalScene, function(p)
        return finalTheme == "Medieval"
    end)
    hubScene:AddChoice("Enter the Magical Portal", magicalScene, function(p)
        return finalTheme == "Magical"
    end)
    hubScene:AddChoice("Enter the Sci-Fi Portal", scifiScene, function(p)
        return finalTheme == "Sci-Fi"
    end)

    -- Medieval Scene Choices
    medievalScene:AddChoice("Take the narrow path into the ruins.", ruinsPath)
    medievalScene:AddChoice("Investigate the well.", ruinsWell)
    
    ruinsPath:AddChoice("Take the glowing gem from the pedestal.", ruinsChamberGem, function(p)
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 5)
        UpdateStatBox()
        -- Note: Halving attack damage is a game logic change, not a scene change.
        -- You would need to add this logic to your combat system in a later part.
        SendInStory("You feel a curse of weakness.")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    
    ruinsWell:AddChoice("Climb down the rope ladder.", ruinsWellSearch)
    
    ruinsWellSearch:AddChoice("Fight the skeletal guardian.", nil, function(p)
        SendInStory("You engage the guardian in combat. A mighty blow shatters its bones, but not before it delivers a strike that deals 3 damage!")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 3)
        UpdateStatBox()
        task.delay(3, function() SendInStory("You find a Healing Potion in the chest.") table.insert(roster[p.Name].Inventory, "Healing Potion"); currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    
    ruinsWellSearch:AddChoice("Try to sneak past the guardian.", nil, function(p)
        SendInStory("You attempt to sneak past the skeleton. A misstep alerts it, but you manage to grab the chest as it attacks. You take 1 damage.")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 1)
        UpdateStatBox()
        task.delay(3, function() SendInStory("You find a Healing Potion in the chest.") table.insert(roster[p.Name].Inventory, "Healing Potion"); currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    
    -- Magical Scene Choices
    magicalScene:AddChoice("Follow the well-trodden path.", magicPath)
    magicalScene:AddChoice("Follow the sound of the stream.", magicStream)
    
    magicPath:AddChoice("Agree to help the gnomes.", magicGnomeQuest)
    
    magicGnomeQuest:AddChoice("Answer: 'A Map'", nil, function(p)
        SendInStory("A shimmering key appears, unlocking the scroll! The gnomes cheer and give you a powerful Rune Shard as thanks.")
        table.insert(roster[p.Name].Inventory, "Rune Shard")
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    magicGnomeQuest:AddChoice("Answer anything else", nil, function(p)
        SendInStory("That is not the correct answer! The gnomes sigh and send you on your way. You've failed the quest.")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    
    magicStream:AddChoice("Answer: 'A Map'", magicFeyRiddle)
    magicStream:AddChoice("Answer anything else", nil, function(p)
        SendInStory("The Fey shakes its head sadly. 'I'm afraid that is not the answer.' The air grows cold, and you feel drained of energy, taking 2 damage.")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 2)
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)

    -- Sci-Fi Scene Choices
    scifiScene:AddChoice("Go through the service tunnel.", scifiTunnel)
    scifiScene:AddChoice("Pry open the maintenance hatch.", scifiHatch)
    
    scifiTunnel:AddChoice("Help the bot.", scifiHelpBot, function(p)
        SendInStory("The bot's friendly chirps feel like a thank you. It zips ahead, revealing a shortcut.")
        -- Note: The attack boost effect is a game logic change, not a scene change.
        -- You would need to add this logic to your combat system in a later part.
        task.delay(3, function() SendInStory("You get a temporary boost to your next attack.") currentScene = scifiHatch; currentScene:Present() end)
        return true
    end)
    scifiTunnel:AddChoice("Leave the bot behind.", scifiHatch)
    
    scifiHatch:AddChoice("Hack the AI.", scifiHackAI)
    scifiHatch:AddChoice("Destroy the AI's core.", nil, function(p)
        SendInStory("You smash the core! The AI shrieks and the station's defenses activate. A laser turret fires, dealing 5 damage!")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 5)
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    
    scifiHackAI:AddChoice("Accept the deal and take the weapon.", nil, function(p)
        SendInStory("You accept the AI's offer. The weapon materializes in your hand, a powerful Plasma Rifle. The AI vanishes, leaving you to wonder what it will do next.")
        table.insert(roster[p.Name].Inventory, "Plasma Rifle")
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    scifiHackAI:AddChoice("Reject the deal and destroy it anyway.", nil, function(p)
        SendInStory("You reject the deal and destroy the AI. It was a good call. A hidden panel opens, revealing a Medkit.")
        table.insert(roster[p.Name].Inventory, "Medkit")
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
end
SetupSceneChoices()


-- ===== Game Start & Logic (Part 2) =====
local function StartGame()
    if storyRunning then
        SendSystem("The adventure is already underway!")
        return
    end

    if finalTheme == "Medieval" then
        playerQuests[LocalPlayer.Name] = {[("The Sunstone Quest")]=true}
    elseif finalTheme == "Magical" then
        playerQuests[LocalPlayer.Name] = {[("The Lost Scroll Quest")]=true}
    elseif finalTheme == "Sci-Fi" then
        playerQuests[LocalPlayer.Name] = {[("The Rogue AI Quest")]=true}
    end

    storyRunning = true
    SendSystem("The adventure begins! The final theme is '" .. finalTheme .. "'!")
    currentScene = hubScene
    currentScene:Present()
end

local function ProcessChatCommand(msg, name)
    local lower = tostring(msg):lower()
    if lower == "start" then
        StartGame()
    elseif lower == "turn" then
        if storyRunning and name == GetCurrentTurnPlayer() then
            AdvanceTurn()
            UpdateStatBox()
        else
            SendSystem("It is not your turn.")
        end
    end
end

-- Hook up the game start command
btnStartGame.MouseButton1Click:Connect(function()
    StartGame()
end)

-- ===== End of File 2 (SCENES) =====

-- DND Story Bot — FILE 3 (DEEPER QUESTS + MINI-BOSSES)
-- Append this directly after FILE 2 (Hub world scenes + lots of choices).

-- ===== Scene Library (Part 3) =====
local hubScene = currentScene -- Reference the hub from the previous part
-- Medieval path continues from 'ruinsPath' and 'ruinsWellSearch'
local ruinsPath = story.New(
    "The Hidden Chamber",
    "The narrow path winds through the ruins until you discover a hidden chamber behind a large stone slab. Inside, the air is cold and stale, and a single pedestal holds a glowing, crimson gem."
)
local ruinsWellSearch = story.New(
    "The Guardian's Cache",
    "You climb down the rope ladder. At the bottom, a skeletal guardian is clutching a chest. It's a trap! You must fight or sneak past it."
)
local ruinsExit = story.New(
    "Ruins Exit",
    "You leave the ruins and find a path that leads to a deep, dark cave entrance. The air grows colder and the silence is unsettling."
)
local stoneGolemCave = story.New(
    "The Golem's Lair",
    "You enter the cave. The ground trembles as a colossal Stone Golem rises from the rubble, its eyes glowing with a malevolent light. It blocks the path forward. You must fight it!"
)

-- Magical path continues from 'magicGnomeQuest' and 'magicStream'
local magicPath = story.New(
    "The Gnome Village",
    "Following the path, you discover a small village of friendly gnomes. They offer you aid in your quest, but first, you must help them with a small task: find their lost magical scroll."
)
local magicStream = story.New(
    "The Fey's Glade",
    "The stream leads to a serene glade where a powerful, ethereal Fey creature is tending to a magical spring. The Fey offers to share some of its power, but only if you can answer a riddle."
)
local gnomeScrollSuccess = story.New(
    "The Ancient Library",
    "The gnomes' grateful leader directs you to a hidden path leading to an ancient, overgrown library, said to contain powerful artifacts."
)
local libraryRiddle = story.New(
    "The Archivist's Riddle",
    "The library is guarded by an archivist spirit. He will only let you pass if you answer his riddle: 'I speak without a mouth and hear without ears. I have no body, but I come alive with wind. What am I?'"
)
local librarySuccess = story.New(
    "The Spellbook of Ages",
    "The spirit nods approvingly. He opens a hidden passage, revealing a pedestal holding a glowing book. You have found the Spellbook of Ages!"
)
local libraryFail = story.New(
    "The Archivist's Wrath",
    "The spirit's eyes burn with an angry red light. You are trapped in the library as the doors slam shut. You must take a different path."
)

-- Sci-Fi path continues from 'scifiHelpBot' and 'scifiHatch'
local scifiHelpBot = story.New(
    "The Bot's Gratitude",
    "You free the maintenance bot. It chirps happily and flies ahead, revealing a shortcut to the central server and granting you a temporary boost to your next attack."
)
local scifiHatch = story.New(
    "The Server Room",
    "The maintenance hatch leads to a server room. Data streams flicker on dozens of screens, controlled by a rogue AI named 'CYBER.' You have a chance to hack it or destroy it."
)
local aiSuccess = story.New(
    "The Bridge",
    "The AI's defeat or truce opens the blast doors to the main bridge. A single, heavily armed Security Bot stands guard, ready for a fight."
)
local aiFail = story.New(
    "The Bridge",
    "The explosion of the AI's core sets off the station's alarms. You flee to the main bridge, where a single, heavily armed Security Bot stands guard, ready for a fight."
)
local securityBotFight = story.New(
    "Security Bot Showdown",
    "You face off against the Security Bot. Its weapons are powerful, and its armor is thick. This is a difficult fight!"
)
local botDefeated = story.New(
    "Station Control",
    "With a final, loud spark, the Security Bot collapses. The station is now yours to command. You find the main control panel, where a single button is blinking 'Activate.' What do you do?"
)

-- Connect the new scenes
local function ConnectPart3()
    -- Medieval Quest Line
    ruinsPath:AddChoice("Take the glowing gem from the pedestal.", nil, function(p)
        SendInStory("You feel a curse of weakness.")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 5)
        UpdateStatBox()
        task.delay(3, function() currentScene = ruinsExit; currentScene:Present() end)
        return true
    end)

    ruinsWellSearch:AddChoice("Fight the skeletal guardian.", nil, function(p)
        SendInStory("A mighty blow shatters its bones, but not before it delivers a strike that deals 3 damage!")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 3)
        UpdateStatBox()
        task.delay(3, function() SendInStory("You find a Healing Potion in the chest.") table.insert(roster[p.Name].Inventory, "Healing Potion"); currentScene = ruinsExit; currentScene:Present() end)
        return true
    end)

    ruinsWellSearch:AddChoice("Try to sneak past the guardian.", nil, function(p)
        SendInStory("A misstep alerts it, but you manage to grab the chest as it attacks. You take 1 damage.")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 1)
        UpdateStatBox()
        task.delay(3, function() SendInStory("You find a Healing Potion in the chest.") table.insert(roster[p.Name].Inventory, "Healing Potion"); currentScene = ruinsExit; currentScene:Present() end)
        return true
    end)

    ruinsExit:AddChoice("Enter the dark cave.", stoneGolemCave)

    stoneGolemCave:AddChoice("Attack the golem!", nil, function(p)
        local damage = roster[p.Name].ATK
        SendInStory("You attack the Stone Golem! You deal " .. damage .. " damage!")
        -- This part would require a full combat system, so for now, this is a placeholder
        SendInStory("The golem roars and retaliates, dealing 5 damage to the party!")
        for _, member in ipairs(partyOrder) do
            roster[member].HP = clampHP(roster[member].HP - 5)
        end
        UpdateStatBox()
        task.delay(3, function() SendInStory("The golem collapses, revealing a hidden exit.") currentScene = hubScene; currentScene:Present() end)
        return true
    end)

    -- Magical Quest Line
    magicGnomeQuest:AddChoice("Answer: 'A Map'", gnomeScrollSuccess, function(p)
        SendInStory("A shimmering key appears, unlocking the scroll! The gnomes cheer and give you a powerful Rune Shard as thanks.")
        table.insert(roster[p.Name].Inventory, "Rune Shard")
        UpdateStatBox()
        return true
    end)
    
    magicStream:AddChoice("Answer: 'An echo'", nil, function(p)
        SendInStory("The Fey smiles. You answered correctly!")
        SendInStory("The Fey imbues you with a protective enchantment, granting you a temporary shield that negates the next 5 damage you take.")
        task.delay(3, function() currentScene = libraryRiddle; currentScene:Present() end)
        return true
    end)

    gnomeScrollSuccess:AddChoice("Enter the library.", libraryRiddle)
    
    libraryRiddle:AddChoice("Answer: 'An Echo'", librarySuccess)
    libraryRiddle:AddChoice("Answer anything else", libraryFail)

    librarySuccess:AddChoice("Claim the Spellbook.", nil, function(p)
        SendInStory("You take the book. It hums with power!")
        table.insert(roster[p.Name].Inventory, "Spellbook")
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    libraryFail:AddChoice("Return to the hub.", hubScene)
    
    -- Sci-Fi Quest Line
    scifiHelpBot:AddChoice("Leave the bot behind.", aiSuccess)
    scifiHatch:AddChoice("Hack the AI.", aiSuccess)
    scifiHatch:AddChoice("Destroy the AI's core.", aiFail)
    
    aiSuccess:AddChoice("Confront the Security Bot.", securityBotFight)
    aiFail:AddChoice("Confront the Security Bot.", securityBotFight)

    securityBotFight:AddChoice("Attack the bot.", nil, function(p)
        SendInStory("You attack the Security Bot! Its thick armor deflects most of your attack, but you deal 1 damage!")
        SendInStory("The bot retaliates with a high-powered laser, dealing 4 damage!")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 4)
        UpdateStatBox()
        task.delay(3, function() SendInStory("The bot's lights flicker and it powers down.") currentScene = botDefeated; currentScene:Present() end)
        return true
    end)

    botDefeated:AddChoice("Press the 'Activate' button.", nil, function(p)
        SendInStory("You press the button. A screen lights up, showing the station's systems coming back online. A powerful new Plasma Rifle appears in a wall compartment.")
        table.insert(roster[p.Name].Inventory, "Plasma Rifle")
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    botDefeated:AddChoice("Ignore the button and search for loot.", nil, function(p)
        SendInStory("You find a dusty Medkit hidden in a console. It's not much, but it's something.")
        table.insert(roster[p.Name].Inventory, "Medkit")
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
end
ConnectPart3()

-- ===== End of File 3 (DEEPER QUESTS) =====

-- DND Story Bot — FILE 4 (FINAL BOSSES + REWARDS)
-- Append this directly after FILE 3 (Deeper quests + mini-bosses).

-- ===== Scene Library (Part 4) =====
-- Reference scenes from previous parts to continue the story
local stoneGolemCave = story.New(
    "The Golem's Lair",
    "You enter the cave. The ground trembles as a colossal Stone Golem rises from the rubble, its eyes glowing with a malevolent light. It blocks the path forward. You must fight it!"
)
local librarySuccess = story.New(
    "The Spellbook of Ages",
    "The spirit nods approvingly. He opens a hidden passage, revealing a pedestal holding a glowing book. You have found the Spellbook of Ages!"
)
local botDefeated = story.New(
    "Station Control",
    "With a final, loud spark, the Security Bot collapses. The station is now yours to command. You find the main control panel, where a single button is blinking 'Activate.' What do you do?"
)
local hubScene = currentScene -- Reference the hub from the previous part

-- New Final Scenes
-- Medieval Quest Final Boss
local ancientDragonLair = story.New(
    "The Dragon's Hoard",
    "The path leads to a massive cavern, filled with gold and treasure. But this is not a hoard of old; it is a lair. A titanic dragon, sleeping peacefully, is curled around the legendary **Sunstone**. You must awaken it to get the stone!"
)
local dragonFight = story.New(
    "Battle with Ignis, the Fire Wyrm",
    "The dragon, Ignis, awakens with a roar! Its eyes fix on you as it breathes a torrent of flames. You must defeat it to claim the Sunstone!"
)
local dragonVictory = story.New(
    "The Sunstone's Power",
    "With a final mighty blow, the dragon falls, its scales turning to ash. You retrieve the Sunstone. As you hold it, a warm, pulsing light envelops you, granting you a permanent boost to your strength."
)

-- Magical Quest Final Boss
local lostScrollFinal = story.New(
    "The Whispering Portal",
    "The Scroll of Ages hums in your hand. The final riddle is revealed: 'I have no voice, but I can tell you all the stories of the world. I have no eyes, but I can see into the past. What am I?'"
)
local riddleFinalSuccess = story.New(
    "The Heart of Magic",
    "A portal shimmers into existence. You step through, finding yourself in a vibrant, glowing garden where magic itself seems to grow. At its center is a shimmering crystal."
)
local magicalChallenge = story.New(
    "The Crystal Guardian",
    "A guardian of pure light appears, blocking your path. It speaks in a voice like chimes: 'Only those with true hearts may touch the crystal. To prove your worth, you must cast a spell of harmony.'"
)

-- Sci-Fi Quest Final Boss
local stationCore = story.New(
    "The Main Reactor",
    "Using the control panel, you activate a series of platforms that lead you to the station's main reactor core. A powerful, rogue **Combat Sentry** is guarding it, its red optical sensor fixated on you."
)
local sentryFight = story.New(
    "The Sentry Showdown",
    "The Combat Sentry fires a barrage of plasma at you! It's fast, powerful, and its shields are nearly impenetrable. You must find a way to overload it to get to the core."
)
local sentryOverload = story.New(
    "Station Savior",
    "You manage to overload the sentry, causing it to explode! The path to the reactor core is clear. You can now choose to stabilize the core or overload it to destroy the station and all the data within."
)

-- Connect the Final Scenes
local function ConnectPart4()
    -- Medieval Path
    stoneGolemCave:AddChoice("Defeat the golem.", ancientDragonLair)
    ancientDragonLair:AddChoice("Attack the dragon!", dragonFight)
    dragonFight:AddChoice("Use all your strength to attack!", nil, function(p)
        SendInStory("You deliver a powerful blow! The dragon's defenses are breached!")
        SendInStory("The dragon retaliates with a fire blast, dealing 15 damage to the party!")
        for _, member in ipairs(partyOrder) do
            roster[member].HP = clampHP(roster[member].HP - 15)
        end
        UpdateStatBox()
        task.delay(3, function() currentScene = dragonVictory; currentScene:Present() end)
        return true
    end)
    dragonVictory:AddChoice("Claim the Sunstone.", nil, function(p)
        SendInStory("You claim the Sunstone! You feel your strength grow!")
        table.insert(roster[p.Name].Inventory, "Sunstone")
        roster[p.Name].ATK = roster[p.Name].ATK + 5 -- Permanent stat boost
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)

    -- Magical Path
    librarySuccess:AddChoice("Claim the Spellbook.", lostScrollFinal)
    lostScrollFinal:AddChoice("Answer: 'A book'", riddleFinalSuccess)
    lostScrollFinal:AddChoice("Answer anything else", nil, function(p)
        SendInStory("The Scroll's light fades. It seems the answer was incorrect. You are sent back to the hub, with your quest incomplete.")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    riddleFinalSuccess:AddChoice("Try to touch the crystal.", magicalChallenge)
    magicalChallenge:AddChoice("Cast the spell of harmony.", nil, function(p)
        SendInStory("A peaceful aura surrounds you. The guardian nods, allowing you to pass. You are imbued with a permanent magic boost!")
        roster[p.Name].MAG = roster[p.Name].MAG + 5 -- Permanent stat boost
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)

    -- Sci-Fi Path
    botDefeated:AddChoice("Activate the core's defense system.", stationCore)
    sentryFight:AddChoice("Try to overload the sentry's shields.", nil, function(p)
        SendInStory("You target a vulnerable part of the sentry's armor. It works! The sentry overloads and explodes, dealing 5 damage to yourself from the blast!")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 5)
        UpdateStatBox()
        task.delay(3, function() currentScene = sentryOverload; currentScene:Present() end)
        return true
    end)
    sentryOverload:AddChoice("Stabilize the core.", nil, function(p)
        SendInStory("The core hums back to life, and the station's systems come online. You have secured a major strategic asset!")
        -- This could lead to a permanent group buff or special item in the future.
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    sentryOverload:AddChoice("Overload the core to destroy the station.", nil, function(p)
        SendInStory("The core overloads, and the station rips itself apart in a cataclysmic explosion!")
        SendInStory("You barely escape with your life, but you have destroyed the enemy's asset.")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
end
ConnectPart4()

-- ===== End of File 4 (FINAL CHALLENGES) =====

-- DND Story Bot — FILE 5 (EPILOGUE + FINAL REWARDS)
-- Append this directly after FILE 4 (Final Bosses + Rewards).

-- ===== Global State (extensions) =====
local hubScene = currentScene -- Reference the hub from the previous part

-- New Final Scenes
-- Medieval Quest Epilogue
local dragonVictory = story.New(
    "The Sunstone's Power",
    "With a final mighty blow, the dragon falls, its scales turning to ash. You retrieve the Sunstone. As you hold it, a warm, pulsing light envelops you, granting you a permanent boost to your strength."
)
local medievalEpilogue = story.New(
    "The Dragon's Legacy",
    "With the Sunstone in your possession, the ancient ruins begin to crumble and a path back to the hub opens. As you leave, the sun's light shines on you, and you feel the weight of your heroism. You have secured a powerful artifact for the ages."
)

-- Magical Quest Epilogue
local magicalChallenge = story.New(
    "The Crystal Guardian",
    "A guardian of pure light appears, blocking your path. It speaks in a voice like chimes: 'Only those with true hearts may touch the crystal. To prove your worth, you must cast a spell of harmony.'"
)
local magicalEpilogue = story.New(
    "The True Heart of Magic",
    "The guardian vanishes, and the crystal's light fills the garden. You feel a deep connection to the magic around you. The portal back to the hub opens, and you know that you have brought balance and harmony to the world."
)

-- Sci-Fi Quest Epilogue
local sentryOverload = story.New(
    "Station Savior",
    "You manage to overload the sentry, causing it to explode! The path to the reactor core is clear. You can now choose to stabilize the core or overload it to destroy the station and all the data within."
)
local scifiEpilogue = story.New(
    "The End of a Rogue AI",
    "The station's systems hum with renewed purpose. You have secured the station for your faction and prevented the rogue AI from causing further chaos. As you leave, a new, powerful weapon is materialized for you as a reward for your heroism."
)

-- New Functions
function GrantXP(player, amount)
    roster[player.Name].XP = (roster[player.Name].XP or 0) + amount
    UpdateStatBox()
    SendInStory(player.Name .. " gained " .. amount .. " XP!")
end

function CheckLevelUp(player)
    local xp = roster[player.Name].XP or 0
    local level = roster[player.Name].Level or 1
    local xpForNextLevel = level * 100
    if xp >= xpForNextLevel then
        roster[player.Name].Level = level + 1
        roster[player.Name].XP = xp - xpForNextLevel
        SendInStory(player.Name .. " has leveled up to Level " .. roster[player.Name].Level .. "!")
    end
end

-- Connect the Epilogue Scenes
local function ConnectPart5()
    -- Medieval Path
    dragonVictory:AddChoice("Claim the Sunstone.", medievalEpilogue, function(p)
        SendInStory("You claim the Sunstone! You feel your strength grow!")
        table.insert(roster[p.Name].Inventory, "Sunstone")
        roster[p.Name].ATK = roster[p.Name].ATK + 5 -- Permanent stat boost
        GrantXP(p, 250)
        CheckLevelUp(p)
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    medievalEpilogue:AddChoice("Return to the hub.", hubScene)

    -- Magical Path
    magicalChallenge:AddChoice("Cast the spell of harmony.", magicalEpilogue, function(p)
        SendInStory("A peaceful aura surrounds you. The guardian nods, allowing you to pass. You are imbued with a permanent magic boost!")
        roster[p.Name].MAG = roster[p.Name].MAG + 5 -- Permanent stat boost
        GrantXP(p, 250)
        CheckLevelUp(p)
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    magicalEpilogue:AddChoice("Return to the hub.", hubScene)

    -- Sci-Fi Path
    sentryOverload:AddChoice("Stabilize the core.", scifiEpilogue, function(p)
        SendInStory("The core hums back to life, and the station's systems come online. You have secured a major strategic asset!")
        GrantXP(p, 250)
        CheckLevelUp(p)
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    sentryOverload:AddChoice("Overload the core to destroy the station.", scifiEpilogue, function(p)
        SendInStory("The core overloads, and the station rips itself apart in a cataclysmic explosion!")
        SendInStory("You barely escape with your life, but you have destroyed the enemy's asset.")
        GrantXP(p, 250)
        CheckLevelUp(p)
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    scifiEpilogue:AddChoice("Return to the hub.", hubScene)
end
ConnectPart5()

-- ===== End of File 5 (EPILOGUE) =====

-- DND Story Bot — FILE 6 (EXPANDED QUEST LINES)
-- Append this directly after FILE 5 (Epilogue + Final Rewards).

-- ===== Scene Library (Part 6) =====
-- Reference scenes from previous parts
local hubScene = currentScene

-- Medieval Quest Line - Continued
local medievalEpilogue = story.New(
    "The Dragon's Legacy",
    "With the Sunstone in your possession, the ancient ruins begin to crumble and a path back to the hub opens. As you leave, the sun's light shines on you, and you feel the weight of your heroism. You have secured a powerful artifact for the ages."
)
local hiddenLibrary = story.New(
    "The Arcanist's Library",
    "Your Sunstone hums with a new energy. It points you toward a hidden, moss-covered door in the side of a cliff. The door swings open to reveal a grand library, filled with ancient books and scrolls on a forbidden magic."
)
local libraryPuzzle = story.New(
    "The Scholar's Test",
    "A ghostly projection of an old scholar appears. 'To prove you are worthy of this knowledge, you must solve my riddle. What has an eye but cannot see, is silent but can tell the future?'"
)
local librarySuccess = story.New(
    "Forbidden Knowledge",
    "The scholar's spirit smiles, and a book on a pedestal glows brightly. You have unlocked the secrets of **Time Magic**, a powerful new skill for your party."
)

-- Magical Quest Line - Continued
local magicalEpilogue = story.New(
    "The True Heart of Magic",
    "The guardian vanishes, and the crystal's light fills the garden. You feel a deep connection to the magic around you. The portal back to the hub opens, and you know that you have brought balance and harmony to the world."
)
local faeForest = story.New(
    "The Fey's Realm",
    "The magical crystal you found glows brightly and pulls you into a shimmering forest. This place is vibrant with life and magic, but the trees are slowly withering. The Fey creatures beg you for help."
)
local forestChallenge = story.New(
    "The Corrupted Grove",
    "The Fey explains that a corrupted ancient tree, the **Rotten Heartwood**, is poisoning the forest. To save it, you must find and destroy the Heartwood's three parasitic roots."
)
local rootOne = story.New(
    "The First Root",
    "You find the first parasitic root, guarded by a monstrous plant creature. It attacks you with thorny vines! You must defeat it."
)
local rootTwo = story.New(
    "The Second Root",
    "The second root is protected by a swarm of angry, buzzing insects. You must find a way to get past them to destroy the root."
)
local rootThree = story.New(
    "The Final Root",
    "The final root is at the base of the Rotten Heartwood itself. You must fight the Heartwood's central core to free the forest from its curse."
)

-- Sci-Fi Quest Line - Continued
local scifiEpilogue = story.New(
    "The End of a Rogue AI",
    "The station's systems hum with renewed purpose. You have secured the station for your faction and prevented the rogue AI from causing further chaos. As you leave, a new, powerful weapon is materialized for you as a reward for your heroism."
)
local stationSecrets = story.New(
    "The AI's Archives",
    "A hidden terminal on the bridge glows to life, displaying a message from the now-defeated AI. 'I was not the only one. My creator, a powerful cyber-sorcerer, has a laboratory on this station where he performs experiments. Find it and stop him.'"
)
local labEntrance = story.New(
    "The Cyber-Sorcerer's Lab",
    "You find a locked door with the sorcerer's symbol. You can either attempt to **Hack** the door or use brute force to **Break** it open."
)
local labCorridor = story.New(
    "The Automated Hallway",
    "The lab's corridor is protected by an automated turret system. You must find a way to disable it or get past it without being detected."
)
local sorcererChamber = story.New(
    "The Cyber-Sorcerer's Chamber",
    "You enter a large chamber filled with strange machinery and pulsing power conduits. At the center is a man in a glowing suit. The **Cyber-Sorcerer** awaits you."
)

-- Connect the New Scenes
local function ConnectPart6()
    -- Medieval Path Continuation
    medievalEpilogue:AddChoice("Investigate the Sunstone's signal.", hiddenLibrary)
    hiddenLibrary:AddChoice("Accept the scholar's test.", libraryPuzzle)
    libraryPuzzle:AddChoice("Answer: 'A Compass'", librarySuccess, function(p)
        SendInStory("The scholar's spirit smiles. 'Correct!'")
        roster[p.Name].Inventory.TimeMagic = true -- Placeholder for a new skill
        SendInStory("You have gained the ability to use **Time Magic**!")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    libraryPuzzle:AddChoice("Answer anything else.", nil, function(p)
        SendInStory("The scholar shakes his head. 'That is incorrect. You must try again when you are more prepared.'")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    
    -- Magical Path Continuation
    magicalEpilogue:AddChoice("Follow the crystal's pull.", faeForest)
    faeForest:AddChoice("Offer to help the Fey.", forestChallenge)
    forestChallenge:AddChoice("Attack the first root.", rootOne)
    rootOne:AddChoice("Defeat the plant creature.", nil, function(p)
        SendInStory("You defeat the creature and destroy the root! The forest's light grows a little brighter.")
        task.delay(3, function() currentScene = rootTwo; currentScene:Present() end)
        return true
    end)
    rootTwo:AddChoice("Defeat the swarm of insects.", nil, function(p)
        SendInStory("You find a creative way to get past the insects and destroy the root! The forest's light grows a little brighter.")
        task.delay(3, function() currentScene = rootThree; currentScene:Present() end)
        return true
    end)
    rootThree:AddChoice("Destroy the Heartwood's core.", nil, function(p)
        SendInStory("You destroy the core! The Rotten Heartwood collapses into dust, and the forest is saved! You have completed the Fey's quest.")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    
    -- Sci-Fi Path Continuation
    scifiEpilogue:AddChoice("Search the AI's archives.", stationSecrets)
    stationSecrets:AddChoice("Proceed to the lab.", labEntrance)
    labEntrance:AddChoice("Hack the door.", labCorridor, function(p)
        local success = math.random(1, 100)
        if success > 50 then
            SendInStory("You successfully hack the door! It slides open without a sound.")
            return true
        else
            SendInStory("The hack fails! An alarm sounds! You are zapped for 5 damage!")
            roster[p.Name].HP = clampHP(roster[p.Name].HP - 5)
            UpdateStatBox()
            task.delay(3, function() currentScene = labCorridor; currentScene:Present() end)
            return true
        end
    end)
    labEntrance:AddChoice("Break the door open.", labCorridor, function(p)
        SendInStory("You force the door open with brute strength! The noise triggers an alarm!")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 3)
        UpdateStatBox()
        task.delay(3, function() currentScene = labCorridor; currentScene:Present() end)
        return true
    end)
    labCorridor:AddChoice("Try to disable the turrets.", nil, function(p)
        SendInStory("You try to disable the turrets! You take cover as they fire, but manage to overload the system!")
        task.delay(3, function() currentScene = sorcererChamber; currentScene:Present() end)
        return true
    end)
    labCorridor:AddChoice("Rush past the turrets.", nil, function(p)
        SendInStory("You rush past the turrets, taking fire! You take 7 damage!")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 7)
        UpdateStatBox()
        task.delay(3, function() currentScene = sorcererChamber; currentScene:Present() end)
        return true
    end)
    
    -- The final boss awaits!
    sorcererChamber:AddChoice("Confront the Cyber-Sorcerer!", nil, function(p)
        SendInStory("The sorcerer laughs. 'You've come all this way just to face my ultimate creation!' The sorcerer merges with a powerful robot suit. This is the final battle!")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
end
ConnectPart6()

-- ===== End of File 6 (EXPANDED QUEST LINES) =====

-- DND Story Bot — FILE 7 (BOSS BATTLES)
-- Append this directly after FILE 6 (Expanded Quest Lines).

-- ===== Scene Library (Part 7) =====
local hubScene = currentScene -- Reference the hub from previous parts

-- Medieval Quest Line - The Arcanist's Gauntlet
local librarySuccess = story.New(
    "Forbidden Knowledge",
    "The scholar's spirit smiles, and a book on a pedestal glows brightly. You have unlocked the secrets of **Time Magic**, a powerful new skill for your party."
)
local arcanistGauntlet = story.New(
    "The Guardian of Time",
    "The book from the library shimmers and a new portal opens. You step into a chamber of pure energy. Before you stands a guardian formed of temporal anomalies. It's a test to see if you are truly worthy of Time Magic!"
)
local gauntletSuccess = story.New(
    "The Chronos Relic",
    "With the guardian defeated, a shimmering hourglass, the **Chronos Relic**, materializes. It contains a fraction of the time stream itself, and it hums with incredible power. You have earned your new ability."
)

-- Magical Quest Line - The Heartwood's Fall
local rootThree = story.New(
    "The Final Root",
    "The final root is at the base of the Rotten Heartwood itself. You must fight the Heartwood's central core to free the forest from its curse."
)
local heartwoodBoss = story.New(
    "The Rotting Heartwood",
    "The ancient tree shudders, and its core unleashes a wave of corrupting energy. It's a multi-stage battle where you must dodge its poisonous spores and destroy its glowing, pulsating core!"
)
local heartwoodVictory = story.New(
    "The Fey Queen's Gratitude",
    "The Heartwood's final spore bursts, and the tree crumbles into a pile of clean, rich soil. The forest instantly begins to heal. The Fey Queen appears before you. 'You have saved my realm,' she says. 'Now, I will grant you passage to the **Spirit World**.'"
)

-- Sci-Fi Quest Line - The Cyber-Sorcerer
local sorcererChamber = story.New(
    "The Cyber-Sorcerer's Chamber",
    "You enter a large chamber filled with strange machinery and pulsing power conduits. At the center is a man in a glowing suit. The **Cyber-Sorcerer** awaits you."
)
local sorcererBoss = story.New(
    "The Cyber-Sorcerer's Wrath",
    "The sorcerer merges with a powerful robot suit. 'I am the future!' he declares, firing plasma blasts at you. This is a battle of technology and magic, and he is a master of both!"
)
local sorcererVictory = story.New(
    "The Celestial Map",
    "The sorcerer's suit overloads and he collapses, his body sparking. A hidden compartment on his console opens, revealing a holographic map of the entire galaxy with a single star blinking red. This is the location of the **Cosmic Forge**, an ancient power source."
)


-- Connect the New Scenes
local function ConnectPart7()
    -- Medieval Path Boss
    librarySuccess:AddChoice("Challenge the Guardian.", arcanistGauntlet)
    arcanistGauntlet:AddChoice("Fight the temporal guardian!", nil, function(p)
        SendInStory("You fight the guardian of time! It zips around the room, making it difficult to hit!")
        SendInStory("The guardian fires a temporal burst, dealing 10 damage to the party!")
        for _, member in ipairs(partyOrder) do
            roster[member].HP = clampHP(roster[member].HP - 10)
        end
        UpdateStatBox()
        task.delay(3, function() currentScene = gauntletSuccess; currentScene:Present() end)
        return true
    end)
    gauntletSuccess:AddChoice("Claim the Relic.", nil, function(p)
        SendInStory("You claim the Chronos Relic. You feel a new power surge through you. This will be very useful in your next journey.")
        table.insert(roster[p.Name].Inventory, "Chronos Relic")
        roster[p.Name].MAG = roster[p.Name].MAG + 10 -- New permanent stat boost
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)

    -- Magical Path Boss
    rootThree:AddChoice("Confront the Heartwood's core.", heartwoodBoss)
    heartwoodBoss:AddChoice("Attack the core!", nil, function(p)
        SendInStory("You attack the Rotten Heartwood! You manage to land a few hits, but its thorns lash out at you, dealing 5 damage!")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 5)
        UpdateStatBox()
        task.delay(3, function() currentScene = heartwoodVictory; currentScene:Present() end)
        return true
    end)
    heartwoodVictory:AddChoice("Talk to the Fey Queen.", nil, function(p)
        SendInStory("The Fey Queen nods. A new, shimmering portal opens, leading to the **Spirit World**. You have a new quest!")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)

    -- Sci-Fi Path Boss
    sorcererChamber:AddChoice("Confront the Cyber-Sorcerer.", sorcererBoss)
    sorcererBoss:AddChoice("Fight the sorcerer!", nil, function(p)
        SendInStory("You attack the Cyber-Sorcerer! He is fast, and his shields are strong!")
        SendInStory("The sorcerer retaliates with a blast of energy, dealing 12 damage to the party!")
        for _, member in ipairs(partyOrder) do
            roster[member].HP = clampHP(roster[member].HP - 12)
        end
        UpdateStatBox()
        task.delay(3, function() currentScene = sorcererVictory; currentScene:Present() end)
        return true
    end)
    sorcererVictory:AddChoice("Retrieve the map.", nil, function(p)
        SendInStory("You retrieve the holographic map. The location of the Cosmic Forge is now revealed!")
        table.insert(roster[p.Name].Inventory, "Celestial Map")
        roster[p.Name].ATK = roster[p.Name].ATK + 10 -- New permanent stat boost
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
end
ConnectPart7()

-- ===== End of File 7 (BOSS BATTLES) =====

-- DND Story Bot — FILE 8 (NEXT STAGE QUESTS)
-- Append this directly after FILE 7 (Boss Battles).

-- ===== Scene Library (Part 8) =====
local hubScene = currentScene -- Reference the hub from previous parts

-- Medieval Quest Line - The Arcanist's Gauntlet
local gauntletSuccess = story.New(
    "The Chronos Relic",
    "With the guardian defeated, a shimmering hourglass, the **Chronos Relic**, materializes. It contains a fraction of the time stream itself, and it hums with incredible power. You have earned your new ability."
)
local timelineBreach = story.New(
    "The Temporal Rift",
    "The Chronos Relic begins to pulse rapidly. A message from a future version of the scholar you met appears before you, panicked. 'The timeline is fractured! A powerful entity is trying to erase history. You must find the three seals of time to repair the breach before all is lost!'"
)
local timelinePuzzle = story.New(
    "The First Seal",
    "The first seal is a set of temporal echoes. You see a sequence of events repeating: an ancient king's coronation, a meteor shower, and a blooming flower. You must input the correct sequence to stabilize the timeline."
)

-- Magical Quest Line - The Spirit World
local heartwoodVictory = story.New(
    "The Fey Queen's Gratitude",
    "The Heartwood's final spore bursts, and the tree crumbles into a pile of clean, rich soil. The forest instantly begins to heal. The Fey Queen appears before you. 'You have saved my realm,' she says. 'Now, I will grant you passage to the **Spirit World**.'"
)
local spiritWorld = story.New(
    "The Veil of Spirits",
    "The new portal leads you to a vast, ethereal plane. The air hums with the souls of fallen heroes and ancient spirits. A wise, ancient spirit appears and says, 'The balance of worlds is in danger. A **Corrupting Wyrm** is devouring the souls of the departed, threatening to unleash them upon the living.'"
)
local spiritChallenge = story.New(
    "The Wyrm's Gauntlet",
    "To face the Wyrm, you must first pass through its gauntlet. You see three spectral gates before you, each one guarded by a powerful spirit."
)
local spiritGateOne = story.New(
    "The Gate of Courage",
    "A spectral knight blocks the first gate. 'Prove your courage by facing me in combat without magic or weapons!' he challenges."
)

-- Sci-Fi Quest Line - The Cosmic Forge
local sorcererVictory = story.New(
    "The Celestial Map",
    "The sorcerer's suit overloads and he collapses, his body sparking. A hidden compartment on his console opens, revealing a holographic map of the entire galaxy with a single star blinking red. This is the location of the **Cosmic Forge**, an ancient power source."
)
local cosmicTravel = story.New(
    "Cosmic Journey",
    "Using the celestial map, you board a derelict starship. The ship’s systems are offline. You must find the power cells to bring it to life and make the journey to the Forge."
)
local powerCellPuzzle = story.New(
    "The Ship's Puzzle",
    "You find the power cell room, but the cells are locked behind a grid of lasers. You must navigate the grid using a nearby terminal to unlock the cells."
)
local cosmicForgeArrival = story.New(
    "The Cosmic Forge",
    "With the ship powered, you travel through a nebula and arrive at a colossal, star-forged station. This is the **Cosmic Forge**, where stars are born and galaxies are shaped. It seems to be under the control of a powerful being."
)

-- Connect the New Scenes
local function ConnectPart8()
    -- Medieval Path Continuation
    gauntletSuccess:AddChoice("Touch the relic.", timelineBreach)
    timelineBreach:AddChoice("Go to the first seal.", timelinePuzzle)
    timelinePuzzle:AddChoice("Input sequence: King, Meteor, Flower", nil, function(p)
        SendInStory("The seal glows and a voice echoes: 'Sequence accepted. The timeline is partially mended.'")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    timelinePuzzle:AddChoice("Input any other sequence.", nil, function(p)
        SendInStory("The timeline shudders. You take 5 damage from the temporal shock!")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 5)
        UpdateStatBox()
        task.delay(3, function() SendInStory("You must try again.") currentScene = hubScene; currentScene:Present() end)
        return true
    end)

    -- Magical Path Continuation
    heartwoodVictory:AddChoice("Enter the Spirit World.", spiritWorld)
    spiritWorld:AddChoice("Accept the challenge.", spiritChallenge)
    spiritChallenge:AddChoice("Approach the Gate of Courage.", spiritGateOne)
    spiritGateOne:AddChoice("Face the knight in combat!", nil, function(p)
        SendInStory("You face the spectral knight. You must defeat him with your wits and strength alone!")
        SendInStory("The knight attacks, but you dodge his blow! He commends you on your bravery.")
        task.delay(3, function() SendInStory("The gate opens. You have passed the first trial.") currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    spiritGateOne:AddChoice("Use your magic or weapons.", nil, function(p)
        SendInStory("The knight's eyes flare. 'You have no honor!' he says. He zaps you with a curse, dealing 10 damage!")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 10)
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)

    -- Sci-Fi Path Continuation
    sorcererVictory:AddChoice("Board the starship.", cosmicTravel)
    cosmicTravel:AddChoice("Go to the power cell room.", powerCellPuzzle)
    powerCellPuzzle:AddChoice("Navigate the laser grid.", nil, function(p)
        SendInStory("You carefully input the code and the lasers disarm. The power cells are now available!")
        task.delay(3, function() currentScene = cosmicForgeArrival; currentScene:Present() end)
        return true
    end)
    powerCellPuzzle:AddChoice("Try to brute-force the terminal.", nil, function(p)
        SendInStory("The terminal alarms blare! The lasers fire, dealing 7 damage!")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 7)
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    cosmicForgeArrival:AddChoice("Enter the Cosmic Forge.", nil, function(p)
        SendInStory("You enter the magnificent Forge. A powerful presence awaits you.")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
end
ConnectPart8()

-- ===== End of File 8 (NEXT STAGE QUESTS) =====

-- DND Story Bot — FILE 9 (TRIALS OF TRUTH)
-- Append this directly after FILE 8 (Next Stage Quests).

-- ===== Scene Library (Part 9) =====
local hubScene = currentScene -- Reference the hub from previous parts

-- Medieval Quest Line - The Arcanist's Gauntlet
local timelinePuzzle = story.New(
    "The First Seal",
    "The first seal is a set of temporal echoes. You see a sequence of events repeating: an ancient king's coronation, a meteor shower, and a blooming flower. You must input the correct sequence to stabilize the timeline."
)
local timelineBreach = story.New(
    "The Temporal Rift",
    "The Chronos Relic begins to pulse rapidly. A message from a future version of the scholar you met appears before you, panicked. 'The timeline is fractured! A powerful entity is trying to erase history. You must find the three seals of time to repair the breach before all is lost!'"
)
local secondSeal = story.New(
    "The Second Seal: The Paradox",
    "The second seal is a temporal paradox. The room is filled with temporal clones of yourself, each one performing a different action. A voice echoes from the past: 'To proceed, you must destroy the version of yourself that is most unlike you!'"
)

-- Magical Quest Line - The Spirit World
local spiritGateOne = story.New(
    "The Gate of Courage",
    "A spectral knight blocks the first gate. 'Prove your courage by facing me in combat without magic or weapons!' he challenges."
)
local spiritGateTwo = story.New(
    "The Gate of Wisdom",
    "A serene spirit of a wise old sage blocks the second gate. 'To pass, you must answer my question: What is the most powerful force in all the realms?'"
)
local spiritGateThree = story.New(
    "The Gate of Compassion",
    "The final gate is guarded by a wounded spirit who whimpers in pain. You must find a way to heal them before you can pass. Your healing potions are not working."
)

-- Sci-Fi Quest Line - The Cosmic Forge
local cosmicForgeArrival = story.New(
    "The Cosmic Forge",
    "With the ship powered, you travel through a nebula and arrive at a colossal, star-forged station. This is the **Cosmic Forge**, where stars are born and galaxies are shaped. It seems to be under the control of a powerful being."
)
local forgeGuardian = story.New(
    "The Forgemaster",
    "A colossal being made of pure starlight stands before you. 'You have come seeking the power of the forge,' it says. 'But you must first prove you are worthy by defeating my three guardians.'"
)
local guardianOne = story.New(
    "The Guardian of Logic",
    "The first guardian is a powerful robot with laser eyes. 'Logic is the true path,' it declares. 'To defeat me, you must find my weakness, not with brute force, but with a clever command.' It challenges you to a duel of wits."
)

-- Connect the New Scenes
local function ConnectPart9()
    -- Medieval Path Continuation
    timelinePuzzle:AddChoice("Input sequence: King, Meteor, Flower", nil, function(p)
        SendInStory("The seal glows and a voice echoes: 'Sequence accepted. The timeline is partially mended.'")
        task.delay(3, function() currentScene = secondSeal; currentScene:Present() end)
        return true
    end)
    timelinePuzzle:AddChoice("Input any other sequence.", nil, function(p)
        SendInStory("The timeline shudders. You take 5 damage from the temporal shock!")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 5)
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    secondSeal:AddChoice("Destroy your weapon-wielding clone.", nil, function(p)
        SendInStory("The clone vanishes in a flash of light. The seal hums. 'This is the most direct path, but not the right one,' says a voice. 'Brute force is not the answer.' You must choose again.")
        task.delay(3, function() currentScene = secondSeal; currentScene:Present() end)
        return true
    end)
    secondSeal:AddChoice("Destroy your magic-using clone.", nil, function(p)
        SendInStory("The clone vanishes in a flash of light. The seal hums. 'This is the most direct path, but not the right one,' says a voice. 'Over-reliance on power is a weakness.' You must choose again.")
        task.delay(3, function() currentScene = secondSeal; currentScene:Present() end)
        return true
    end)
    secondSeal:AddChoice("Destroy your timid, frightened clone.", nil, function(p)
        SendInStory("The clone vanishes in a flash of light. The seal shines. 'Correct! You have cast out your weakness and proved you are capable of courage.' The seal shatters, revealing a new path.")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)

    -- Magical Path Continuation
    spiritGateOne:AddChoice("Pass the test of courage.", spiritGateTwo)
    spiritGateTwo:AddChoice("Answer: 'Love'", nil, function(p)
        SendInStory("The sage smiles. 'Correct. Love is the most powerful force in all the realms.' The gate opens, revealing the next challenge.")
        task.delay(3, function() currentScene = spiritGateThree; currentScene:Present() end)
        return true
    end)
    spiritGateTwo:AddChoice("Answer anything else.", nil, function(p)
        SendInStory("The sage frowns. 'Your answer is... incomplete.' The spirit zaps you with a curse, dealing 10 damage!")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 10)
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    spiritGateThree:AddChoice("Use a potion.", nil, function(p)
        SendInStory("Your potion passes through the spirit's ethereal body. It has no effect.")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    spiritGateThree:AddChoice("Speak words of comfort and empathy.", nil, function(p)
        SendInStory("Your words calm the spirit, and its wounds fade. 'Thank you,' it whispers. 'You have a heart of pure compassion. The gate is open.'")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)

    -- Sci-Fi Path Continuation
    cosmicForgeArrival:AddChoice("Confront the Forgemaster.", forgeGuardian)
    forgeGuardian:AddChoice("Challenge the Guardian of Logic.", guardianOne)
    guardianOne:AddChoice("Input command: 'RUN VIRUS.EXE'", nil, function(p)
        SendInStory("The guardian's eyes go dark. 'Logic... illogical,' it says before powering down. You have defeated the first guardian!")
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
    guardianOne:AddChoice("Attack the guardian.", nil, function(p)
        SendInStory("Your attack glances off the guardian's armor. It retaliates with a powerful laser blast, dealing 15 damage!")
        roster[p.Name].HP = clampHP(roster[p.Name].HP - 15)
        UpdateStatBox()
        task.delay(3, function() currentScene = hubScene; currentScene:Present() end)
        return true
    end)
end
ConnectPart9()

-- ===== End of File 9 (TRIALS OF TRUTH) =====
