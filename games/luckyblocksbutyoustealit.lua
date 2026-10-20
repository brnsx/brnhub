local Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Remote = ReplicatedStorage.Packages.Replion.Remotes.TrollTarget

local Window = Rayfield:CreateWindow({
    Name = "BrN Hub",
    Subtitle = "By BreNo",
    Theme = "Amethyst",
})

local MainTab = Window:CreateTab({
    Name = " Main",
    Icon = nil,
})

MainTab:CreateSection("All Abusing")

local function createPlayerToggle(toggleName, actionName)
    local enabled = false

    MainTab:CreateToggle({
        Name = " " .. toggleName,
        CurrentValue = false,

        Callback = function(Value)
            enabled = Value

            if enabled then
                task.spawn(function()
                    while enabled do
                        for _, player in ipairs(Players:GetPlayers()) do
                            if not enabled then
                                break
                            end

                            if player ~= LocalPlayer then
                                Remote:FireServer(player.Name, actionName)
                                task.wait(1)
                            end
                        end

                        task.wait(0.1)
                    end
                end)
            end
        end,
    })
end

createPlayerToggle("Freeze All", "Freeze")
createPlayerToggle("Kill All", "Kill")
createPlayerToggle("Fling All", "Fling")
createPlayerToggle("Slow All", "Slow")
createPlayerToggle("Jail All", "Jail")

MainTab:CreateSection("Stealing")

local fastStealEnabled = false
local promptConnection = nil
local promptHooks = {}

local function hookPrompt(prompt)
    if not prompt:IsA("ProximityPrompt") then
        return
    end

    if promptHooks[prompt] then
        return
    end

    promptHooks[prompt] =
        prompt:GetPropertyChangedSignal("HoldDuration"):Connect(function()
            if fastStealEnabled
                and prompt.Parent
                and prompt.HoldDuration ~= 0 then
                prompt.HoldDuration = 0
            end
        end)

    if fastStealEnabled then
        prompt.HoldDuration = 0
    end
end

MainTab:CreateToggle({
    Name = " Fast Steal",
    CurrentValue = false,

    Callback = function(Value)
        fastStealEnabled = Value

        if fastStealEnabled then
            for _, prompt in ipairs(Workspace:GetDescendants()) do
                hookPrompt(prompt)
            end

            if not promptConnection then
                promptConnection = Workspace.DescendantAdded:Connect(function(obj)
                    if fastStealEnabled then
                        hookPrompt(obj)
                    end
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
    end,
})

-- Auto Spin Galactic
local autoSpinEnabled = false

local spinRemote = ReplicatedStorage
    :WaitForChild("Packages")
    :WaitForChild("Net")
    :FindFirstChild("RE/GalaxyEventService/Spin")

MainTab:CreateToggle({
    Name = " Auto Spin Galactic",
    CurrentValue = false,

    Callback = function(Value)
        autoSpinEnabled = Value

        if autoSpinEnabled then
            task.spawn(function()
                while autoSpinEnabled do
                    if spinRemote then
                        pcall(function()
                            spinRemote:FireServer()
                        end)
                    end

                    task.wait(0.1)
                end
            end)
        end
    end,
})

-- Auto Spin Lava
local autoSpinLavaEnabled = false

local lavaSpinRemote = ReplicatedStorage
    :WaitForChild("Packages")
    :WaitForChild("Net")
    :FindFirstChild("RE/MoltenEventService/Spin")

MainTab:CreateToggle({
    Name = " Auto Spin Lava",
    CurrentValue = false,

    Callback = function(Value)
        autoSpinLavaEnabled = Value

        if autoSpinLavaEnabled then
            task.spawn(function()
                while autoSpinLavaEnabled do
                    if lavaSpinRemote then
                        pcall(function()
                            lavaSpinRemote:FireServer()
                        end)
                    end

                    task.wait(0.1)
                end
            end)
        end
    end,
})

-- Delete Lasers
MainTab:CreateToggle({
    Name = " Delete Lasers",
    CurrentValue = false,

    Callback = function(Value)
        if Value then
            local plots = Workspace:FindFirstChild("Plots")

            if plots then
                for _, obj in ipairs(plots:GetDescendants()) do
                    if obj:IsA("Folder") and (
                        obj.Name == "Laser" or
                        obj.Name == "LaserHitbox"
                    ) then
                        obj:Destroy()
                    end
                end
            end
        end
    end,
})

-- Target Tab
local TargetTab = Window:CreateTab({
    Name = " Target",
    Icon = nil,
})

TargetTab:CreateSection("Select Target")

local selectedPlayer = nil
local playerDropdown = nil

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

playerDropdown = TargetTab:CreateDropdown({
    Name = " Select Player",
    Options = getPlayerNames(),
    CurrentOption = {},
    MultipleOptions = false,

    Callback = function(Option)
        if typeof(Option) == "table" then
            selectedPlayer = Option[1]
        else
            selectedPlayer = Option
        end
    end,
})

task.spawn(function()
    while task.wait(1) do
        local names = getPlayerNames()

        if playerDropdown and playerDropdown.Refresh then
            playerDropdown:Refresh(names)
        end

        if selectedPlayer and not Players:FindFirstChild(selectedPlayer) then
            selectedPlayer = nil
        end
    end
end)

TargetTab:CreateSection("Target Actions")

local function createTargetToggle(toggleName, actionName)
    local enabled = false
    local loopId = 0

    TargetTab:CreateToggle({
        Name = " " .. toggleName,
        CurrentValue = false,

        Callback = function(Value)
            enabled = Value
            loopId += 1

            local currentLoopId = loopId

            if not enabled then
                return
            end

            task.spawn(function()
                while enabled and loopId == currentLoopId do
                    local targetName = selectedPlayer
                    local target = targetName
                        and Players:FindFirstChild(targetName)

                    if target and target ~= LocalPlayer then
                        pcall(function()
                            Remote:FireServer(target.Name, actionName)
                        end)
                    end

                    task.wait(1)
                end
            end)
        end,
    })
end

createTargetToggle("Freeze", "Freeze")
createTargetToggle("Kill", "Kill")
createTargetToggle("Slow", "Slow")
createTargetToggle("Jail", "Jail")
createTargetToggle("Fling", "Fling")

-- Movement Tab
local MovementTab = Window:CreateTab({
    Name = " Movement",
    Icon = nil,
})

MovementTab:CreateSection("Movement Settings")

local WalkSpeedValue = 16
local JumpHeightValue = 7.2

local function getCharacter()
    return LocalPlayer.Character
end

local function getHumanoid()
    local character = getCharacter()
    return character and character:FindFirstChildOfClass("Humanoid")
end

local function applyWalkSpeed()
    local humanoid = getHumanoid()

    if humanoid then
        humanoid.WalkSpeed = WalkSpeedValue
    end
end

local function applyJumpHeight()
    local humanoid = getHumanoid()

    if humanoid then
        humanoid.UseJumpPower = false
        humanoid.JumpHeight = JumpHeightValue
    end
end

RunService.Heartbeat:Connect(function()
    applyWalkSpeed()
    applyJumpHeight()
end)

MovementTab:CreateSlider({
    Name = " Walkspeed",
    Range = {16, 200},
    Increment = 1,
    Suffix = "Speed",
    CurrentValue = 16,

    Callback = function(Value)
        WalkSpeedValue = Value
        applyWalkSpeed()
    end,
})

MovementTab:CreateSlider({
    Name = " Jump Height",
    Range = {7, 150},
    Increment = 1,
    Suffix = "Height",
    CurrentValue = 7,

    Callback = function(Value)
        JumpHeightValue = Value
        applyJumpHeight()
    end,
})

LocalPlayer.CharacterAdded:Connect(function(character)
    local humanoid = character:WaitForChild("Humanoid", 10)

    if humanoid then
        task.wait(0.2)
        applyWalkSpeed()
        applyJumpHeight()
    end
end)

MovementTab:CreateSection("Movement Toggles")

-- Float
local floatEnabled = false
local floatConnection = nil

MovementTab:CreateToggle({
    Name = " Float",
    CurrentValue = false,

    Callback = function(Value)
        floatEnabled = Value

        if floatConnection then
            floatConnection:Disconnect()
            floatConnection = nil
        end

        if floatEnabled then
            floatConnection = RunService.Heartbeat:Connect(function()
                local character = getCharacter()
                local root = character
                    and character:FindFirstChild("HumanoidRootPart")

                if root then
                    local float = character:FindFirstChild(
                        "RayfieldFloatPlatform"
                    )

                    if not float then
                        float = Instance.new("Part")
                        float.Name = "RayfieldFloatPlatform"
                        float.Size = Vector3.new(6, 0.5, 6)
                        float.Transparency = 1
                        float.Anchored = true
                        float.CanCollide = true
                        float.Parent = character
                    end

                    float.CFrame = root.CFrame * CFrame.new(0, -3.5, 0)
                end
            end)
        else
            local character = getCharacter()
            local float = character
                and character:FindFirstChild("RayfieldFloatPlatform")

            if float then
                float:Destroy()
            end
        end
    end,
})

-- Noclip
local noclipEnabled = false
local noclipConnection = nil

MovementTab:CreateToggle({
    Name = " Noclip",
    CurrentValue = false,

    Callback = function(Value)
        noclipEnabled = Value

        if noclipConnection then
            noclipConnection:Disconnect()
            noclipConnection = nil
        end

        if noclipEnabled then
            noclipConnection = RunService.Stepped:Connect(function()
                local character = getCharacter()

                if character then
                    for _, part in ipairs(character:GetDescendants()) do
                        if part:IsA("BasePart") then
                            part.CanCollide = false
                        end
                    end
                end
            end)
        else
            local character = getCharacter()

            if character then
                for _, part in ipairs(character:GetDescendants()) do
                    if part:IsA("BasePart")
                        and part.Name ~= "HumanoidRootPart" then
                        part.CanCollide = true
                    end
                end
            end
        end
    end,
})

-- Fly
local flyEnabled = false
local flyConnection = nil
local flyBodyVelocity = nil
local flyBodyGyro = nil

local function stopFly()
    if flyConnection then
        flyConnection:Disconnect()
        flyConnection = nil
    end

    if flyBodyVelocity then
        flyBodyVelocity:Destroy()
        flyBodyVelocity = nil
    end

    if flyBodyGyro then
        flyBodyGyro:Destroy()
        flyBodyGyro = nil
    end
end

local function startFly()
    stopFly()

    local character = getCharacter()
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = getHumanoid()

    if not root or not humanoid then
        return
    end

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
        if not flyEnabled or not root.Parent then
            stopFly()
            return
        end

        local camera = Workspace.CurrentCamera
        local direction = Vector3.zero

        if humanoid.MoveDirection.Magnitude > 0 then
            direction = camera.CFrame.LookVector
                * humanoid.MoveDirection.Magnitude
        end

        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
            direction += Vector3.new(0, 1, 0)
        end

        if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
            direction -= Vector3.new(0, 1, 0)
        end

        flyBodyVelocity.Velocity = direction * 60
        flyBodyGyro.CFrame = camera.CFrame
    end)
end

MovementTab:CreateToggle({
    Name = " Fly",
    CurrentValue = false,

    Callback = function(Value)
        flyEnabled = Value

        if flyEnabled then
            startFly()
        else
            stopFly()
        end
    end,
})

-- Infinite Jump
local infiniteJumpEnabled = false

UserInputService.JumpRequest:Connect(function()
    if infiniteJumpEnabled then
        local humanoid = getHumanoid()

        if humanoid then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end
end)

MovementTab:CreateToggle({
    Name = " Infinite Jump",
    CurrentValue = false,

    Callback = function(Value)
        infiniteJumpEnabled = Value
    end,
})

-- Tp Through Wall
local tpWallEnabled = false
local tpWallDistance = 8

MovementTab:CreateSlider({
    Name = " TP Through Wall Distance",
    Range = {2, 30},
    Increment = 1,
    Suffix = "Studs",
    CurrentValue = 8,

    Callback = function(Value)
        tpWallDistance = Value
    end,
})

MovementTab:CreateToggle({
    Name = " Tp Through Wall",
    CurrentValue = false,

    Callback = function(Value)
        tpWallEnabled = Value
    end,
})

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed or not tpWallEnabled then
        return
    end

    if input.KeyCode == Enum.KeyCode.T then
        local character = getCharacter()
        local root = character and character:FindFirstChild("HumanoidRootPart")

        if root then
            local direction = Workspace.CurrentCamera.CFrame.LookVector
            local origin = root.Position

            local raycastParams = RaycastParams.new()
            raycastParams.FilterType = Enum.RaycastFilterType.Exclude
            raycastParams.FilterDescendantsInstances = {character}

            local result = Workspace:Raycast(
                origin,
                direction * tpWallDistance,
                raycastParams
            )

            if result then
                local destination = result.Position
                    + direction * tpWallDistance

                root.CFrame = CFrame.new(
                    destination,
                    destination + direction
                )
            else
                root.CFrame = root.CFrame
                    + direction * tpWallDistance
            end
        end
    end
end)
