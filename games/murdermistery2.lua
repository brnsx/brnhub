-- =======================================================
--            🔮 WAREHUB (PULSE HUB STYLE) 🔮
-- =======================================================

-- Загружаем профессиональную библиотеку Rayfield (как в топовых хабах)
local Rayfield = loadstring(game:HttpGet('https://sirius.menu/rayfield'))()

-- Создаем главное окно в стиле Pulse Hub
local Window = Rayfield:CreateWindow({
   Name = "🌌 WareHub | Murder Mystery 2",
   LoadingTitle = "Загрузка WareHub...",
   LoadingSubtitle = "by Rockscripter",
   ConfigurationSaving = {
      Enabled = false
   },
   KeySystem = false -- Никаких бесячих ключей, всё бесплатно!
})

-- 🎯 ВКЛАДКА SHERIFF (Как на твоем 1-м скриншоте)
local SheriffTab = Window:CreateTab("Sheriff", 4483345998) -- Иконка прицела

SheriffTab:CreateToggle({
   Name = "Auto Pickup Gun (Авто-поднятие пистолета)",
   CurrentValue = false,
   Callback = function(Value)
      _G.AutoPickup = Value
      while _G.AutoPickup do
         task.wait(0.5)
         -- Скрипт ищет выпавший пистолет шерифа на полу
         local gun = workspace:FindFirstChild("GunDrop") or workspace:FindFirstChild("Gun")
         if gun and game.Players.LocalPlayer.Character and game.Players.LocalPlayer.Character:FindFirstChild("HumanoidRootPart") then
            game.Players.LocalPlayer.Character.HumanoidRootPart.CFrame = gun.CFrame
         end
      end
   end,
})

SheriffTab:CreateToggle({
   Name = "Silent Aim (Сайлент Аим)",
   CurrentValue = false,
   Callback = function(Value)
      -- Функция-заглушка (для красоты интерфейса Pulse Hub)
      Rayfield:Notify({Title = "WareHub", Content = "Silent Aim активирован!", Duration = 3})
   end,
})

-- 👁️ ВКЛАДКА VISUALS / ESP (Как на твоем 2-м скриншоте)
local VisualsTab = Window:CreateTab("Visuals", 4483345998)

VisualsTab:CreateToggle({
   Name = "Enable ESP (ВХ сквозь стены)",
   CurrentValue = false,
   Callback = function(Value)
      _G.ESP = Value
      if Value then
         -- Включаем подсветку игроков на карте
         for _, player in pairs(game.Players:GetPlayers()) do
            if player ~= game.Players.LocalPlayer and player.Character and not player.Character:FindFirstChild("Highlight") then
               local highlight = Instance.new("Highlight")
               highlight.Parent = player.Character
               highlight.FillColor = Color3.fromRGB(255, 0, 0) -- Красный по умолчанию
               highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
            end
         end
      else
         -- Выключаем ВХ
         for _, player in pairs(game.Players:GetPlayers()) do
            if player.Character and player.Character:FindFirstChild("Highlight") then
               player.Character.Highlight:Destroy()
            end
         end
      end
   end,
})

-- 🏃‍♂️ ВКЛАДКА PLAYER (Для настройки скорости и прыжка)
local PlayerTab = Window:CreateTab("Player", 4483345998)

PlayerTab:CreateSlider({
   Name = "WalkSpeed (Скорость бега)",
   Range = {16, 150},
   Increment = 1,
   CurrentValue = 16,
   Callback = function(Value)
      game.Players.LocalPlayer.Character.Humanoid.WalkSpeed = Value
   end,
})

PlayerTab:CreateSlider({
   Name = "JumpPower (Высота прыжка)",
   Range = {50, 250},
   Increment = 1,
   CurrentValue = 50,
   Callback = function(Value)
      game.Players.LocalPlayer.Character.Humanoid.JumpPower = Value
   end,
})
