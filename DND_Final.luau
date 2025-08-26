-- Dungeon & Dragons Bot for Roblox (LocalScript)
-- Voting-enabled: all choices are decided by party vote (chat + GUI voting)
-- The script is intended to be run by a single GM (LocalPlayer). It listens to all players' chat.

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TextChatService = game:GetService("TextChatService")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

-- Configuration
local CONFIG = {
    XP_PER_ACTION = 10,
    TURN_TIMEOUT = 30,
    ALLOW_ROLLS = true,
    CRIT_THRESHOLD = 20, -- natural d20 result = 20 is crit
    GUI_ZINDEX = 10,
    MAX_PARTY = 8,
    LEVEL_XP = function(level) return 100 + (level - 1) * 75 end,
    VOTE_DURATION = 18, -- default seconds for a vote
    VOTE_CHAT_PREFIX = "!vote", -- chat commands accepted to vote
    VOTE_ACCEPT_SINGLE_LETTER = true
}

-- State
local DM_USER_ID = LocalPlayer.UserId -- script runner is the GM
local party = {} -- map userId => CharacterEntry
local partyOrder = {} -- list of userIds in turn order
local monsters = {} -- active monsters list
local encounter = nil -- current encounter table
local sessionRunning = false
local currentTurnIndex = 1
local awaitingAction = false
local gui = {} -- store gui elements
local currentVote = nil -- active vote object or nil

-- Utilities
local function notify(title, text, duration)
    StarterGui:SetCore("SendNotification", {
        Title = title or "D&D Bot",
        Text = text or "",
        Duration = duration or 6
    })
end

local function Chat(msg)
    -- robust chat send
    if TextChatService and TextChatService.TextChannels and TextChatService.TextChannels:FindFirstChild("RBXGeneral") then
        pcall(function() TextChatService.TextChannels.RBXGeneral:SendAsync(msg) end)
    else
        pcall(function() ReplicatedStorage.DefaultChatSystemChatEvents.SayMessageRequest:FireServer(msg, "All") end)
    end
end

local function clamp(n, a, b) return math.max(a, math.min(b, n)) end
math.randomseed(tick() % 1 * 1000000)

-- Dice helpers
local function rollDice(notation)
    -- supports "d20", "1d6", "2d6+3", "4d8-1", or a plain number
    if type(notation) ~= "string" then return tonumber(notation) or 0 end
    local count, sides, sign, mod = notation:match("^(%d*)[dD](%d+)([%+%-]?)(%d*)$")
    if not sides then
        local n = tonumber(notation)
        return n or 0
    end
    count = tonumber(count) or 1
    sides = tonumber(sides)
    mod = tonumber(mod) or 0
    if sign == '-' then mod = -mod end
    local total = 0
    for i = 1, count do total = total + math.random(1, sides) end
    return total + mod
end

local function d20() return rollDice("d20") end

-- Character templates & management
local StatNames = {"STR","DEX","CON","INT","WIS","CHA"}
local function abilityMod(score) return math.floor((score - 10) / 2) end

local function MakeCharacterTemplate(name, displayName, userId)
    local tpl = {
        UserId = userId,
        Name = name or ("Player"..tostring(userId)),
        DisplayName = displayName or name,
        Level = 1,
        XP = 0,
        HP = 10,
        MaxHP = 10,
        AC = 10,
        Stats = {STR = 10, DEX = 10, CON = 10, INT = 10, WIS = 10, CHA = 10},
        Inventory = {},
        Spells = {},
        Conditions = {},
        Alive = true,
        Resistances = {}
    }
    return tpl
end

local function updatePartyUI() end -- placeholder, real function set after GUI creation
local function updateMonstersUI() end
local function updateTurnUI() end

local function AddPlayerToParty(player)
    if not player then return false, "no player" end
    if party[player.UserId] then return false, "already in party" end
    if #partyOrder >= CONFIG.MAX_PARTY then return false, "party full" end
    local char = MakeCharacterTemplate(player.Name, player.DisplayName, player.UserId)
    -- assign sample stats (4d6 drop lowest)
    for _, s in ipairs(StatNames) do
        local rolls = {}
        for i=1,4 do table.insert(rolls, math.random(1,6)) end
        table.sort(rolls, function(a,b) return a>b end)
        char.Stats[s] = clamp(rolls[1]+rolls[2]+rolls[3], 6, 20)
    end
    char.MaxHP = math.max(1, 8 + abilityMod(char.Stats.CON))
    char.HP = char.MaxHP
    char.AC = 10 + abilityMod(char.Stats.DEX)
    party[player.UserId] = char
    table.insert(partyOrder, player.UserId)
    updatePartyUI()
    Chat("🧭 "..player.DisplayName.." joined the party!")
    return true
end

local function RemovePlayerFromParty(player)
    if not player then return end
    if party[player.UserId] then
        party[player.UserId] = nil
        for i,id in ipairs(partyOrder) do if id == player.UserId then table.remove(partyOrder, i); break end end
        updatePartyUI()
        Chat("⛔ "..player.DisplayName.." has left the party.")
    end
end

local function GetCharacterByUserId(userId) return party[userId] end

-- XP and leveling
local function GrantXP(userId, xp)
    local char = GetCharacterByUserId(userId)
    if not char then return end
    char.XP = char.XP + xp
    Chat("✨ "..char.DisplayName.." gains "..xp.." XP (total "..char.XP..")")
    while char.XP >= CONFIG.LEVEL_XP(char.Level + 1) do
        char.XP = char.XP - CONFIG.LEVEL_XP(char.Level + 1)
        char.Level = char.Level + 1
        local deltaHP = math.max(1, abilityMod(char.Stats.CON) + rollDice("d6"))
        char.MaxHP = char.MaxHP + deltaHP
        char.HP = char.MaxHP
        Chat("⬆️ "..char.DisplayName.." reached level "..char.Level.."! MaxHP -> "..char.MaxHP)
    end
    updatePartyUI()
end

-- Items, Spells, Monsters (templates)
local Items = {
    HealthPotion = {Name="Health Potion", Type="consumable", Heal="1d8+2"},
    Greatsword = {Name="Greatsword", Type="weapon", Damage="2d6", DamageType="slashing", AttackBonus=2},
    Shortbow = {Name="Shortbow", Type="weapon", Damage="1d6", DamageType="piercing", AttackBonus=1},
    WandOfSparks = {Name="Wand of Sparks", Type="wand", Damage="1d8", DamageType="fire", AttackBonus=0},
    Shield = {Name="Shield", Type="armor", ACBonus=2}
}

local Spells = {
    MagicMissile = {Name="Magic Missile", Damage="1d4+1"},
    Fireball = {Name="Fireball", Damage="6d6", Dc=14},
    CureWounds = {Name="Cure Wounds", Heal="1d8"}
}

local MonsterTemplates = {
    Goblin = {Name="Goblin", HP=7, AC=13, Attack="1d6+2", DamageType="piercing", XP=25, Resistances={}},
    Orc = {Name="Orc", HP=15, AC=13, Attack="1d12+3", DamageType="slashing", XP=100},
    Skeleton = {Name="Skeleton", HP=8, AC=13, Attack="1d6+1", DamageType="piercing", XP=50},
    YoungDragon = {Name="Young Dragon", HP=60, AC=17, Attack="2d10+5", DamageType="fire", XP=1200},
    Bandit = {Name="Bandit", HP=11, AC=12, Attack="1d8+2", DamageType="slashing", XP=75},
    GiantRat = {Name="Giant Rat", HP=4, AC=12, Attack="1d4+1", DamageType="piercing", XP=10}
}

local function SpawnMonster(templateName)
    local tpl = MonsterTemplates[templateName]
    if not tpl then return nil end
    local m = {
        Id = "M"..tostring(math.random(10000,99999)),
        Name = tpl.Name,
        HP = tpl.HP,
        MaxHP = tpl.HP,
        AC = tpl.AC,
        Attack = tpl.Attack,
        DamageType = tpl.DamageType,
        XP = tpl.XP,
        Resistances = tpl.Resistances or {},
        Alive = true
    }
    table.insert(monsters, m)
    updateMonstersUI()
    Chat("👹 A "..m.Name.." (HP "..m.HP..") appears!")
    return m
end

local function DamageMonster(monster, dmg, dtype)
    if not monster or not monster.Alive then return end
    local final = dmg
    for _, r in ipairs(monster.Resistances or {}) do
        if string.lower(r) == string.lower(dtype or "") then final = math.floor(final/2); break end
    end
    monster.HP = monster.HP - final
    Chat("🔪 "..monster.Name.." takes "..final.." "..(dtype or "damage").." (HP "..math.max(0,monster.HP).."/"..monster.MaxHP..")")
    if monster.HP <= 0 then
        monster.Alive = false
        Chat("💀 "..monster.Name.." was slain!")
        local aliveCount = 0
        for _, id in ipairs(partyOrder) do if party[id] and party[id].Alive then aliveCount = aliveCount + 1 end end
        local xpShare = math.floor((monster.XP) / math.max(1, aliveCount))
        for _, id in ipairs(partyOrder) do if party[id] and party[id].Alive then GrantXP(id, xpShare) end end
        updateMonstersUI()
    end
end

-- Encounters
local Encounters = {
    GoblinPack = {Name="Goblin Pack", Description="A pack of goblins attacks.", Monsters={"Goblin","Goblin","GiantRat"}, Loot={Items.Greatsword, Items.HealthPotion}},
    Ambush = {Name="Ambush", Description="Bandits ambush the party.", Monsters={"Bandit","Bandit"}, Loot={Items.FireCrystal}}
}

-- Combat: attacker char uses weapon or fists
local function AttackTarget(attackerChar, targetMonster, weapon)
    if not attackerChar or not targetMonster or not targetMonster.Alive then return end
    local toRoll = d20()
    local atkBonus = (weapon and weapon.AttackBonus) or 0
    local attackTotal = toRoll + abilityMod(attackerChar.Stats.STR) + atkBonus
    local hit = attackTotal >= targetMonster.AC
    local isCrit = (toRoll >= CONFIG.CRIT_THRESHOLD)
    Chat("🎯 "..attackerChar.DisplayName.." attacks "..targetMonster.Name.." (roll "..toRoll.." + "..abilityMod(attackerChar.Stats.STR).." + "..atkBonus.." = "..attackTotal..") vs AC "..targetMonster.AC)
    if isCrit and hit then
        local base = rollDice(weapon and weapon.Damage or "1d6")
        local base2 = rollDice(weapon and weapon.Damage or "1d6")
        local dmg = base + base2 + math.max(0, abilityMod(attackerChar.Stats.STR))
        Chat("💥 Critical! Damage: "..dmg)
        DamageMonster(targetMonster, dmg, weapon and weapon.DamageType)
    elseif hit then
        local dmg = rollDice(weapon and weapon.Damage or "1d6") + math.max(0, abilityMod(attackerChar.Stats.STR))
        Chat("✅ Hit! Damage: "..dmg)
        DamageMonster(targetMonster, dmg, weapon and weapon.DamageType)
    else
        Chat("❌ Missed!")
    end
end

local function MonsterAct(monster)
    if not monster or not monster.Alive then return end
    local candidates = {}
    for _, id in ipairs(partyOrder) do local c = party[id]; if c and c.Alive then table.insert(candidates, c) end end
    if #candidates == 0 then Chat("🏳️ All party members are down.") return end
    local target = candidates[math.random(1,#candidates)]
    local attackRoll = d20()
    Chat("👾 "..monster.Name.." attacks "..target.DisplayName.." (roll "..attackRoll..")")
    local hit = (attackRoll + 0) >= (target.AC - abilityMod(target.Stats.DEX))
    if hit then
        local dmg = rollDice(monster.Attack or "1d4")
        Chat("💢 "..target.DisplayName.." takes "..dmg.." "..(monster.DamageType or "damage"))
        target.HP = target.HP - dmg
        if target.HP <= 0 then
            target.Alive = false
            Chat("⚰️ "..target.DisplayName.." fell unconscious!")
        end
        updatePartyUI()
    else
        Chat("🛡️ "..monster.Name.." missed "..target.DisplayName)
    end
end

-- TURN and ACTION flow + Voting system
local function executeChosenActionForPlayer(playerId, choiceKey, extra)
    -- choiceKey is an index or string representing which action (e.g., "Attack", "Cast", etc)
    -- This function actually performs the chosen action for the active player after the vote ends
    local char = party[playerId]
    if not char then return end
    if choiceKey == "Attack" then
        local weapon = nil
        for _, it in ipairs(char.Inventory) do if it.Type == "weapon" then weapon = it; break end end
        if not weapon then weapon = {Name="Fist", Damage="1d4", AttackBonus=0} end
        local target = gui.SelectedMonster
        if not target then Chat("No monster targeted; attack fails."); return end
        AttackTarget(char, target, weapon)
    elseif choiceKey == "Cast" then
        if #char.Spells == 0 then Chat("No spells known. Turn wasted."); return end
        local spellKey = char.Spells[1]
        local spell = Spells[spellKey] or {}
        Chat("✨ "..char.DisplayName.." casts "..(spell.Name or spellKey))
        if spell.Damage and gui.SelectedMonster then
            local dmg = rollDice(spell.Damage)
            DamageMonster(gui.SelectedMonster, dmg, spell.DamageType)
        end
        if spell.Heal then
            local heal = rollDice(spell.Heal)
            char.HP = math.min(char.MaxHP, char.HP + heal)
            Chat("❤ "..char.DisplayName.." healed "..heal.." HP.")
        end
    elseif choiceKey == "Use" then
        local consumableIndex = nil
        for i,it in ipairs(char.Inventory) do if it.Type == "consumable" then consumableIndex = i; break end end
        if consumableIndex then
            local it = table.remove(char.Inventory, consumableIndex)
            if it.Heal then
                local amount = rollDice(it.Heal)
                char.HP = math.min(char.MaxHP, char.HP + amount)
                Chat("🧪 "..char.DisplayName.." uses "..it.Name.." and heals "..amount.." HP.")
            else
                Chat(char.DisplayName.." uses "..it.Name..".")
            end
        else
            Chat("No usable items.")
        end
    elseif choiceKey == "Defend" then
        Chat(char.DisplayName.." takes a defensive stance (+2 AC briefly).")
        char.AC = char.AC + 2
        for _, m in ipairs(monsters) do if m.Alive then MonsterAct(m) end end
        char.AC = char.AC - 2
    elseif choiceKey == "Dodge" then
        Chat(char.DisplayName.." dodges; advantage simulated loosely.")
        for _, m in ipairs(monsters) do if m.Alive then MonsterAct(m) end end
    elseif choiceKey == "Flee" then
        local roll = d20() + abilityMod(char.Stats.DEX)
        if roll >= 12 then
            Chat(char.DisplayName.." successfully flees from combat!")
            party[playerId] = nil
            for i,id in ipairs(partyOrder) do if id == playerId then table.remove(partyOrder, i); break end end
            updatePartyUI()
        else
            Chat(char.DisplayName.." fails to flee!")
        end
    elseif choiceKey == "Custom" then
        Chat(char.DisplayName.." attempts a custom action. DM adjudicates.")
    elseif choiceKey == "Skip" then
        Chat(char.DisplayName.." ends their turn.")
    else
        Chat("Choice unknown: "..tostring(choiceKey))
    end
    updatePartyUI()
    updateMonstersUI()
end

-- Voting system
local function startVote(proposerId, title, options, duration, eligibleVoters, onComplete)
    -- options: array of strings
    -- eligibleVoters: array of userIds who can vote (defaults to all party members)
    -- onComplete(chosenIndex, resultsTable)
    if currentVote then
        Chat("⚠️ A vote is already active. DM can force or wait.")
        return nil
    end
    duration = duration or CONFIG.VOTE_DURATION
    local vote = {
        id = "V"..tostring(math.random(100000,999999)),
        proposer = proposerId,
        title = title,
        options = options,
        duration = duration,
        votes = {}, -- map userId -> index
        counts = {}, -- index -> count
        startedAt = tick(),
        endsAt = tick() + duration,
        eligible = {},
        onComplete = onComplete
    }
    for i=1,#options do vote.counts[i] = 0 end
    if eligibleVoters and #eligibleVoters>0 then
        for _,id in ipairs(eligibleVoters) do vote.eligible[id] = true end
    else
        for _,id in ipairs(partyOrder) do vote.eligible[id] = true end
    end
    currentVote = vote

    -- Announce
    local optStrings = {}
    for i,opt in ipairs(options) do table.insert(optStrings, ("[%s] %s"):format(string.char(64 + i), opt)) end
    Chat("🗳️ Vote started: "..title)
    Chat("Options: "..table.concat(optStrings, " | "))
    Chat("Vote by chat using: "..CONFIG.VOTE_CHAT_PREFIX.." <letter|number> (e.g. "..CONFIG.VOTE_CHAT_PREFIX.." A) or click the DM GUI. Voting ends in "..duration.."s.")

    -- Show GUI update if present
    if gui and gui.VoteFrame then
        gui.VoteFrame.Visible = true
        gui.VoteTitle.Text = "Vote: "..title
        for i=1,6 do
            local btn = gui["VoteOpt"..i]
            if btn then
                if i <= #options then
                    btn.Visible = true
                    btn.Text = ("[%s] %s"):format(string.char(64 + i), options[i])
                    gui["VoteCount"..i].Text = "0"
                    gui["VoteCount"..i].Visible = true
                else
                    btn.Visible = false
                    if gui["VoteCount"..i] then gui["VoteCount"..i].Visible = false end
                end
            end
        end
    end

    -- Voting loop and completion
    spawn(function()
        while tick() < vote.endsAt and currentVote == vote do
            -- live GUI update is handled by recordVote
            wait(0.5)
        end
        if currentVote ~= vote then return end -- maybe DM forced completion
        -- Tally
        local highest = -1
        for i=1,#options do
            if vote.counts[i] > highest then highest = vote.counts[i] end
        end
        local topIndices = {}
        for i=1,#options do if vote.counts[i] == highest then table.insert(topIndices, i) end end
        local chosenIndex
        if #topIndices == 0 then
            chosenIndex = 1 -- default fallback
        elseif #topIndices == 1 then
            chosenIndex = topIndices[1]
        else
            chosenIndex = topIndices[math.random(1,#topIndices)] -- random tie-break
        end

        -- Announce result
        Chat("🗳️ Vote ended. Result: ["..string.char(64 + chosenIndex).."] "..options[chosenIndex].." ("..vote.counts[chosenIndex].." votes)")
        if vote.onComplete then pcall(vote.onComplete, chosenIndex, vote.counts) end

        -- hide GUI
        if gui and gui.VoteFrame then gui.VoteFrame.Visible = false end
        currentVote = nil
    end)

    return vote
end

local function recordVote(player, rawChoice)
    if not currentVote then return false, "No active vote" end
    if not currentVote.eligible[player.UserId] then return false, "Not eligible to vote" end
    -- parse rawChoice: accept letters A.., numbers 1.., or patterns like "!vote A"
    local choice = nil
    if type(rawChoice) == "number" then choice = rawChoice end
    if type(rawChoice) == "string" then
        local s = rawChoice:match("^%s*(.-)%s*$")
        -- strip prefix if present
        s = s:gsub("^"..CONFIG.VOTE_CHAT_PREFIX.."%s*", "")
        -- letter
        local letter = s:match("^([A-Za-z])$")
        if letter and CONFIG.VOTE_ACCEPT_SINGLE_LETTER then
            local idx = string.byte(letter:upper()) - 64
            if idx >= 1 and idx <= #currentVote.options then choice = idx end
        end
        -- number
        local num = tonumber(s)
        if tonumber(num) and num >= 1 and num <= #currentVote.options then choice = tonumber(num) end
        -- also accept "A" when typed with punctuation etc
        if not choice then
            local letter2 = s:match("([A-Za-z])")
            if letter2 and CONFIG.VOTE_ACCEPT_SINGLE_LETTER then
                local idx = string.byte(letter2:upper()) - 64
                if idx >= 1 and idx <= #currentVote.options then choice = idx end
            end
        end
    end
    if not choice then return false, "Unrecognized vote option" end

    -- Remove previous vote if any
    local prev = currentVote.votes[player.UserId]
    if prev then currentVote.counts[prev] = math.max(0, currentVote.counts[prev] - 1) end
    currentVote.votes[player.UserId] = choice
    currentVote.counts[choice] = (currentVote.counts[choice] or 0) + 1

    -- Update GUI counts
    if gui and gui.VoteFrame then
        for i=1,#currentVote.options do
            if gui["VoteCount"..i] then
                gui["VoteCount"..i].Text = tostring(currentVote.counts[i] or 0)
            end
        end
    end

    -- Optionally instant finish if every eligible voted
    local totalEligible = 0
    for id,_ in pairs(currentVote.eligible) do totalEligible = totalEligible + 1 end
    local totalVotes = 0
    for uid,_ in pairs(currentVote.votes) do totalVotes = totalVotes + 1 end
    if totalVotes >= totalEligible then
        -- finish early: compute and call onComplete
        local highest = -1
        for i=1,#currentVote.options do if (currentVote.counts[i] or 0) > highest then highest = currentVote.counts[i] end end
        local topIndices = {}
        for i=1,#currentVote.options do if (currentVote.counts[i] or 0) == highest then table.insert(topIndices, i) end end
        local chosenIndex
        if #topIndices == 0 then chosenIndex = 1 else chosenIndex = topIndices[math.random(1,#topIndices)] end
        Chat("🗳️ All votes in. Result: ["..string.char(64+chosenIndex).."] "..currentVote.options[chosenIndex].." ("..(currentVote.counts[chosenIndex] or 0).." votes)")
        if currentVote.onComplete then pcall(currentVote.onComplete, chosenIndex, currentVote.counts) end
        if gui and gui.VoteFrame then gui.VoteFrame.Visible = false end
        currentVote = nil
    end

    return true
end

-- GUI creation (compact) and wiring
local function CreateGui()
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "DnDBotGUI"
    screenGui.ResetOnSpawn = false
    screenGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
    gui.Root = screenGui

    local main = Instance.new("Frame", screenGui)
    main.Name = "Main"
    main.Size = UDim2.new(0,900,0,520)
    main.Position = UDim2.new(0.5,-450,0.5,-260)
    main.BackgroundColor3 = Color3.fromRGB(30,30,30)
    gui.MainFrame = main

    local title = Instance.new("TextLabel", main)
    title.Size = UDim2.new(1,0,0,28)
    title.Position = UDim2.new(0,0,0,0)
    title.Text = "D&D Bot - DM GUI (Voting Enabled)"
    title.Font = Enum.Font.SourceSansBold
    title.TextSize = 18
    title.BackgroundTransparency = 1
    title.TextColor3 = Color3.fromRGB(255,255,255)

    -- Party list
    local partyFrame = Instance.new("ScrollingFrame", main)
    partyFrame.Name = "PartyFrame"
    partyFrame.Size = UDim2.new(0,260,1,-36)
    partyFrame.Position = UDim2.new(0,8,0,36)
    partyFrame.BackgroundTransparency = 1
    partyFrame.ScrollBarThickness = 6
    gui.PartyList = partyFrame

    -- Monsters
    local monstersFrame = Instance.new("ScrollingFrame", main)
    monstersFrame.Name = "MonstersFrame"
    monstersFrame.Size = UDim2.new(0,260,0,220)
    monstersFrame.Position = UDim2.new(1,-268,0,36)
    monstersFrame.BackgroundTransparency = 1
    monstersFrame.ScrollBarThickness = 6
    gui.MonstersList = monstersFrame

    -- Center actions
    local center = Instance.new("Frame", main)
    center.Name = "Center"
    center.Size = UDim2.new(1, -540, 1, -36)
    center.Position = UDim2.new(0,280,0,36)
    center.BackgroundTransparency = 1
    gui.Center = center

    local turnLabel = Instance.new("TextLabel", center)
    turnLabel.Name = "TurnLabel"
    turnLabel.Size = UDim2.new(1,0,0,24)
    turnLabel.Position = UDim2.new(0,0,0,0)
    turnLabel.BackgroundTransparency = 1
    turnLabel.Font = Enum.Font.SourceSansBold
    turnLabel.Text = "Session idle"
    turnLabel.TextColor3 = Color3.new(1,1,1)
    gui.TurnLabel = turnLabel

    local actions = Instance.new("Frame", center)
    actions.Name = "Actions"
    actions.Size = UDim2.new(1,0,0,200)
    actions.Position = UDim2.new(0,0,0,36)
    actions.BackgroundTransparency = 1

    local function makeButton(parent, xIndex, yIndex, text)
        local b = Instance.new("TextButton", parent)
        b.Size = UDim2.new(0, 1/3, 0, 42)
        b.Position = UDim2.new((xIndex-1)/3, 6, (yIndex-1)*46, 0)
        b.Text = text
        b.BackgroundColor3 = Color3.fromRGB(60,60,60)
        b.TextColor3 = Color3.fromRGB(255,255,255)
        b.Font = Enum.Font.SourceSans
        b.TextSize = 16
        return b
    end

    gui.Buttons = {}
    gui.Buttons.Attack = makeButton(actions, 1, 1, "Attack")
    gui.Buttons.Cast = makeButton(actions, 2, 1, "Cast Spell")
    gui.Buttons.Use = makeButton(actions, 3, 1, "Use Item")
    gui.Buttons.Defend = makeButton(actions, 1, 2, "Defend")
    gui.Buttons.Dodge = makeButton(actions, 2, 2, "Dodge")
    gui.Buttons.Flee = makeButton(actions, 3, 2, "Flee")
    gui.Buttons.Custom = makeButton(actions, 1, 3, "Custom Action")
    gui.Buttons.Skip = makeButton(actions, 2, 3, "Skip/End Turn")
    gui.Buttons.Roll = makeButton(actions, 3, 3, "Quick d20")

    -- DM Controls
    local dm = Instance.new("Frame", main)
    dm.Name = "DM"
    dm.Size = UDim2.new(0,260,0,220)
    dm.Position = UDim2.new(1,-268,1,-236)
    dm.BackgroundColor3 = Color3.fromRGB(22,22,22)

    local dmTitle = Instance.new("TextLabel", dm)
    dmTitle.Size = UDim2.new(1,0,0,24)
    dmTitle.Position = UDim2.new(0,0,0,0)
    dmTitle.BackgroundTransparency = 1
    dmTitle.Font = Enum.Font.SourceSansBold
    dmTitle.Text = "DM Controls"
    dmTitle.TextColor3 = Color3.new(1,1,1)

    local encBox = Instance.new("TextBox", dm)
    encBox.Size = UDim2.new(1,-10,0,24)
    encBox.Position = UDim2.new(0,5,0,36)
    encBox.PlaceholderText = "Encounter name (e.g. GoblinPack)"
    gui.EncounterInput = encBox

    local spawnEncBtn = Instance.new("TextButton", dm)
    spawnEncBtn.Size = UDim2.new(1,-10,0,28)
    spawnEncBtn.Position = UDim2.new(0,5,0,66)
    spawnEncBtn.Text = "Spawn Encounter"
    spawnEncBtn.BackgroundColor3 = Color3.fromRGB(80,80,80)
    gui.SpawnEncounterBtn = spawnEncBtn

    local spawnMonBox = Instance.new("TextBox", dm)
    spawnMonBox.Size = UDim2.new(1,-10,0,24)
    spawnMonBox.Position = UDim2.new(0,5,0,106)
    spawnMonBox.PlaceholderText = "Monster template (e.g. Goblin)"
    gui.SpawnMonsterInput = spawnMonBox

    local spawnMonBtn = Instance.new("TextButton", dm)
    spawnMonBtn.Size = UDim2.new(1,-10,0,28)
    spawnMonBtn.Position = UDim2.new(0,5,0,136)
    spawnMonBtn.Text = "Spawn Monster"
    spawnMonBtn.BackgroundColor3 = Color3.fromRGB(80,80,80)
    gui.SpawnMonsterBtn = spawnMonBtn

    local giveBox = Instance.new("TextBox", dm)
    giveBox.Size = UDim2.new(1,-10,0,24)
    giveBox.Position = UDim2.new(0,5,0,176)
    giveBox.PlaceholderText = "Grant XP: '@All 50' or 'Name 50'"
    gui.GiveXPBox = giveBox

    local giveBtn = Instance.new("TextButton", dm)
    giveBtn.Size = UDim2.new(1,-10,0,26)
    giveBtn.Position = UDim2.new(0,5,0,206)
    giveBtn.Text = "Grant XP"
    giveBtn.BackgroundColor3 = Color3.fromRGB(80,80,80)
    gui.GiveXPBtn = giveBtn

    -- Voting frame (hidden until vote)
    local vframe = Instance.new("Frame", main)
    vframe.Name = "VoteFrame"
    vframe.Size = UDim2.new(0,420,0,140)
    vframe.Position = UDim2.new(0.5,-210,1,-156)
    vframe.BackgroundColor3 = Color3.fromRGB(16,16,16)
    vframe.Visible = false
    gui.VoteFrame = vframe

    local vtitle = Instance.new("TextLabel", vframe)
    vtitle.Size = UDim2.new(1, -10, 0, 24)
    vtitle.Position = UDim2.new(0,6,0,6)
    vtitle.BackgroundTransparency = 1
    vtitle.Font = Enum.Font.SourceSansBold
    vtitle.TextSize = 16
    vtitle.Text = "Vote:"
    vtitle.TextColor3 = Color3.new(1,1,1)
    gui.VoteTitle = vtitle

    -- up to 6 options
    for i=1,6 do
        local btn = Instance.new("TextButton", vframe)
        btn.Name = "VoteOpt"..i
        btn.Size = UDim2.new(1, -120, 0, 28)
        btn.Position = UDim2.new(0,6,0, 10 + 30 * (i-1) + 24)
        btn.BackgroundColor3 = Color3.fromRGB(70,70,70)
        btn.TextColor3 = Color3.new(1,1,1)
        btn.Font = Enum.Font.SourceSans
        btn.TextSize = 14
        btn.Visible = false
        gui["VoteOpt"..i] = btn

        local count = Instance.new("TextLabel", vframe)
        count.Name = "VoteCount"..i
        count.Size = UDim2.new(0,80,0,28)
        count.Position = UDim2.new(1,-102,0, 10 + 30 * (i-1) + 24)
        count.BackgroundColor3 = Color3.fromRGB(40,40,40)
        count.TextColor3 = Color3.new(1,1,1)
        count.Font = Enum.Font.SourceSansBold
        count.TextSize = 14
        count.Text = "0"
        count.Visible = false
        gui["VoteCount"..i] = count

        -- clicking a vote option in DM GUI counts as DM casting vote on behalf of LocalPlayer
        btn.MouseButton1Click:Connect(function()
            if not currentVote then return end
            recordVote(LocalPlayer, tostring(i))
        end)
    end

    -- Wire DM control buttons
    gui.SpawnEncounterBtn.MouseButton1Click:Connect(function()
        local encName = gui.EncounterInput.Text
        if Encounters[encName] then
            Chat("🗺️ DM spawns encounter: "..Encounters[encName].Name)
            for _,m in ipairs(Encounters[encName].Monsters) do SpawnMonster(m) end
            encounter = Encounters[encName]
            updateMonstersUI()
        else
            Chat("❌ Unknown encounter. Try GoblinPack or Ambush etc.")
        end
    end)
    gui.SpawnMonsterBtn.MouseButton1Click:Connect(function()
        local name = gui.SpawnMonsterInput.Text
        if MonsterTemplates[name] then SpawnMonster(name) else Chat("❌ Unknown monster template.") end
    end)
    gui.GiveXPBtn.MouseButton1Click:Connect(function()
        local txt = gui.GiveXPBox.Text
        if not txt or txt=="" then return end
        local all, amt = txt:match("^@All%s+(%d+)$")
        if all then
            local val = tonumber(amt)
            for id,_ in pairs(party) do GrantXP(id, val) end
            return
        end
        local name, xpv = txt:match("^(%S+)%s+(%d+)$")
        if name and xpv then
            local target = nil
            name = name:lower()
            for _,p in ipairs(Players:GetPlayers()) do
                if p.Name:lower():sub(1,#name) == name or p.DisplayName:lower():sub(1,#name) == name then target = p; break end
            end
            if target and party[target.UserId] then GrantXP(target.UserId, tonumber(xpv)) else Chat("Player not found in party.") end
        else
            Chat("Invalid format. Examples: '@All 50' or 'Alice 50'")
        end
    end)

    -- Wire action buttons to start votes
    local function proposeActionAndVote(actionKey)
        local uid = partyOrder[currentTurnIndex]
        if not uid then Chat("No active player"); return end
        local activeChar = party[uid]
        if not activeChar then Chat("Active character not found"); return end
        -- options for the action category; we'll present members with a short set to choose from
        local options = {}
        if actionKey == "Attack" then
            options = {"Attack with weapon", "Use unarmed / shove", "Aim & strike (better accuracy)", "Use ranged attack", "Feint (roleplay)", "Custom"}
        elseif actionKey == "Cast" then
            options = {"Cast strongest offensive", "Cast helpful/support", "Use low-level quick spell", "Conserve spell", "Use magic item", "Custom"}
        elseif actionKey == "Use" then
            options = {"Use Health Potion", "Use Utility Item", "Equip Shield", "Use Wand", "Pass", "Custom"}
        else
            options = {actionKey}
        end

        -- eligible voters: party members (including the acting player), you may also include spectators if desired
        local eligible = {}
        for _, id in ipairs(partyOrder) do eligible[#eligible+1] = id end

        -- start vote
        startVote(LocalPlayer.UserId, (activeChar.DisplayName.."'s action - "..actionKey), options, CONFIG.VOTE_DURATION, eligible, function(chosenIndex, counts)
            -- map the chosenIndex back to an actionable key
            local chosenText = options[chosenIndex]
            Chat("🧭 Executing chosen action for "..activeChar.DisplayName..": "..chosenText)
            -- perform a reasonable mapping
            if actionKey == "Attack" then
                -- treat indexes: 1 weapon, 2 unarmed, 3 precise (improve hit), 4 ranged, 5 roleplay/no mechanical effect, 6 custom
                if chosenIndex == 1 or chosenIndex == 3 then
                    -- normal attack
                    local weapon = nil
                    for _,it in ipairs(activeChar.Inventory) do if it.Type=="weapon" then weapon = it; break end end
                    if not weapon then weapon = {Name="Fist", Damage="1d4", AttackBonus=0} end
                    AttackTarget(activeChar, gui.SelectedMonster, weapon)
                elseif chosenIndex == 2 then
                    local unarmed = {Name="Unarmed", Damage="1d4", AttackBonus=0}
                    AttackTarget(activeChar, gui.SelectedMonster, unarmed)
                elseif chosenIndex == 4 then
                    local bow = nil
                    for _,it in ipairs(activeChar.Inventory) do if it.Name:lower():find("bow") then bow = it; break end end
                    if not bow then bow = {Name="Throw", Damage="1d4", AttackBonus=0} end
                    AttackTarget(activeChar, gui.SelectedMonster, bow)
                elseif chosenIndex == 5 then
                    Chat(activeChar.DisplayName.." performs a roleplay action - DM notes.")
                elseif chosenIndex == 6 then
                    Chat(activeChar.DisplayName.." performs a custom action. DM to adjudicate.")
                end
            elseif actionKey == "Cast" then
                if #activeChar.Spells == 0 then Chat("No spells known. Turn wasted.") else
                    -- pick highest-damage spell present
                    local chosenSpellKey = activeChar.Spells[1]
                    local spell = Spells[chosenSpellKey]
                    if spell and spell.Damage and gui.SelectedMonster then
                        local dmg = rollDice(spell.Damage)
                        DamageMonster(gui.SelectedMonster, dmg, spell.DamageType)
                    elseif spell and spell.Heal then
                        local heal = rollDice(spell.Heal)
                        activeChar.HP = math.min(activeChar.MaxHP, activeChar.HP + heal)
                        Chat(activeChar.DisplayName.." heals "..heal.." HP.")
                    else
                        Chat("Spell had no effect (placeholder)")
                    end
                end
            elseif actionKey == "Use" then
                -- try to use potion if selected
                local used = false
                for i,it in ipairs(activeChar.Inventory) do
                    if it.Type == "consumable" and it.Heal then
                        local amount = rollDice(it.Heal)
                        activeChar.HP = math.min(activeChar.MaxHP, activeChar.HP + amount)
                        Chat(activeChar.DisplayName.." uses "..it.Name.." and heals "..amount.." HP.")
                        table.remove(activeChar.Inventory, i)
                        used = true
                        break
                    end
                end
                if not used then Chat("No consumable used.") end
            else
                -- fallback single-key choices like Defend/Dodge/Flee/Custom/Skip
                executeChosenActionForPlayer(activeChar.UserId, actionKey)
            end

            -- after action: monster turn
            for _, m in ipairs(monsters) do if m.Alive then MonsterAct(m) end end
            -- advance turn
            currentTurnIndex = currentTurnIndex % #partyOrder + 1
            nextTurn()
        end)
    end

    -- connect action buttons
    gui.Buttons.Attack.MouseButton1Click:Connect(function() proposeActionAndVote("Attack") end)
    gui.Buttons.Cast.MouseButton1Click:Connect(function() proposeActionAndVote("Cast") end)
    gui.Buttons.Use.MouseButton1Click:Connect(function() proposeActionAndVote("Use") end)
    gui.Buttons.Defend.MouseButton1Click:Connect(function() proposeActionAndVote("Defend") end)
    gui.Buttons.Dodge.MouseButton1Click:Connect(function() proposeActionAndVote("Dodge") end)
    gui.Buttons.Flee.MouseButton1Click:Connect(function() proposeActionAndVote("Flee") end)
    gui.Buttons.Custom.MouseButton1Click:Connect(function() proposeActionAndVote("Custom") end)
    gui.Buttons.Skip.MouseButton1Click:Connect(function() proposeActionAndVote("Skip") end)
    gui.Buttons.Roll.MouseButton1Click:Connect(function()
        local uid = partyOrder[currentTurnIndex]
        local char = party[uid]
        if not char then Chat("No active char"); return end
        local r = d20()
        Chat("🎲 "..char.DisplayName.." rolled a d20: "..r.." (mod "..abilityMod(char.Stats.STR)..")")
    end)

    -- DM buttons for spawn etc
    gui.SpawnEncounterBtn.MouseButton1Click:Connect(function()
        local enc = gui.EncounterInput.Text
        if Encounters[enc] then
            Chat("🗺️ DM spawns encounter "..Encounters[enc].Name)
            for _,m in ipairs(Encounters[enc].Monsters) do SpawnMonster(m) end
        else
            Chat("Unknown encounter name.")
        end
    end)
    gui.SpawnMonsterBtn.MouseButton1Click:Connect(function()
        local name = gui.SpawnMonsterInput.Text
        if MonsterTemplates[name] then SpawnMonster(name) else Chat("Unknown monster template.") end
    end)
    gui.GiveXPBtn.MouseButton1Click:Connect(function()
        local txt = gui.GiveXPBox.Text
        if txt:match("^@All%s+%d+") then
            local num = tonumber(txt:match("%d+"))
            for id,_ in pairs(party) do GrantXP(id, num) end
            return
        end
        local name, val = txt:match("^(%S+)%s+(%d+)$")
        if name and val then
            local p = nil; name = name:lower()
            for _,pl in ipairs(Players:GetPlayers()) do
                if pl.Name:lower():sub(1,#name) == name or pl.DisplayName:lower():sub(1,#name) == name then p = pl; break end
            end
            if p and party[p.UserId] then GrantXP(p.UserId, tonumber(val)) else Chat("Player not found in party") end
        else
            Chat("Invalid XP format. '@All 50' or 'Alice 50'")
        end
    end)
end

-- UI updates (implementations)
function updatePartyUI()
    if not gui or not gui.PartyList then return end
    local frame = gui.PartyList
    for _,c in pairs(frame:GetChildren()) do c:Destroy() end
    local y = 0
    for i, uid in ipairs(partyOrder) do
        local c = party[uid]
        if c then
            local entry = Instance.new("Frame", frame)
            entry.Size = UDim2.new(1,-8,0,64)
            entry.Position = UDim2.new(0,4,0,y)
            entry.BackgroundColor3 = Color3.fromRGB(40,40,40)
            entry.BorderSizePixel = 0

            local name = Instance.new("TextLabel", entry)
            name.Size = UDim2.new(0.6,0,0,20)
            name.Position = UDim2.new(0,6,0,6)
            name.BackgroundTransparency = 1
            name.Text = c.DisplayName.." (Lvl "..c.Level..")"
            name.Font = Enum.Font.SourceSansBold
            name.TextColor3 = Color3.fromRGB(255,255,255)

            local hp = Instance.new("TextLabel", entry)
            hp.Size = UDim2.new(0.9,0,0,18)
            hp.Position = UDim2.new(0,6,0,28)
            hp.BackgroundTransparency = 1
            hp.Text = "HP: "..c.HP.."/"..c.MaxHP.." | AC: "..c.AC.." | XP: "..c.XP
            hp.Font = Enum.Font.SourceSans
            hp.TextColor3 = Color3.fromRGB(200,200,200)

            y = y + 70
        end
    end
    frame.CanvasSize = UDim2.new(0,0,0,y)
end

function updateMonstersUI()
    if not gui or not gui.MonstersList then return end
    local frame = gui.MonstersList
    for _,c in pairs(frame:GetChildren()) do c:Destroy() end
    local y = 0
    for i, m in ipairs(monsters) do
        local entry = Instance.new("Frame", frame)
        entry.Size = UDim2.new(1,-8,0,48)
        entry.Position = UDim2.new(0,4,0,y)
        entry.BackgroundColor3 = Color3.fromRGB(40,40,40)

        local name = Instance.new("TextLabel", entry)
        name.Size = UDim2.new(0.7,0,1,0)
        name.Position = UDim2.new(0,6,0,0)
        name.BackgroundTransparency = 1
        name.Text = "["..m.Id.."] "..m.Name.." (HP: "..math.max(0,m.HP).."/"..m.MaxHP..")"
        name.Font = Enum.Font.SourceSansBold
        name.TextColor3 = Color3.fromRGB(255,255,255)

        local targetBtn = Instance.new("TextButton", entry)
        targetBtn.Size = UDim2.new(0,70,0,28)
        targetBtn.Position = UDim2.new(1,-78,0,10)
        targetBtn.Text = "Target"
        targetBtn.BackgroundColor3 = Color3.fromRGB(90,90,90)
        targetBtn.MouseButton1Click:Connect(function()
            gui.SelectedMonster = m
            Chat("🎯 Target set to "..m.Name)
        end)

        y = y + 54
    end
    frame.CanvasSize = UDim2.new(0,0,0,y)
end

function updateTurnUI()
    if not gui or not gui.TurnLabel then return end
    if not sessionRunning then
        gui.TurnLabel.Text = "Session idle"
    else
        local uid = partyOrder[currentTurnIndex]
        local name = (party[uid] and party[uid].DisplayName) or "Unknown"
        gui.TurnLabel.Text = "Current turn: "..name.." ("..currentTurnIndex.."/"..#partyOrder..")"
    end
    updatePartyUI(); updateMonstersUI()
end

-- turn progression (uses startVote through button actions)
local function nextTurn()
    if not sessionRunning then return end
    if #partyOrder == 0 then Chat("No party members. Stopping session."); sessionRunning = false; updateTurnUI(); return end
    -- find next alive player
    local attempts = 0
    repeat
        attempts = attempts + 1
        if currentTurnIndex > #partyOrder then currentTurnIndex = 1 end
        local uid = partyOrder[currentTurnIndex]
        local char = party[uid]
        if char and char.Alive then break end
        currentTurnIndex = currentTurnIndex + 1
        if attempts > #partyOrder * 2 then
            Chat("All party members are down. Session ended.")
            sessionRunning = false
            updateTurnUI()
            return
        end
    until false
    updateTurnUI()
    awaitingAction = true
    local uid = partyOrder[currentTurnIndex]
    local char = party[uid]
    Chat("🎲 It's "..char.DisplayName.."'s turn! Party may vote on their action.")
    notify("Your Turn", char.DisplayName.." - party vote to decide action.", 4)

    -- if the party is only one person, skip voting and allow direct action via DM commands or GUI
    local eligibleCount = 0
    for _,id in ipairs(partyOrder) do if party[id] and party[id].Alive then eligibleCount = eligibleCount + 1 end end
    if eligibleCount <= 1 then
        Chat("Only one eligible voter; skip vote. Waiting for manual action.")
        return
    end
    -- optionally: automatically propose a generic vote (e.g., Attack/Cast/Use/Defend)
    local defaultOptions = {"Attack", "Cast", "Use", "Defend", "Dodge", "Flee", "Custom", "Skip"}
    startVote(LocalPlayer.UserId, (char.DisplayName.."'s action"), defaultOptions, CONFIG.VOTE_DURATION, partyOrder, function(chosenIndex)
        local choice = defaultOptions[chosenIndex] or "Skip"
        Chat("🧭 Chosen: "..choice.." - executing for "..char.DisplayName)
        -- If choice is one of the categories, map to a sub-vote or execute directly
        if choice == "Attack" then
            -- open sub-vote with Attack-specific options
            local opts = {"Weapon attack","Unarmed","Ranged","Aim & strike","Roleplay/Feint","Custom"}
            startVote(LocalPlayer.UserId, char.DisplayName.." - Attack style", opts, CONFIG.VOTE_DURATION, partyOrder, function(subIndex)
                -- map to attack behavior
                if subIndex == 1 or subIndex == 4 then
                    local weapon = nil
                    for _,it in ipairs(char.Inventory) do if it.Type=="weapon" then weapon = it; break end end
                    if not weapon then weapon = {Name="Fist", Damage="1d4", AttackBonus=0} end
                    AttackTarget(char, gui.SelectedMonster, weapon)
                elseif subIndex == 2 then
                    AttackTarget(char, gui.SelectedMonster, {Name="Unarmed", Damage="1d4", AttackBonus=0})
                elseif subIndex == 3 then
                    AttackTarget(char, gui.SelectedMonster, {Name="Thrown", Damage="1d4", AttackBonus=0})
                elseif subIndex == 5 then Chat(char.DisplayName.." roleplays a feint.") end
                -- monsters act then advance
                for _,m in ipairs(monsters) do if m.Alive then MonsterAct(m) end end
                currentTurnIndex = currentTurnIndex % #partyOrder + 1
                nextTurn()
            end)
        elseif choice == "Cast" then
            -- cast subvote or direct if no spell
            if #char.Spells == 0 then
                Chat(char.DisplayName.." knows no spells.")
                for _,m in ipairs(monsters) do if m.Alive then MonsterAct(m) end end
                currentTurnIndex = currentTurnIndex % #partyOrder + 1
                nextTurn()
            else
                local opts = {}
                for _,s in ipairs(char.Spells) do table.insert(opts, s) end
                startVote(LocalPlayer.UserId, char.DisplayName.." - Which spell?", opts, CONFIG.VOTE_DURATION, partyOrder, function(si)
                    local sk = opts[si]
                    local spell = Spells[sk]
                    if spell and spell.Damage and gui.SelectedMonster then DamageMonster(gui.SelectedMonster, rollDice(spell.Damage), spell.DamageType) end
                    if spell and spell.Heal then local h = rollDice(spell.Heal); char.HP = math.min(char.MaxHP, char.HP + h); Chat(char.DisplayName.." healed "..h) end
                    for _,m in ipairs(monsters) do if m.Alive then MonsterAct(m) end end
                    currentTurnIndex = currentTurnIndex % #partyOrder + 1
                    nextTurn()
                end)
            end
        elseif choice == "Use" then
            -- subvote for items
            local items = {}
            for _,it in ipairs(char.Inventory) do table.insert(items, it.Name) end
            if #items == 0 then Chat("No items to use."); for _,m in ipairs(monsters) do if m.Alive then MonsterAct(m) end end currentTurnIndex = currentTurnIndex % #partyOrder + 1; nextTurn() return end
            startVote(LocalPlayer.UserId, char.DisplayName.." - Use which item?", items, CONFIG.VOTE_DURATION, partyOrder, function(si)
                local itemName = items[si]
                local selectedIndex
                for i,it in ipairs(char.Inventory) do if it.Name == itemName then selectedIndex = i; break end end
                if selectedIndex then
                    local it = table.remove(char.Inventory, selectedIndex)
                    if it.Heal then local heal = rollDice(it.Heal); char.HP = math.min(char.MaxHP, char.HP + heal); Chat(char.DisplayName.." uses "..it.Name.." and heals "..heal.." HP.") end
                end
                for _,m in ipairs(monsters) do if m.Alive then MonsterAct(m) end end
                currentTurnIndex = currentTurnIndex % #partyOrder + 1
                nextTurn()
            end)
        else
            -- direct execution for Defend/Dodge/Flee/Custom/Skip
            executeChosenActionForPlayer(partyOrder[currentTurnIndex], choice)
            for _,m in ipairs(monsters) do if m.Alive then MonsterAct(m) end end
            currentTurnIndex = currentTurnIndex % #partyOrder + 1
            nextTurn()
        end
    end)
end

-- Chat processing: listens to players for votes and commands
local function getPlayerByName(name)
    if not name then return nil end
    name = name:lower()
    for _,p in ipairs(Players:GetPlayers()) do
        if p.Name:lower():sub(1,#name) == name or p.DisplayName:lower():sub(1,#name) == name then return p end
    end
end

local function onChatMessage(player, text)
    if not text or not player then return end
    local lower = tostring(text)
    -- voting input handling: only when currentVote exists
    if currentVote then
        -- accept patterns like "!vote A", "!vote 1", or single-letter "A" if enabled and voter is eligible
        local trimmed = lower:match("^%s*(.-)%s*$")
        local voteToken = nil
        -- check prefix
        if trimmed:lower():sub(1, #CONFIG.VOTE_CHAT_PREFIX) == CONFIG.VOTE_CHAT_PREFIX then
            voteToken = trimmed:sub(#CONFIG.VOTE_CHAT_PREFIX+1):match("%s*(.-)%s*$")
        else
            -- accept single letter or single-number messages
            if CONFIG.VOTE_ACCEPT_SINGLE_LETTER and (trimmed:match("^%a$") or trimmed:match("^%d$")) then voteToken = trimmed end
        end
        if voteToken then
            local ok, err = recordVote(player, voteToken)
            if not ok and err then Chat("⚠️ Vote error: "..err) end
            return
        end
    end

    -- other chat commands (join/leave/action/roll/lb)
    local l = lower:lower()
    if l:sub(1,5) == "!join" then AddPlayerToParty(player); return end
    if l:sub(1,6) == "!leave" then RemovePlayerFromParty(player); return end
    if l:sub(1,6) == "!start" and player.UserId == DM_USER_ID then
        if not sessionRunning then sessionRunning = true; currentTurnIndex = 1; Chat("🏁 Session started by DM."); updateTurnUI(); nextTurn() else Chat("Session already running.") end
        return
    end
    if l:sub(1,4) == "!end" and player.UserId == DM_USER_ID then
        sessionRunning = false; Chat("🏁 Session ended by DM."); updateTurnUI(); return
    end
    if l:sub(1,8) == "!propose " then
        -- allow players to propose a custom vote (e.g. "!propose Attack the goblin")
        local proposal = text:sub(10)
        -- DM reviews proposals; for now announce to party as a suggestion
        Chat(player.DisplayName.." proposes: "..proposal.." (DM may convert to a vote)")
        return
    end
    if l:sub(1,6) == "!roll " then
        local notat = text:sub(7)
        local r = rollDice(notat)
        Chat("🎲 "..player.DisplayName.." rolls "..notat.." -> "..tostring(r))
        return
    end
    if l:sub(1,3) == "!lb" then
        Chat("🏆 Party Leaderboard:")
        local arr = {}
        for uid,c in pairs(party) do table.insert(arr, {c.DisplayName, c.XP}) end
        table.sort(arr, function(a,b) return a[2] > b[2] end)
        for i=1, math.min(6,#arr) do Chat(i..". "..arr[i][1].." - "..arr[i][2].." XP") end
        return
    end
end

-- Chat hooks
if TextChatService and TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
    TextChatService.MessageReceived:Connect(function(msg)
        local src = msg.TextSource
        if src and src.UserId then
            local p = Players:GetPlayerByUserId(src.UserId)
            if p then onChatMessage(p, msg.Text) end
        end
    end)
else
    -- fallback to old chat
    for _,p in ipairs(Players:GetPlayers()) do
        p.Chatted:Connect(function(m) onChatMessage(p, m) end)
    end
    Players.PlayerAdded:Connect(function(p) p.Chatted:Connect(function(m) onChatMessage(p, m) end) end)
end

-- Create GUI and start
CreateGui()
updatePartyUI = updatePartyUI -- already defined
updateMonstersUI = updateMonstersUI
updateTurnUI = updateTurnUI
updatePartyUI()
updateMonstersUI()
updateTurnUI()

-- Studio convenience: add LocalPlayer and some demo NPCs if running in Studio
if RunService:IsStudio() then
    if #partyOrder == 0 then
        AddPlayerToParty(LocalPlayer)
        for i=1,2 do
            local fakeId = 900000 + i
            local pchar = MakeCharacterTemplate("NPC"..i, "NPC_Player"..i, fakeId)
            pchar.Stats.STR = 12; pchar.Stats.DEX = 10; pchar.Stats.CON = 12
            pchar.MaxHP = 10 + i*2; pchar.HP = pchar.MaxHP
            party[fakeId] = pchar
            table.insert(partyOrder, fakeId)
        end
        updatePartyUI()
    end
end

Chat("📜 D&D Bot ready (voting enabled). Commands: !join, !leave, !start (DM), !end (DM), !vote <A|1> to vote when prompted. DM GUI shows live votes.")
