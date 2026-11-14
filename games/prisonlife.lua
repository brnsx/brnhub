-- ⚡ BrN Hub | Prison Life | Rayfield UI
local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

local CoreGui      = game:GetService("CoreGui")
local TweenService = game:GetService("TweenService")
local UIS          = game:GetService("UserInputService")
local Players      = game:GetService("Players")
local RunService   = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local HttpService  = game:GetService("HttpService")
local lp           = Players.LocalPlayer
local Camera       = workspace.CurrentCamera

-- ════════════════════════════════
-- SOUND
-- ════════════════════════════════
local function playToggleSound(on)
    local s = Instance.new("Sound")
    s.SoundId       = "rbxassetid://6026984224"
    s.Volume        = 0.4
    s.PlaybackSpeed = on and 1.2 or 0.9
    s.Parent        = SoundService
    s:Play()
    game:GetService("Debris"):AddItem(s, 2)
end

-- ════════════════════════════════
-- STATE
-- ════════════════════════════════
local states = {
    ESP = false,
    Crosshair = false,
    Aimbot = false,
    Speed = false,
    Noclip = false,
    Precision = false,
    Ammo = false,
    Fly = false,
    InfJump = false,
    AntiFling = false,
    AntiVoid = false,
    AntiRagdoll = false,
    ClickTP = false,
    FlySpeedVal = 60,
    WalkSpeedVal = 55
}

local function safeHrp()
    local c = lp.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

-- ════════════════════════════════
-- TEAM DETECTION
-- ════════════════════════════════
local POLICE_WORDS   = { "police", "polic", "cop", "guard", "sheriff", "swat" }
local CRIMINAL_WORDS = { "criminal", "convict", "escaped", "wanted" }
local PRISON_WORDS   = { "prison", "inmate", "crim" }

local function teamCategory(teamName)
    if not teamName then return nil end
    local n = teamName:lower()
    for _, w in ipairs(POLICE_WORDS)   do if n:find(w, 1, true) then return "police"   end end
    for _, w in ipairs(CRIMINAL_WORDS) do if n:find(w, 1, true) then return "criminal" end end
    for _, w in ipairs(PRISON_WORDS)   do if n:find(w, 1, true) then return "prisoner" end end
    return nil
end

local function sideOf(teamName)
    local cat = teamCategory(teamName)
    if cat == "police" then return "police" end
    if cat == "criminal" or cat == "prisoner" then return "prison" end
    return nil
end

local function isEnemy(p)
    if p == lp then return false end
    if not lp.Team or not p.Team then return false end
    local mySide, hisSide = sideOf(lp.Team.Name), sideOf(p.Team.Name)
    if mySide and hisSide then
        return mySide ~= hisSide
    end
    return lp.Team ~= p.Team
end

-- ════════════════════════════════
-- WANTED / SHOOTER DETECTION
-- ════════════════════════════════
local WANTED_SECONDS = 15
local wanted = {}

local function hasGunEquipped(char)
    if not char then return false end
    local tool = char:FindFirstChildOfClass("Tool")
    return tool ~= nil
end

local function markShooter()
    local myHrp = safeHrp()
    if not myHrp then return end
    local best, bestD
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp and p.Team and teamCategory(p.Team.Name) == "prisoner" then
            local ch = p.Character
            local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
            if hrp and hasGunEquipped(ch) then
                local d = (hrp.Position - myHrp.Position).Magnitude
                if d < 150 and (not bestD or d < bestD) then best, bestD = p, d end
            end
        end
    end
    if best then wanted[best] = tick() + WANTED_SECONDS end
end

local function hookShooterDetection(char)
    local hum = char:WaitForChild("Humanoid", 5)
    if not hum then return end
    local lastHealth = hum.Health
    hum:GetPropertyChangedSignal("Health"):Connect(function()
        if hum.Health < lastHealth then markShooter() end
        lastHealth = hum.Health
    end)
end
if lp.Character then hookShooterDetection(lp.Character) end
lp.CharacterAdded:Connect(hookShooterDetection)

local function isAimTarget(p)
    if not isEnemy(p) then return false end
    local myCat = teamCategory(lp.Team and lp.Team.Name)
    if myCat == "police" then
        local cat = teamCategory(p.Team and p.Team.Name)
        if cat == "criminal" then return true end
        if cat == "prisoner" and wanted[p] and wanted[p] > tick() then return true end
        return false
    end
    return true
end

-- ════════════════════════════════
-- ESP
-- ════════════════════════════════
local LIME = Color3.fromRGB(170, 255, 60)
local espObjects = {}

local function removeESP(player)
    local o = espObjects[player]
    if not o then return end
    if o.bb   and o.bb.Parent   then o.bb:Destroy()   end
    if o.hl   and o.hl.Parent   then o.hl:Destroy()   end
    if o.conn then o.conn:Disconnect() end
    espObjects[player] = nil
end

local function createESP(player)
    if espObjects[player] then return end
    local function build()
        if not states.ESP or not isEnemy(player) then return end
        local char = player.Character
        if not char then return end
        local root = char:FindFirstChild("HumanoidRootPart")
        local hum  = char:FindFirstChildOfClass("Humanoid")
        if not root then return end

        local bb = Instance.new("BillboardGui")
        bb.Name        = "BrNESP"
        bb.Size        = UDim2.new(0, 140, 0, 40)
        bb.StudsOffset = Vector3.new(0, 4, 0)
        bb.AlwaysOnTop = true
        bb.Parent      = root

        local nameLbl = Instance.new("TextLabel", bb)
        nameLbl.Size                   = UDim2.new(1, 0, 0.6, 0)
        nameLbl.BackgroundTransparency = 1
        nameLbl.Font                   = Enum.Font.GothamBold
        nameLbl.TextSize               = 13
        nameLbl.TextColor3             = LIME
        nameLbl.TextStrokeColor3       = Color3.new(0, 0, 0)
        nameLbl.TextStrokeTransparency = 0
        nameLbl.Text                   = player.Name

        local hpLbl = Instance.new("TextLabel", bb)
        hpLbl.Size                   = UDim2.new(1, 0, 0.4, 0)
        hpLbl.Position               = UDim2.new(0, 0, 0.6, 0)
        hpLbl.BackgroundTransparency = 1
        hpLbl.Font                   = Enum.Font.Gotham
        hpLbl.TextSize               = 10
        hpLbl.TextColor3             = Color3.new(1, 1, 1)
        hpLbl.TextStrokeColor3       = Color3.new(0, 0, 0)
        hpLbl.TextStrokeTransparency = 0.2
        hpLbl.Text                   = "HP: --"

        local hl = Instance.new("Highlight")
        hl.Name                = "BrNHL"
        hl.Adornee             = char
        hl.FillColor           = LIME
        hl.OutlineColor        = LIME
        hl.FillTransparency    = 0.6
        hl.OutlineTransparency = 0
        hl.DepthMode           = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent              = char

        local updateConn
        if hum then
            updateConn = hum:GetPropertyChangedSignal("Health"):Connect(function()
                if hpLbl and hpLbl.Parent then
                    hpLbl.Text = string.format("HP: %d / %d", math.floor(hum.Health), math.floor(hum.MaxHealth))
                end
            end)
            hpLbl.Text = string.format("HP: %d / %d", math.floor(hum.Health), math.floor(hum.MaxHealth))
        end

        espObjects[player] = { bb = bb, hl = hl, conn = updateConn }
    end

    build()
    player.CharacterAdded:Connect(function()
        task.wait(0.5)
        removeESP(player)
        if states.ESP then build() end
    end)
    player:GetPropertyChangedSignal("Team"):Connect(function()
        removeESP(player)
        if states.ESP then build() end
    end)
end

local playerAddedConn, playerRemovingConn, myTeamConn

local function startESP()
    for _, p in ipairs(Players:GetPlayers()) do createESP(p) end
    playerAddedConn    = Players.PlayerAdded:Connect(createESP)
    playerRemovingConn = Players.PlayerRemoving:Connect(removeESP)
    myTeamConn = lp:GetPropertyChangedSignal("Team"):Connect(function()
        for _, p in ipairs(Players:GetPlayers()) do
            removeESP(p)
            if p ~= lp and states.ESP then createESP(p) end
        end
    end)
end

local function stopESP()
    for _, p in ipairs(Players:GetPlayers()) do removeESP(p) end
    if playerAddedConn    then playerAddedConn:Disconnect();    playerAddedConn    = nil end
    if playerRemovingConn then playerRemovingConn:Disconnect(); playerRemovingConn = nil end
    if myTeamConn         then myTeamConn:Disconnect();         myTeamConn         = nil end
end

-- ════════════════════════════════
-- CROSSHAIR
-- ════════════════════════════════
local crosshairGui, crosshairConn = nil, nil

local function createCrosshair()
    if crosshairGui then return end
    crosshairGui = Instance.new("ScreenGui")
    crosshairGui.Name           = "BrNCrosshairPL"
    crosshairGui.IgnoreGuiInset = true
    crosshairGui.ResetOnSpawn   = false
    crosshairGui.DisplayOrder   = 999999
    crosshairGui.Parent         = CoreGui

    local holder = Instance.new("Frame", crosshairGui)
    holder.Name                   = "X"
    holder.Size                   = UDim2.new(0, 12, 0, 12)
    holder.AnchorPoint            = Vector2.new(0.5, 0.5)
    holder.BackgroundTransparency = 1
    holder.ZIndex                 = 999999

    local bar1 = Instance.new("Frame", holder)
    bar1.AnchorPoint       = Vector2.new(0.5, 0.5)
    bar1.Position          = UDim2.new(0.5, 0, 0.5, 0)
    bar1.Size              = UDim2.new(0, 12, 0, 1.8)
    bar1.Rotation          = 45
    bar1.BorderSizePixel   = 0
    bar1.BackgroundColor3  = Color3.new(1, 1, 1)
    bar1.ZIndex            = 999999
    local s1 = Instance.new("UIStroke", bar1); s1.Color = Color3.new(0, 0, 0); s1.Thickness = 1

    local bar2 = bar1:Clone()
    bar2.Rotation = -45
    bar2.Parent   = holder

    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude

    crosshairConn = RunService.RenderStepped:Connect(function()
        if not crosshairGui or not holder then return end
        local vp = Camera.ViewportSize
        holder.Position = UDim2.new(0, vp.X / 2, 0, vp.Y / 2)

        local ignore = {}
        if lp.Character then table.insert(ignore, lp.Character) end
        params.FilterDescendantsInstances = ignore

        local origin    = Camera.CFrame.Position
        local direction = Camera.CFrame.LookVector * 2500
        local result    = workspace:Raycast(origin, direction, params)
        local enemy     = false

        if result and result.Instance then
            local model = result.Instance:FindFirstAncestorOfClass("Model")
            if model then
                local hum = model:FindFirstChildOfClass("Humanoid")
                local plr = Players:GetPlayerFromCharacter(model)
                if hum and hum.Health > 0 and plr and isEnemy(plr) then
                    enemy = true
                end
            end
        end

        local color = enemy and Color3.fromRGB(255, 40, 40) or Color3.new(1, 1, 1)
        bar1.BackgroundColor3 = color
        bar2.BackgroundColor3 = color
    end)
end

local function destroyCrosshair()
    if crosshairConn then crosshairConn:Disconnect(); crosshairConn = nil end
    if crosshairGui  then crosshairGui:Destroy();     crosshairGui = nil end
end

-- ════════════════════════════════
-- AIMBOT
-- ════════════════════════════════
local aimbotConn
local AIMBOT_FOV   = 250
local AIMBOT_RANGE = 180

local function aimVisible(part)
    local rp = RaycastParams.new()
    rp.FilterType = Enum.RaycastFilterType.Exclude
    rp.FilterDescendantsInstances = { lp.Character }
    local dir = part.Position - Camera.CFrame.Position
    local hit = workspace:Raycast(Camera.CFrame.Position, dir, rp)
    return (not hit) or hit.Instance:IsDescendantOf(part.Parent)
end

local function startAimbot()
    aimbotConn = RunService:BindToRenderStep("BrNPLAim", Enum.RenderPriority.Camera.Value + 2, function()
        local center = Camera.ViewportSize / 2
        local myHrp = safeHrp()
        local best, bestD
        for _, p in ipairs(Players:GetPlayers()) do
            if isAimTarget(p) then
                local ch = p.Character
                local hum = ch and ch:FindFirstChildOfClass("Humanoid")
                local head = ch and ch:FindFirstChild("Head")
                if hum and hum.Health > 0 and head and myHrp
                and (head.Position - myHrp.Position).Magnitude <= AIMBOT_RANGE then
                    local v, onScreen = Camera:WorldToViewportPoint(head.Position)
                    if onScreen then
                        local d = (Vector2.new(v.X, v.Y) - center).Magnitude
                        if d < AIMBOT_FOV and (not bestD or d < bestD) and aimVisible(head) then
                            best, bestD = head, d
                        end
                    end
                end
            end
        end
        if best then
            Camera.CFrame = Camera.CFrame:Lerp(CFrame.new(Camera.CFrame.Position, best.Position), 0.6)
        end
    end)
end

local function stopAimbot()
    pcall(function() RunService:UnbindFromRenderStep("BrNPLAim") end)
    aimbotConn = nil
end

-- ════════════════════════════════
-- SPEED
-- ════════════════════════════════
local speedConn, speedBase

local function startSpeed()
    local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
    speedBase = hum and hum.WalkSpeed or 16
    speedConn = RunService.Heartbeat:Connect(function()
        local h = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
        if h and states.Speed then h.WalkSpeed = states.WalkSpeedVal end
    end)
end

local function stopSpeed()
    if speedConn then speedConn:Disconnect(); speedConn = nil end
    local h = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
    if h then h.WalkSpeed = speedBase or 16 end
end

-- ════════════════════════════════
-- NOCLIP
-- ════════════════════════════════
local noclipConn, noclipConn2

local function noclipPass()
    local char = lp.Character
    if not char then return end
    for _, v in ipairs(char:GetDescendants()) do
        if v:IsA("BasePart") then v.CanCollide = false end
    end
end

local function startNoclip()
    noclipConn  = RunService.Stepped:Connect(noclipPass)
    noclipConn2 = RunService.Heartbeat:Connect(noclipPass)
end

local function stopNoclip()
    if noclipConn  then noclipConn:Disconnect();  noclipConn  = nil end
    if noclipConn2 then noclipConn2:Disconnect(); noclipConn2 = nil end
    local char = lp.Character
    if char then
        for _, v in ipairs(char:GetDescendants()) do
            if v:IsA("BasePart") then v.CanCollide = true end
        end
    end
end

-- ════════════════════════════════
-- NO SPREAD / PRECISION
-- ════════════════════════════════
local precOrig = {}

local function precApply(tool)
    if precOrig[tool] ~= nil then return end
    local sr = tool:GetAttribute("SpreadRadius")
    if sr ~= nil then
        precOrig[tool] = sr
        tool:SetAttribute("SpreadRadius", 0)
    end
end

local function precScan()
    local char, bp = lp.Character, lp:FindFirstChild("Backpack")
    if char then for _, t in ipairs(char:GetChildren()) do if t:IsA("Tool") then precApply(t) end end end
    if bp   then for _, t in ipairs(bp:GetChildren())   do if t:IsA("Tool") then precApply(t) end end end
end

local function startPrecision()
    task.spawn(function()
        while states.Precision do
            precScan()
            task.wait(0.5)
        end
    end)
end

local function stopPrecision()
    states.Precision = false
    for tool, v in pairs(precOrig) do
        if tool.Parent then pcall(function() tool:SetAttribute("SpreadRadius", v) end) end
    end
    precOrig = {}
end

-- ════════════════════════════════
-- INFINITE AMMO
-- ════════════════════════════════
local ammoOrig = {}

local function ammoApply(tool)
    if ammoOrig[tool] ~= nil then return end
    local v = tool:GetAttribute("CurrentAmmo")
    if type(v) == "number" then ammoOrig[tool] = v end
end

local function ammoRefill(tool)
    local maxAmmo = tool:GetAttribute("MaxAmmo")
    if maxAmmo ~= nil and tool:GetAttribute("CurrentAmmo") ~= nil then
        tool:SetAttribute("CurrentAmmo", maxAmmo)
    end
end

local function startAmmo()
    task.spawn(function()
        while states.Ammo do
            local char, bp = lp.Character, lp:FindFirstChild("Backpack")
            if char then for _, t in ipairs(char:GetChildren()) do if t:IsA("Tool") then ammoApply(t); ammoRefill(t) end end end
            if bp   then for _, t in ipairs(bp:GetChildren())   do if t:IsA("Tool") then ammoApply(t); ammoRefill(t) end end end
            task.wait(0.1)
        end
    end)
end

local function stopAmmo()
    states.Ammo = false
    for tool, v in pairs(ammoOrig) do
        if tool.Parent then pcall(function() tool:SetAttribute("CurrentAmmo", v) end) end
    end
    ammoOrig = {}
end

-- ════════════════════════════════
-- INFINITE JUMP
-- ════════════════════════════════
local infJumpConn

local function startInfJump()
    infJumpConn = UIS.JumpRequest:Connect(function()
        local hum = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum:ChangeState(Enum.HumanoidStateType.Jumping) end
    end)
end

local function stopInfJump()
    if infJumpConn then infJumpConn:Disconnect(); infJumpConn = nil end
end

-- ════════════════════════════════
-- ANTI-FLING
-- ════════════════════════════════
local antiFlingConn

local function startAntiFling()
    antiFlingConn = RunService.Stepped:Connect(function()
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= lp and p.Character then
                for _, v in ipairs(p.Character:GetDescendants()) do
                    if v:IsA("BasePart") then v.CanCollide = false end
                end
            end
        end
        local hrp = safeHrp()
        if hrp and hrp.AssemblyLinearVelocity.Magnitude > 150 then
            hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        end
    end)
end

local function stopAntiFling()
    if antiFlingConn then antiFlingConn:Disconnect(); antiFlingConn = nil end
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= lp and p.Character then
            for _, v in ipairs(p.Character:GetDescendants()) do
                if v:IsA("BasePart") then v.CanCollide = true end
            end
        end
    end
end

-- ════════════════════════════════
-- ANTI-VOID
-- ════════════════════════════════
local antiVoidConn, lastSafeCFrame

local function startAntiVoid()
    antiVoidConn = RunService.Heartbeat:Connect(function()
        local hrp = safeHrp()
        if not hrp then return end
        if hrp.Position.Y > -20 then
            lastSafeCFrame = hrp.CFrame
        elseif lastSafeCFrame then
            hrp.CFrame = lastSafeCFrame
            hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        end
    end)
end

local function stopAntiVoid()
    if antiVoidConn then antiVoidConn:Disconnect(); antiVoidConn = nil end
    lastSafeCFrame = nil
end

-- ════════════════════════════════
-- ANTI-RAGDOLL
-- ════════════════════════════════
local antiRagdollConns = {}

local function applyAntiRagdoll(hum)
    pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false) end)
    pcall(function() hum:SetStateEnabled(Enum.HumanoidStateType.Physics, false) end)
    local c = hum:GetPropertyChangedSignal("PlatformStand"):Connect(function()
        if states.AntiRagdoll and hum.PlatformStand then hum.PlatformStand = false end
    end)
    table.insert(antiRagdollConns, c)
end

local function startAntiRagdoll()
    local char = lp.Character
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if hum then applyAntiRagdoll(hum) end
    local c2 = lp.CharacterAdded:Connect(function(ch)
        local h = ch:WaitForChild("Humanoid", 5)
        if h and states.AntiRagdoll then applyAntiRagdoll(h) end
    end)
    table.insert(antiRagdollConns, c2)
end

local function stopAntiRagdoll()
    for _, c in ipairs(antiRagdollConns) do c:Disconnect() end
    antiRagdollConns = {}
end

-- ════════════════════════════════
-- CLICK TP
-- ════════════════════════════════
local clickTpConn

local function startClickTP()
    clickTpConn = UIS.InputBegan:Connect(function(input, processed)
        if processed or not states.ClickTP then return end
        local isTouch     = input.UserInputType == Enum.UserInputType.Touch
        local isCtrlClick = input.UserInputType == Enum.UserInputType.MouseButton1
            and (UIS:IsKeyDown(Enum.KeyCode.LeftControl) or UIS:IsKeyDown(Enum.KeyCode.RightControl))
        if not (isTouch or isCtrlClick) then return end
        local ok, hit = pcall(function() return lp:GetMouse().Hit end)
        local hrp = safeHrp()
        if ok and hit and hrp then
            hrp.CFrame = CFrame.new(hit.Position + Vector3.new(0, 3, 0))
        end
    end)
end

local function stopClickTP()
    if clickTpConn then clickTpConn:Disconnect(); clickTpConn = nil end
end

-- ════════════════════════════════
-- FLY
-- ════════════════════════════════
local flyConn

local function startFly()
    flyConn = RunService.Heartbeat:Connect(function()
        local char = lp.Character
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        local hum  = char and char:FindFirstChildOfClass("Humanoid")
        if not hrp or not hum then return end
        local moveDir  = hum.MoveDirection
        local vertical = hum.Jump and states.FlySpeedVal or -states.FlySpeedVal * 0.5
        hrp.AssemblyLinearVelocity = (moveDir * states.FlySpeedVal) + Vector3.new(0, vertical, 0)
    end)
end

local function stopFly()
    if flyConn then flyConn:Disconnect(); flyConn = nil end
    local hrp = safeHrp()
    if hrp then hrp.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end
end

-- ════════════════════════════════
-- RAYFIELD WINDOW & TABS
-- ════════════════════════════════
local Window = Rayfield:CreateWindow({
    Name = "BrN Hub | Prison Life",
    Icon = 0,
    LoadingTitle = "BrN Hub",
    LoadingSubtitle = "Prison Life",
    Theme = "Default",
    DisableRayfieldPrompts = false,
    DisableBuildWarnings = false,
    ConfigurationSaving = {
        Enabled = true,
        FolderName = "BrNHub",
        FileName = "PrisonLife_Config"
    },
    KeySystem = false
})

local CombatTab   = Window:CreateTab("Combat", "crosshair")
local VisualsTab  = Window:CreateTab("Visuals", "eye")
local MovementTab = Window:CreateTab("Movement", "zap")
local MiscTab     = Window:CreateTab("Misc", "shield")

-- ════════════════════════════════
-- COMBAT TAB
-- ════════════════════════════════
CombatTab:CreateSection("Targeting & Weapons")

CombatTab:CreateToggle({
    Name = "Smart Aimbot",
    CurrentValue = false,
    Flag = "AimbotToggle",
    Callback = function(Value)
        states.Aimbot = Value
        playToggleSound(Value)
        if Value then startAimbot() else stopAimbot() end
    end,
})

CombatTab:CreateSlider({
    Name = "Aimbot FOV",
    Range = {50, 500},
    Increment = 10,
    Suffix = "px",
    CurrentValue = 250,
    Flag = "AimbotFOVSlider",
    Callback = function(Value)
        AIMBOT_FOV = Value
    end,
})

CombatTab:CreateSlider({
    Name = "Aimbot Max Range",
    Range = {50, 500},
    Increment = 10,
    Suffix = " studs",
    CurrentValue = 180,
    Flag = "AimbotRangeSlider",
    Callback = function(Value)
        AIMBOT_RANGE = Value
    end,
})

CombatTab:CreateToggle({
    Name = "No Spread (Perfect Precision)",
    CurrentValue = false,
    Flag = "PrecisionToggle",
    Callback = function(Value)
        states.Precision = Value
        playToggleSound(Value)
        if Value then startPrecision() else stopPrecision() end
    end,
})

CombatTab:CreateToggle({
    Name = "Infinite Ammo",
    CurrentValue = false,
    Flag = "AmmoToggle",
    Callback = function(Value)
        states.Ammo = Value
        playToggleSound(Value)
        if Value then startAmmo() else stopAmmo() end
    end,
})

-- ════════════════════════════════
-- VISUALS TAB
-- ════════════════════════════════
VisualsTab:CreateSection("ESP & Crosshair")

VisualsTab:CreateToggle({
    Name = "Enemy Team ESP",
    CurrentValue = false,
    Flag = "ESPToggle",
    Callback = function(Value)
        states.ESP = Value
        playToggleSound(Value)
        if Value then startESP() else stopESP() end
    end,
})

VisualsTab:CreateToggle({
    Name = "Dynamic Crosshair",
    CurrentValue = false,
    Flag = "CrosshairToggle",
    Callback = function(Value)
        states.Crosshair = Value
        playToggleSound(Value)
        if Value then createCrosshair() else destroyCrosshair() end
    end,
})

-- ════════════════════════════════
-- MOVEMENT TAB
-- ════════════════════════════════
MovementTab:CreateSection("Speed & Flight")

MovementTab:CreateToggle({
    Name = "WalkSpeed",
    CurrentValue = false,
    Flag = "SpeedToggle",
    Callback = function(Value)
        states.Speed = Value
        playToggleSound(Value)
        if Value then startSpeed() else stopSpeed() end
    end,
})

MovementTab:CreateSlider({
    Name = "WalkSpeed Value",
    Range = {16, 150},
    Increment = 1,
    Suffix = " WS",
    CurrentValue = 55,
    Flag = "WalkSpeedSlider",
    Callback = function(Value)
        states.WalkSpeedVal = Value
    end,
})

MovementTab:CreateToggle({
    Name = "Fly",
    CurrentValue = false,
    Flag = "FlyToggle",
    Callback = function(Value)
        states.Fly = Value
        playToggleSound(Value)
        if Value then startFly() else stopFly() end
    end,
})

MovementTab:CreateSlider({
    Name = "Fly Speed",
    Range = {20, 200},
    Increment = 5,
    Suffix = " Speed",
    CurrentValue = 60,
    Flag = "FlySpeedSlider",
    Callback = function(Value)
        states.FlySpeedVal = Value
    end,
})

MovementTab:CreateToggle({
    Name = "Noclip",
    CurrentValue = false,
    Flag = "NoclipToggle",
    Callback = function(Value)
        states.Noclip = Value
        playToggleSound(Value)
        if Value then startNoclip() else stopNoclip() end
    end,
})

MovementTab:CreateToggle({
    Name = "Infinite Jump",
    CurrentValue = false,
    Flag = "InfJumpToggle",
    Callback = function(Value)
        states.InfJump = Value
        playToggleSound(Value)
        if Value then startInfJump() else stopInfJump() end
    end,
})

MovementTab:CreateToggle({
    Name = "Click TP (Ctrl + Click / Tap)",
    CurrentValue = false,
    Flag = "ClickTPToggle",
    Callback = function(Value)
        states.ClickTP = Value
        playToggleSound(Value)
        if Value then startClickTP() else stopClickTP() end
    end,
})

-- ════════════════════════════════
-- MISC TAB
-- ════════════════════════════════
MiscTab:CreateSection("Protections")

MiscTab:CreateToggle({
    Name = "Anti-Fling",
    CurrentValue = false,
    Flag = "AntiFlingToggle",
    Callback = function(Value)
        states.AntiFling = Value
        playToggleSound(Value)
        if Value then startAntiFling() else stopAntiFling() end
    end,
})

MiscTab:CreateToggle({
    Name = "Anti-Void",
    CurrentValue = false,
    Flag = "AntiVoidToggle",
    Callback = function(Value)
        states.AntiVoid = Value
        playToggleSound(Value)
        if Value then startAntiVoid() else stopAntiVoid() end
    end,
})

MiscTab:CreateToggle({
    Name = "Anti-Ragdoll / Anti-Taser",
    CurrentValue = false,
    Flag = "AntiRagdollToggle",
    Callback = function(Value)
        states.AntiRagdoll = Value
        playToggleSound(Value)
        if Value then startAntiRagdoll() else stopAntiRagdoll() end
    end,
})

MiscTab:CreateSection("Server")

MiscTab:CreateButton({
    Name = "Server Hop",
    Callback = function()
        pcall(function()
            game:GetService("TeleportService"):Teleport(game.PlaceId, lp)
        end)
    end,
})

-- Load saved Rayfield configuration automatically
Rayfield:LoadConfiguration()
