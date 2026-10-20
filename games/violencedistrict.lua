--====================================================
-- Violence District - BrN Hub
-- UI: Rayfield GEN2 (https://sirius.menu/gen2)
-- Features:
--   * ESP: survivors, killer, generators, pallets,
--          windows, lockers, hooks
--   * Auto repair (walks to a generator, holds click)
--   * Auto skill check (experimental, reads the GUI)
--   * Skill check debug print (for calibration)
--   * Speed boost (speedboost attribute multiplier)
--   * Fullbright
--   * Remove fog
--   * Unload script
-- Built from scanner output:
--   Workspace.Map.newGenerators.Generator
--   PlayerGui.SkillCheckPromptGui.Check (Line / Goal)
--====================================================

--====================================================
-- Services
--====================================================
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Lighting = game:GetService("Lighting")
local CoreGui = game:GetService("CoreGui")
local VirtualInputManager = game:GetService("VirtualInputManager")
local PathfindingService = game:GetService("PathfindingService")

local LocalPlayer = Players.LocalPlayer

--====================================================
-- State
--====================================================
local running = true

local espPlayers = false
local espKiller = false
local espGenerators = false
local espPallets = false
local espWindows = false
local espLockers = false
local espHooks = false

local autoSkillCheck = false
local skillCheckAimAngle = 109
local skillCheckDelay = 0
local skillSpeed = 300
local skillLastRot = nil
local skillLastTime = nil
local skillCheckDebug = false
local lastPress = 0
local lastDebug = 0

local speedEnabled = false
local speedMultiplier = 1.3

local fullbrightEnabled = false
local lightingSaved = false
local savedLighting = {}

local autoRepair = false
local mouseHeld = false
local repairBlacklist = {}

local noFogEnabled = false
local fogSaved = false
local savedFog = {}

local espEntries = {}
local connections = {}

--====================================================
-- Colors
--====================================================
local colorSurvivor = Color3.fromRGB(80, 255, 120)
local colorKiller = Color3.fromRGB(255, 50, 50)
local colorGenerator = Color3.fromRGB(255, 220, 60)
local colorPallet = Color3.fromRGB(255, 150, 50)
local colorWindow = Color3.fromRGB(80, 200, 255)
local colorLocker = Color3.fromRGB(190, 120, 255)
local colorHook = Color3.fromRGB(255, 90, 200)

--====================================================
-- ESP container
--====================================================
local espFolder = Instance.new("Folder")
espFolder.Name = "VDEspFolder"

local okHui, huiParent = pcall(function()
    return gethui()
end)

if okHui and huiParent then
    espFolder.Parent = huiParent
else
    espFolder.Parent = CoreGui
end

--====================================================
-- Rayfield GEN2
--====================================================
local Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()

local Window = Rayfield:CreateWindow({
    Name = "BrN Hub",
    Subtitle = "By BreNo",
    SidebarLayout = true,
})

local TabEsp = Window:CreateTab({
    Name = "ESP",
    Icon = "eye",
})

local TabGenerator = Window:CreateTab({
    Name = "Generator",
    Icon = "zap",
})

local TabPlayer = Window:CreateTab({
    Name = "Player",
    Icon = "user",
})

--====================================================
-- Helpers
--====================================================
local function getRoot()
    local character = LocalPlayer.Character

    if character == nil then
        return nil
    end

    return character:FindFirstChild("HumanoidRootPart")
end

local function getAdornee(target)
    if target:IsA("BasePart") then
        return target
    end

    if target:IsA("Model") then
        if target.PrimaryPart then
            return target.PrimaryPart
        end

        return target:FindFirstChildWhichIsA("BasePart", true)
    end

    return nil
end

local function angleDiff(a, b)
    local difference = (a - b) % 360

    if difference > 180 then
        difference = difference - 360
    end

    return difference
end

--====================================================
-- ESP: build / remove
--====================================================
local function makeEsp(target, color, text)
    local adornee = getAdornee(target)

    if adornee == nil then
        return nil
    end

    local highlight = Instance.new("Highlight")
    highlight.Adornee = target
    highlight.FillColor = color
    highlight.OutlineColor = color
    highlight.FillTransparency = 0.7
    highlight.OutlineTransparency = 0
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Parent = espFolder

    local billboard = Instance.new("BillboardGui")
    billboard.Adornee = adornee
    billboard.Size = UDim2.new(0, 140, 0, 22)
    billboard.StudsOffset = Vector3.new(0, 3, 0)
    billboard.AlwaysOnTop = true
    billboard.Parent = espFolder

    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 1, 0)
    label.BackgroundTransparency = 1
    label.TextColor3 = color
    label.TextStrokeTransparency = 0
    label.TextSize = 13
    label.Font = Enum.Font.GothamBold
    label.Text = text
    label.Parent = billboard

    return {
        highlight = highlight,
        billboard = billboard,
        label = label,
        adornee = adornee,
        text = text,
    }
end

local function removeEsp(target)
    local entry = espEntries[target]

    if entry == nil then
        return
    end

    entry.highlight:Destroy()
    entry.billboard:Destroy()

    espEntries[target] = nil
end

local function clearAllEsp()
    for target in pairs(espEntries) do
        removeEsp(target)
    end
end

--====================================================
-- ESP: find targets
--====================================================
local function collectTargets()
    local wanted = {}

    --------------------------------------------------
    -- Players (killer is guessed from the team name)
    --------------------------------------------------
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.Character then
            local teamName = ""

            if player.Team then
                teamName = string.lower(player.Team.Name)
            end

            local isKiller = string.find(teamName, "killer", 1, true) ~= nil

            if isKiller and espKiller then
                wanted[player.Character] = {
                    color = colorKiller,
                    text = "KILLER | " .. player.Name,
                }
            end

            if not isKiller and espPlayers then
                wanted[player.Character] = {
                    color = colorSurvivor,
                    text = player.Name,
                }
            end
        end
    end

    --------------------------------------------------
    -- Map objects
    --------------------------------------------------
    local map = Workspace:FindFirstChild("Map")

    if map == nil then
        return wanted
    end

    for _, descendant in ipairs(map:GetDescendants()) do
        if descendant:IsA("Model") then
            local lowerName = string.lower(descendant.Name)

            if espGenerators and lowerName == "generator" then
                wanted[descendant] = {
                    color = colorGenerator,
                    text = "Generator",
                }
            elseif espPallets and string.find(lowerName, "pallet", 1, true) then
                wanted[descendant] = {
                    color = colorPallet,
                    text = "Pallet",
                }
            elseif espWindows and lowerName == "window" then
                wanted[descendant] = {
                    color = colorWindow,
                    text = "Window",
                }
            elseif espLockers and lowerName == "locker" then
                wanted[descendant] = {
                    color = colorLocker,
                    text = "Locker",
                }
            elseif espHooks and string.find(lowerName, "hook", 1, true) then
                wanted[descendant] = {
                    color = colorHook,
                    text = "Hook",
                }
            end
        end
    end

    return wanted
end

local function refreshEsp()
    local wanted = collectTargets()

    for target in pairs(espEntries) do
        if wanted[target] == nil or target.Parent == nil then
            removeEsp(target)
        end
    end

    for target, info in pairs(wanted) do
        if espEntries[target] == nil then
            espEntries[target] = makeEsp(target, info.color, info.text)
        end
    end
end

local function updateEspLabels()
    local root = getRoot()

    if root == nil then
        return
    end

    for _, entry in pairs(espEntries) do
        if entry.adornee and entry.adornee.Parent then
            local distance = math.floor((entry.adornee.Position - root.Position).Magnitude)
            entry.label.Text = entry.text .. " [" .. tostring(distance) .. "]"
        end
    end
end

--====================================================
-- Fullbright
--====================================================
local function saveLighting()
    if lightingSaved then
        return
    end

    lightingSaved = true

    savedLighting = {
        Brightness = Lighting.Brightness,
        ClockTime = Lighting.ClockTime,
        FogStart = Lighting.FogStart,
        FogEnd = Lighting.FogEnd,
        Ambient = Lighting.Ambient,
        OutdoorAmbient = Lighting.OutdoorAmbient,
        GlobalShadows = Lighting.GlobalShadows,
    }
end

local function applyFullbright()
    Lighting.Brightness = 2
    Lighting.ClockTime = 14
    Lighting.FogStart = 100000
    Lighting.FogEnd = 100000
    Lighting.Ambient = Color3.fromRGB(178, 178, 178)
    Lighting.OutdoorAmbient = Color3.fromRGB(178, 178, 178)
    Lighting.GlobalShadows = false
end

local function restoreLighting()
    if not lightingSaved then
        return
    end

    Lighting.Brightness = savedLighting.Brightness
    Lighting.ClockTime = savedLighting.ClockTime
    Lighting.FogStart = savedLighting.FogStart
    Lighting.FogEnd = savedLighting.FogEnd
    Lighting.Ambient = savedLighting.Ambient
    Lighting.OutdoorAmbient = savedLighting.OutdoorAmbient
    Lighting.GlobalShadows = savedLighting.GlobalShadows

    lightingSaved = false
end

--====================================================
-- Remove fog
--====================================================
local function saveFog()
    if fogSaved then
        return
    end

    fogSaved = true

    local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")

    savedFog = {
        FogStart = Lighting.FogStart,
        FogEnd = Lighting.FogEnd,
        Density = atmosphere and atmosphere.Density or nil,
        Haze = atmosphere and atmosphere.Haze or nil,
    }
end

local function applyNoFog()
    Lighting.FogStart = 100000
    Lighting.FogEnd = 100000

    local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")

    if atmosphere then
        atmosphere.Density = 0
        atmosphere.Haze = 0
    end
end

local function restoreFog()
    if not fogSaved then
        return
    end

    Lighting.FogStart = savedFog.FogStart
    Lighting.FogEnd = savedFog.FogEnd

    local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")

    if atmosphere and savedFog.Density ~= nil then
        atmosphere.Density = savedFog.Density
        atmosphere.Haze = savedFog.Haze
    end

    fogSaved = false
end

--====================================================
-- Auto skill check
--====================================================
local function getCheck(guiName)
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")

    if playerGui == nil then
        return nil
    end

    local gui = playerGui:FindFirstChild(guiName)

    if gui == nil then
        return nil
    end

    if gui:IsA("ScreenGui") and not gui.Enabled then
        return nil
    end

    local check = gui:FindFirstChild("Check")

    if check == nil or not check.Visible then
        return nil
    end

    return check
end

local function pressSpace()
    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.Space, false, game)
    task.wait(0.03)
    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.Space, false, game)
end

local function handleSkillCheck()
    for _, guiName in ipairs({"SkillCheckPromptGui", "SkillCheckPromptGui-con"}) do
        local check = getCheck(guiName)

        if check then
            local line = check:FindFirstChild("Line")
            local goal = check:FindFirstChild("Goal")

            if line and goal then
                local difference = line.Rotation - goal.Rotation

                local now = os.clock()
                local frameTime = 1 / 60

                if skillLastTime ~= nil and skillLastRot ~= nil and line.Rotation > skillLastRot then
                    frameTime = now - skillLastTime
                    local measured = (line.Rotation - skillLastRot) / frameTime
                    skillSpeed = skillSpeed * 0.6 + measured * 0.4
                end

                skillLastRot = line.Rotation
                skillLastTime = now

                local landing = difference
                    + skillSpeed * (skillCheckDelay / 1000)
                    + skillSpeed * frameTime / 2

                if skillCheckDebug and os.clock() - lastDebug > 0.25 then
                    lastDebug = os.clock()

                    print(
                        "[VD] " .. guiName
                        .. " | Line=" .. tostring(line.Rotation)
                        .. " | Goal=" .. tostring(goal.Rotation)
                        .. " | diff=" .. tostring(difference)
                        .. " | speed=" .. tostring(math.floor(skillSpeed))
                        .. " | landing=" .. tostring(math.floor(landing))
                    )
                end

                if autoSkillCheck
                    and landing >= skillCheckAimAngle
                    and difference <= 150
                    and os.clock() - lastPress > 0.6
                then
                    lastPress = os.clock()
                    task.spawn(pressSpace)
                end
            end
        end
    end
end

--====================================================
-- Auto repair (walks to a generator, holds left click)
--====================================================
local function setMouseHeld(down)
    if down == mouseHeld then
        return
    end

    mouseHeld = down

    local camera = Workspace.CurrentCamera

    if camera == nil then
        return
    end

    local size = camera.ViewportSize

    VirtualInputManager:SendMouseButtonEvent(
        size.X / 2,
        size.Y / 2,
        0,
        down,
        game,
        0
    )
end

local function findRepairPoint()
    local root = getRoot()

    if root == nil then
        return nil
    end

    local map = Workspace:FindFirstChild("Map")

    if map == nil then
        return nil
    end

    local best = nil
    local bestDistance = math.huge

    for _, descendant in ipairs(map:GetDescendants()) do
        if descendant:IsA("BasePart") and string.find(descendant.Name, "GeneratorPoint", 1, true) then
            local blockedUntil = repairBlacklist[descendant.Parent]
            local blocked = blockedUntil ~= nil and os.clock() < blockedUntil

            if not blocked and descendant:GetAttribute("IsRepairing") ~= true then
                local distance = (descendant.Position - root.Position).Magnitude

                if distance < bestDistance then
                    best = descendant
                    bestDistance = distance
                end
            end
        end
    end

    return best
end

local function isRepairingNow()
    local character = LocalPlayer.Character

    if character == nil then
        return false
    end

    local script = character:FindFirstChild("CheckInterractable")

    if script == nil then
        return false
    end

    return script:GetAttribute("isRepairing") == true
end

local function walkTo(target)
    local character = LocalPlayer.Character

    if character == nil then
        return
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = getRoot()

    if humanoid == nil or root == nil then
        return
    end

    local path = PathfindingService:CreatePath({
        AgentRadius = 2,
        AgentHeight = 5,
        AgentCanJump = false,
    })

    local ok = pcall(function()
        path:ComputeAsync(root.Position, target.Position)
    end)

    if not ok or path.Status ~= Enum.PathStatus.Success then
        humanoid:MoveTo(target.Position)
        task.wait(2)
        return
    end

    for _, waypoint in ipairs(path:GetWaypoints()) do
        if not running or not autoRepair then
            return
        end

        if (target.Position - root.Position).Magnitude <= 2.5 then
            return
        end

        humanoid:MoveTo(waypoint.Position)

        local finished = false

        local finishedConnection = humanoid.MoveToFinished:Connect(function()
            finished = true
        end)

        local started = os.clock()

        while not finished and os.clock() - started < 2 and running and autoRepair do
            task.wait(0.05)
        end

        finishedConnection:Disconnect()
    end
end

local function repairAt(point)
    local root = getRoot()

    if root == nil then
        return
    end

    root.CFrame = CFrame.lookAt(
        root.Position,
        Vector3.new(point.Position.X, root.Position.Y, point.Position.Z)
    )

    setMouseHeld(true)

    local started = os.clock()

    while running and autoRepair and not isRepairingNow() and os.clock() - started < 3 do
        task.wait(0.1)
    end

    if not isRepairingNow() then
        setMouseHeld(false)
        repairBlacklist[point.Parent] = os.clock() + 30
        return
    end

    while running and autoRepair and isRepairingNow() do
        task.wait(0.25)
    end

    setMouseHeld(false)
    repairBlacklist[point.Parent] = os.clock() + 90
end

task.spawn(function()
    while running do
        if autoRepair then
            local character = LocalPlayer.Character

            if character and character:GetAttribute("Knocked") ~= true then
                local point = findRepairPoint()

                if point then
                    walkTo(point)

                    local root = getRoot()

                    if autoRepair and root and (point.Position - root.Position).Magnitude <= 4 then
                        repairAt(point)
                    end
                end
            end
        else
            setMouseHeld(false)
        end

        task.wait(0.5)
    end
end)

--====================================================
-- Loops
--====================================================
table.insert(
    connections,
    RunService.Heartbeat:Connect(function()
        if not running then
            return
        end

        if autoSkillCheck or skillCheckDebug then
            handleSkillCheck()
        end

        if fullbrightEnabled then
            applyFullbright()
        end

        if noFogEnabled then
            applyNoFog()
        end
    end)
)

local function setSpeedBoost(amount)
    local character = LocalPlayer.Character

    if character == nil then
        return
    end

    if character:GetAttribute("speedboost") == nil then
        return
    end

    if character:GetAttribute("speedboost") ~= amount then
        character:SetAttribute("speedboost", amount)
    end
end

table.insert(
    connections,
    RunService.Heartbeat:Connect(function()
        if not running or not speedEnabled then
            return
        end

        setSpeedBoost(speedMultiplier)
    end)
)

task.spawn(function()
    local tick = 0

    while running do
        tick = tick + 1

        if tick % 4 == 1 then
            refreshEsp()
        end

        updateEspLabels()

        task.wait(0.5)
    end
end)

--====================================================
-- UI: ESP tab
--====================================================
TabEsp:CreateToggle({
    Name = "Survivor ESP",
    CurrentValue = false,
    Callback = function(on)
        espPlayers = on
        refreshEsp()
    end,
})

TabEsp:CreateToggle({
    Name = "Killer ESP",
    Description = "Killer is guessed from the team name",
    CurrentValue = false,
    Callback = function(on)
        espKiller = on
        refreshEsp()
    end,
})

TabEsp:CreateToggle({
    Name = "Generator ESP",
    CurrentValue = false,
    Callback = function(on)
        espGenerators = on
        refreshEsp()
    end,
})

TabEsp:CreateToggle({
    Name = "Pallet ESP",
    CurrentValue = false,
    Callback = function(on)
        espPallets = on
        refreshEsp()
    end,
})

TabEsp:CreateToggle({
    Name = "Window ESP",
    CurrentValue = false,
    Callback = function(on)
        espWindows = on
        refreshEsp()
    end,
})

TabEsp:CreateToggle({
    Name = "Locker ESP",
    CurrentValue = false,
    Callback = function(on)
        espLockers = on
        refreshEsp()
    end,
})

TabEsp:CreateToggle({
    Name = "Hook ESP",
    Description = "Matches models with hook in the name",
    CurrentValue = false,
    Callback = function(on)
        espHooks = on
        refreshEsp()
    end,
})

--====================================================
-- UI: Generator tab
--====================================================
TabGenerator:CreateToggle({
    Name = "Auto skill check",
    Description = "Taps Space when the line reaches the great zone",
    CurrentValue = false,
    Callback = function(on)
        autoSkillCheck = on
    end,
})

TabGenerator:CreateSlider({
    Name = "Aim angle",
    Description = "Where the press should land, past the goal. Great zone is 102 to 116",
    Range = {102, 116},
    Increment = 1,
    CurrentValue = 109,
    Suffix = " deg",
    Callback = function(amount)
        skillCheckAimAngle = amount
    end,
})

TabGenerator:CreateSlider({
    Name = "Input delay",
    Description = "Raise it if presses land early, lower it if they land late",
    Range = {-30, 80},
    Increment = 1,
    CurrentValue = 0,
    Suffix = " ms",
    Callback = function(amount)
        skillCheckDelay = amount
    end,
})

TabGenerator:CreateToggle({
    Name = "Debug print (F9)",
    Description = "Prints Line / Goal rotation while a check is on screen",
    CurrentValue = false,
    Callback = function(on)
        skillCheckDebug = on
    end,
})

TabGenerator:CreateToggle({
    Name = "Auto repair",
    Description = "Walks to the nearest free generator and holds left click. Turn on Auto skill check too",
    CurrentValue = false,
    Callback = function(on)
        autoRepair = on

        if not on then
            setMouseHeld(false)
        end
    end,
})

--====================================================
-- UI: Player tab
--====================================================
TabPlayer:CreateToggle({
    Name = "Speed boost",
    Description = "Multiplies the game's own speed. Works while walking, sprinting and crouching",
    CurrentValue = false,
    Callback = function(on)
        speedEnabled = on

        if not on then
            setSpeedBoost(1)
        end
    end,
})

TabPlayer:CreateSlider({
    Name = "Multiplier",
    Range = {1, 2},
    Increment = 0.1,
    CurrentValue = 1.3,
    Suffix = "x",
    Callback = function(amount)
        speedMultiplier = amount
    end,
})

TabPlayer:CreateToggle({
    Name = "Fullbright",
    CurrentValue = false,
    Callback = function(on)
        fullbrightEnabled = on

        if on then
            saveLighting()
        else
            restoreLighting()
        end
    end,
})

TabPlayer:CreateToggle({
    Name = "Remove fog",
    Description = "Clears the fog and the atmosphere haze",
    CurrentValue = false,
    Callback = function(on)
        noFogEnabled = on

        if on then
            saveFog()
        else
            restoreFog()
        end
    end,
})

TabPlayer:CreateButton({
    Name = "Unload script",
    Callback = function()
        running = false

        autoSkillCheck = false
        skillCheckDebug = false
        speedEnabled = false
        fullbrightEnabled = false

        setSpeedBoost(1)

        for _, connection in ipairs(connections) do
            connection:Disconnect()
        end

        noFogEnabled = false
        autoRepair = false

        setMouseHeld(false)

        restoreFog()
        restoreLighting()
        clearAllEsp()
        espFolder:Destroy()

        Window:Unload()
    end,
})

--====================================================
-- Ready
--====================================================
Window:Notify({
    Title = "BrN Hub",
    Content = "Loaded.",
    Duration = 5,
})
