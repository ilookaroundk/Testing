-- DND Story Bot — FILE 1 (CORE SYSTEM + GUI + VOTING + TURN ORDER)
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

