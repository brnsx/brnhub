-- BrN Hub — Rayfield Gen2 port
-- By BreNo
-- (core logic preserved from v3.4)

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace        = game:GetService("Workspace")
local GuiService       = game:GetService("GuiService")

local LP = Players.LocalPlayer

print("[BrN] load start — BrN Hub (rayfield gen2)")

local CONFIG = {
    recon = true,
    force_player_gui = false,
    whitelist = {},

    esp = {
        enabled        = true,
        box            = true,
        name           = true,
        distance       = true,
        health         = true,
        team_check     = true,
        show_teammates = false,
        include_npcs   = false,
        include_corpses = true,
        corpse_color   = Color3.fromRGB(180, 180, 180),
        max_distance   = 700,
        enemy_color    = Color3.fromRGB(255, 60, 60),
        team_color     = Color3.fromRGB(80, 220, 120),
        npc_color      = Color3.fromRGB(255, 180, 60),

        minimap_enabled = true,
        minimap_size = 200,
        minimap_position = "topright",
        minimap_range = 1000,
        minimap_show_players = true,
        minimap_show_npcs = true,
        minimap_show_corpses = true,
        minimap_show_team = true,
        minimap_rotation = true,
        minimap_background = true,
        minimap_bg_color = Color3.fromRGB(10, 10, 15),
        minimap_border_color = Color3.fromRGB(60, 60, 80),
    },

    aim = {
        enabled      = true,
        input        = Enum.UserInputType.MouseButton2,
        method       = "auto",
        fov          = 110,
        speed        = 16,
        max_step     = 30,
        max_distance = 500,
        team_check   = true,
        wall_check   = true,
        hit_part     = "Head",
        humanize     = true,
        jitter       = 1,
        show_fov     = true,
        fov_color    = Color3.fromRGB(255, 255, 255),
    },

    team = {
        mode   = "auto",
        debug  = true,
        key    = nil,
        manual = nil,
    },
}

local SESSION = {
    speed_scale = 0.85 + math.random() * 0.30,
    step_scale  = 0.90 + math.random() * 0.20,
}

-- ==== anti-hook ====

local WATCHED_FUNCS = {
    "mousemoverel",
    "gethui", "getgenv", "hookfunction", "hookmetamethod",
    "getrawmetatable", "firetouchinterest", "request",
}

local ANTI_HOOK = {
    enabled = true,
    originals = {},
    restores = 0,
}

local _getgenv = type(getgenv) == "function" and getgenv or nil

local function exec_env()
    if _getgenv then
        local ok, env = pcall(_getgenv)
        if ok and env then return env end
    end
    return _G
end

local function snapshot_exec()
    ANTI_HOOK.originals = {}
    local env = exec_env()
    for _, name in ipairs(WATCHED_FUNCS) do
        local fn = rawget(env, name)
        if type(fn) == "function" then
            ANTI_HOOK.originals[name] = fn
        end
    end
end

local function verify_exec()
    if not ANTI_HOOK.enabled then return end
    local env = exec_env()
    for name, original in pairs(ANTI_HOOK.originals) do
        local current = rawget(env, name)
        if current ~= original then
            local ok = pcall(function() env[name] = original end)
            if ok then
                ANTI_HOOK.restores = ANTI_HOOK.restores + 1
                print(string.format("[BrN] antihook: '%s' tampered — original restored", name))
            end
        end
    end
end

snapshot_exec()

-- ==== team check ====

local SQUAD_KEYWORDS = { "squad", "party", "group", "lobby" }
local FACTION_KEYWORDS = { "faction", "team", "side", "allegiance", "clan", "guild" }

local TEAM = {
    squad = nil,
    faction = nil,
    attempts = 0,
    last_report = "",
}

local function classify(key)
    local n = string.lower(key)
    for _, k in ipairs(SQUAD_KEYWORDS) do
        if string.find(n, k, 1, true) then return "squad" end
    end
    for _, k in ipairs(FACTION_KEYWORDS) do
        if string.find(n, k, 1, true) then return "faction" end
    end
    return nil
end

local function primitive(v)
    local t = type(v)
    return t == "string" or t == "number" or t == "boolean"
end

local function desc_read(plr, desc)
    if not desc then return nil end
    if desc.scope == "team" then
        local t = plr.Team
        return t and tostring(t) or nil
    end
    local root
    if desc.scope == "char" then
        root = plr.Character
    elseif desc.scope == "leaderstats" then
        root = plr:FindFirstChild("leaderstats")
    else
        root = plr
    end
    if not root then return nil end

    if desc.kind == "attr" then
        local v = root:GetAttribute(desc.key)
        return (v ~= nil and primitive(v)) and tostring(v) or nil
    end

    local obj = root
    for _, step in ipairs(desc.path) do
        obj = obj:FindFirstChild(step)
        if not obj then return nil end
    end
    if obj:IsA("ValueBase") and primitive(obj.Value) then
        return tostring(obj.Value)
    end
    return nil
end

local function desc_str(desc)
    if not desc then return "none" end
    if desc.scope == "team" then return "Player.Team" end
    if desc.kind == "attr" then return string.format("%s.attr '%s'", desc.scope, desc.key) end
    return string.format("%s.%s", desc.scope, table.concat(desc.path, "."))
end

local function collect_candidates()
    local map = {}
    local function add(class, desc)
        map[class] = map[class] or {}
        map[class][desc_str(desc)] = desc
    end
    local function add_values(scope, container)
        for _, c in ipairs(container:GetChildren()) do
            if c:IsA("ValueBase") and primitive(c.Value) then
                local cls = classify(c.Name)
                if cls then add(cls, { scope = scope, kind = "value", path = { c.Name } }) end
            end
        end
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr.Team ~= nil then
            add("faction", { scope = "team" })
        end
        for k, v in pairs(plr:GetAttributes()) do
            if primitive(v) then
                local cls = classify(k)
                if cls then add(cls, { scope = "player", kind = "attr", key = k }) end
            end
        end
        add_values("player", plr)
        for _, c in ipairs(plr:GetChildren()) do
            if c:IsA("Folder") or c:IsA("Configuration") then
                for _, sc in ipairs(c:GetChildren()) do
                    if sc:IsA("ValueBase") and primitive(sc.Value) then
                        local cls = classify(sc.Name)
                        if cls then
                            add(cls, { scope = "player", kind = "value", path = { c.Name, sc.Name } })
                        end
                    end
                end
            end
        end
        local ls = plr:FindFirstChild("leaderstats")
        if ls then add_values("leaderstats", ls) end
        local char = plr.Character
        if char then
            for k, v in pairs(char:GetAttributes()) do
                if primitive(v) then
                    local cls = classify(k)
                    if cls then add(cls, { scope = "char", kind = "attr", key = k }) end
                end
            end
            add_values("char", char)
        end
    end
    return map
end

local function score(desc)
    local distinct, count, mine = {}, 0, false
    for _, plr in ipairs(Players:GetPlayers()) do
        local v = desc_read(plr, desc)
        if v ~= nil then
            count = count + 1
            distinct[v] = true
            if plr == LP then mine = true end
        end
    end
    local d = 0
    for _ in pairs(distinct) do d = d + 1 end
    return mine, count, d, distinct
end

local function resolve_team()
    local best = { squad = nil, faction = nil }
    local reports = { squad = "none", faction = "none" }

    if CONFIG.team.key then
        for _, desc in ipairs({
            { scope = "player", kind = "attr", key = CONFIG.team.key },
            { scope = "player", kind = "value", path = { CONFIG.team.key } },
            { scope = "leaderstats", kind = "value", path = { CONFIG.team.key } },
            { scope = "char", kind = "attr", key = CONFIG.team.key },
            { scope = "char", kind = "value", path = { CONFIG.team.key } },
        }) do
            local _, count = score(desc)
            if count > 0 then
                local class = classify(CONFIG.team.key) or "faction"
                best[class] = desc
                reports[class] = desc_str(desc) .. " (forced)"
                break
            end
        end
    else
        local candidates = collect_candidates()
        for class, list in pairs(candidates) do
            local winner = nil
            for _, desc in pairs(list) do
                local mine, count, d, distinct = score(desc)
                if mine and count >= 2 and d >= 2 then
                    if winner == nil or d > winner.d or (d == winner.d and count > winner.count) then
                        winner = { desc = desc, d = d, count = count, distinct = distinct }
                    end
                end
            end
            if winner then
                best[class] = winner.desc
                local vals = {}
                for v in pairs(winner.distinct) do
                    vals[#vals + 1] = v
                    if #vals >= 4 then break end
                end
                reports[class] = string.format("%s (%d vals: %s)", desc_str(winner.desc), winner.d, table.concat(vals, "/"))
            end
        end
    end

    TEAM.squad = best.squad
    TEAM.faction = best.faction
    TEAM.attempts = TEAM.attempts + 1

    local report = string.format("team[%s]: squad = %s · faction = %s", CONFIG.team.mode, reports.squad, reports.faction)
    if CONFIG.team.debug and report ~= TEAM.last_report then
        TEAM.last_report = report
        print("[BrN] " .. report)
    end
    if CONFIG.team.debug and not best.squad and not best.faction and TEAM.attempts == 8 then
        print("[BrN] no discriminating team source yet — run BrN.dump_team() and set config.team.key")
    end
end

local function is_friendly(plr)
    if plr == LP then return true end
    if CONFIG.whitelist[plr.Name] or CONFIG.whitelist[plr.UserId] then return true end

    if type(CONFIG.team.manual) == "function" then
        local ok, res = pcall(CONFIG.team.manual, plr)
        if ok and res ~= nil then return res and true or false end
    end

    local mode = CONFIG.team.mode
    if mode == "none" then return false end

    if mode == "squad" then
        local a, b = desc_read(plr, TEAM.squad), desc_read(LP, TEAM.squad)
        return a ~= nil and b ~= nil and a == b
    end
    if mode == "faction" then
        local a, b = desc_read(plr, TEAM.faction), desc_read(LP, TEAM.faction)
        return a ~= nil and b ~= nil and a == b
    end

    if TEAM.squad then
        local a, b = desc_read(plr, TEAM.squad), desc_read(LP, TEAM.squad)
        return a ~= nil and b ~= nil and a == b
    elseif TEAM.faction then
        local a, b = desc_read(plr, TEAM.faction), desc_read(LP, TEAM.faction)
        return a ~= nil and b ~= nil and a == b
    end
    return false
end

local function dump_team()
    print("==== [BrN] team dump ====")
    for _, plr in ipairs(Players:GetPlayers()) do
        local parts = { plr.Name, "Team=" .. tostring(plr.Team) }
        for k, v in pairs(plr:GetAttributes()) do
            if primitive(v) then parts[#parts + 1] = string.format("attr.%s=%s", k, tostring(v)) end
        end
        for _, c in ipairs(plr:GetChildren()) do
            if c:IsA("ValueBase") then parts[#parts + 1] = string.format("%s=%s", c.Name, tostring(c.Value)) end
            if c:IsA("Folder") or c:IsA("Configuration") then
                for _, sc in ipairs(c:GetChildren()) do
                    if sc:IsA("ValueBase") then
                        parts[#parts + 1] = string.format("%s.%s=%s", c.Name, sc.Name, tostring(sc.Value))
                    end
                end
            end
        end
        local ls = plr:FindFirstChild("leaderstats")
        if ls then
            for _, c in ipairs(ls:GetChildren()) do
                if c:IsA("ValueBase") then
                    parts[#parts + 1] = string.format("ls.%s=%s", c.Name, tostring(c.Value))
                end
            end
        end
        local char = plr.Character
        if char then
            for k, v in pairs(char:GetAttributes()) do
                if primitive(v) then parts[#parts + 1] = string.format("char.attr.%s=%s", k, tostring(v)) end
            end
            for _, c in ipairs(char:GetChildren()) do
                if c:IsA("ValueBase") then
                    parts[#parts + 1] = string.format("char.%s=%s", c.Name, tostring(c.Value))
                end
            end
        end
        print("  " .. table.concat(parts, " | "))
    end
end

-- ==== character helpers ====

local function get_character(plr)
    local char = plr.Character
    if not char or not char.Parent then return nil end
    local hum  = char:FindFirstChildOfClass("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart") or char.PrimaryPart or char:FindFirstChildWhichIsA("BasePart")
    if not hum or not root or hum.Health <= 0 then return nil end
    return char, hum, root
end

local function to_screen(world_pos)
    local camera = Workspace.CurrentCamera
    if not camera then return nil end
    local sp, on_screen = camera:WorldToViewportPoint(world_pos)
    if not on_screen or sp.Z <= 0 then return nil end
    return Vector2.new(sp.X, sp.Y)
end

local function body_box(char)
    local ok, cf, size = pcall(function() return char:GetBoundingBox() end)
    if not ok or size.Y < 0.05 then return nil end

    local p = cf.Position
    local a = to_screen(Vector3.new(p.X, p.Y + size.Y * 0.5, p.Z))
    local b = to_screen(Vector3.new(p.X, p.Y - size.Y * 0.5, p.Z))
    if not a or not b then return nil end

    local top_scr, bottom_scr = math.min(a.Y, b.Y), math.max(a.Y, b.Y)
    local height = bottom_scr - top_scr
    if height < 5 then return nil end
    local width = height * 0.5
    return Vector2.new((a.X + b.X) * 0.5 - width * 0.5, top_scr), Vector2.new(width, height)
end

local function model_root(model)
    return model.PrimaryPart
        or model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChildWhichIsA("BasePart")
end

-- ==== visibility raycast ====

local ray_params = RaycastParams.new()
ray_params.FilterType = Enum.RaycastFilterType.Exclude
ray_params.IgnoreWater = true

local VIEW_HINTS = { "view", "vm", "arm", "hand", "weapon", "gun", "muzzle", "scope", "tool" }
local IGNORE_TABLE = {}

local function ray_blocked(origin, world_pos, ignore)
    table.clear(IGNORE_TABLE)
    for _, v in ipairs(ignore) do IGNORE_TABLE[#IGNORE_TABLE + 1] = v end
    ray_params.FilterDescendantsInstances = IGNORE_TABLE
    local result = Workspace:Raycast(origin, world_pos - origin, ray_params)
    if result == nil then return false end
    local inst = result.Instance
    if inst == nil or inst == Workspace.Terrain then return true end
    if inst.CanCollide == false and inst.Transparency >= 0.9 then return false end
    local n = string.lower(inst.Name)
    for _, frag in ipairs(VIEW_HINTS) do
        if string.find(n, frag, 1, true) then
            local parent = inst.Parent
            if parent and (parent:IsA("Tool") or parent:IsA("Model") and parent:FindFirstChildOfClass("Humanoid")) then
                return false
            end
        end
    end
    return true
end

local function is_visible(target_char, world_pos)
    local camera = Workspace.CurrentCamera
    if not camera then return false end
    local ignore = { camera }
    local lp_char = LP.Character
    if lp_char then ignore[#ignore + 1] = lp_char end
    if target_char then ignore[#ignore + 1] = target_char end
    if not ray_blocked(camera.CFrame.Position, world_pos, ignore) then return true end
    local head = lp_char and lp_char:FindFirstChild("Head")
    if head and not ray_blocked(head.Position, world_pos, ignore) then return true end
    return false
end

-- ==== overlay container ====

local overlay_parent
if not CONFIG.force_player_gui then
    if type(gethui) == "function" then
        local ok, res = pcall(gethui)
        if ok and res then overlay_parent = res end
    end
    if not overlay_parent then
        local ok, res = pcall(function() return game:GetService("CoreGui") end)
        if ok and res then overlay_parent = res end
    end
end

local screens = {}
local warned_fallback = false

local function new_screen(name, order)
    local g = Instance.new("ScreenGui")
    g.Name = name
    g.ResetOnSpawn = false
    g.IgnoreGuiInset = true
    g.DisplayOrder = order
    g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

    local placed = false
    if overlay_parent then
        placed = pcall(function() g.Parent = overlay_parent end)
    end
    if not placed then
        g.Parent = LP:WaitForChild("PlayerGui")
        if not warned_fallback then
            warned_fallback = true
            print("[BrN] gethui unavailable — overlay in PlayerGui")
        end
    end
    screens[#screens + 1] = g
    return g
end

local esp_gui = new_screen("BrN_Overlay", 998)
local menu_gui = new_screen("BrN_Menu", 999)

-- ==== ESP (GUI overlay) ====

local ESP = {}
ESP.__index = ESP

local UDim2_fromOffset = UDim2.fromOffset
local UDim2_new = UDim2.new
local Color3_fromRGB = Color3.fromRGB
local Vector2_new = Vector2.new

function ESP.new()
    local self = setmetatable({}, ESP)

    self._label, self._box_color = nil, nil
    self._dist_m, self._dist_color = nil, nil
    self._hp_key, self._name_color = nil, nil

    self.box = Instance.new("Frame")
    self.box.BackgroundTransparency = 1
    self.box.BorderSizePixel = 0
    self.box.ZIndex = 2
    self.box.Visible = false
    self.box.Parent = esp_gui
    self.stroke = Instance.new("UIStroke")
    self.stroke.Thickness = 1
    self.stroke.Parent = self.box

    self.name = Instance.new("TextLabel")
    self.name.BackgroundTransparency = 1
    self.name.Font = Enum.Font.GothamMedium
    self.name.TextSize = 12
    self.name.TextColor3 = Color3_fromRGB(255, 255, 255)
    self.name.AnchorPoint = Vector2_new(0.5, 0)
    self.name.AutomaticSize = Enum.AutomaticSize.XY
    self.name.ZIndex = 3
    self.name.Visible = false
    self.name.Parent = esp_gui
    local ns = Instance.new("UIStroke")
    ns.Thickness = 1
    ns.Color = Color3_fromRGB(0, 0, 0)
    ns.Parent = self.name

    self.dist = Instance.new("TextLabel")
    self.dist.BackgroundTransparency = 1
    self.dist.Font = Enum.Font.Gotham
    self.dist.TextSize = 11
    self.dist.TextColor3 = Color3_fromRGB(255, 255, 255)
    self.dist.AnchorPoint = Vector2_new(0.5, 0)
    self.dist.AutomaticSize = Enum.AutomaticSize.XY
    self.dist.ZIndex = 3
    self.dist.Visible = false
    self.dist.Parent = esp_gui
    local ds = Instance.new("UIStroke")
    ds.Thickness = 1
    ds.Color = Color3_fromRGB(0, 0, 0)
    ds.Parent = self.dist

    self.hp_bg = Instance.new("Frame")
    self.hp_bg.BackgroundColor3 = Color3_fromRGB(10, 10, 10)
    self.hp_bg.BorderSizePixel = 0
    self.hp_bg.ZIndex = 2
    self.hp_bg.Visible = false
    self.hp_bg.Parent = esp_gui

    self.hp = Instance.new("Frame")
    self.hp.BorderSizePixel = 0
    self.hp.ZIndex = 3
    self.hp.Parent = self.hp_bg

    return self
end

function ESP:hide()
    self.box.Visible = false
    self.name.Visible = false
    self.dist.Visible = false
    self.hp_bg.Visible = false
end

function ESP:destroy()
    self.box:Destroy()
    self.name:Destroy()
    self.dist:Destroy()
    self.hp_bg:Destroy()
end

function ESP:render(char, hum, label, color, dist_studs)
    local pos, size = body_box(char)
    if not pos then
        self:hide()
        return
    end

    local cx = pos.X + size.X * 0.5

    self.box.Visible = CONFIG.esp.box
    if self.box.Visible then
        self.box.Position = UDim2_fromOffset(pos.X, pos.Y)
        self.box.Size = UDim2_fromOffset(size.X, size.Y)
        if self._box_color ~= color then
            self._box_color = color
            self.stroke.Color = color
        end
    end

    self.name.Visible = CONFIG.esp.name
    if self.name.Visible then
        self.name.Position = UDim2_fromOffset(cx, pos.Y - 18)
        if self._label ~= label then
            self._label = label
            self.name.Text = label
        end
        if self._name_color ~= color then
            self._name_color = color
            self.name.TextColor3 = color
        end
    end

    self.dist.Visible = CONFIG.esp.distance
    if self.dist.Visible then
        self.dist.Position = UDim2_fromOffset(cx, pos.Y + size.Y + 2)
        local meters = math.floor(dist_studs * 0.28)
        if self._dist_m ~= meters then
            self._dist_m = meters
            self.dist.Text = string.format("%d m", meters)
        end
        if self._dist_color ~= color then
            self._dist_color = color
            self.dist.TextColor3 = color
        end
    end

    if CONFIG.esp.health and hum then
        local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
        self.hp_bg.Visible = true
        self.hp_bg.Position = UDim2_fromOffset(pos.X - 6, pos.Y)
        self.hp_bg.Size = UDim2_fromOffset(3, size.Y)
        local hp_key = math.floor(frac * 100)
        if self._hp_key ~= hp_key then
            self._hp_key = hp_key
            self.hp.Position = UDim2_new(0, 0, 1 - frac, 0)
            self.hp.Size = UDim2_new(1, 0, frac, 0)
            self.hp.BackgroundColor3 = Color3_fromRGB(255, 70, 70):Lerp(Color3_fromRGB(70, 255, 70), frac)
        end
    else
        self.hp_bg.Visible = false
    end
end

-- ==== fov circle ====

local fov_circle = Instance.new("Frame")
fov_circle.AnchorPoint = Vector2.new(0.5, 0.5)
fov_circle.BackgroundTransparency = 1
fov_circle.BorderSizePixel = 0
fov_circle.ZIndex = 4
fov_circle.Visible = false
fov_circle.Parent = esp_gui
local fov_stroke = Instance.new("UIStroke")
fov_stroke.Thickness = 1
fov_stroke.Color = Color3.fromRGB(255, 255, 255)
fov_stroke.Transparency = 0.5
fov_stroke.Parent = fov_circle
local fov_corner = Instance.new("UICorner")
fov_corner.CornerRadius = UDim.new(1, 0)
fov_corner.Parent = fov_circle
local fov_aspect = Instance.new("UIAspectRatioConstraint")
fov_aspect.AspectRatio = 1
fov_aspect.Parent = fov_circle

-- ==== ESP pools ====

local player_esp = {}
local npc_esp = {}
local npc_cache = {}
local corpse_esp = {}
local corpse_cache = {}

-- ==== off-screen indicators ====

local OFFSCREEN_MARGIN = 50
local offscreen_indicators = {}

local function get_offscreen_indicator(color)
    for _, ind in ipairs(offscreen_indicators) do
        if not ind.in_use and ind.color == color then
            ind.in_use = true
            ind.arrow.Visible = true
            return ind
        end
    end
    local arrow = Instance.new("ImageLabel")
    arrow.BackgroundTransparency = 1
    arrow.Image = "rbxassetid://13177036320"
    arrow.Size = UDim2.fromOffset(28, 28)
    arrow.ZIndex = 5
    arrow.Visible = false
    arrow.Parent = esp_gui
    local ind = { arrow = arrow, color = color, in_use = true }
    offscreen_indicators[#offscreen_indicators + 1] = ind
    return ind
end

local function clear_offscreen_indicators()
    for _, ind in ipairs(offscreen_indicators) do
        ind.in_use = false
        ind.arrow.Visible = false
        ind.arrow.ImageColor3 = Color3.fromRGB(255, 255, 255)
    end
end

local function update_offscreen_indicators(camera)
    clear_offscreen_indicators()
    if not CONFIG.esp.enabled then return end
    local viewport = camera.ViewportSize
    local center = viewport * 0.5
    local cam_cframe = camera.CFrame
    local cam_pos = cam_cframe.Position
    local cam_look = cam_cframe.LookVector
    local cam_right = cam_cframe.RightVector

    local function process_target(world_pos, color, label, dist)
        local sp, on_screen = camera:WorldToViewportPoint(world_pos)
        if on_screen and sp.Z > 0 then return end

        local rel = world_pos - cam_pos
        if rel.Magnitude < 1 then return end
        local dir = rel.Unit

        local angle = math.atan2(dir:Dot(cam_right), dir:Dot(cam_look))
        local radius = math.min(viewport.X, viewport.Y) * 0.5 - OFFSCREEN_MARGIN
        local screen_x = center.X + math.sin(angle) * radius
        local screen_y = center.Y - math.cos(angle) * radius

        screen_x = math.clamp(screen_x, OFFSCREEN_MARGIN, viewport.X - OFFSCREEN_MARGIN)
        screen_y = math.clamp(screen_y, OFFSCREEN_MARGIN, viewport.Y - OFFSCREEN_MARGIN)

        local ind = get_offscreen_indicator(color)
        ind.arrow.Position = UDim2.fromOffset(screen_x, screen_y)
        ind.arrow.Rotation = math.deg(angle) + 90
        ind.arrow.ImageColor3 = color
    end

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            local friendly = is_friendly(plr)
            if not (CONFIG.esp.team_check and friendly) then
                local char, _, root = get_character(plr)
                if char and root then
                    local dist = (root.Position - cam_pos).Magnitude
                    if dist <= CONFIG.esp.max_distance then
                        local color = friendly and CONFIG.esp.team_color or CONFIG.esp.enemy_color
                        process_target(root.Position, color, plr.Name, dist)
                    end
                end
            end
        end
    end

    if CONFIG.esp.include_npcs then
        for _, e in ipairs(npc_cache) do
            local root = e.root
            if e.hum.Parent and root and root.Parent then
                local dist = (root.Position - cam_pos).Magnitude
                if dist <= CONFIG.esp.max_distance then
                    process_target(root.Position, CONFIG.esp.npc_color, "NPC", dist)
                end
            end
        end
    end

    if CONFIG.esp.include_corpses then
        for _, e in ipairs(corpse_cache) do
            local root = e.root
            if root and root.Parent then
                local dist = (root.Position - cam_pos).Magnitude
                if dist <= CONFIG.esp.max_distance then
                    process_target(root.Position, CONFIG.esp.corpse_color, e.label, dist)
                end
            end
        end
    end
end

-- ==== ESP update ====

local function hide_all_esp()
    for _, esp in pairs(player_esp) do esp:hide() end
    for _, esp in pairs(npc_esp) do esp:hide() end
    for _, esp in pairs(corpse_esp) do esp:hide() end
end

-- ==== entity tracker ====

local tracked_hums = {}
local tracker_stopped = false

local function track_humanoid(hum)
    if tracked_hums[hum] ~= nil then return end
    local model = hum.Parent
    if not model or not model:IsA("Model") then return end
    tracked_hums[hum] = model
end

local function on_workspace_added(d)
    if d:IsA("Humanoid") then
        track_humanoid(d)
    elseif d:IsA("Model") then
        local h = d:FindFirstChildOfClass("Humanoid")
        if h then track_humanoid(h) end
    end
end

local function scan_workspace_sliced()
    local stack = { Workspace }
    local n = 0
    while #stack > 0 and not tracker_stopped do
        local node = stack[#stack]
        stack[#stack] = nil
        local ok, kids = pcall(node.GetChildren, node)
        if ok then
            for i = 1, #kids do
                local k = kids[i]
                if k:IsA("Humanoid") then track_humanoid(k) end
                stack[#stack + 1] = k
            end
        end
        n = n + 1
        if n % 150 == 0 then task.wait() end
    end
end

local CORPSE_LIMIT = 48
local NPC_LIMIT = 256

local function rebuild_entity_caches()
    local player_chars = {}
    for _, p in ipairs(Players:GetPlayers()) do
        local c = p.Character
        if c then player_chars[c] = p end
    end

    local origin
    local lp_char = LP.Character
    if lp_char then
        local lr = lp_char:FindFirstChild("HumanoidRootPart")
        if lr then origin = lr.Position end
    end

    local alive, dead = {}, {}
    for hum, model in pairs(tracked_hums) do
        if not hum.Parent or not model.Parent or not model:IsDescendantOf(Workspace) then
            tracked_hums[hum] = nil
        else
            local root = model_root(model)
            if hum.Health > 0 then
                if not player_chars[model] then
                    alive[#alive + 1] = { model = model, hum = hum, root = root }
                end
            else
                local owner = player_chars[model]
                dead[#dead + 1] = {
                    model = model, hum = hum, root = root,
                    label = owner and (owner.Name .. " (dead)") or "Corpse",
                }
            end
        end
    end

    if origin then
        local sort_by_dist = (function(a, b)
            local da = a.root and a.root.Parent and (a.root.Position - origin).Magnitude or math.huge
            local db = b.root and b.root.Parent and (b.root.Position - origin).Magnitude or math.huge
            return da < db
        end)
        if #alive > NPC_LIMIT then
            table.sort(alive, sort_by_dist)
            for i = NPC_LIMIT + 1, #alive do alive[i] = nil end
        end
        if #dead > CORPSE_LIMIT then
            table.sort(dead, sort_by_dist)
            for i = CORPSE_LIMIT + 1, #dead do dead[i] = nil end
        end
    end

    npc_cache = alive
    corpse_cache = dead
end

local function update_esp(camera)
    hide_all_esp()
    local cam_pos = camera.CFrame.Position
    local current_players = {}

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP then
            current_players[plr] = true
            local esp = player_esp[plr]
            if not esp then
                esp = ESP.new()
                player_esp[plr] = esp
            end

            local char, hum, root = get_character(plr)
            local friendly = is_friendly(plr)
            local dist = root and (root.Position - cam_pos).Magnitude or math.huge
            local drawable = char ~= nil
                and dist <= CONFIG.esp.max_distance
                and not (CONFIG.esp.team_check and friendly and not CONFIG.esp.show_teammates)

            if drawable then
                local color = friendly and CONFIG.esp.team_color or CONFIG.esp.enemy_color
                esp:render(char, hum, plr.Name, color, dist)
            else
                esp:hide()
            end
        end
    end

    for plr, esp in pairs(player_esp) do
        if not current_players[plr] then
            esp:destroy()
            player_esp[plr] = nil
        end
    end

    if not (CONFIG.esp.enabled and CONFIG.esp.include_npcs) then
        for _, esp in pairs(npc_esp) do esp:hide() end
    else
        local active = {}
        for _, e in ipairs(npc_cache) do
            active[e.model] = true
            local esp = npc_esp[e.model]
            if not esp then
                esp = ESP.new()
                npc_esp[e.model] = esp
            end
            local root = e.root
            local dist = root and root.Parent and (root.Position - cam_pos).Magnitude or math.huge
            if e.hum.Parent and e.hum.Health > 0 and dist <= CONFIG.esp.max_distance then
                esp:render(e.model, e.hum, "NPC", CONFIG.esp.npc_color, dist)
            else
                esp:hide()
            end
        end
        for model, esp in pairs(npc_esp) do
            if not active[model] then
                esp:destroy()
                npc_esp[model] = nil
            end
        end
    end

    if not (CONFIG.esp.enabled and CONFIG.esp.include_corpses) then
        for _, esp in pairs(corpse_esp) do esp:hide() end
    else
        local active = {}
        for _, e in ipairs(corpse_cache) do
            active[e.model] = true
            local esp = corpse_esp[e.model]
            if not esp then
                esp = ESP.new()
                corpse_esp[e.model] = esp
            end
            local root = e.root
            local dist = root and root.Parent and (root.Position - cam_pos).Magnitude or math.huge
            if e.hum.Parent and e.hum.Health <= 0 and dist <= CONFIG.esp.max_distance then
                esp:render(e.model, e.hum, e.label, CONFIG.esp.corpse_color, dist)
            else
                esp:hide()
            end
        end
        for model, esp in pairs(corpse_esp) do
            if not active[model] then
                esp:destroy()
                corpse_esp[model] = nil
            end
        end
    end
end

-- ==== aimbot ====

local function get_best_target(camera)
    local center  = camera.ViewportSize * 0.5
    local cam_pos = camera.CFrame.Position
    local best, best_score = nil, math.huge

    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LP and not (CONFIG.aim.team_check and is_friendly(plr)) then
            local char, _, root = get_character(plr)
            if char then
                local part = char:FindFirstChild(CONFIG.aim.hit_part) or root
                if part then
                    local dist = (part.Position - cam_pos).Magnitude
                    if dist <= CONFIG.aim.max_distance then
                        local sp, on_screen = camera:WorldToViewportPoint(part.Position)
                        if on_screen and sp.Z > 0 then
                            local offset = (Vector2.new(sp.X, sp.Y) - center).Magnitude
                            if offset <= CONFIG.aim.fov and offset < best_score
                                and (not CONFIG.aim.wall_check or is_visible(char, part.Position)) then
                                best, best_score = plr, offset
                            end
                        end
                    end
                end
            end
        end
    end
    return best, best_score
end

-- ==== Minimap / Radar ====

local minimap_gui = nil
local minimap_container = nil
local minimap_background = nil
local minimap_border = nil
local minimap_center_dot = nil
local minimap_dots = {}
local minimap_labels = {}
local MINIMAP_DOT_POOL = {}

local function create_minimap()
    if minimap_gui then return end

    local size = CONFIG.esp.minimap_size
    local pos = CONFIG.esp.minimap_position
    local viewport = Workspace.CurrentCamera and Workspace.CurrentCamera.ViewportSize or Vector2.new(1920, 1080)

    local x, y = 20, 20
    if pos == "topright" then
        x = viewport.X - size - 20
        y = 20
    elseif pos == "bottomleft" then
        x = 20
        y = viewport.Y - size - 20
    elseif pos == "bottomright" then
        x = viewport.X - size - 20
        y = viewport.Y - size - 20
    end

    minimap_gui = Instance.new("ScreenGui")
    minimap_gui.Name = "BrN_Minimap"
    minimap_gui.ResetOnSpawn = false
    minimap_gui.IgnoreGuiInset = true
    minimap_gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    minimap_gui.DisplayOrder = 997
    minimap_gui.Parent = esp_gui.Parent

    minimap_container = Instance.new("Frame")
    minimap_container.Name = "Container"
    minimap_container.Size = UDim2.fromOffset(size, size)
    minimap_container.Position = UDim2.fromOffset(x, y)
    minimap_container.BackgroundTransparency = 1
    minimap_container.ClipsDescendants = true
    minimap_container.Parent = minimap_gui

    if CONFIG.esp.minimap_background then
        minimap_background = Instance.new("Frame")
        minimap_background.Name = "Background"
        minimap_background.Size = UDim2.fromScale(1, 1)
        minimap_background.BackgroundColor3 = CONFIG.esp.minimap_bg_color
        minimap_background.BorderSizePixel = 0
        minimap_background.ZIndex = 1
        minimap_background.Parent = minimap_container
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 4)
        corner.Parent = minimap_background

        minimap_border = Instance.new("UIStroke")
        minimap_border.Color = CONFIG.esp.minimap_border_color
        minimap_border.Thickness = 1
        minimap_border.Parent = minimap_background
    end

    minimap_center_dot = Instance.new("Frame")
    minimap_center_dot.Name = "CenterDot"
    minimap_center_dot.Size = UDim2.fromOffset(6, 6)
    minimap_center_dot.AnchorPoint = Vector2.new(0.5, 0.5)
    minimap_center_dot.Position = UDim2.fromScale(0.5, 0.5)
    minimap_center_dot.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    minimap_center_dot.BorderSizePixel = 0
    minimap_center_dot.ZIndex = 10
    minimap_center_dot.Parent = minimap_container
    local ccorner = Instance.new("UICorner")
    ccorner.CornerRadius = UDim.new(1, 0)
    ccorner.Parent = minimap_center_dot
    local cstroke = Instance.new("UIStroke")
    cstroke.Color = Color3.fromRGB(0, 0, 0)
    cstroke.Thickness = 1
    cstroke.Parent = minimap_center_dot

    local compass = Instance.new("TextLabel")
    compass.Name = "Compass"
    compass.Size = UDim2.fromOffset(size, 20)
    compass.Position = UDim2.fromScale(0, 0)
    compass.BackgroundTransparency = 1
    compass.Text = "N"
    compass.TextColor3 = Color3.fromRGB(200, 200, 200)
    compass.TextSize = 12
    compass.Font = Enum.Font.GothamBold
    compass.ZIndex = 11
    compass.Parent = minimap_container

    local legend = Instance.new("TextLabel")
    legend.Name = "Legend"
    legend.Size = UDim2.fromOffset(size - 10, 60)
    legend.Position = UDim2.fromOffset(5, size - 65)
    legend.BackgroundTransparency = 1
    legend.Text = "● Enemy  ● Team  ● NPC  ■ Corpse"
    legend.TextColor3 = Color3.fromRGB(180, 180, 180)
    legend.TextSize = 10
    legend.Font = Enum.Font.Gotham
    legend.TextXAlignment = Enum.TextXAlignment.Left
    legend.TextYAlignment = Enum.TextYAlignment.Top
    legend.ZIndex = 11
    legend.Parent = minimap_container
end

local MINIMAP_FREES = {}
local MINIMAP_IN_USE = {}

local function dot_key(color, square)
    return string.format("%d_%d_%d_%s",
        math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5),
        square and "s" or "c")
end

local function acquire_dot(color, square)
    local key = dot_key(color, square)
    local stack = MINIMAP_FREES[key]
    local dot
    if stack and #stack > 0 then
        dot = stack[#stack]
        stack[#stack] = nil
        dot.frame.BackgroundColor3 = color
        dot.frame.Visible = true
    else
        local frame = Instance.new("Frame")
        local px = square and 5 or 6
        frame.Size = UDim2.fromOffset(px, px)
        frame.AnchorPoint = Vector2.new(0.5, 0.5)
        frame.BackgroundColor3 = color
        frame.BorderSizePixel = 0
        frame.Visible = true
        frame.ZIndex = 5
        frame.Parent = minimap_container
        if not square then
            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(1, 0)
            corner.Parent = frame
        end
        dot = { frame = frame, key = key, in_use = true, is_square = square }
        MINIMAP_DOT_POOL[#MINIMAP_DOT_POOL + 1] = dot
    end
    dot.in_use = true
    MINIMAP_IN_USE[#MINIMAP_IN_USE + 1] = dot
    return dot
end

local function get_minimap_dot(color) return acquire_dot(color, false) end
local function get_minimap_square(color) return acquire_dot(color, true) end

local function clear_minimap_dots()
    for i = #MINIMAP_IN_USE, 1, -1 do
        local dot = MINIMAP_IN_USE[i]
        dot.in_use = false
        dot.frame.Visible = false
        local stack = MINIMAP_FREES[dot.key]
        if not stack then
            stack = {}
            MINIMAP_FREES[dot.key] = stack
        end
        stack[#stack + 1] = dot
        MINIMAP_IN_USE[i] = nil
    end
end

local function reset_minimap_pool()
    for _, dot in ipairs(MINIMAP_DOT_POOL) do pcall(function() dot.frame:Destroy() end) end
    MINIMAP_DOT_POOL = {}
    MINIMAP_FREES = {}
    MINIMAP_IN_USE = {}
end

local function world_to_minimap(world_pos, cam_pos, cam_look, cam_right, size, range, rotation_enabled)
    local relative = world_pos - cam_pos
    local dist = relative.Magnitude
    if dist > range then return nil end

    local scale = size / (range * 2)
    local x, z

    if rotation_enabled then
        x = relative:Dot(cam_right) * scale
        z = relative:Dot(cam_look) * scale
    else
        x = relative.X * scale
        z = -relative.Z * scale
    end

    local center = size * 0.5
    local screen_x = center + x
    local screen_y = center - z

    local margin = 4
    if screen_x < margin or screen_x > size - margin or screen_y < margin or screen_y > size - margin then
        return nil
    end

    return Vector2.new(screen_x, screen_y), dist
end

local function update_minimap(camera)
    if not CONFIG.esp.enabled or not CONFIG.esp.minimap_enabled then
        if minimap_gui then minimap_gui.Enabled = false end
        clear_minimap_dots()
        return
    end

    if not minimap_gui then
        create_minimap()
    end
    minimap_gui.Enabled = true

    local cam_pos = camera.CFrame.Position
    local cam_look = camera.CFrame.LookVector
    local cam_right = camera.CFrame.RightVector
    local size = CONFIG.esp.minimap_size
    local range = CONFIG.esp.minimap_range
    local rotation = CONFIG.esp.minimap_rotation

    clear_minimap_dots()

    if CONFIG.esp.minimap_show_players then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= LP then
                local char, _, root = get_character(plr)
                if char and root then
                    local friendly = is_friendly(plr)
                    if friendly and not CONFIG.esp.minimap_show_team then continue end
                    if not friendly and not CONFIG.esp.minimap_show_players then continue end

                    local pos, dist = world_to_minimap(root.Position, cam_pos, cam_look, cam_right, size, range, rotation)
                    if pos then
                        local color = friendly and CONFIG.esp.team_color or CONFIG.esp.enemy_color
                        local dot = get_minimap_dot(color)
                        dot.frame.Position = UDim2.fromOffset(pos.X, pos.Y)
                    end
                end
            end
        end
    end

    if CONFIG.esp.minimap_show_npcs then
        for _, e in ipairs(npc_cache) do
            local root = e.root
            if e.hum.Parent and e.hum.Health > 0 and root and root.Parent then
                local pos = world_to_minimap(root.Position, cam_pos, cam_look, cam_right, size, range, rotation)
                if pos then
                    local dot = get_minimap_dot(CONFIG.esp.npc_color)
                    dot.frame.Position = UDim2.fromOffset(pos.X, pos.Y)
                end
            end
        end
    end

    if CONFIG.esp.minimap_show_corpses then
        for _, e in ipairs(corpse_cache) do
            local root = e.root
            if root and root.Parent then
                local pos = world_to_minimap(root.Position, cam_pos, cam_look, cam_right, size, range, rotation)
                if pos then
                    local dot = get_minimap_square(CONFIG.esp.corpse_color)
                    dot.frame.Position = UDim2.fromOffset(pos.X, pos.Y)
                end
            end
        end
    end
end

local AIM_STATE = { last_target = nil, origin_screen = nil }

local function aim_step(target_plr)
    local char = target_plr.Character
    if not char then return end
    local part = char:FindFirstChild(CONFIG.aim.hit_part) or char:FindFirstChild("HumanoidRootPart")
    if not part then return end

    local camera = Workspace.CurrentCamera
    if not camera then return end
    local sp, on_screen = camera:WorldToViewportPoint(part.Position)
    if not on_screen or sp.Z <= 0 then return end

    if AIM_STATE.last_target ~= target_plr then
        AIM_STATE.last_target = target_plr
    end

    local origin_screen
    if UserInputService.MouseBehavior == Enum.MouseBehavior.Default then
        origin_screen = UserInputService:GetMouseLocation() - Vector2.new(0, GuiService:GetGuiInset().Y)
    else
        origin_screen = camera.ViewportSize * 0.5
    end
    AIM_STATE.origin_screen = origin_screen

    local delta = Vector2.new(sp.X, sp.Y) - origin_screen
    local speed = math.clamp(((CONFIG.aim.speed or 16) / 100) * SESSION.speed_scale, 0.01, 1)
    local step = delta * speed
    local max_step = CONFIG.aim.max_step * SESSION.step_scale
    if step.Magnitude > max_step then
        step = step.Unit * max_step
    end

    if CONFIG.aim.humanize and CONFIG.aim.jitter > 0 then
        local closeness = 1 - math.clamp(delta.Magnitude / math.max(CONFIG.aim.fov, 1), 0, 1)
        local amp = CONFIG.aim.jitter * closeness
        if amp > 0 then
            step = step + Vector2.new(
                (math.random() * 2 - 1) * amp,
                (math.random() * 2 - 1) * amp
            )
        end
    end

    if step.Magnitude < 0.05 then return end

    local mm = ANTI_HOOK.originals.mousemoverel or mousemoverel
    local use_mouse = (CONFIG.aim.method == "mouse")
        or (CONFIG.aim.method == "auto" and type(mm) == "function")

    if use_mouse and type(mm) == "function" then
        mm(step.X, step.Y)
    else
        local look = CFrame.lookAt(camera.CFrame.Position, part.Position)
        camera.CFrame = camera.CFrame:Lerp(look, speed)
    end
end

-- ==== AC recon ====

local AC_KEYWORDS = {
    "anticheat", "anti_cheat", "anti-cheat", "integrity", "clientcheck", "client_check",
    "ac_client", "acclient", "guard", "shield", "watchdog", "honeypot", "exploit",
}

local function matches_ac(name)
    local n = string.lower(name)
    for _, kw in ipairs(AC_KEYWORDS) do
        if string.find(n, kw, 1, true) then return true end
    end
    return false
end

local function scan_ac()
    local hits = {}
    local containers = {
        LP:FindFirstChild("PlayerScripts"),
        game:GetService("ReplicatedFirst"),
        game:GetService("ReplicatedStorage"),
    }
    for _, root in ipairs(containers) do
        if root then
            for _, d in ipairs(root:GetDescendants()) do
                if (d:IsA("LocalScript") or d:IsA("ModuleScript") or d:IsA("Script"))
                    and matches_ac(d.Name) then
                    hits[#hits + 1] = d:GetFullName()
                end
            end
        end
    end
    pcall(function()
        for _, d in ipairs(game:GetService("CoreGui"):GetDescendants()) do
            if (d:IsA("LocalScript") or d:IsA("ModuleScript")) and matches_ac(d.Name) then
                hits[#hits + 1] = d:GetFullName()
            end
        end
    end)
    if #hits > 0 then
        print("[BrN] AC candidates:")
        for _, h in ipairs(hits) do print("  " .. h) end
    else
        print("[BrN] AC candidates: none by name")
    end
end

-- ==== lifecycle ====

local connections = {}
local running = true

local Rayfield = nil
local Window = nil
local antihook_status = nil

local function bind(conn)
    connections[#connections + 1] = conn
end

local function on_character_added(char)
    task.wait(0.5)
    if running then
        print("[BrN] LP character respawned")
    end
end

if LP.Character then
    on_character_added(LP.Character)
end
bind(LP.CharacterAdded:Connect(on_character_added))
bind(Workspace.DescendantAdded:Connect(on_workspace_added))

local unloaded = false

local function unload()
    if unloaded then return end
    unloaded = true
    running = false
    tracker_stopped = true

    task.wait(0.1)

    local genv = (type(getgenv) == "function" and getgenv()) or _G
    local exp = genv.BrN_Hub
    if exp and exp.config == CONFIG then
        exp.config.aim.enabled = false
        exp.config.esp.enabled = false
        genv.BrN_Hub = nil
    end
    CONFIG.aim.enabled = false
    CONFIG.esp.enabled = false
    ANTI_HOOK.enabled = false
    ANTI_HOOK.originals = {}

    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    connections = {}

    if Rayfield then
        pcall(function() Rayfield:Destroy() end)
    end
    Rayfield = nil
    Window = nil

    for _, esp in pairs(player_esp) do pcall(function() esp:destroy() end) end
    for _, esp in pairs(npc_esp) do pcall(function() esp:destroy() end) end
    for _, esp in pairs(corpse_esp) do pcall(function() esp:destroy() end) end
    for _, ind in ipairs(offscreen_indicators) do pcall(function() ind.arrow:Destroy() end) end
    if minimap_gui then pcall(function() minimap_gui:Destroy() end) end
    reset_minimap_pool()
    player_esp = {}
    npc_esp = {}
    npc_cache = {}
    corpse_esp = {}
    corpse_cache = {}
    tracked_hums = {}
    offscreen_indicators = {}
    MINIMAP_DOT_POOL = {}
    minimap_gui = nil
    minimap_container = nil
    minimap_background = nil
    minimap_border = nil
    minimap_center_dot = nil

    for _, g in ipairs(screens) do
        pcall(function() g:Destroy() end)
    end
    screens = {}

    print("[BrN] unloaded — hooks removed, GUI destroyed, loops stopped")
end

local function sleep_running(seconds)
    for _ = 1, math.ceil(seconds / 0.25) do
        if not running then return end
        task.wait(0.25)
    end
end

-- ==== menu (Rayfield Gen2) ====

local RAYFIELD_SRC = "https://sirius.menu/rayfield"

local function build_menu()
    local ok_lib, RayfieldLib = pcall(function()
        return loadstring(game:HttpGet(RAYFIELD_SRC))()
    end)
    if not ok_lib or type(RayfieldLib) ~= "table" then
        print("[BrN] Rayfield load failed:", tostring(RayfieldLib))
        return false
    end
    Rayfield = RayfieldLib

    local Win = Rayfield:CreateWindow({
        Name = "BrN Hub",
        LoadingTitle = "BrN Hub",
        LoadingSubtitle = "By BreNo",
        ConfigurationSaving = {
            Enabled = true,
            FolderName = "BrNHub",
            FileName = "BrNHubConfig"
        },
        Discord = { Enabled = false },
        KeySystem = false,
    })
    Window = Win

    Rayfield:Notify({
        Title = "BrN Hub",
        Content = "v3.4 loaded — RightShift menu",
        Duration = 4,
        Image = 4483362458,
    })

    local function minimap_rebuild()
        if minimap_gui then pcall(function() minimap_gui:Destroy() end) end
        minimap_gui = nil
        minimap_container = nil
        minimap_background = nil
        minimap_border = nil
        minimap_center_dot = nil
        reset_minimap_pool()
    end

    -- // AIM
    local AimTab = Win:CreateTab("AIM", 4483362458)
    AimTab:CreateSection("Aimbot")
    AimTab:CreateToggle({
        Name = "Enabled",
        CurrentValue = CONFIG.aim.enabled,
        Flag = "AimEnabled",
        Callback = function(v) CONFIG.aim.enabled = v end,
    })
    AimTab:CreateDropdown({
        Name = "Method",
        Options = { "auto", "mouse", "camera" },
        CurrentOption = { CONFIG.aim.method },
        MultipleOptions = false,
        Flag = "AimMethod",
        Callback = function(Option)
            CONFIG.aim.method = Option[1]
        end,
    })
    AimTab:CreateDropdown({
        Name = "Hitbox",
        Options = { "Head", "UpperTorso", "HumanoidRootPart" },
        CurrentOption = { CONFIG.aim.hit_part },
        MultipleOptions = false,
        Flag = "AimHitbox",
        Callback = function(Option)
            CONFIG.aim.hit_part = Option[1]
        end,
    })
    AimTab:CreateToggle({
        Name = "Wall check",
        CurrentValue = CONFIG.aim.wall_check,
        Flag = "AimWall",
        Callback = function(v) CONFIG.aim.wall_check = v end,
    })
    AimTab:CreateToggle({
        Name = "Ignore teammates",
        CurrentValue = CONFIG.aim.team_check,
        Flag = "AimTeam",
        Callback = function(v) CONFIG.aim.team_check = v end,
    })
    AimTab:CreateToggle({
        Name = "Humanize",
        CurrentValue = CONFIG.aim.humanize,
        Flag = "AimHumanize",
        Callback = function(v) CONFIG.aim.humanize = v end,
    })
    AimTab:CreateSlider({
        Name = "Jitter",
        Range = { 0, 5 },
        Increment = 1,
        Suffix = "px",
        CurrentValue = CONFIG.aim.jitter,
        Flag = "AimJitter",
        Callback = function(v) CONFIG.aim.jitter = v end,
    })

    AimTab:CreateSection("General")
    AimTab:CreateSlider({
        Name = "FOV",
        Range = { 20, 400 },
        Increment = 1,
        Suffix = "px",
        CurrentValue = CONFIG.aim.fov,
        Flag = "AimFOV",
        Callback = function(v) CONFIG.aim.fov = v end,
    })
    AimTab:CreateSlider({
        Name = "Aim speed",
        Range = { 2, 100 },
        Increment = 1,
        Suffix = "%",
        CurrentValue = CONFIG.aim.speed,
        Flag = "AimSpeed",
        Callback = function(v) CONFIG.aim.speed = v end,
    })
    AimTab:CreateSlider({
        Name = "Max step",
        Range = { 5, 120 },
        Increment = 1,
        Suffix = "px",
        CurrentValue = CONFIG.aim.max_step,
        Flag = "AimMaxStep",
        Callback = function(v) CONFIG.aim.max_step = v end,
    })
    AimTab:CreateSlider({
        Name = "Max distance",
        Range = { 50, 1000 },
        Increment = 10,
        Suffix = "studs",
        CurrentValue = CONFIG.aim.max_distance,
        Flag = "AimMaxDist",
        Callback = function(v) CONFIG.aim.max_distance = v end,
    })
    AimTab:CreateToggle({
        Name = "Visualize FOV",
        CurrentValue = CONFIG.aim.show_fov,
        Flag = "AimShowFOV",
        Callback = function(v) CONFIG.aim.show_fov = v end,
    })
    AimTab:CreateColorPicker({
        Name = "Circle color",
        Color = CONFIG.aim.fov_color,
        Flag = "AimFOVColor",
        Callback = function(v) CONFIG.aim.fov_color = v end,
    })

    -- // VISUAL
    local VisTab = Win:CreateTab("VISUAL", 4483362458)
    VisTab:CreateSection("ESP")
    VisTab:CreateToggle({
        Name = "Enabled",
        CurrentValue = CONFIG.esp.enabled,
        Flag = "EspEnabled",
        Callback = function(v)
            CONFIG.esp.enabled = v
            if not v then hide_all_esp() end
        end,
    })
    VisTab:CreateToggle({
        Name = "Box",
        CurrentValue = CONFIG.esp.box,
        Flag = "EspBox",
        Callback = function(v) CONFIG.esp.box = v end,
    })
    VisTab:CreateToggle({
        Name = "Name",
        CurrentValue = CONFIG.esp.name,
        Flag = "EspName",
        Callback = function(v) CONFIG.esp.name = v end,
    })
    VisTab:CreateToggle({
        Name = "Distance",
        CurrentValue = CONFIG.esp.distance,
        Flag = "EspDistance",
        Callback = function(v) CONFIG.esp.distance = v end,
    })
    VisTab:CreateToggle({
        Name = "Health bar",
        CurrentValue = CONFIG.esp.health,
        Flag = "EspHealth",
        Callback = function(v) CONFIG.esp.health = v end,
    })
    VisTab:CreateToggle({
        Name = "Ignore teammates",
        CurrentValue = CONFIG.esp.team_check,
        Flag = "EspTeamCheck",
        Callback = function(v) CONFIG.esp.team_check = v end,
    })
    VisTab:CreateToggle({
        Name = "Show teammates",
        CurrentValue = CONFIG.esp.show_teammates,
        Flag = "EspShowTeam",
        Callback = function(v) CONFIG.esp.show_teammates = v end,
    })
    VisTab:CreateToggle({
        Name = "NPC ESP",
        CurrentValue = CONFIG.esp.include_npcs,
        Flag = "EspNPC",
        Callback = function(v) CONFIG.esp.include_npcs = v end,
    })
    VisTab:CreateToggle({
        Name = "Corpse ESP",
        CurrentValue = CONFIG.esp.include_corpses,
        Flag = "EspCorpse",
        Callback = function(v) CONFIG.esp.include_corpses = v end,
    })
    VisTab:CreateSlider({
        Name = "Max distance",
        Range = { 50, 1500 },
        Increment = 10,
        Suffix = "studs",
        CurrentValue = CONFIG.esp.max_distance,
        Flag = "EspMaxDist",
        Callback = function(v) CONFIG.esp.max_distance = v end,
    })

    VisTab:CreateSection("Radar")
    VisTab:CreateToggle({
        Name = "Minimap",
        CurrentValue = CONFIG.esp.minimap_enabled,
        Flag = "MinimapEnabled",
        Callback = function(v)
            CONFIG.esp.minimap_enabled = v
            minimap_rebuild()
        end,
    })
    VisTab:CreateDropdown({
        Name = "Position",
        Options = { "topright", "topleft", "bottomright", "bottomleft" },
        CurrentOption = { CONFIG.esp.minimap_position },
        MultipleOptions = false,
        Flag = "MinimapPos",
        Callback = function(Option)
            CONFIG.esp.minimap_position = Option[1]
            minimap_rebuild()
        end,
    })
    VisTab:CreateSlider({
        Name = "Size",
        Range = { 100, 400 },
        Increment = 10,
        Suffix = "px",
        CurrentValue = CONFIG.esp.minimap_size,
        Flag = "MinimapSize",
        Callback = function(v)
            CONFIG.esp.minimap_size = v
            minimap_rebuild()
        end,
    })
    VisTab:CreateSlider({
        Name = "Range",
        Range = { 200, 3000 },
        Increment = 50,
        Suffix = "studs",
        CurrentValue = CONFIG.esp.minimap_range,
        Flag = "MinimapRange",
        Callback = function(v) CONFIG.esp.minimap_range = v end,
    })
    VisTab:CreateToggle({
        Name = "Show players",
        CurrentValue = CONFIG.esp.minimap_show_players,
        Flag = "MinimapPlayers",
        Callback = function(v) CONFIG.esp.minimap_show_players = v end,
    })
    VisTab:CreateToggle({
        Name = "Show team",
        CurrentValue = CONFIG.esp.minimap_show_team,
        Flag = "MinimapTeam",
        Callback = function(v) CONFIG.esp.minimap_show_team = v end,
    })
    VisTab:CreateToggle({
        Name = "Show NPCs",
        CurrentValue = CONFIG.esp.minimap_show_npcs,
        Flag = "MinimapNPCs",
        Callback = function(v) CONFIG.esp.minimap_show_npcs = v end,
    })
    VisTab:CreateToggle({
        Name = "Show corpses",
        CurrentValue = CONFIG.esp.minimap_show_corpses,
        Flag = "MinimapCorpses",
        Callback = function(v) CONFIG.esp.minimap_show_corpses = v end,
    })
    VisTab:CreateToggle({
        Name = "Rotate with camera",
        CurrentValue = CONFIG.esp.minimap_rotation,
        Flag = "MinimapRot",
        Callback = function(v) CONFIG.esp.minimap_rotation = v end,
    })
    VisTab:CreateToggle({
        Name = "Background",
        CurrentValue = CONFIG.esp.minimap_background,
        Flag = "MinimapBg",
        Callback = function(v)
            CONFIG.esp.minimap_background = v
            if minimap_background then minimap_background.Visible = v end
            if minimap_border then minimap_border.Visible = v end
        end,
    })
    VisTab:CreateColorPicker({
        Name = "Bg color",
        Color = CONFIG.esp.minimap_bg_color,
        Flag = "MinimapBgColor",
        Callback = function(v) CONFIG.esp.minimap_bg_color = v end,
    })

    VisTab:CreateSection("Colors")
    VisTab:CreateColorPicker({
        Name = "Enemy",
        Color = CONFIG.esp.enemy_color,
        Flag = "EspEnemyColor",
        Callback = function(v) CONFIG.esp.enemy_color = v end,
    })
    VisTab:CreateColorPicker({
        Name = "Team",
        Color = CONFIG.esp.team_color,
        Flag = "EspTeamColor",
        Callback = function(v) CONFIG.esp.team_color = v end,
    })
    VisTab:CreateColorPicker({
        Name = "NPC",
        Color = CONFIG.esp.npc_color,
        Flag = "EspNPCColor",
        Callback = function(v) CONFIG.esp.npc_color = v end,
    })
    VisTab:CreateColorPicker({
        Name = "Corpse",
        Color = CONFIG.esp.corpse_color,
        Flag = "EspCorpseColor",
        Callback = function(v) CONFIG.esp.corpse_color = v end,
    })

    -- // MISC
    local MiscTab = Win:CreateTab("MISC", 4483362458)
    MiscTab:CreateSection("Antihook")
    MiscTab:CreateToggle({
        Name = "Integrity guard",
        CurrentValue = ANTI_HOOK.enabled,
        Flag = "AntihookEnabled",
        Callback = function(v) ANTI_HOOK.enabled = v end,
    })
    MiscTab:CreateButton({
        Name = "Re-snapshot",
        Callback = function()
            snapshot_exec()
            print("[BrN] antihook: re-snapshot done")
        end,
    })
    MiscTab:CreateButton({
        Name = "Verify now",
        Callback = verify_exec,
    })
    MiscTab:CreateButton({
        Name = "Unload (F4)",
        Callback = unload,
    })

    task.spawn(function()
        while running do
            local watched = 0
            for _ in pairs(ANTI_HOOK.originals) do watched = watched + 1 end
            task.wait(1)
        end
    end)

    return true
end

do
    local ok, err = pcall(build_menu)
    if ok then
        print("[BrN] BrN Hub menu ready")
    else
        print("[BrN] menu build failed:", err)
    end
end

-- ==== loops ====

task.spawn(function()
    scan_workspace_sliced()
    while running do
        pcall(rebuild_entity_caches)
        sleep_running(4)
    end
end)

task.spawn(function()
    while running do
        pcall(resolve_team)
        sleep_running((TEAM.squad or TEAM.faction) and 15 or 4)
    end
end)

task.spawn(function()
    while running do
        if ANTI_HOOK.enabled then pcall(verify_exec) end
        sleep_running(5)
    end
end)

local VIS_INTERVAL = 1 / 30
local vis_last = 0

bind(RunService.RenderStepped:Connect(function()
    if not running then return end
    local camera = Workspace.CurrentCamera
    if not camera then return end

    -- visual layer (ESP/offscreen/minimap) runs at 30 Hz max; aim stays per-frame
    local now = os.clock()
    if now - vis_last >= VIS_INTERVAL then
        vis_last = now
        if CONFIG.esp.enabled then
            pcall(update_esp, camera)
            pcall(update_offscreen_indicators, camera)
            pcall(update_minimap, camera)
        else
            hide_all_esp()
            clear_offscreen_indicators()
            if minimap_gui then minimap_gui.Enabled = false end
            clear_minimap_dots()
        end
    end

    local aiming = CONFIG.aim.enabled
        and UserInputService:IsMouseButtonPressed(CONFIG.aim.input)

    if not aiming then
        AIM_STATE.last_target = nil
        AIM_STATE.origin_screen = nil
    end

    local viewport = camera.ViewportSize
    fov_circle.Visible = CONFIG.aim.enabled and CONFIG.aim.show_fov
    if fov_circle.Visible then
        fov_circle.Position = UDim2.fromOffset(viewport.X * 0.5, viewport.Y * 0.5)
        fov_circle.Size = UDim2.fromOffset(CONFIG.aim.fov * 2, CONFIG.aim.fov * 2)
        fov_stroke.Color = CONFIG.aim.fov_color
    end

    if minimap_container and minimap_gui and minimap_gui.Enabled then
        local pos = CONFIG.esp.minimap_position
        local size = CONFIG.esp.minimap_size
        local x, y = 20, 20
        if pos == "topright" then
            x = viewport.X - size - 20
            y = 20
        elseif pos == "bottomleft" then
            x = 20
            y = viewport.Y - size - 20
        elseif pos == "bottomright" then
            x = viewport.X - size - 20
            y = viewport.Y - size - 20
        end
        minimap_container.Position = UDim2.fromOffset(x, y)
    end

    if aiming then
        local ok, target = pcall(get_best_target, camera)
        if ok and target then
            pcall(aim_step, target)
        end
    end
end))

bind(Players.PlayerRemoving:Connect(function(plr)
    local esp = player_esp[plr]
    if esp then
        esp:destroy()
        player_esp[plr] = nil
    end
    if npc_esp[plr] then
        npc_esp[plr]:destroy()
        npc_esp[plr] = nil
    end
    resolve_team()
end))

bind(Players.PlayerAdded:Connect(function()
    resolve_team()
end))

bind(UserInputService.InputBegan:Connect(function(input, game_processed)
    if not running then return end
    if game_processed then return end
    if input.KeyCode == Enum.KeyCode.F2 then
        CONFIG.esp.enabled = not CONFIG.esp.enabled
        if not CONFIG.esp.enabled then hide_all_esp() end
        print("[BrN] ESP:", CONFIG.esp.enabled and "on" or "off")
    elseif input.KeyCode == Enum.KeyCode.F3 then
        CONFIG.aim.enabled = not CONFIG.aim.enabled
        print("[BrN] AIM:", CONFIG.aim.enabled and "on" or "off")
    elseif input.KeyCode == Enum.KeyCode.F4 then
        unload()
    end
end))

-- ==== export ====

local genv = (type(getgenv) == "function" and getgenv()) or _G
genv.BrN_Hub = {
    config = CONFIG,
    unload = unload,
    esp = player_esp,
    npc_esp = npc_esp,
    corpse_esp = corpse_esp,
    team = TEAM,
    resolve_team = resolve_team,
    dump_team = dump_team,
    antihook = ANTI_HOOK,
    snapshot_exec = snapshot_exec,
    verify_exec = verify_exec,
    toggle_menu = function()
        if Window then
            pcall(function() Window:Toggle() end)
        end
    end,
}

print("[BrN] BrN Hub loaded — RightShift menu · RMB aim · F2 ESP · F3 aim · F4 unload")
if CONFIG.recon then
    pcall(scan_ac)
end
pcall(resolve_team)
