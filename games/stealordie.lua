local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

loadstring(game:HttpGet('https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source'))()

local Window = Rayfield:CreateWindow({
   Name = "Steal or Die",
   Icon = 0,
   LoadingTitle = "Loading...",
   LoadingSubtitle = "by Personal Hub",
   ShowText = "Rayfield",
   Theme = "Default",
   ToggleUIKeybind = "K",
   DisableRayfieldPrompts = false,
   DisableBuildWarnings = false,
   ConfigurationSaving = {
      Enabled = true,
      FolderName = nil,
      FileName = "Big Hub"
   },
   Discord = {
      Enabled = false,
      Invite = "noinvitelink",
      RememberJoins = true
   },
   KeySystem = false,
   KeySettings = {
      Title = "Untitled",
      Subtitle = "Key System",
      Note = "No method of obtaining the key is provided",
      FileName = "Key",
      SaveKey = true,
      GrabKeyFromSite = false,
      Key = {"Hello"}
   }
})

local Main = Window:CreateTab("Main", 4483362458)
local Settings = Window:CreateTab("Settings", 4483362458)

local MainSection = Main:CreateSection("Idk")
local SettingsSection1 = Settings:CreateSection("Settings")

local MainDivider = Main:CreateDivider()
local SettingsDivider = Settings:CreateDivider()

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local playerESP = false
local playerESPSession = 0
local itemESP = false
local entityESP = false

local rarityColors = {
    Common = Color3.fromRGB(128, 128, 128),
    Uncommon = Color3.fromRGB(30, 255, 0),
    Rare = Color3.fromRGB(163, 53, 238),
    Mythic = Color3.fromRGB(255, 0, 0),
    Legendary = Color3.fromRGB(255, 128, 0),
}

local lootFolder = workspace:WaitForChild("MyLoot")
local TEXT_SIZE = 16

local function createInfoBillboard(item, rarity, color)
    local price = item:GetAttribute("Value") or 0
    local weight = item:GetAttribute("Weight") or 0

    local text = string.format("%s\n$%s\n%s kg", rarity, tostring(price), tostring(weight))

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "ESPInfo"
    billboard.Adornee = item
    billboard.AlwaysOnTop = true
    billboard.Size = UDim2.fromOffset(100, TEXT_SIZE * 3 + 16)
    billboard.StudsOffset = Vector3.new(0, 3, 0)
    billboard.MaxDistance = 250

    local panel = Instance.new("Frame")
    panel.Size = UDim2.fromScale(1, 1)
    panel.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    panel.BackgroundTransparency = 1
    panel.BorderSizePixel = 0
    panel.Parent = billboard

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 4)
    corner.Parent = panel

    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1, 1)
    label.BackgroundTransparency = 1
    label.Font = Enum.Font.Code
    label.TextSize = TEXT_SIZE
    label.TextColor3 = color
    label.TextXAlignment = Enum.TextXAlignment.Center
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.Text = text
    label.Parent = panel

    billboard.Parent = item
    return billboard
end

local function addESP(item)
    if item:FindFirstChild("ESP") or item:FindFirstChild("ESPInfo") then
        return
    end

    local rarity = item:GetAttribute("Rarity")
    local color = rarityColors[rarity]
    if not color then
        return
    end

    local highlight = Instance.new("Highlight")
    highlight.Name = "ESP"
    highlight.FillColor = color
    highlight.OutlineColor = color
    highlight.Parent = item

    createInfoBillboard(item, rarity, color)
end

local function clearESP()
    for _, item in ipairs(lootFolder:GetChildren()) do
        local highlight = item:FindFirstChild("ESP")
        if highlight then
            highlight:Destroy()
        end

        local billboard = item:FindFirstChild("ESPInfo")
        if billboard then
            billboard:Destroy()
        end
    end
end

local espSession = 0 

local itemESPToggle = Main:CreateToggle({
    Name = "Item ESP",
    CurrentValue = false,
    Flag = "Toggle1",
    Callback = function(Value)
        itemESP = Value
        espSession += 1
        local mySession = espSession

        if not itemESP then
            clearESP()
            return
        end

        task.spawn(function()
            while itemESP and mySession == espSession do
                for _, item in ipairs(lootFolder:GetChildren()) do
                    if item:IsA("Part") or item:IsA("UnionOperation") then
                        addESP(item)
                    end
                end

                task.wait(0.5)
            end
        end)
    end,
})

local TEXT_SIZE = 14
local MAX_DISTANCE = 1000
local DEFAULT_COLOR = Color3.fromRGB(255, 255, 255)

local function getColor(player)
    if player.Team then
        return player.TeamColor.Color
    end
    return DEFAULT_COLOR
end

local function updatePlayerESP(player)
    local character = player.Character
    if not character then
        return
    end

    if character:GetAttribute("EntityKind") then
        return
    end

    local head = character:FindFirstChild("Head")
    local root = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    if not (head and root and humanoid) then
        return
    end

    local color = getColor(player)

    local highlight = character:FindFirstChild("PlayerESP")
    if not highlight then
        highlight = Instance.new("Highlight")
        highlight.Name = "PlayerESP"
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        highlight.FillTransparency = 0.6
        highlight.Parent = character
    end
    highlight.FillColor = color
    highlight.OutlineColor = color
end

local function clearPlayerESP()
    for _, player in ipairs(Players:GetPlayers()) do
        local character = player.Character
        if character then
            local highlight = character:FindFirstChild("PlayerESP")
            if highlight then
                highlight:Destroy()
            end

            local head = character:FindFirstChild("Head")
            local billboard = head and head:FindFirstChild("PlayerESPInfo")
            if billboard then
                billboard:Destroy()
            end
        end
    end
end

local playerESPToggle = Main:CreateToggle({
    Name = "Player ESP",
    CurrentValue = false,
    Flag = "Toggle2",
    Callback = function(Value)
        playerESP = Value
        playerESPSession += 1
        local mySession = playerESPSession

        if not playerESP then
            clearPlayerESP()
            return
        end

        task.spawn(function()
            while playerESP and mySession == playerESPSession do
                for _, player in ipairs(Players:GetPlayers()) do
                    if player ~= LocalPlayer then
                        updatePlayerESP(player)
                    end
                end

                task.wait(0.1)
            end
        end)
    end,
})

local entityESPSession = 0
 
local ESP_NAME = "EntityESP"
local ESP_COLOR = Color3.fromRGB(255, 0, 0)
 
local entityNames = {
    ["The Hollow"] = true,
    ["The Rictus"] = true,
    ["The Wendell"] = true,
    ["The Locust"] = true,
    ["The Maternal Wraith"] = true,
}
 
local tracked = {}
 
local function highlightEntity(model)
    if not model or not model.Parent then
        return
    end
 
    local existing = tracked[model]
    if existing and existing.Parent then
        return
    end
 
    local highlight = model:FindFirstChild(ESP_NAME)
    if not highlight then
        highlight = Instance.new("Highlight")
        highlight.Name = ESP_NAME
        highlight.FillColor = ESP_COLOR
        highlight.OutlineColor = ESP_COLOR
        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        highlight.Parent = model
    end
 
    tracked[model] = highlight
end
 
local function getEntities()
    local found = {}
 
    for _, obj in ipairs(workspace:GetChildren()) do
        if obj:IsA("Model") and (entityNames[obj.Name] or obj:GetAttribute("EntityKind")) then
            if not Players:GetPlayerFromCharacter(obj) then
                table.insert(found, obj)
            end
        end
    end
 
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local char = player.Character
            if char and char:GetAttribute("EntityKind") then
                table.insert(found, char)
            end
        end
    end
 
    return found
end
 
local function clearEntityESP()
    for model, highlight in pairs(tracked) do
        if highlight and highlight.Parent then
            highlight:Destroy()
        end
        tracked[model] = nil
    end
 
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Highlight") and obj.Name == ESP_NAME then
            obj:Destroy()
        end
    end
end
 
local entityESPToggle = Main:CreateToggle({
    Name = "Entity ESP",
    CurrentValue = false,
    Flag = "Toggle3",
    Callback = function(Value)
        entityESP = Value
        entityESPSession += 1
        local mySession = entityESPSession
 
        if not entityESP then
            clearEntityESP()
            return
        end
 
        task.spawn(function()
            while entityESP and mySession == entityESPSession do
                local entities = getEntities()
                local alive = {}
 
                for _, entity in ipairs(entities) do
                    alive[entity] = true
                    highlightEntity(entity)
                end
 
                for model, highlight in pairs(tracked) do
                    if not alive[model] or not model.Parent then
                        if highlight and highlight.Parent then
                            highlight:Destroy()
                        end
                        tracked[model] = nil
                    end
                end
 
                task.wait(0.1)
            end
        end)
    end,
})
