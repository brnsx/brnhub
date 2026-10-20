-- =========================================================
-- MÓDULO: Lucky blocks but you steal it
-- =========================================================

-- Captura a janela principal e a biblioteca passada pelo orquestrador
local Window, Fluent = ...

if not Window then
    return warn("[Nexus Hub] Erro: Janela da UI não foi recebida pelo módulo.")
end

-- Serviços do Roblox
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

-- Remotes
local Remote = ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Replion"):WaitForChild("Remotes"):WaitForChild("TrollTarget")
local spinRemote = ReplicatedStorage:FindFirstChild("Packages") and ReplicatedStorage.Packages:FindFirstChild("Net") and ReplicatedStorage.Packages.Net:FindFirstChild("RE/GalaxyEventService/Spin")
local lavaSpinRemote = ReplicatedStorage:FindFirstChild("Packages") and ReplicatedStorage.Packages:FindFirstChild("Net") and ReplicatedStorage.Packages.Net:FindFirstChild("RE/MoltenEventService/Spin")

-- =========================================================
-- ABA MAIN (Funções do Jogo)
-- =========================================================
local MainTab = Window:AddTab({ Title = "Main", Icon = "sparkles" })

-- --- All Abusing ---
local function createPlayerToggle(toggleTitle, actionName)
    local enabled = false

    MainTab:AddToggle(toggleTitle, {
        Title = toggleTitle,
        Default = false,
        Callback = function(Value)
            enabled = Value
            if enabled then
                task.spawn(function()
                    while enabled do
                        for _, player in ipairs(Players:GetPlayers()) do
                            if not enabled then break end
                            if player ~= LocalPlayer then
                                pcall(function()
                                    Remote:FireServer(player.Name, actionName)
                                end)
                                task.wait(1)
                            end
                        end
                        task.wait(0.1)
                    end
                end)
            end
        end
    })
end

createPlayerToggle("Freeze All", "Freeze")
createPlayerToggle("Kill All", "Kill")
createPlayerToggle("Fling All", "Fling")
createPlayerToggle("Slow All", "Slow")
createPlayerToggle("Jail All", "Jail")

-- --- Stealing ---
local fastStealEnabled = false
local promptConnection = nil
local promptHooks = {}

local function hookPrompt(prompt)
    if not prompt:IsA("ProximityPrompt") or promptHooks[prompt] then return end

    promptHooks[prompt] = prompt:GetPropertyChangedSignal("HoldDuration"):Connect(function()
        if fastStealEnabled and prompt.Parent and prompt.HoldDuration ~= 0 then
            prompt.HoldDuration = 0
        end
    end)

    if fastStealEnabled then
        prompt.HoldDuration = 0
    end
end

MainTab:AddToggle("FastSteal", {
    Title = "Fast Steal",
    Default = false,
    Callback = function(Value)
        fastStealEnabled = Value

        if fastStealEnabled then
            for _, prompt in ipairs(Workspace:GetDescendants()) do
                hookPrompt(prompt)
            end

            if not promptConnection then
                promptConnection = Workspace.DescendantAdded:Connect(function(obj)
                    if fastStealEnabled then hookPrompt(obj) end
                end)
            end
        else
            if promptConnection then
                promptConnection:Disconnect()
                promptConnection = nil
            end

            for prompt, connection in pairs(promptHooks) do
                connection:Disconnect()
                promptHooks[prompt] = nil
            end
        end
    end
})

-- --- Auto Spins ---
local autoSpinEnabled = false
MainTab:AddToggle("AutoSpinGalactic", {
    Title = "Auto Spin Galactic",
    Default = false,
    Callback = function(Value)
        autoSpinEnabled = Value
        if autoSpinEnabled then
            task.spawn(function()
                while autoSpinEnabled do
                    if spinRemote then
                        pcall(function() spinRemote:FireServer() end)
                    end
                    task.wait(0.1)
                end
            end)
        end
    end
})

local autoSpinLavaEnabled = false
MainTab:AddToggle("AutoSpinLava", {
    Title = "Auto Spin Lava",
    Default = false,
    Callback = function(Value)
        autoSpinLavaEnabled = Value
        if autoSpinLavaEnabled then
            task.spawn(function()
                while autoSpinLavaEnabled do
                    if lavaSpinRemote then
                        pcall(function() lavaSpinRemote:FireServer() end)
                    end
                    task.wait(0.1)
                end
            end)
        end
    end
})

-- --- Delete Lasers ---
MainTab:AddButton({
    Title = "Delete Lasers",
    Callback = function()
        local plots = Workspace:FindFirstChild("Plots")
        if plots then
            for _, obj in ipairs(plots:GetDescendants()) do
                if obj:IsA("Folder") and (obj.Name == "Laser" or obj.Name == "LaserHitbox") then
                    obj:Destroy()
                end
            end
            Fluent:Notify({ Title = "Sucesso", Content = "Lasers deletados!", Duration = 3 })
        end
    end
})

-- =========================================================
-- ABA TARGET (Ações Indivíduais)
-- =========================================================
local TargetTab = Window:AddTab({ Title = "Target", Icon = "user" })

local selectedPlayer = nil

local function getPlayerNames()
    local names = {}
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            table.insert(names, player.Name)
        end
    end
    table.sort(names)
    return names
end

local playerDropdown = TargetTab:AddDropdown("PlayerDropdown", {
    Title = "Selecionar Jogador",
    Values = getPlayerNames(),
    Multi = false,
    Default = nil,
    Callback = function(Value)
        selectedPlayer = Value
    end
})

-- Atualiza lista de jogadores dinamicamente
task.spawn(function()
    while task.wait(2) do
        if playerDropdown then
            playerDropdown:SetValues(getPlayerNames())
        end
    end
end)

local function createTargetToggle(toggleTitle, actionName)
    local enabled = false
    local loopId = 0

    TargetTab:AddToggle(toggleTitle, {
        Title = toggleTitle,
        Default = false,
        Callback = function(Value)
            enabled = Value
            loopId += 1
            local currentLoopId = loopId

            if not enabled then return end

            task.spawn(function()
                while enabled and loopId == currentLoopId do
                    local target = selectedPlayer and Players:FindFirstChild(selectedPlayer)
                    if target and target ~= LocalPlayer then
                        pcall(function()
                            Remote:FireServer(target.Name, actionName)
                        end)
                    end
                    task.wait(1)
                end
            end)
        end
    })
end

createTargetToggle("Freeze Target", "Freeze")
createTargetToggle("Kill Target", "Kill")
createTargetToggle("Slow Target", "Slow")
createTargetToggle("Jail Target", "Jail")
createTargetToggle("Fling Target", "Fling")

-- =========================================================
-- ABA MOVEMENT (Movimentação)
-- =========================================================
local MovementTab = Window:AddTab({ Title = "Movement", Icon = "move" })

local WalkSpeedValue = 16
local JumpHeightValue = 7.2

local function getCharacter() return LocalPlayer.Character end
local function getHumanoid()
    local char = getCharacter()
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function applyWalkSpeed()
    local hum = getHumanoid()
    if hum then hum.WalkSpeed = WalkSpeedValue end
end

local function applyJumpHeight()
    local hum = getHumanoid()
    if hum then
        hum.UseJumpPower = false
        hum.JumpHeight = JumpHeightValue
    end
end

RunService.Heartbeat:Connect(function()
    applyWalkSpeed()
    applyJumpHeight()
end)

MovementTab:AddSlider("WalkSpeedSlider", {
    Title = "WalkSpeed",
    Min = 16, Max = 200, Default = 16, Rounding = 0,
    Callback = function(Value)
        WalkSpeedValue = Value
        applyWalkSpeed()
    end
})

MovementTab:AddSlider("JumpHeightSlider", {
    Title = "Jump Height",
    Min = 7, Max = 150, Default = 7, Rounding = 0,
    Callback = function(Value)
        JumpHeightValue = Value
        applyJumpHeight()
    end
})

-- --- Float Platform ---
local floatEnabled = false
local floatConnection = nil

MovementTab:AddToggle("FloatToggle", {
    Title = "Float",
    Default = false,
    Callback = function(Value)
        floatEnabled = Value
        if floatConnection then floatConnection:Disconnect() floatConnection = nil end

        if floatEnabled then
            floatConnection = RunService.Heartbeat:Connect(function()
                local char = getCharacter()
                local root = char and char:FindFirstChild("HumanoidRootPart")
                if root then
                    local float = char:FindFirstChild("RayfieldFloatPlatform")
                    if not float then
                        float = Instance.new("Part")
                        float.Name = "RayfieldFloatPlatform"
                        float.Size = Vector3.new(6, 0.5, 6)
                        float.Transparency = 1
                        float.Anchored = true
                        float.CanCollide = true
                        float.Parent = char
                    end
                    float.CFrame = root.CFrame * CFrame.new(0, -3.5, 0)
                end
            end)
        else
            local char = getCharacter()
            local float = char and char:FindFirstChild("RayfieldFloatPlatform")
            if float then float:Destroy() end
        end
    end
})

-- --- Noclip ---
local noclipEnabled = false
local noclipConnection = nil

MovementTab:AddToggle("NoclipToggle", {
    Title = "Noclip",
    Default = false,
    Callback = function(Value)
        noclipEnabled = Value
        if noclipConnection then noclipConnection:Disconnect() noclipConnection = nil end

        if noclipEnabled then
            noclipConnection = RunService.Stepped:Connect(function()
                local char = getCharacter()
                if char then
                    for _, part in ipairs(char:GetDescendants()) do
                        if part:IsA("BasePart") then part.CanCollide = false end
                    end
                end
            end)
        end
    end
})

-- --- Fly ---
local flyEnabled = false
local flyConnection = nil
local flyBodyVelocity = nil
local flyBodyGyro = nil

local function stopFly()
    if flyConnection then flyConnection:Disconnect() flyConnection = nil end
    if flyBodyVelocity then flyBodyVelocity:Destroy() flyBodyVelocity = nil end
    if flyBodyGyro then flyBodyGyro:Destroy() flyBodyGyro = nil end
end

MovementTab:AddToggle("FlyToggle", {
    Title = "Fly",
    Default = false,
    Callback = function(Value)
        flyEnabled = Value
        if not flyEnabled then return stopFly() end

        stopFly()
        local char = getCharacter()
        local root = char and char:FindFirstChild("HumanoidRootPart")
        local hum = getHumanoid()
        if not root or not hum then return end

        flyBodyVelocity = Instance.new("BodyVelocity")
        flyBodyVelocity.MaxForce = Vector3.new(1e5, 1e5, 1e5)
        flyBodyVelocity.Velocity = Vector3.zero
        flyBodyVelocity.Parent = root

        flyBodyGyro = Instance.new("BodyGyro")
        flyBodyGyro.MaxTorque = Vector3.new(1e5, 1e5, 1e5)
        flyBodyGyro.P = 1e4
        flyBodyGyro.CFrame = root.CFrame
        flyBodyGyro.Parent = root

        flyConnection = RunService.RenderStepped:Connect(function()
            if not flyEnabled or not root.Parent then return stopFly() end
            local camera = Workspace.CurrentCamera
            local direction = Vector3.zero

            if hum.MoveDirection.Magnitude > 0 then
                direction = camera.CFrame.LookVector * hum.MoveDirection.Magnitude
            end

            if UserInputService:IsKeyDown(Enum.KeyCode.Space) then direction += Vector3.new(0, 1, 0) end
            if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then direction -= Vector3.new(0, 1, 0) end

            flyBodyVelocity.Velocity = direction * 60
            flyBodyGyro.CFrame = camera.CFrame
        end)
    end
})

-- --- Infinite Jump ---
local infiniteJumpEnabled = false
UserInputService.JumpRequest:Connect(function()
    if infiniteJumpEnabled then
        local hum = getHumanoid()
        if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
    end
end)

MovementTab:AddToggle("InfJumpToggle", {
    Title = "Infinite Jump",
    Default = false,
    Callback = function(Value)
        infiniteJumpEnabled = Value
    end
})

-- --- TP Through Wall ---
local tpWallEnabled = false
local tpWallDistance = 8

MovementTab:AddSlider("TpWallDistance", {
    Title = "TP Distance (Press T)",
    Min = 2, Max = 30, Default = 8, Rounding = 0,
    Callback = function(Value) tpWallDistance = Value end
})

MovementTab:AddToggle("TpWallToggle", {
    Title = "TP Through Wall (Key T)",
    Default = false,
    Callback = function(Value) tpWallEnabled = Value end
})

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed or not tpWallEnabled or input.KeyCode ~= Enum.KeyCode.T then return end

    local char = getCharacter()
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then
        local direction = Workspace.CurrentCamera.CFrame.LookVector
        local raycastParams = RaycastParams.new()
        raycastParams.FilterType = Enum.RaycastFilterType.Exclude
        raycastParams.FilterDescendantsInstances = {char}

        local result = Workspace:Raycast(root.Position, direction * tpWallDistance, raycastParams)
        if result then
            local destination = result.Position + direction * tpWallDistance
            root.CFrame = CFrame.new(destination, destination + direction)
        else
            root.CFrame = root.CFrame + direction * tpWallDistance
        end
    end
end)
