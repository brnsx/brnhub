--// BrN Hub - Dead Rails (Rayfield UI)
--// Targets NPCs only (zombies, werewolves, outlaws, etc.), never players.
--// Your camera is never moved: the game's own shot is redirected to the target.

----------------------------------------------------------------
-- (added) unload older builds from the generator so their hooks go quiet
----------------------------------------------------------------
do
    local e = (getgenv and getgenv()) or _G
    if e.DR_SilentAim then pcall(e.DR_SilentAim.Unload, true) e.DR_SilentAim = nil end
    if e.DR_ShopHelper then pcall(e.DR_ShopHelper.Unload, true) e.DR_ShopHelper = nil end
end

local Players          = game:GetService("Players")
local RunService       = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService       = game:GetService("GuiService")
local Workspace        = game:GetService("Workspace")
local Stats            = game:GetService("Stats")

local LocalPlayer = Players.LocalPlayer
local Camera      = Workspace.CurrentCamera

-- All console output in this script goes through print / warn below, which are
-- SILENT by default. Turn "Console output" on in the Settings tab if you ever
-- want the debug text (vault codes, reports, remote logs) in the console again.
local Console = { on = false }
local rawprint, rawwarn = print, warn
local function print(...) if Console.on then rawprint(...) end end
local function warn(...) if Console.on then rawwarn(...) end end

----------------------------------------------------------------
-- UNLOAD SYSTEM
-- If an older copy of this script is still running, it is unloaded first,
-- then this copy takes its place. The Quit button calls the same function.
----------------------------------------------------------------
local env = (getgenv and getgenv()) or _G
if env.DeadRailsAimUnload then
    pcall(env.DeadRailsAimUnload)
end

-- Shared state read by the (single) silent-aim hooks. Lives in env so re-running the
-- script reuses the same hooks instead of stacking new ones.
env.DeadRailsSilent = env.DeadRailsSilent or {}
local Silent = env.DeadRailsSilent
Silent.active, Silent.point, Silent.part, Silent.log = false, nil, nil, false
Silent.armfix = false -- (revert) silences arm-fix hooks left over in this session

local Running = true
local Connections = {}
local RayfieldWindow -- Rayfield window reference
local RayfieldLib -- Rayfield library reference
local Circle -- FOV circle frame
local VaultFolder -- assigned in the VAULT ESP section

local function Unload()
    Running = false
    Silent.active, Silent.point, Silent.part, Silent.log = false, nil, nil, false
    pcall(function() RunService:UnbindFromRenderStep("DeadRailsAim") end) -- from older versions
    for _, c in pairs(Connections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(Connections)
    if Circle then
        pcall(function() Circle:Destroy() end)
        Circle = nil
    end
    if RayfieldWindow and RayfieldWindow.Destroy then
        pcall(function() RayfieldWindow:Destroy() end)
    elseif RayfieldLib and RayfieldLib.Destroy then
        pcall(function() RayfieldLib:Destroy() end)
    end
    RayfieldWindow = nil
    if VaultFolder then
        pcall(function() VaultFolder:Destroy() end)
        VaultFolder = nil
    end
    if env.DRCollect then env.DRCollect.part = nil end
    if env.DRReach then
        env.DRReach.on = false
        if env.DRReach.restore then pcall(env.DRReach.restore) end
    end
    if env.DRAirWeld then
        local a = env.DRAirWeld
        a.on, a.log, a.held, a.heldPos, a.train = false, false, nil, nil, nil
    end
    if env.DRVisual and env.DRVisual.restore then pcall(env.DRVisual.restore) end
    if env.DRReload and env.DRReload.restore then pcall(env.DRReload.restore) end
    if env.DRMove and env.DRMove.restore then pcall(env.DRMove.restore) end
    if env.DeadRailsAimUnload == Unload then
        env.DeadRailsAimUnload = nil
    end
end
env.DeadRailsAimUnload = Unload

----------------------------------------------------------------
-- SILENT AIM HOOKS
----------------------------------------------------------------
local HooksSupported = (hookmetamethod and getnamecallmethod and setnamecallmethod
    and checkcaller and newcclosure) and true or false

local IsA, IsDescendantOf, GetFullName = game.IsA, game.IsDescendantOf, game.GetFullName
local GUN_WORDS = { "shoot", "fire", "gun", "bullet", "hit", "weapon", "damage", "attack", "shot" }

local function looksLikeGunRemote(name)
    name = name:lower()
    for _, w in ipairs(GUN_WORDS) do
        if name:find(w, 1, true) then return true end
    end
    return false
end

local function getPoint()
    local base = Silent.base or Silent.point
    local vel  = Silent.vel or Vector3.zero
    local dt   = (os.clock() - (Silent.t or os.clock())) + (Silent.lead or 0)
    local shift = vel * dt
    if shift.Magnitude > 10 then shift = shift.Unit * 10 end
    return base + shift
end

local function rewriteArgs(args)
    local camPos = Workspace.CurrentCamera.CFrame.Position
    local point, part = getPoint(), Silent.part
    local char = LocalPlayer.Character
    for i = 1, args.n do
        local a = args[i]
        local t = typeof(a)
        if t == "Vector3" then
            if math.abs(a.Magnitude - 1) < 0.02 then
                args[i] = (point - camPos).Unit
            elseif (a - camPos).Magnitude > 12 then
                args[i] = point
            end
        elseif t == "CFrame" then
            if (a.Position - camPos).Magnitude > 12 then
                args[i] = CFrame.new(point)
            else
                args[i] = CFrame.new(a.Position, point)
            end
        elseif t == "Instance" and IsA(a, "BasePart") and not (char and IsDescendantOf(a, char)) then
            args[i] = part
        end
    end
end

if HooksSupported and not env.DeadRailsHooked then
    env.DeadRailsHooked = true
    local mouse = LocalPlayer:GetMouse()
    local lastLog = {}

    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod()
        if (Silent.active or Silent.log) and not checkcaller() then
            if method == "FireServer" and IsA(self, "RemoteEvent") then
                local args = table.pack(...)
                local name = self.Name
                if Silent.log then
                    local now = os.clock()
                    if not lastLog[name] or now - lastLog[name] > 0.5 then
                        lastLog[name] = now
                        local parts = {}
                        for i = 1, args.n do
                            parts[i] = typeof(args[i]) .. ":" .. tostring(args[i])
                        end
                        print("[DeadRailsAim] FireServer " .. GetFullName(self) .. "(" .. table.concat(parts, ", ") .. ")")
                    end
                end
                if Silent.active and Silent.point and looksLikeGunRemote(name) then
                    pcall(rewriteArgs, args)
                    setnamecallmethod(method)
                    return oldNamecall(self, table.unpack(args, 1, args.n))
                end
                setnamecallmethod(method)
            elseif method == "Raycast" and Silent.active and Silent.point and self == Workspace then
                local origin, direction, params = ...
                if typeof(origin) == "Vector3" and typeof(direction) == "Vector3"
                    and direction.Magnitude >= 80
                    and (origin - Workspace.CurrentCamera.CFrame.Position).Magnitude < 25 then
                    setnamecallmethod(method)
                    return oldNamecall(self, origin, (getPoint() - origin).Unit * direction.Magnitude, params)
                end
            end
        end
        return oldNamecall(self, ...)
    end))

    local oldIndex
    oldIndex = hookmetamethod(game, "__index", newcclosure(function(self, key)
        if Silent.active and Silent.point and self == mouse and not checkcaller() then
            if key == "Hit" then
                return CFrame.new(getPoint())
            elseif key == "Target" then
                return Silent.part
            end
        end
        return oldIndex(self, key)
    end))
end

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------
local Config = {
    Silent      = false,
    AimPart     = "Head",
    FOV         = 400,
    Unlimited   = false,
    MaxDistance = 400,
    WallCheck   = true,
    Lead        = true,
    AutoLead    = true,
    LeadTime    = 0.02,
    ShowFOV     = true,
    LogRemotes  = false,
    Targets     = {
        Zombie   = true,
        Werewolf = true,
        Outlaw   = true,
        Other    = true,
    },
}

local Keywords = {
    Zombie   = { "zombie", "runner", "walker", "undead", "ghoul" },
    Werewolf = { "werewolf", "wolf" },
    Outlaw   = { "outlaw", "bandit", "sniper", "turret", "gunman", "cowboy" },
}

local function classify(name)
    name = name:lower()
    for category, words in pairs(Keywords) do
        for _, w in ipairs(words) do
            if name:find(w, 1, true) then return category end
        end
    end
    return "Other"
end

----------------------------------------------------------------
-- NPC CACHE
----------------------------------------------------------------
local NPCs = {}
local NPCMap = {}

local function isPlayerCharacter(model)
    return Players:GetPlayerFromCharacter(model) ~= nil
end

local function addHumanoid(inst)
    local model = inst.Parent
    if model and model:IsA("Model") and not NPCMap[model] and not isPlayerCharacter(model) then
        local e = { model = model, humanoid = inst, kind = classify(model.Name) }
        NPCMap[model] = e
        table.insert(NPCs, e)
    end
end

local function cleanup()
    local i = 1
    while i <= #NPCs do
        local e = NPCs[i]
        if not e.model.Parent or not e.humanoid.Parent or isPlayerCharacter(e.model) then
            NPCMap[e.model] = nil
            NPCs[i] = NPCs[#NPCs]
            NPCs[#NPCs] = nil
        else
            i = i + 1
        end
    end
end

task.spawn(function()
    local all = Workspace:GetDescendants()
    for i, inst in ipairs(all) do
        if not Running then return end
        if inst:IsA("Humanoid") then addHumanoid(inst) end
        if i % 4000 == 0 then task.wait() end
    end
end)

Connections.added = Workspace.DescendantAdded:Connect(function(inst)
    if inst.ClassName == "Humanoid" then
        task.defer(addHumanoid, inst)
    end
end)

task.spawn(function()
    while Running do
        pcall(cleanup)
        task.wait(1)
    end
end)

local PingMs = 0
local PingInfo = { net = 0, data = 0, hist = {} }
Config.PingMode = "Network"

local function samplePing()
    local net, data
    pcall(function()
        local p = LocalPlayer:GetNetworkPing()
        if type(p) == "number" and p > 0 then net = p * 1000 end
    end)
    pcall(function()
        local v = Stats.Network.ServerStatsItem["Data Ping"]:GetValue()
        if type(v) == "number" and v > 0 then data = v end
    end)
    if net then PingInfo.net = net end
    if data then PingInfo.data = data end

    local raw
    if Config.PingMode == "Data Ping" then
        raw = data or (net and net * 2)
    elseif Config.PingMode == "Network x2" then
        raw = (net and net * 2) or data
    else
        raw = net or data
    end
    if not raw then return end

    local h = PingInfo.hist
    h[#h + 1] = raw
    if #h > 5 then table.remove(h, 1) end
    local s = table.clone(h)
    table.sort(s)
    local med = s[math.ceil(#s / 2)]
    PingMs = (PingMs == 0) and med or (PingMs + (med - PingMs) * 0.5)
end

local function autoLead()
    local t = math.clamp((PingMs - 40) / 110, 0, 1)
    return math.min((PingMs / 1000) * (0.5 + 0.5 * t), 0.3)
end

local Track = setmetatable({}, { __mode = "k" })

local function trackVelocities()
    local now = os.clock()
    for _, npc in ipairs(NPCs) do
        local root = npc.model:FindFirstChild("HumanoidRootPart") or npc.model.PrimaryPart
        if root then
            local st = Track[npc.model]
            if not st then
                st = { pos = root.Position, t = now, vel = Vector3.zero }
                Track[npc.model] = st
            else
                local dt = now - st.t
                if dt >= 0.25 then
                    st.pos, st.t, st.vel = root.Position, now, Vector3.zero
                elseif dt > 1e-3 then
                    local v = (root.Position - st.pos) / dt
                    if v.Magnitude > 120 then v = v.Unit * 120 end
                    st.vel = st.vel:Lerp(v, 0.5)
                    st.pos, st.t = root.Position, now
                end
            end
        end
    end
end

----------------------------------------------------------------
-- TARGETING
----------------------------------------------------------------
local function getAimPart(model)
    if Config.AimPart == "Head" then
        return model:FindFirstChild("Head")
    end
    return model:FindFirstChild("UpperTorso")
        or model:FindFirstChild("Torso")
        or model:FindFirstChild("HumanoidRootPart")
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local function isVisible(point, model)
    if not Config.WallCheck then return true end
    local origin = Camera.CFrame.Position
    local filter = { model }
    if LocalPlayer.Character then table.insert(filter, LocalPlayer.Character) end
    rayParams.FilterDescendantsInstances = filter
    local hit = Workspace:Raycast(origin, point - origin, rayParams)
    return hit == nil or (hit.Position - point).Magnitude < 1.5
end

local function pickTarget(mouse)
    local camPos = Camera.CFrame.Position
    local look = Camera:ViewportPointToRay(mouse.X, mouse.Y).Direction.Unit
    local list = {}

    for _, npc in ipairs(NPCs) do
        if Config.Targets[npc.kind] and npc.model.Parent and npc.humanoid.Health > 0 then
            local part = getAimPart(npc.model)
            if part then
                local point  = part.Position
                local offset = point - camPos
                if offset.Magnitude <= Config.MaxDistance and offset.Magnitude > 0.01 then
                    local score
                    if Config.Unlimited then
                        score = math.acos(math.clamp(look:Dot(offset.Unit), -1, 1))
                    else
                        local pos, onScreen = Camera:WorldToViewportPoint(point)
                        if onScreen then
                            local d = (Vector2.new(pos.X, pos.Y) - mouse).Magnitude
                            if d <= Config.FOV then score = d end
                        end
                    end
                    if score then
                        table.insert(list, { part = part, model = npc.model, npc = npc, score = score })
                    end
                end
            end
        end
    end

    table.sort(list, function(a, b) return a.score < b.score end)
    for i = 1, math.min(#list, 3) do
        if isVisible(list[i].part.Position, list[i].model) then
            return list[i].part, list[i].npc
        end
    end
    return nil
end

----------------------------------------------------------------
-- VAULT ESP
----------------------------------------------------------------
Config.VaultESP = true

local Vaults, Bankers, Notes = {}, {}, {}
local CODE_WORDS = { "code", "combo", "combination", "pin", "password", "passcode" }

local function hasWord(s, list)
    s = string.lower(tostring(s))
    for _, w in ipairs(list) do
        if string.find(s, w, 1, true) then return true end
    end
    return false
end

local function digitsFrom(v, loose)
    if type(v) == "number" then
        if v >= 100 and v < 100000000 and v == math.floor(v) then return tostring(v) end
        return nil
    end
    if type(v) ~= "string" then return nil end
    local d = string.match(v, "%d%d%d%d%d?%d?%d?%d?")
    if d then return d end
    if loose then
        local all = string.gsub(v, "%D", "")
        if #all >= 3 and #all <= 8 then return all end
    end
    return nil
end

local function checkInst(d, trusted)
    local ok, attrs = pcall(function() return d:GetAttributes() end)
    if ok then
        for k, v in pairs(attrs) do
            if hasWord(k, CODE_WORDS) then
                local c = digitsFrom(v, true)
                if c then return c, "attribute '" .. k .. "' on " .. d.Name end
            end
        end
    end
    if d:IsA("ValueBase") and (trusted or hasWord(d.Name, CODE_WORDS)) then
        local okv, val = pcall(function() return d.Value end)
        local c = okv and digitsFrom(val, true)
        if c then return c, "value '" .. d.Name .. "'" end
    end
    if d:IsA("TextLabel") or d:IsA("TextBox") or d:IsA("TextButton") then
        local t = d.Text
        if t and t ~= "" then
            local hint = trusted or hasWord(t, CODE_WORDS) or hasWord(d.Name, CODE_WORDS)
                or (d.Parent and hasWord(d.Parent.Name, CODE_WORDS))
            if hint then
                local c = digitsFrom(t, true)
                if c then return c, "text on " .. d.Name end
            end
        end
    end
    return nil
end

local function findCode(root, trusted)
    if not root or not root.Parent then return nil end
    local c, src = checkInst(root, trusted)
    if c then return c, src end
    local ok, desc = pcall(function() return root:GetDescendants() end)
    if not ok then return nil end
    for i = 1, math.min(#desc, 1500) do
        c, src = checkInst(desc[i], trusted)
        if c then return c, src end
    end
    return nil
end

local function posPart(inst)
    if inst:IsA("BasePart") then return inst end
    if inst:IsA("Model") then
        return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
    end
    return inst:FindFirstChildWhichIsA("BasePart", true)
end

local function bankOf(vault)
    local a = vault.Parent
    for _ = 1, 4 do
        if not a or a == Workspace then return nil end
        if hasWord(a.Name, { "bank" }) then return a end
        a = a.Parent
    end
    return nil
end

local function insideTracked(inst)
    local a = inst.Parent
    for _ = 1, 3 do
        if not a then return false end
        if Vaults[a] or Notes[a] or Bankers[a] then return true end
        a = a.Parent
    end
    return false
end

local function trackThing(inst)
    local n = string.lower(inst.Name)
    local isModel = inst:IsA("Model")
    if isModel and string.find(n, "vault", 1, true) then
        if not Vaults[inst] and not insideTracked(inst) then Vaults[inst] = {} end
    elseif isModel and string.find(n, "banker", 1, true) then
        if not Bankers[inst] then Bankers[inst] = {} end
    elseif (string.find(n, "combo", 1, true) or string.find(n, "combination", 1, true))
        and (isModel or inst:IsA("BasePart") or inst:IsA("Tool")) then
        if not Notes[inst] and not insideTracked(inst) then Notes[inst] = {} end
    elseif (string.find(n, "note", 1, true) or string.find(n, "letter", 1, true)
        or (string.find(n, "paper", 1, true) and not string.find(n, "newspaper", 1, true)))
        and (isModel or inst:IsA("Tool")) then
        if not Notes[inst] and not insideTracked(inst) then Notes[inst] = { weak = true } end
    end
end

do
    local espParent = (gethui and gethui()) or game:GetService("CoreGui")
    local oldF = espParent:FindFirstChild("DRVaultESP")
    if oldF then oldF:Destroy() end
    VaultFolder = Instance.new("Folder")
    VaultFolder.Name = "DRVaultESP"
    VaultFolder.Parent = espParent
end

local function makeTag(adornee, color)
    local b = Instance.new("BillboardGui")
    b.Adornee = adornee
    b.Size = UDim2.fromOffset(240, 46)
    b.StudsOffset = Vector3.new(0, 4, 0)
    b.AlwaysOnTop = true
    b.LightInfluence = 0
    local t = Instance.new("TextLabel")
    t.Size = UDim2.fromScale(1, 1)
    t.BackgroundTransparency = 1
    t.Font = Enum.Font.GothamBold
    t.TextSize = 14
    t.TextColor3 = color
    t.TextStrokeTransparency = 0.3
    t.TextWrapped = true
    t.Parent = b
    b.Parent = VaultFolder
    return b, t
end

local function nearest(list, pos, maxDist)
    local best, bestD = nil, maxDist
    for inst in pairs(list) do
        local p = inst.Parent and posPart(inst)
        if p then
            local d = (p.Position - pos).Magnitude
            if d < bestD then best, bestD = inst, d end
        end
    end
    return best
end

local function dropDead(list)
    for inst, e in pairs(list) do
        if not inst.Parent then
            if e.tag then pcall(function() e.tag:Destroy() end) end
            if e.hl then pcall(function() e.hl:Destroy() end) end
            list[inst] = nil
        end
    end
end

local function dumpVaults()
    local lines = 0
    local function dump(label, root)
        print("[VaultESP] ---- " .. label .. ": " .. GetFullName(root))
        local all = { root }
        for _, d in ipairs(root:GetDescendants()) do table.insert(all, d) end
        for _, d in ipairs(all) do
            if lines > 120 then return end
            local ok, attrs = pcall(function() return d:GetAttributes() end)
            if ok then
                for k, v in pairs(attrs) do
                    print(("   attr  %s.%s = %s"):format(d.Name, k, tostring(v))); lines = lines + 1
                end
            end
            if d:IsA("ValueBase") then
                print(("   value %s = %s"):format(d.Name, tostring(d.Value))); lines = lines + 1
            elseif d:IsA("TextLabel") or d:IsA("TextBox") then
                if d.Text ~= "" then print(("   text  %s = %q"):format(d.Name, d.Text)); lines = lines + 1 end
            end
        end
    end
    local n = 0
    for v in pairs(Vaults) do n = n + 1 pcall(dump, "VAULT", v) end
    for b in pairs(Bankers) do pcall(dump, "BANKER", b) end
    for no in pairs(Notes) do pcall(dump, "NOTE", no) end
    print(("[VaultESP] %d vault(s) tracked. Send this output if no code shows up."):format(n))
end

Config.VaultNearby = true
Config.VaultRange  = 1500

local function townOf(inst)
    local full = GetFullName(inst)
    local n = tonumber(string.match(full, "[Tt]own_?(%d+)"))
        or tonumber(string.match(full, "[Tt]own%s+(%d+)"))
    return n, full
end

local function vaultText()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local myPos = (root and root.Position) or Workspace.CurrentCamera.CFrame.Position
    local rows = {}
    for inst, e in pairs(Vaults) do
        if inst.Parent then
            local p = posPart(inst)
            local dist = p and (p.Position - myPos).Magnitude or math.huge
            if not Config.VaultNearby or dist <= Config.VaultRange then
                local town, full = townOf(inst)
                local destroyed = string.find(full, "Destroyed", 1, true) ~= nil
                rows[#rows + 1] = {
                    dist = dist,
                    name = full,
                    text = ("Town %s%s:  %s  (%d st)"):format(
                        town and tostring(town) or "?",
                        destroyed and " (destroyed)" or "",
                        e.code and tostring(e.code) or "?",
                        dist == math.huge and 0 or math.floor(dist)),
                }
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.dist ~= b.dist then return a.dist < b.dist end
        return a.name < b.name
    end)
    local lines = {}
    for i, r in ipairs(rows) do lines[i] = r.text end
    if #lines == 0 then
        return Config.VaultNearby
            and ("No vaults within %d studs - get closer to a town"):format(Config.VaultRange)
            or "No vaults found yet"
    end
    return table.concat(lines, "\n")
end

----------------------------------------------------------------
-- EXTRA VAULT CODE SOURCES
----------------------------------------------------------------
local STRICT_WORDS = { "vault", "bank", "combo", "combination", "safe" }
local GlobalCode, GlobalSrc = nil, nil

local function setGlobal(c, src)
    if c and c ~= GlobalCode then
        GlobalCode, GlobalSrc = c, src
        print(("[VaultESP] code found: %s  (from %s)"):format(c, tostring(src)))
    end
end

local function strictCheck(d)
    local nameHit = hasWord(d.Name, STRICT_WORDS)
    local ok, attrs = pcall(function() return d:GetAttributes() end)
    if ok then
        for k, v in pairs(attrs) do
            if hasWord(k, STRICT_WORDS) or (nameHit and hasWord(k, CODE_WORDS)) then
                local c = digitsFrom(v, true)
                if c then return c, "attribute " .. GetFullName(d) .. "." .. k end
            end
        end
    end
    if nameHit and d:IsA("ValueBase") then
        local okv, val = pcall(function() return d.Value end)
        local c = okv and digitsFrom(val, true)
        if c then return c, "value " .. GetFullName(d) end
    end
    if d:IsA("TextLabel") or d:IsA("TextBox") then
        local t = d.Text
        if t and t ~= "" and (nameHit or hasWord(t, STRICT_WORDS)) then
            local c = digitsFrom(t, false)
            if c then return c, "text " .. GetFullName(d) end
        end
    end
    return nil
end

local function scanGlobals()
    local roots = { LocalPlayer }
    pcall(function() table.insert(roots, 1, game:GetService("ReplicatedStorage")) end)
    for _, r in ipairs(roots) do
        local c, src = strictCheck(r)
        if c then setGlobal(c, src) return end
        local ok, desc = pcall(function() return r:GetDescendants() end)
        if ok then
            for i, d in ipairs(desc) do
                if not Running then return end
                c, src = strictCheck(d)
                if c then setGlobal(c, src) return end
                if i % 1500 == 0 then task.wait() end
            end
        end
    end
    local c, src = strictCheck(Workspace)
    if c then setGlobal(c, src) end
end

task.spawn(function()
    while Running do
        if Config.VaultESP and not GlobalCode then pcall(scanGlobals) end
        task.wait(10)
    end
end)

local function argCode(remoteName, ...)
    local nameHit = hasWord(remoteName, STRICT_WORDS)
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "string" then
            if nameHit or hasWord(v, STRICT_WORDS) then
                local c = digitsFrom(v, false)
                if c then return c end
            end
        elseif type(v) == "number" and nameHit then
            local c = digitsFrom(v, false)
            if c then return c end
        elseif type(v) == "table" then
            local okp, res = pcall(function()
                for k, val in pairs(v) do
                    if type(k) == "string" and (hasWord(k, STRICT_WORDS)
                        or (nameHit and hasWord(k, CODE_WORDS))) then
                        local c = digitsFrom(val, true)
                        if c then return c end
                    end
                end
            end)
            if okp and res then return res end
        end
    end
    return nil
end

local sniffed = setmetatable({}, { __mode = "k" })
local function sniff(r)
    if sniffed[r] or r.ClassName ~= "RemoteEvent" then return end
    sniffed[r] = true
    table.insert(Connections, r.OnClientEvent:Connect(function(...)
        if not Running then return end
        local c = argCode(r.Name, ...)
        if c then setGlobal(c, "server message via " .. r.Name) end
    end))
end

task.spawn(function()
    local ok, desc = pcall(function() return game:GetService("ReplicatedStorage"):GetDescendants() end)
    if not ok then return end
    for i, d in ipairs(desc) do
        if not Running then return end
        if d.ClassName == "RemoteEvent" then sniff(d) end
        if i % 2000 == 0 then task.wait() end
    end
end)
pcall(function()
    Connections.sniffAdded = game:GetService("ReplicatedStorage").DescendantAdded:Connect(function(d)
        if d.ClassName == "RemoteEvent" then sniff(d) end
    end)
end)

pcall(function()
    local pg = LocalPlayer:WaitForChild("PlayerGui", 5)
    if pg then
        Connections.pgAdded = pg.DescendantAdded:Connect(function(d)
            if d.ClassName == "TextLabel" or d.ClassName == "TextBox" then
                task.delay(0.15, function()
                    if Running and d.Parent then
                        local c, src = strictCheck(d)
                        if c then setGlobal(c, src) end
                    end
                end)
            end
        end)
    end
end)

local GC_WORDS = { "vaultcode", "bankcode", "vault_code", "bank_code", "combo",
    "combination", "safecode", "vaultcombo" }

local function deepScan()
    if not getgc then
        print("[VaultESP] your executor has no getgc - deep scan unavailable")
        return
    end
    print("[VaultESP] deep scan started...")
    local ok, gc = pcall(getgc, true)
    if not ok or type(gc) ~= "table" then print("[VaultESP] getgc failed") return end
    local hits = 0
    for i = 1, #gc do
        if not Running then return end
        local v = gc[i]
        if type(v) == "table" then
            pcall(function()
                for k, val in next, v do
                    if type(k) == "string" then
                        local lk = string.lower(k)
                        local strong = hasWord(lk, GC_WORDS)
                        local weak = (lk == "code" or lk == "vault" or lk == "pin")
                        if strong or weak then
                            local c = digitsFrom(val, false)
                            if c and #c >= 4 and #c <= 6 then
                                hits = hits + 1
                                print(("[VaultESP] deep hit: %s = %s%s"):format(k, c, strong and "" or " (weak)"))
                                if strong then setGlobal(c, "memory key '" .. k .. "'") end
                            end
                        end
                    end
                end
            end)
        end
        if i % 15000 == 0 then task.wait() end
    end
    print(("[VaultESP] deep scan done, %d candidate(s)"):format(hits))
    if not GlobalCode then
        print("[VaultESP] nothing found: the code is most likely kept on the server until the banker drops the note")
    end
end

task.spawn(function()
    local all = Workspace:GetDescendants()
    for i, inst in ipairs(all) do
        if not Running then return end
        local cn = inst.ClassName
        if cn == "Model" or cn == "Part" or cn == "MeshPart" or cn == "Tool" or cn == "UnionOperation" then
            trackThing(inst)
        end
        if i % 4000 == 0 then task.wait() end
    end
end)

Connections.vaultAdded = Workspace.DescendantAdded:Connect(function(inst)
    local cn = inst.ClassName
    if cn == "Model" or cn == "Part" or cn == "MeshPart" or cn == "Tool" or cn == "UnionOperation" then
        trackThing(inst)
    end
end)

task.spawn(function()
    local step = 0
    while Running do
        step = step + 1
        pcall(function()
            dropDead(Vaults); dropDead(Bankers); dropDead(Notes)
            local on = Config.VaultESP
            local camPos = Workspace.CurrentCamera.CFrame.Position
            local searchNow = (step % 4 == 1)

            for inst, e in pairs(Notes) do
                local p = posPart(inst)
                if p then
                    if searchNow and not e.code then
                        e.code, e.src = findCode(inst, not e.weak)
                        if e.code then setGlobal(e.code, "note " .. inst.Name) end
                    end
                    if e.weak and not e.code then
                        if e.tag then e.tag.Enabled = false end
                    else
                        if not e.tag then e.tag, e.label = makeTag(p, Color3.fromRGB(120, 255, 160)) end
                        e.tag.Enabled = on
                        e.label.Text = ("BANK COMBO NOTE  %s\n%d st"):format(
                            e.code and ("[" .. e.code .. "]") or "[?]", (p.Position - camPos).Magnitude)
                    end
                end
            end

            for inst, e in pairs(Bankers) do
                local p = posPart(inst)
                if p then
                    if searchNow and not e.code then e.code, e.src = findCode(inst, false) end
                    if not e.tag then e.tag, e.label = makeTag(p, Color3.fromRGB(255, 140, 90)) end
                    e.tag.Enabled = on
                    e.label.Text = ("BANKER (drops code)  %s\n%d st"):format(
                        e.code and ("[" .. e.code .. "]") or "", (p.Position - camPos).Magnitude)
                end
            end

            for inst, e in pairs(Vaults) do
                local p = posPart(inst)
                if p then
                    if searchNow and not e.code then
                        local c, src = findCode(inst, false)
                        if not c then c, src = findCode(bankOf(inst), false) end
                        if not c then
                            local nb = nearest(Bankers, p.Position, 250)
                            if nb and Bankers[nb].code then c, src = Bankers[nb].code, "banker" end
                        end
                        if not c then
                            local nn = nearest(Notes, p.Position, 400)
                            if nn and Notes[nn].code then c, src = Notes[nn].code, "combo note" end
                        end
                        if not c and GlobalCode then c, src = GlobalCode, GlobalSrc end
                        if c and c ~= e.code then
                            print(("[VaultESP] %s code = %s  (from %s)"):format(GetFullName(inst), c, tostring(src)))
                        end
                        e.code, e.src = c, src
                    end
                    if not e.tag then
                        e.tag, e.label = makeTag(p, Color3.fromRGB(255, 210, 60))
                        local h = Instance.new("Highlight")
                        h.Adornee = inst
                        h.FillColor = Color3.fromRGB(255, 200, 40)
                        h.FillTransparency = 0.75
                        h.OutlineColor = Color3.fromRGB(255, 230, 120)
                        h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
                        h.Parent = VaultFolder
                        e.hl = h
                    end
                    e.tag.Enabled = on
                    e.hl.Enabled = on
                    local dist = (p.Position - camPos).Magnitude
                    if e.code then
                        e.label.Text = ("VAULT  CODE: %s\n%d st"):format(e.code, dist)
                    else
                        e.label.Text = ("VAULT  code: ?\nkill the banker / grab the note · %d st"):format(dist)
                    end
                end
            end
        end)
        task.wait(0.5)
    end
end)

----------------------------------------------------------------
-- AMMO AURA
----------------------------------------------------------------
Config.AmmoAura     = true
Config.SkipShop     = true
Config.CollectMoney = false
Config.AuraRadius   = 14
Config.AuraBurst    = 6
Config.AuraDebug    = false

local AMMO_WORDS     = { "ammo", "shell", "bullet", "cartridge", "rounds" }
local MONEY_WORDS    = { "money", "cash" }
local SHOP_WORDS     = { "shop", "store", "gunsmith", "doctor", "merchant", "vendor", "trader",
    "shelf", "counter", "forsale", "for sale" }
local SHOP_NPC_WORDS = { "shopkeeper", "gunsmith", "doctor", "merchant", "clerk", "vendor", "trader" }

env.DRCollect = env.DRCollect or {}
local Collect = env.DRCollect
Collect.part = nil

if HooksSupported and not env.DRCollectHooked then
    env.DRCollectHooked = true
    local mouse = LocalPlayer:GetMouse()
    local oldIdx
    oldIdx = hookmetamethod(game, "__index", newcclosure(function(self, key)
        local p = Collect.part
        if p and self == mouse and not checkcaller() then
            if key == "Target" then return p end
            if key == "Hit" then return CFrame.new(p.Position) end
        end
        return oldIdx(self, key)
    end))
    local oldNc
    oldNc = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local p = Collect.part
        if p and self == Workspace and not checkcaller() then
            local method = getnamecallmethod()
            if method == "Raycast" then
                local origin, dir, params = ...
                if typeof(origin) == "Vector3" and typeof(dir) == "Vector3"
                    and (origin - Workspace.CurrentCamera.CFrame.Position).Magnitude < 3 then
                    local to = p.Position - origin
                    setnamecallmethod(method)
                    return oldNc(self, origin, to.Unit * math.max(dir.Magnitude, to.Magnitude + 5), params)
                end
            end
            setnamecallmethod(method)
        end
        return oldNc(self, ...)
    end))
end

local Pickups   = {}
local ShopZones = {}
local ShopNPCs  = {}
local ShopSpots = {}
local CollectedCount = 0
local CollectParagraph -- Rayfield paragraph reference

local function updateCollectStatus(txt)
    if CollectParagraph and CollectParagraph.Set then
        pcall(function() CollectParagraph:Set({ Title = "Aura Status", Content = txt }) end)
    end
end

local function kindOf(inst)
    local n = string.lower(inst.Name)
    if hasWord(n, AMMO_WORDS) then return "ammo" end
    if hasWord(n, MONEY_WORDS) then return "money" end
    return nil
end

local function insidePickup(inst)
    local a = inst.Parent
    for _ = 1, 3 do
        if not a then return false end
        if Pickups[a] then return true end
        a = a.Parent
    end
    return false
end

local function trackPickup(inst)
    local cn = inst.ClassName
    if cn == "Model" then
        local n = string.lower(inst.Name)
        if hasWord(n, SHOP_NPC_WORDS) then ShopNPCs[inst] = true end
        if hasWord(n, SHOP_WORDS) then ShopZones[inst] = ShopZones[inst] or {} end
    end
    if cn ~= "Model" and cn ~= "Part" and cn ~= "MeshPart" and cn ~= "Tool" and cn ~= "UnionOperation" then
        return
    end
    if Pickups[inst] then return end
    local k = kindOf(inst)
    if k and not insidePickup(inst) then
        Pickups[inst] = { kind = k, tries = 0, next = 0 }
    end
end

local function inShopZone(pos)
    for m, z in pairs(ShopZones) do
        if not m.Parent then
            ShopZones[m] = nil
        else
            if not z.cf then
                local ok, cf, size = pcall(function() return m:GetBoundingBox() end)
                if ok then z.cf, z.size = cf, size else z.cf, z.size = CFrame.new(), Vector3.zero end
            end
            if z.size.Magnitude > 0 and z.size.Magnitude < 400 then
                local lp = z.cf:PointToObjectSpace(pos)
                local h = z.size / 2 + Vector3.new(6, 6, 6)
                if math.abs(lp.X) <= h.X and math.abs(lp.Y) <= h.Y and math.abs(lp.Z) <= h.Z then
                    return true
                end
            end
        end
    end
    for m in pairs(ShopNPCs) do
        if not m.Parent then
            ShopNPCs[m] = nil
        else
            local p = posPart(m)
            if p and (p.Position - pos).Magnitude < 22 then return true end
        end
    end
    for _, s in ipairs(ShopSpots) do
        if (s - pos).Magnitude < 6 then return true end
    end
    return false
end

local function priceText(s)
    return type(s) == "string" and string.find(s, "%$%s*%d") ~= nil
end

local function isShopItem(inst, part)
    if part and inShopZone(part.Position) then return true end
    local a = inst
    for _ = 1, 6 do
        if not a or a == Workspace then break end
        if hasWord(a.Name, SHOP_WORDS) then return true end
        local okA, attrs = pcall(function() return a:GetAttributes() end)
        if okA then
            for k in pairs(attrs) do
                local lk = string.lower(k)
                if string.find(lk, "price", 1, true) or lk == "cost" or lk == "buyable" or lk == "forsale" then
                    return true
                end
            end
        end
        a = a.Parent
    end
    local ok, desc = pcall(function() return inst:GetDescendants() end)
    if ok then
        for _, d in ipairs(desc) do
            local cn = d.ClassName
            if cn == "ProximityPrompt" then
                local t = string.lower(d.ActionText .. " " .. d.ObjectText)
                if string.find(t, "buy", 1, true) or string.find(t, "purchase", 1, true) or priceText(t) then
                    return true
                end
            elseif cn == "TextLabel" then
                if priceText(d.Text) then return true end
            elseif cn == "NumberValue" or cn == "IntValue" then
                local ln = string.lower(d.Name)
                if string.find(ln, "price", 1, true) or ln == "cost" then return true end
            end
        end
    end
    return false
end

local function isHeld(inst)
    for _, plr in ipairs(Players:GetPlayers()) do
        local c = plr.Character
        if c and inst:IsDescendantOf(c) then return true end
    end
    return false
end

local function getMoney()
    local v
    pcall(function()
        local ls = LocalPlayer:FindFirstChild("leaderstats")
        local m = ls and (ls:FindFirstChild("Money") or ls:FindFirstChild("Cash"))
        if m then v = m.Value end
        if v == nil then v = LocalPlayer:GetAttribute("Money") or LocalPlayer:GetAttribute("Cash") end
    end)
    return tonumber(v)
end

local function pressE(hold)
    local focused = nil
    pcall(function() focused = UserInputService:GetFocusedTextBox() end)
    if focused then return false end
    hold = hold or 0.04
    if keypress and keyrelease then
        if pcall(function() keypress(0x45); task.wait(hold); keyrelease(0x45) end) then return true end
    end
    return pcall(function()
        local vim = game:GetService("VirtualInputManager")
        vim:SendKeyEvent(true, Enum.KeyCode.E, false, game)
        task.wait(hold)
        vim:SendKeyEvent(false, Enum.KeyCode.E, false, game)
    end)
end

local function firePrompt(pp)
    if fireproximityprompt then
        pcall(fireproximityprompt, pp)
    else
        pcall(function()
            pp.HoldDuration = 0
            pp:InputHoldBegin()
            task.wait()
            pp:InputHoldEnd()
        end)
    end
end

local function methodFor(inst)
    local prompts = {}
    for _, d in ipairs(inst:GetDescendants()) do
        if d.ClassName == "ProximityPrompt" and d.Enabled then prompts[#prompts + 1] = d end
    end
    if #prompts > 0 then return "prompt", prompts end
    local cd = inst:FindFirstChildWhichIsA("ClickDetector", true)
    if cd and fireclickdetector then return "click", cd end
    return "hover"
end

task.spawn(function()
    local all = Workspace:GetDescendants()
    for i, inst in ipairs(all) do
        if not Running then return end
        trackPickup(inst)
        if i % 4000 == 0 then task.wait() end
    end
end)
Connections.pickAdded = Workspace.DescendantAdded:Connect(trackPickup)

local function sweep()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local now = os.clock()
    local cands = {}
    for inst, e in pairs(Pickups) do
        if not inst.Parent then
            Pickups[inst] = nil
        elseif (e.kind == "ammo" or (e.kind == "money" and Config.CollectMoney)) and now >= e.next then
            if not (e.part and e.part.Parent) then e.part = posPart(inst) end
            local p = e.part
            if p then
                local d = (p.Position - root.Position).Magnitude
                if d <= Config.AuraRadius and not isHeld(inst) then
                    if Config.SkipShop and not e.shop and (not e.shopT or now - e.shopT > 4) then
                        e.shop = isShopItem(inst, p)
                        e.shopT = now
                    end
                    if not (Config.SkipShop and e.shop) then
                        cands[#cands + 1] = { inst = inst, e = e, part = p, d = d }
                    end
                end
            end
        end
    end
    if #cands == 0 then return end
    table.sort(cands, function(a, b) return a.d < b.d end)

    local moneyBefore = getMoney()
    local done = {}
    for i = 1, math.min(#cands, Config.AuraBurst) do
        local c = cands[i]
        if c.inst.Parent then
            c.e.tries = c.e.tries + 1
            if c.e.tries >= 6 then
                c.e.tries = 0
                c.e.next = now + 6
            else
                c.e.next = now + 0.6
            end
            local okM, how, data = pcall(methodFor, c.inst)
            if okM then
                if how == "prompt" then
                    for _, pp in ipairs(data) do task.spawn(firePrompt, pp) end
                elseif how == "click" then
                    task.spawn(pcall, fireclickdetector, data)
                elseif HooksSupported then
                    Collect.part = c.part
                    task.wait()
                    pressE(0.03)
                    task.wait(0.03)
                    Collect.part = nil
                else
                    how = "no hooks"
                end
                CollectedCount = CollectedCount + 1
                done[#done + 1] = c
                if Config.AuraDebug then
                    print(("[Aura] %s (%s) %d st -> %s"):format(c.inst.Name, c.e.kind, math.floor(c.d), tostring(how)))
                end
                updateCollectStatus(("Aura: %d pickup(s), last: %s"):format(CollectedCount, tostring(how)))
            end
        end
    end

    if moneyBefore and #done > 0 then
        task.delay(0.7, function()
            local after = getMoney()
            if after and after < moneyBefore then
                for _, c in ipairs(done) do
                    c.e.shop = true
                    if #ShopSpots < 300 then table.insert(ShopSpots, c.part.Position) end
                end
                print(("[Aura] money dropped %s -> %s: marked %d spot(s) as shop, they won't be touched again"):format(
                    tostring(moneyBefore), tostring(after), #done))
            end
        end)
    end
end

local sweeping = false
task.spawn(function()
    while Running do
        if Config.AmmoAura and not sweeping then
            sweeping = true
            local ok, err = pcall(sweep)
            Collect.part = nil
            sweeping = false
            if not ok and Config.AuraDebug then warn("[Aura] sweep error: " .. tostring(err)) end
        end
        task.wait(0.1)
    end
end)

local function listPickups()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then print("[Aura] no character") return end
    local n, zones, npcs = 0, 0, 0
    for _ in pairs(ShopZones) do zones = zones + 1 end
    for _ in pairs(ShopNPCs) do npcs = npcs + 1 end
    for inst, e in pairs(Pickups) do
        local p = inst.Parent and posPart(inst)
        if p then
            local d = (p.Position - root.Position).Magnitude
            if d <= 60 then
                n = n + 1
                e.tries, e.next = 0, 0
                e.shop = isShopItem(inst, p)
                e.shopT = os.clock()
                local hasPrompt = inst:FindFirstChildWhichIsA("ProximityPrompt", true) ~= nil
                print(("[Aura] %s | %s | shop=%s | prompt=%s | %d st | %s"):format(
                    inst.Name, e.kind, tostring(e.shop), tostring(hasPrompt), math.floor(d), GetFullName(inst)))
            end
        end
    end
    print(("[Aura] %d pickup(s) within 60 st | shop buildings %d, shopkeepers %d, learned shop spots %d | money=%s"):format(
        n, zones, npcs, #ShopSpots, tostring(getMoney())))
end

----------------------------------------------------------------
-- REACH
----------------------------------------------------------------
Config.Reach     = false
Config.ReachDist = 30

env.DRReach = env.DRReach or {}
local Reach = env.DRReach
Reach.on, Reach.dist, Reach.silent = false, Config.ReachDist, Silent

Connections.reachCam = RunService.RenderStepped:Connect(function()
    local cam = Workspace.CurrentCamera
    if cam then Reach.camPos = cam.CFrame.Position end
end)

if HooksSupported and not env.DRReachHooked then
    env.DRReachHooked = true
    local oldNc
    oldNc = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if Reach.on and self == Workspace and not checkcaller() then
            local method = getnamecallmethod()
            local camPos = Reach.camPos
            if camPos then
                if method == "Raycast" then
                    local origin, dir, params = ...
                    if typeof(origin) == "Vector3" and typeof(dir) == "Vector3" then
                        local len = dir.Magnitude
                        if len > 2 and len < 60 and len < Reach.dist
                            and (origin - camPos).Magnitude < 1.5 then
                            local S = Reach.silent
                            local sa = S and S.active
                            if S then S.active = false end
                            setnamecallmethod(method)
                            local ok, res = pcall(oldNc, self, origin, dir.Unit * Reach.dist, params)
                            if S then S.active = sa end
                            if ok then return res end
                        end
                    end
                elseif method == "FindPartOnRay" or method == "FindPartOnRayWithIgnoreList"
                    or method == "FindPartOnRayWithWhitelist" then
                    local args = table.pack(...)
                    local ray = args[1]
                    if typeof(ray) == "Ray" then
                        local len = ray.Direction.Magnitude
                        if len > 2 and len < 60 and len < Reach.dist
                            and (ray.Origin - camPos).Magnitude < 1.5 then
                            args[1] = Ray.new(ray.Origin, ray.Direction.Unit * Reach.dist)
                            setnamecallmethod(method)
                            local ok, a, b, c, d = pcall(oldNc, self, table.unpack(args, 1, args.n))
                            if ok then return a, b, c, d end
                        end
                    end
                end
            end
            setnamecallmethod(method)
        end
        return oldNc(self, ...)
    end))
end

Reach.promptOrig = Reach.promptOrig or setmetatable({}, { __mode = "k" })
Reach.tableOrig  = Reach.tableOrig  or setmetatable({}, { __mode = "k" })
Reach.raisedTo   = Reach.raisedTo or {}
local PromptOrig, TableOrig = Reach.promptOrig, Reach.tableOrig
local DEFAULT_PROMPT, DEFAULT_CLICK = 10, 32
local ReachParagraph -- Rayfield paragraph reference

local function updateReachStatus(txt)
    if ReachParagraph and ReachParagraph.Set then
        pcall(function() ReachParagraph:Set({ Title = "Reach Status", Content = txt }) end)
    end
end

local function countKeys(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function looksRaised(v)
    if Reach.on and v == Reach.dist then return true end
    return Reach.raisedTo[v] == true
end

local function trackReachObj(d)
    local cn = d.ClassName
    if cn ~= "ProximityPrompt" and cn ~= "ClickDetector" then return end
    if PromptOrig[d] == nil then
        local ok, v = pcall(function() return d.MaxActivationDistance end)
        if not (ok and type(v) == "number") then return end
        if looksRaised(v) then
            v = (cn == "ProximityPrompt") and DEFAULT_PROMPT or DEFAULT_CLICK
        end
        PromptOrig[d] = v
    end
    local orig = PromptOrig[d]
    local want = (Reach.on and math.max(orig, Reach.dist)) or orig
    pcall(function()
        if d.MaxActivationDistance ~= want then d.MaxActivationDistance = want end
    end)
end

task.spawn(function()
    local all = Workspace:GetDescendants()
    for i, d in ipairs(all) do
        if not Running then return end
        trackReachObj(d)
        if i % 4000 == 0 then task.wait() end
    end
end)
Connections.reachAdded = Workspace.DescendantAdded:Connect(trackReachObj)

local function applyPrompts()
    for d, orig in pairs(PromptOrig) do
        if d.Parent then
            local want = (Reach.on and math.max(orig, Reach.dist)) or orig
            pcall(function()
                if d.MaxActivationDistance ~= want then d.MaxActivationDistance = want end
            end)
        end
    end
end

local REACH_KEY_A = { "drag", "grab", "carry", "pickup", "interact" }
local REACH_KEY_B = { "dist", "range", "reach", "length" }

local function isReachKey(k)
    if type(k) ~= "string" then return false end
    local lk = string.lower(k)
    if lk == "reach" or lk == "maxreach" then return true end
    return hasWord(lk, REACH_KEY_A) and hasWord(lk, REACH_KEY_B)
end

local function reachScan()
    if not getgc then return end
    local ok, gc = pcall(getgc, true)
    if not ok or type(gc) ~= "table" then return end
    local normalOf = {}
    for _, rec in pairs(TableOrig) do
        for k, v in pairs(rec) do normalOf[k] = normalOf[k] or v end
    end
    for i = 1, #gc do
        if not Running then return end
        local t = gc[i]
        if type(t) == "table" and t ~= Config and t ~= Reach then
            pcall(function()
                for k, v in next, t do
                    if type(v) == "number" and v >= 3 and v <= 200 and isReachKey(k) then
                        local rec = TableOrig[t]
                        if not (rec and rec[k] ~= nil) then
                            local orig = v
                            if looksRaised(v) then
                                orig = normalOf[k]
                            end
                            if orig then
                                if not rec then rec = {} TableOrig[t] = rec end
                                rec[k] = orig
                                normalOf[k] = normalOf[k] or orig
                                print(("[Reach] found drag setting %s = %s"):format(tostring(k), tostring(orig)))
                            end
                        end
                    end
                end
            end)
        end
        if i % 20000 == 0 then task.wait() end
    end
end

local function applyTables()
    for t, rec in pairs(TableOrig) do
        for k, orig in pairs(rec) do
            pcall(function()
                local want = (Reach.on and math.max(orig, Reach.dist)) or orig
                if t[k] ~= want then t[k] = want end
            end)
        end
    end
end

local function applyReach()
    Reach.on = Config.Reach and Running
    Reach.dist = Config.ReachDist
    if Reach.on then Reach.raisedTo[Reach.dist] = true end
    applyPrompts()
    applyTables()
end

Reach.restore = function()
    Reach.on = false
    pcall(applyPrompts)
    pcall(applyTables)
end

task.spawn(function()
    local lastOn, lastDist, lastTxt = nil, nil, nil
    while Running do
        if Config.Reach ~= lastOn or Config.ReachDist ~= lastDist then
            local turningOn = Config.Reach and not lastOn
            local turningOff = (not Config.Reach) and lastOn
            if turningOn and countKeys(TableOrig) == 0 then pcall(reachScan) end
            lastOn, lastDist = Config.Reach, Config.ReachDist
            pcall(applyReach)
            if turningOff then
                task.spawn(function()
                    pcall(reachScan)
                    for _, w in ipairs({ 0.3, 0.7, 1.5 }) do
                        task.wait(w)
                        if Config.Reach or not Running then return end
                        pcall(applyReach)
                    end
                end)
            end
        end
        local txt = Config.Reach
            and ("Reach: ON (%d studs)"):format(Config.ReachDist)
            or "Reach: OFF (normal distance)"
        if txt ~= lastTxt then
            lastTxt = txt
            updateReachStatus(txt)
        end
        task.wait(0.2)
    end
end)

----------------------------------------------------------------
-- AIR WELD
----------------------------------------------------------------
Config.AirWeld      = false
Config.LogWeld      = false
Config.AirWeldRange = 80

env.DRAirWeld = env.DRAirWeld or {}
local AW = env.DRAirWeld
AW.on, AW.log, AW.held, AW.heldPos, AW.train = false, false, nil, nil, nil
local AirParagraph -- Rayfield paragraph reference

local function updateAirStatus(txt)
    if AirParagraph and AirParagraph.Set then
        pcall(function() AirParagraph:Set({ Title = "Air Weld Status", Content = txt }) end)
    end
end

local TRAIN_WORDS = { "train", "locomotive", "wagon", "caboose" }
local TrainModels = {}

local function trackTrain(inst)
    if inst.ClassName ~= "Model" or not hasWord(inst.Name, TRAIN_WORDS) then return end
    if isPlayerCharacter(inst) then return end
    local a = inst.Parent
    for _ = 1, 4 do
        if not a then break end
        if TrainModels[a] then return end
        a = a.Parent
    end
    TrainModels[inst] = TrainModels[inst] or {}
end

task.spawn(function()
    local all = Workspace:GetDescendants()
    for i, d in ipairs(all) do
        if not Running then return end
        trackTrain(d)
        if i % 4000 == 0 then task.wait() end
    end
end)
Connections.trainAdded = Workspace.DescendantAdded:Connect(trackTrain)

local function isHeldPart(p)
    local h = AW.held
    return h ~= nil and (p == h or p:IsDescendantOf(h))
end

local function nearestTrainPart(pos)
    local best, bestD = nil, Config.AirWeldRange
    local now = os.clock()
    for m, e in pairs(TrainModels) do
        if not m.Parent then
            TrainModels[m] = nil
        else
            if not e.parts or now - (e.t or 0) > 5 then
                e.parts, e.t = {}, now
                local ok, desc = pcall(function() return m:GetDescendants() end)
                if ok then
                    for _, d in ipairs(desc) do
                        if d:IsA("BasePart") and d.Size.Magnitude >= 3 then
                            e.parts[#e.parts + 1] = d
                            if #e.parts >= 80 then break end
                        end
                    end
                end
            end
            for _, p in ipairs(e.parts) do
                if p.Parent and not isHeldPart(p) then
                    local d = (p.Position - pos).Magnitude
                    if d < bestD then best, bestD = p, d end
                end
            end
        end
    end
    return best, bestD
end

Connections.awDown = UserInputService.InputBegan:Connect(function(input)
    local it = input.UserInputType
    if it ~= Enum.UserInputType.MouseButton1 and it ~= Enum.UserInputType.Touch then return end
    if not Config.AirWeld then return end
    task.defer(function()
        local ok, t = pcall(function() return LocalPlayer:GetMouse().Target end)
        if not (ok and t) or t.Anchored then return end
        local m = t:FindFirstAncestorOfClass("Model")
        if m and isPlayerCharacter(m) then return end
        if m and not TrainModels[m] then AW.held = m else AW.held = t end
    end)
end)
Connections.awUp = UserInputService.InputEnded:Connect(function(input)
    local it = input.UserInputType
    if it ~= Enum.UserInputType.MouseButton1 and it ~= Enum.UserInputType.Touch then return end
    local h = AW.held
    task.delay(0.6, function()
        local still = false
        pcall(function() still = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) end)
        if AW.held == h and not still then AW.held = nil end
    end)
end)

task.spawn(function()
    local lastTxt = nil
    while Running do
        AW.on = Config.AirWeld and Running
        AW.log = Config.LogWeld and Running
        if AW.held and not AW.held.Parent then AW.held = nil end
        local dist
        if AW.on and AW.held then
            local p = AW.held:IsA("BasePart") and AW.held or posPart(AW.held)
            if p then
                AW.heldPos = p.Position
                AW.train, dist = nearestTrainPart(p.Position)
            end
        else
            AW.train, AW.heldPos = nil, nil
        end
        local txt
        if not Config.AirWeld then
            txt = "Air weld: off"
        elseif not AW.held then
            txt = "Air weld: hold an item"
        elseif AW.train then
            txt = ("Air weld: READY - press Z (train %d st)"):format(math.floor(dist or 0))
        else
            txt = ("Air weld: no train within %d st"):format(Config.AirWeldRange)
        end
        if txt ~= lastTxt then
            lastTxt = txt
            updateAirStatus(txt)
        end
        task.wait(0.2)
    end
end)

if HooksSupported and not env.DRAirWeldHooked then
    env.DRAirWeldHooked = true
    local oldNc
    oldNc = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        if (AW.on or AW.log) and not checkcaller() then
            local method = getnamecallmethod()

            if AW.log and method == "FireServer" and typeof(self) == "Instance"
                and IsA(self, "RemoteEvent") and string.find(string.lower(self.Name), "weld", 1, true) then
                local args = table.pack(...)
                pcall(function()
                    local parts = {}
                    for i = 1, args.n do
                        local v = args[i]
                        parts[i] = typeof(v) == "Instance" and (v.Name .. " <" .. v.ClassName .. ">")
                            or (typeof(v) .. ":" .. tostring(v))
                    end
                    print("[AirWeld] " .. GetFullName(self) .. ":FireServer(" .. table.concat(parts, ", ") .. ")")
                end)
                setnamecallmethod(method)
                return oldNc(self, table.unpack(args, 1, args.n))
            end

            local h, train = AW.held, AW.train
            if AW.on and h and train and train.Parent then
                local hit = false
                if method == "GetTouchingParts" and typeof(self) == "Instance"
                    and IsA(self, "BasePart") and (self == h or IsDescendantOf(self, h)) then
                    hit = true
                elseif self == Workspace and method == "GetPartsInPart" then
                    local p = ...
                    if typeof(p) == "Instance" and (p == h or IsDescendantOf(p, h)) then hit = true end
                elseif self == Workspace and (method == "GetPartBoundsInBox" or method == "GetPartBoundsInRadius") then
                    local a = ...
                    local pos = (typeof(a) == "CFrame" and a.Position) or (typeof(a) == "Vector3" and a) or nil
                    if pos and AW.heldPos and (pos - AW.heldPos).Magnitude < 8 then hit = true end
                end
                if hit then
                    setnamecallmethod(method)
                    local ok, res = pcall(oldNc, self, ...)
                    if ok and type(res) == "table" then
                        table.insert(res, train)
                        return res
                    end
                    setnamecallmethod(method)
                    return oldNc(self, ...)
                end
            end
            setnamecallmethod(method)
        end
        return oldNc(self, ...)
    end))
end

----------------------------------------------------------------
-- FULLBRIGHT + NO FOG
----------------------------------------------------------------
Config.Fullbright = false
Config.NoFog      = false

local Lighting = game:GetService("Lighting")
env.DRVisual = env.DRVisual or {}
local Vis = env.DRVisual
Vis.saved = Vis.saved or setmetatable({}, { __mode = "k" })
local VisAppliers = {}
local visBusy = false

local function same(a, b)
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 1e-3 end
    if typeof(a) == "Color3" and typeof(b) == "Color3" then
        return math.abs(a.R - b.R) < 0.005 and math.abs(a.G - b.G) < 0.005 and math.abs(a.B - b.B) < 0.005
    end
    return a == b
end

local function visGroupOn(group)
    if not Running then return false end
    if group == "fb" then return Config.Fullbright end
    if group == "fog" then return Config.NoFog end
    return false
end

local function enforce(obj, prop, want, group)
    local saved = Vis.saved[obj]
    if not saved then saved = {} Vis.saved[obj] = saved end
    local function apply()
        if visBusy or not obj.Parent then return end
        local ok, cur = pcall(function() return obj[prop] end)
        if not ok then return end
        if visGroupOn(group) then
            if not same(cur, want) then
                saved[prop] = cur
                visBusy = true
                pcall(function() obj[prop] = want end)
                visBusy = false
            end
        elseif saved[prop] ~= nil then
            local back = saved[prop]
            saved[prop] = nil
            visBusy = true
            pcall(function() obj[prop] = back end)
            visBusy = false
        end
    end
    local ok, sig = pcall(function() return obj:GetPropertyChangedSignal(prop) end)
    if ok and sig then table.insert(Connections, sig:Connect(apply)) end
    table.insert(VisAppliers, apply)
    apply()
end

local FB_GRAY = Color3.fromRGB(178, 178, 178)
enforce(Lighting, "Brightness", 2, "fb")
enforce(Lighting, "GlobalShadows", false, "fb")
enforce(Lighting, "Ambient", FB_GRAY, "fb")
enforce(Lighting, "OutdoorAmbient", FB_GRAY, "fb")
enforce(Lighting, "ExposureCompensation", 0, "fb")
enforce(Lighting, "FogEnd", 100000, "fog")
enforce(Lighting, "FogStart", 100000, "fog")

local function hookLightingChild(c)
    if c.ClassName == "Atmosphere" then
        enforce(c, "Density", 0, "fog")
        enforce(c, "Haze", 0, "fog")
    end
end
for _, c in ipairs(Lighting:GetChildren()) do hookLightingChild(c) end
Connections.lightAdded = Lighting.ChildAdded:Connect(hookLightingChild)

Vis.restore = function()
    for _, f in ipairs(VisAppliers) do pcall(f) end
end

task.spawn(function()
    local lastFb, lastFog = nil, nil
    while Running do
        if Config.Fullbright ~= lastFb or Config.NoFog ~= lastFog then
            lastFb, lastFog = Config.Fullbright, Config.NoFog
            for _, f in ipairs(VisAppliers) do pcall(f) end
        end
        task.wait(0.25)
    end
end)

----------------------------------------------------------------
-- AUTO RELOAD + FAST RELOAD
----------------------------------------------------------------
Config.AutoReload      = false
Config.ReloadTopUp     = true
Config.FastReload      = false
Config.ReloadAnimSpeed = 5
Config.ReloadDebug     = false

env.DRReload = env.DRReload or {}
local RL = env.DRReload
RL.valOrig   = RL.valOrig   or setmetatable({}, { __mode = "k" })
RL.attrOrig  = RL.attrOrig  or setmetatable({}, { __mode = "k" })
RL.tableOrig = RL.tableOrig or setmetatable({}, { __mode = "k" })
RL.normal    = RL.normal    or {}

local FAST_RELOAD = 0.05
local Gun = { tool = nil, src = nil, max = 0, conns = {}, lastShot = 0, lastReload = 0, label = nil }
local ReloadParagraph -- Rayfield paragraph reference

local function updateReloadStatus(txt)
    if ReloadParagraph and ReloadParagraph.Set then
        pcall(function() ReloadParagraph:Set({ Title = "Reload Status", Content = txt }) end)
    end
end

local AMMO_YES = { "ammo", "mag", "clip", "bullet", "round", "loaded", "shots" }
local AMMO_NO  = { "max", "reserve", "stored", "total", "spare", "capacity", "size", "type",
    "price", "cost", "reload", "speed", "damage" }
local RELOAD_A = { "reload" }
local RELOAD_B = { "time", "duration", "delay", "length", "cooldown" }

local function isAmmoName(n)
    return hasWord(n, AMMO_YES) and not hasWord(n, AMMO_NO)
end
local function isReloadTimeName(n)
    return type(n) == "string" and hasWord(n, RELOAD_A) and hasWord(n, RELOAD_B)
end

local function findAmmo(tool)
    local list = { tool }
    for _, d in ipairs(tool:GetDescendants()) do list[#list + 1] = d end
    for _, d in ipairs(list) do
        local cn = d.ClassName
        if (cn == "IntValue" or cn == "NumberValue") and isAmmoName(d.Name) then
            return { kind = "value", obj = d, name = d.Name }
        end
        local ok, attrs = pcall(function() return d:GetAttributes() end)
        if ok then
            for k, v in pairs(attrs) do
                if type(v) == "number" and isAmmoName(k) then
                    return { kind = "attr", obj = d, name = k }
                end
            end
        end
    end
    return nil
end

local function readAmmo()
    local s = Gun.src
    if not s or not s.obj.Parent then return nil end
    local v
    pcall(function()
        if s.kind == "value" then v = s.obj.Value
        elseif s.kind == "attr" then v = s.obj:GetAttribute(s.name)
        else v = tonumber(string.match(s.obj.Text, "^%s*(%d+)%s*/")) end
    end)
    return tonumber(v)
end

local function pressR()
    local focused = nil
    pcall(function() focused = UserInputService:GetFocusedTextBox() end)
    if focused then return false end
    if keypress and keyrelease then
        if pcall(function() keypress(0x52); task.wait(0.03); keyrelease(0x52) end) then return true end
    end
    return pcall(function()
        local vim = game:GetService("VirtualInputManager")
        vim:SendKeyEvent(true, Enum.KeyCode.R, false, game)
        task.wait(0.03)
        vim:SendKeyEvent(false, Enum.KeyCode.R, false, game)
    end)
end

local function gunEquipped()
    local t = Gun.tool
    return t ~= nil and t.Parent ~= nil and t.Parent == LocalPlayer.Character
end

local function requestReload(why)
    if not (Config.AutoReload and Running and gunEquipped()) then return end
    local now = os.clock()
    if now - Gun.lastReload < 0.6 then return end
    Gun.lastReload = now
    task.spawn(pressR)
    if Config.ReloadDebug then
        print(("[Reload] %s -> pressed R (%s, ammo %s/%s)"):format(
            Gun.tool.Name, why, tostring(readAmmo()), tostring(Gun.max)))
    end
end

local function onAmmo()
    local v = readAmmo()
    if not v then return end
    if v > Gun.max then Gun.max = v end
    if v <= 0 then requestReload("empty") end
end

local function learn(store, owner, key, cur)
    local orig = cur
    if math.abs(cur - FAST_RELOAD) < 1e-6 then orig = RL.normal[key] end
    if orig then
        store[owner] = orig
        RL.normal[key] = RL.normal[key] or orig
    end
end

local function registerToolReload(tool)
    local list = { tool }
    for _, d in ipairs(tool:GetDescendants()) do list[#list + 1] = d end
    for _, d in ipairs(list) do
        local cn = d.ClassName
        if (cn == "NumberValue" or cn == "IntValue") and isReloadTimeName(d.Name)
            and RL.valOrig[d] == nil and type(d.Value) == "number" and d.Value > 0 then
            learn(RL.valOrig, d, d.Name, d.Value)
        end
        local ok, attrs = pcall(function() return d:GetAttributes() end)
        if ok then
            for k, v in pairs(attrs) do
                if type(v) == "number" and v > 0 and isReloadTimeName(k) then
                    local rec = RL.attrOrig[d]
                    if not (rec and rec[k] ~= nil) then
                        rec = rec or {}
                        RL.attrOrig[d] = rec
                        local tmp = {}
                        learn(tmp, k, k, v)
                        if tmp[k] then rec[k] = tmp[k] end
                    end
                end
            end
        end
    end
end

local lastGcFast = 0
local function gcFastScan(force)
    if not getgc then return end
    if not force and os.clock() - lastGcFast < 5 then return end
    lastGcFast = os.clock()
    local ok, gc = pcall(getgc, true)
    if not ok or type(gc) ~= "table" then return end
    for i = 1, #gc do
        if not Running then return end
        local t = gc[i]
        if type(t) == "table" and t ~= Config and t ~= RL then
            pcall(function()
                for k, v in next, t do
                    if type(v) == "number" and v > 0 and v <= 30 and isReloadTimeName(k) then
                        local rec = RL.tableOrig[t]
                        if not (rec and rec[k] ~= nil) then
                            local tmp = {}
                            learn(tmp, k, k, v)
                            if tmp[k] then
                                rec = rec or {}
                                RL.tableOrig[t] = rec
                                rec[k] = tmp[k]
                            end
                        end
                    end
                end
            end)
        end
        if i % 20000 == 0 then task.wait() end
    end
end

local function applyFast()
    local on = Config.FastReload and Running
    for d, orig in pairs(RL.valOrig) do
        if d.Parent then
            local want = on and math.min(orig, FAST_RELOAD) or orig
            pcall(function() if d.Value ~= want then d.Value = want end end)
        end
    end
    for inst, rec in pairs(RL.attrOrig) do
        if inst.Parent then
            for k, orig in pairs(rec) do
                local want = on and math.min(orig, FAST_RELOAD) or orig
                pcall(function() if inst:GetAttribute(k) ~= want then inst:SetAttribute(k, want) end end)
            end
        end
    end
    for t, rec in pairs(RL.tableOrig) do
        for k, orig in pairs(rec) do
            local want = on and math.min(orig, FAST_RELOAD) or orig
            pcall(function() if t[k] ~= want then t[k] = want end end)
        end
    end
end

local function unequipGun()
    for _, c in ipairs(Gun.conns) do pcall(function() c:Disconnect() end) end
    table.clear(Gun.conns)
    Gun.tool, Gun.src, Gun.max = nil, nil, 0
end

local function watchSource(src)
    local sig
    if src.kind == "value" then sig = src.obj:GetPropertyChangedSignal("Value")
    elseif src.kind == "attr" then sig = src.obj:GetAttributeChangedSignal(src.name)
    else sig = src.obj:GetPropertyChangedSignal("Text") end
    table.insert(Gun.conns, sig:Connect(onAmmo))
end

local function equipGun(tool)
    unequipGun()
    Gun.tool = tool
    local src = findAmmo(tool)
    if not src and Gun.label and Gun.label.Parent then
        src = { kind = "label", obj = Gun.label, name = "screen text" }
    end
    Gun.src = src
    if src then
        watchSource(src)
        Gun.max = readAmmo() or 0
    end
    pcall(registerToolReload, tool)
    if Config.FastReload then
        pcall(applyFast)
        task.spawn(function() pcall(gcFastScan); pcall(applyFast) end)
    end
end

local function ammoLabels()
    local out = {}
    local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    if not pg then return out end
    for _, d in ipairs(pg:GetDescendants()) do
        if d.ClassName == "TextLabel" and d.Visible then
            local a = string.match(d.Text, "^%s*(%d+)%s*/%s*%d+")
            if a then out[d] = tonumber(a) end
        end
    end
    return out
end

Connections.reloadShot = UserInputService.InputBegan:Connect(function(input)
    local it = input.UserInputType
    if it ~= Enum.UserInputType.MouseButton1 and it ~= Enum.UserInputType.Touch then return end
    Gun.lastShot = os.clock()
    if Config.AutoReload and gunEquipped() and not Gun.src then
        local tool = Gun.tool
        local before = ammoLabels()
        task.delay(0.3, function()
            if Gun.tool ~= tool or Gun.src then return end
            for lbl, b in pairs(before) do
                local a = lbl.Parent and tonumber(string.match(lbl.Text, "^%s*(%d+)%s*/"))
                if a and a < b then
                    Gun.label = lbl
                    Gun.src = { kind = "label", obj = lbl, name = "screen text" }
                    Gun.max = math.max(b, a)
                    watchSource(Gun.src)
                    if Config.ReloadDebug then print("[Reload] learned ammo text on screen: " .. GetFullName(lbl)) end
                    onAmmo()
                    return
                end
            end
        end)
    end
end)

local function hookAnimator(char)
    local hum = char:FindFirstChildOfClass("Humanoid") or char:WaitForChild("Humanoid", 5)
    if not hum or not Running then return end
    local src = hum:FindFirstChildOfClass("Animator") or hum
    table.insert(Connections, src.AnimationPlayed:Connect(function(track)
        if not Running then return end
        local n = ""
        pcall(function()
            n = string.lower((track.Name or "") .. " " .. ((track.Animation and track.Animation.Name) or ""))
        end)
        if string.find(n, "reload", 1, true) then
            Gun.lastReload = os.clock()
            if Config.FastReload then
                pcall(function() track:AdjustSpeed(Config.ReloadAnimSpeed) end)
            end
        end
    end))
end

local function hookCharReload(char)
    table.insert(Connections, char.ChildAdded:Connect(function(t)
        if t:IsA("Tool") then equipGun(t) end
    end))
    table.insert(Connections, char.ChildRemoved:Connect(function(t)
        if t == Gun.tool then unequipGun() end
    end))
    for _, t in ipairs(char:GetChildren()) do
        if t:IsA("Tool") then equipGun(t) break end
    end
    task.spawn(hookAnimator, char)
end
if LocalPlayer.Character then hookCharReload(LocalPlayer.Character) end
Connections.reloadChar = LocalPlayer.CharacterAdded:Connect(hookCharReload)

RL.restore = function()
    unequipGun()
    pcall(applyFast)
end

task.spawn(function()
    local lastFast, lastTxt = nil, nil
    while Running do
        if Config.FastReload ~= lastFast then
            lastFast = Config.FastReload
            if Config.FastReload then
                if Gun.tool then pcall(registerToolReload, Gun.tool) end
                task.spawn(function() pcall(gcFastScan, true); pcall(applyFast) end)
            end
            pcall(applyFast)
        end

        local now = os.clock()
        local v = gunEquipped() and readAmmo() or nil
        if Config.AutoReload and Config.ReloadTopUp and v and Gun.max > 0 and v < Gun.max
            and now - Gun.lastShot > 0.8 and now - Gun.lastReload > 1.2 then
            local held = false
            pcall(function() held = UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) end)
            if not held then requestReload("top up") end
        end

        local txt
        if not gunEquipped() then
            txt = "Reload: equip a gun"
        elseif not Gun.src then
            txt = "Reload: fire once so it finds the ammo"
        else
            txt = ("Reload: %s %s/%s"):format(Gun.tool.Name, tostring(v or "?"), tostring(Gun.max))
        end
        if txt ~= lastTxt then
            lastTxt = txt
            updateReloadStatus(txt)
        end
        task.wait(0.2)
    end
end)

----------------------------------------------------------------
-- NOCLIP + FLOOR HOLD + ANTI-VOID
----------------------------------------------------------------
local MoveUI = {}
do
Config.Noclip    = false
Config.FloorHold = true
Config.AntiVoid  = true
Config.VoidDrop  = 150

local collideOrig = setmetatable({}, { __mode = "k" })
local charParts, partsT = {}, 0
local holdY = nil
local safe = { part = nil, offset = nil, cf = nil, y = nil, name = "none" }
local rescues = 0

local floorParams = RaycastParams.new()
floorParams.FilterType = Enum.RaycastFilterType.Exclude
floorParams.RespectCanCollide = true

local function refreshParts(char, now)
    if now - partsT < 0.5 and #charParts > 0 then return end
    partsT = now
    table.clear(charParts)
    for _, d in ipairs(char:GetDescendants()) do
        if d:IsA("BasePart") then charParts[#charParts + 1] = d end
    end
end

local function restoreCollide()
    for p, v in pairs(collideOrig) do
        if p.Parent then pcall(function() p.CanCollide = v end) end
    end
    table.clear(collideOrig)
end

local function standHeight(hum, root)
    if hum.RigType == Enum.HumanoidRigType.R6 then return 3 end
    return hum.HipHeight + root.Size.Y / 2
end

Connections.noclipStep = RunService.Stepped:Connect(function()
    local char = LocalPlayer.Character
    if Running and Config.Noclip and char then
        refreshParts(char, os.clock())
        for _, p in ipairs(charParts) do
            if p.Parent then
                if collideOrig[p] == nil then collideOrig[p] = p.CanCollide end
                if p.CanCollide then p.CanCollide = false end
            end
        end
    elseif next(collideOrig) then
        restoreCollide()
        holdY = nil
    end
end)

local function rescue(root, char, why)
    local target
    if safe.part and safe.part.Parent and safe.offset then
        target = safe.part.CFrame * safe.offset
    else
        target = safe.cf
    end
    if not target then return end
    pcall(function()
        root.AssemblyLinearVelocity = Vector3.zero
        char:PivotTo(target + Vector3.new(0, 3, 0))
    end)
    holdY = nil
    rescues = rescues + 1
    print(("[AntiVoid] saved you (%s) -> back on %s"):format(why, safe.name))
end

Connections.noclipHold = RunService.Heartbeat:Connect(function()
    if not Running then return end
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    local hum = char and char:FindFirstChildOfClass("Humanoid")
    if not (root and hum) or hum.Health <= 0 then return end

    if Config.Noclip and Config.FloorHold then
        floorParams.FilterDescendantsInstances = { char }
        local hit = Workspace:Raycast(root.Position + Vector3.new(0, 3, 0), Vector3.new(0, -60, 0), floorParams)
        local minY
        if hit then
            minY = hit.Position.Y + standHeight(hum, root)
            holdY = minY
        else
            minY = holdY
        end
        if minY and root.Position.Y < minY - 0.05 then
            local v = root.AssemblyLinearVelocity
            root.CFrame = root.CFrame + Vector3.new(0, minY - root.Position.Y, 0)
            root.AssemblyLinearVelocity = Vector3.new(v.X, math.max(v.Y, 0), v.Z)
        end
    else
        holdY = nil
    end

    if Config.AntiVoid and safe.y then
        local y = root.Position.Y
        local killY = Workspace.FallenPartsDestroyHeight
        local falling = root.AssemblyLinearVelocity.Y < -20
        if y < killY + 40 then
            rescue(root, char, "near kill height")
        elseif falling and (safe.y - y) > Config.VoidDrop then
            rescue(root, char, ("fell %d studs"):format(math.floor(safe.y - y)))
        end
    end
end)

task.spawn(function()
    local lastTxt = nil
    while Running do
        pcall(function()
            local char = LocalPlayer.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            local hum = char and char:FindFirstChildOfClass("Humanoid")
            if root and hum and hum.Health > 0 and hum.FloorMaterial ~= Enum.Material.Air
                and root.Position.Y > Workspace.FallenPartsDestroyHeight + 60 then
                floorParams.FilterDescendantsInstances = { char }
                local hit = Workspace:Raycast(root.Position, Vector3.new(0, -12, 0), floorParams)
                if hit and hit.Instance then
                    safe.part = hit.Instance
                    safe.offset = hit.Instance.CFrame:ToObjectSpace(root.CFrame)
                    safe.cf = root.CFrame
                    safe.y = root.Position.Y
                    safe.name = hit.Instance.Name
                end
            end
            local txt = ("Noclip %s | hold %s | anti-void %s | saves %d\nsafe spot: %s"):format(
                Config.Noclip and "ON" or "off", Config.FloorHold and "ON" or "off",
                Config.AntiVoid and "ON" or "off", rescues, safe.name)
            if txt ~= lastTxt and MoveUI.paragraph and MoveUI.paragraph.Set then
                lastTxt = txt
                MoveUI.paragraph:Set({ Title = "Movement Status", Content = txt })
            end
        end)
        task.wait(0.25)
    end
end)

Connections.moveChar = LocalPlayer.CharacterAdded:Connect(function()
    table.clear(collideOrig)
    table.clear(charParts)
    partsT, holdY = 0, nil
    safe.part, safe.offset, safe.cf, safe.y, safe.name = nil, nil, nil, nil, "none"
end)

env.DRMove = { restore = function() restoreCollide() end }
MoveUI.rescueNow = function()
    local char = LocalPlayer.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if root then rescue(root, char, "button") end
end
end

----------------------------------------------------------------
-- RAYFIELD GUI (BrN Hub)
----------------------------------------------------------------
local function buildGui()
    local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
    RayfieldLib = Rayfield

    local Window = Rayfield:CreateWindow({
        Name = "BrN Hub",
        Icon = 0,
        LoadingTitle = "BrN Hub",
        LoadingSubtitle = "Dead Rails",
        Theme = "Default",
        DisableRayfieldPrompts = false,
        DisableBuildWarnings = false,
        ConfigurationSaving = {
            Enabled = false,
            FolderName = "BrNHub",
            FileName = "DeadRails"
        },
        Discord = {
            Enabled = false,
            Invite = "noinvitelink",
            RememberJoins = true
        },
        KeySystem = false
    })
    RayfieldWindow = Window

    -- FOV circle (kept separate from Rayfield window)
    local guiParent = (gethui and gethui()) or game:GetService("CoreGui")
    local fovGui = Instance.new("ScreenGui")
    fovGui.Name = "BrNHubFOV"
    fovGui.ResetOnSpawn = false
    fovGui.IgnoreGuiInset = true
    fovGui.Parent = guiParent
    Connections.fovGui = { Disconnect = function() pcall(function() fovGui:Destroy() end) end }

    Circle = Instance.new("Frame")
    Circle.AnchorPoint = Vector2.new(0.5, 0.5)
    Circle.BackgroundTransparency = 1
    Circle.Parent = fovGui
    Instance.new("UICorner", Circle).CornerRadius = UDim.new(1, 0)
    local stroke = Instance.new("UIStroke", Circle)
    stroke.Color = Color3.fromRGB(80, 160, 255)
    stroke.Thickness = 1.5

    ----------------------------------------------------------------
    -- AIM TAB
    ----------------------------------------------------------------
    local AimTab = Window:CreateTab("Aim", 4483362458)

    if not HooksSupported then
        AimTab:CreateParagraph({ Title = "Executor Warning", Content = "Needs hook support (executor)" })
    end

    AimTab:CreateSection("Silent Aim")
    AimTab:CreateToggle({
        Name = "Silent Aim",
        CurrentValue = Config.Silent,
        Flag = "SilentAim",
        Callback = function(v)
            Config.Silent = v
        end,
    })

    AimTab:CreateSection("AIM PART")
    AimTab:CreateDropdown({
        Name = "Aim at",
        Options = { "Head", "Torso" },
        CurrentOption = { Config.AimPart },
        MultipleOptions = false,
        Flag = "AimPart",
        Callback = function(opt)
            local chosen = type(opt) == "table" and opt[1] or opt
            if chosen == "Head" or chosen == "Torso" then
                Config.AimPart = chosen
            end
        end,
    })

    AimTab:CreateSection("TARGETS")
    for _, kind in ipairs({ "Zombie", "Werewolf", "Outlaw", "Other" }) do
        AimTab:CreateToggle({
            Name = kind,
            CurrentValue = Config.Targets[kind],
            Flag = "Target_" .. kind,
            Callback = function(v)
                Config.Targets[kind] = v
            end,
        })
    end

    AimTab:CreateSection("FOV")
    AimTab:CreateSlider({
        Name = "FOV radius",
        Range = { 25, 3000 },
        Increment = 25,
        Suffix = "px",
        CurrentValue = Config.FOV,
        Flag = "FOVRadius",
        Callback = function(v)
            Config.FOV = v
        end,
    })
    AimTab:CreateToggle({
        Name = "Unlimited FOV (360)",
        CurrentValue = Config.Unlimited,
        Flag = "UnlimitedFOV",
        Callback = function(v)
            Config.Unlimited = v
        end,
    })
    AimTab:CreateSlider({
        Name = "Max distance",
        Range = { 50, 2000 },
        Increment = 50,
        Suffix = "studs",
        CurrentValue = Config.MaxDistance,
        Flag = "MaxDistance",
        Callback = function(v)
            Config.MaxDistance = v
        end,
    })
    AimTab:CreateToggle({
        Name = "Show FOV circle",
        CurrentValue = Config.ShowFOV,
        Flag = "ShowFOV",
        Callback = function(v)
            Config.ShowFOV = v
        end,
    })

    AimTab:CreateSection("LEAD")
    local PingParagraph = AimTab:CreateParagraph({ Title = "Ping & Lead", Content = "Ping: ..." })
    AimTab:CreateToggle({
        Name = "Lead moving targets",
        CurrentValue = Config.Lead,
        Flag = "LeadTargets",
        Callback = function(v)
            Config.Lead = v
        end,
    })
    AimTab:CreateToggle({
        Name = "Auto lead (ping)",
        CurrentValue = Config.AutoLead,
        Flag = "AutoLead",
        Callback = function(v)
            Config.AutoLead = v
        end,
    })
    AimTab:CreateSlider({
        Name = "Extra lead (s)",
        Range = { 0, 0.4 },
        Increment = 0.02,
        Suffix = "s",
        CurrentValue = Config.LeadTime,
        Flag = "LeadTime",
        Callback = function(v)
            Config.LeadTime = math.floor(v * 100 + 0.5) / 100
        end,
    })
    AimTab:CreateDropdown({
        Name = "Ping source",
        Options = { "Network", "Network x2", "Data Ping" },
        CurrentOption = { Config.PingMode },
        MultipleOptions = false,
        Flag = "PingSource",
        Callback = function(opt)
            local chosen = type(opt) == "table" and opt[1] or opt
            if chosen then
                Config.PingMode = chosen
                table.clear(PingInfo.hist)
                PingMs = 0
            end
        end,
    })

    AimTab:CreateSection("OPTIONS")
    AimTab:CreateToggle({
        Name = "Wall Check",
        CurrentValue = Config.WallCheck,
        Flag = "WallCheck",
        Callback = function(v)
            Config.WallCheck = v
        end,
    })
    AimTab:CreateToggle({
        Name = "Log Gun Remotes",
        CurrentValue = Config.LogRemotes,
        Flag = "LogRemotes",
        Callback = function(v)
            Config.LogRemotes = v
        end,
    })
    AimTab:CreateButton({
        Name = "Debug: print NPCs",
        Callback = function()
            print(("[DeadRailsAim] %d NPC models detected"):format(#NPCs))
            for i, npc in ipairs(NPCs) do
                if i > 20 then break end
                local m = npc.model
                print(("  %s | kind=%s | Head=%s HRP=%s UpperTorso=%s Torso=%s | path=%s"):format(
                    m.Name, npc.kind,
                    tostring(m:FindFirstChild("Head") ~= nil),
                    tostring(m:FindFirstChild("HumanoidRootPart") ~= nil),
                    tostring(m:FindFirstChild("UpperTorso") ~= nil),
                    tostring(m:FindFirstChild("Torso") ~= nil),
                    m:GetFullName()))
            end
        end,
    })

    ----------------------------------------------------------------
    -- PLAYER TAB
    ----------------------------------------------------------------
    local PlayerTab = Window:CreateTab("Player", 4483362458)

    PlayerTab:CreateSection("NOCLIP")
    PlayerTab:CreateToggle({
        Name = "Noclip (walk through walls)",
        CurrentValue = Config.Noclip,
        Flag = "Noclip",
        Callback = function(v)
            Config.Noclip = v
        end,
    })
    PlayerTab:CreateToggle({
        Name = "Floor hold (don't fall through)",
        CurrentValue = Config.FloorHold,
        Flag = "FloorHold",
        Callback = function(v)
            Config.FloorHold = v
        end,
    })

    PlayerTab:CreateSection("VOID PROTECTION")
    PlayerTab:CreateToggle({
        Name = "Anti-void (save me from falling)",
        CurrentValue = Config.AntiVoid,
        Flag = "AntiVoid",
        Callback = function(v)
            Config.AntiVoid = v
        end,
    })
    PlayerTab:CreateSlider({
        Name = "Fall distance to save (studs)",
        Range = { 50, 1000 },
        Increment = 25,
        Suffix = "studs",
        CurrentValue = Config.VoidDrop,
        Flag = "VoidDrop",
        Callback = function(v)
            Config.VoidDrop = v
        end,
    })
    PlayerTab:CreateButton({
        Name = "Teleport to last safe spot",
        Callback = function()
            pcall(MoveUI.rescueNow)
        end,
    })

    MoveUI.paragraph = PlayerTab:CreateParagraph({ Title = "Movement Status", Content = "Noclip off" })

    ----------------------------------------------------------------
    -- VISUALS TAB
    ----------------------------------------------------------------
    local VisualsTab = Window:CreateTab("Visuals", 4483362458)

    VisualsTab:CreateSection("WORLD")
    VisualsTab:CreateToggle({
        Name = "Fullbright",
        CurrentValue = Config.Fullbright,
        Flag = "Fullbright",
        Callback = function(v)
            Config.Fullbright = v
        end,
    })
    VisualsTab:CreateToggle({
        Name = "No fog",
        CurrentValue = Config.NoFog,
        Flag = "NoFog",
        Callback = function(v)
            Config.NoFog = v
        end,
    })

    VisualsTab:CreateSection("VAULT")
    VisualsTab:CreateToggle({
        Name = "Vault ESP + code",
        CurrentValue = Config.VaultESP,
        Flag = "VaultESP",
        Callback = function(v)
            Config.VaultESP = v
        end,
    })
    VisualsTab:CreateToggle({
        Name = "Only nearby towns",
        CurrentValue = Config.VaultNearby,
        Flag = "VaultNearby",
        Callback = function(v)
            Config.VaultNearby = v
        end,
    })
    VisualsTab:CreateSlider({
        Name = "Nearby range (studs)",
        Range = { 250, 10000 },
        Increment = 250,
        Suffix = "studs",
        CurrentValue = Config.VaultRange,
        Flag = "VaultRange",
        Callback = function(v)
            Config.VaultRange = v
        end,
    })

    local VaultCodesParagraph = VisualsTab:CreateParagraph({
        Title = "VAULT CODES (closest first)",
        Content = "No vaults found yet",
    })
    task.spawn(function()
        local lastVaultTxt = nil
        while Running do
            local ok, txt = pcall(vaultText)
            if ok and txt ~= lastVaultTxt then
                lastVaultTxt = txt
                pcall(function()
                    VaultCodesParagraph:Set({ Title = "VAULT CODES (closest first)", Content = txt })
                end)
            end
            task.wait(0.5)
        end
    end)

    VisualsTab:CreateButton({
        Name = "Copy all codes",
        Callback = function()
            if setclipboard then pcall(setclipboard, vaultText()) end
        end,
    })
    VisualsTab:CreateButton({
        Name = "Deep scan for code (F9)",
        Callback = function()
            task.spawn(function() pcall(deepScan) end)
        end,
    })
    VisualsTab:CreateButton({
        Name = "Debug: dump vault data",
        Callback = function()
            pcall(dumpVaults)
        end,
    })

    ----------------------------------------------------------------
    -- GUN TAB
    ----------------------------------------------------------------
    local GunTab = Window:CreateTab("Gun", 4483362458)

    GunTab:CreateSection("RELOAD")
    GunTab:CreateToggle({
        Name = "Auto reload",
        CurrentValue = Config.AutoReload,
        Flag = "AutoReload",
        Callback = function(v)
            Config.AutoReload = v
        end,
    })
    GunTab:CreateToggle({
        Name = "Top up when not full",
        CurrentValue = Config.ReloadTopUp,
        Flag = "ReloadTopUp",
        Callback = function(v)
            Config.ReloadTopUp = v
        end,
    })
    GunTab:CreateToggle({
        Name = "Fast reload",
        CurrentValue = Config.FastReload,
        Flag = "FastReload",
        Callback = function(v)
            Config.FastReload = v
        end,
    })
    GunTab:CreateSlider({
        Name = "Reload anim speed",
        Range = { 1, 15 },
        Increment = 1,
        Suffix = "x",
        CurrentValue = Config.ReloadAnimSpeed,
        Flag = "ReloadAnimSpeed",
        Callback = function(v)
            Config.ReloadAnimSpeed = v
        end,
    })
    GunTab:CreateToggle({
        Name = "Reload debug (F9)",
        CurrentValue = Config.ReloadDebug,
        Flag = "ReloadDebug",
        Callback = function(v)
            Config.ReloadDebug = v
        end,
    })
    ReloadParagraph = GunTab:CreateParagraph({ Title = "Reload Status", Content = "Reload: equip a gun" })
    GunTab:CreateButton({
        Name = "Reload: report (F9)",
        Callback = function()
            task.spawn(function()
                if Gun.tool then pcall(registerToolReload, Gun.tool) end
                pcall(gcFastScan, true)
                pcall(applyFast)
                local nt = 0
                for _, rec in pairs(RL.tableOrig) do nt = nt + countKeys(rec) end
                print(("[Reload] gun: %s | ammo source: %s (%s) | ammo %s/%s"):format(
                    Gun.tool and Gun.tool.Name or "none",
                    Gun.src and Gun.src.kind or "not found",
                    Gun.src and tostring(Gun.src.name) or "-",
                    tostring(readAmmo()), tostring(Gun.max)))
                print(("[Reload] reload-time settings: gun values %d, gun attributes %d, script settings %d | keypress=%s"):format(
                    countKeys(RL.valOrig), countKeys(RL.attrOrig), nt, tostring(keypress ~= nil)))
            end)
        end,
    })

    ----------------------------------------------------------------
    -- ITEMS TAB
    ----------------------------------------------------------------
    local ItemsTab = Window:CreateTab("Items", 4483362458)

    ItemsTab:CreateSection("COLLECT")
    ItemsTab:CreateToggle({
        Name = "Ammo aura",
        CurrentValue = Config.AmmoAura,
        Flag = "AmmoAura",
        Callback = function(v)
            Config.AmmoAura = v
        end,
    })
    ItemsTab:CreateToggle({
        Name = "Skip shop items",
        CurrentValue = Config.SkipShop,
        Flag = "SkipShop",
        Callback = function(v)
            Config.SkipShop = v
        end,
    })
    ItemsTab:CreateToggle({
        Name = "Also money bags",
        CurrentValue = Config.CollectMoney,
        Flag = "CollectMoney",
        Callback = function(v)
            Config.CollectMoney = v
        end,
    })
    ItemsTab:CreateSlider({
        Name = "Aura radius",
        Range = { 6, 30 },
        Increment = 2,
        Suffix = "studs",
        CurrentValue = Config.AuraRadius,
        Flag = "AuraRadius",
        Callback = function(v)
            Config.AuraRadius = v
        end,
    })
    ItemsTab:CreateSlider({
        Name = "Items per sweep",
        Range = { 1, 15 },
        Increment = 1,
        Suffix = "items",
        CurrentValue = Config.AuraBurst,
        Flag = "AuraBurst",
        Callback = function(v)
            Config.AuraBurst = v
        end,
    })
    ItemsTab:CreateToggle({
        Name = "Aura debug (F9)",
        CurrentValue = Config.AuraDebug,
        Flag = "AuraDebug",
        Callback = function(v)
            Config.AuraDebug = v
        end,
    })
    ItemsTab:CreateButton({
        Name = "Debug: list nearby ammo",
        Callback = function()
            pcall(listPickups)
        end,
    })
    ItemsTab:CreateButton({
        Name = "Clear learned shop spots",
        Callback = function()
            table.clear(ShopSpots)
            for _, e in pairs(Pickups) do e.shop, e.shopT = nil, nil end
        end,
    })
    CollectParagraph = ItemsTab:CreateParagraph({ Title = "Aura Status", Content = "Aura: idle" })

    ItemsTab:CreateSection("REACH")
    ItemsTab:CreateToggle({
        Name = "Reach (grab items far)",
        CurrentValue = Config.Reach,
        Flag = "Reach",
        Callback = function(v)
            Config.Reach = v
        end,
    })
    ItemsTab:CreateSlider({
        Name = "Reach distance",
        Range = { 10, 150 },
        Increment = 5,
        Suffix = "studs",
        CurrentValue = Config.ReachDist,
        Flag = "ReachDist",
        Callback = function(v)
            Config.ReachDist = v
        end,
    })
    ReachParagraph = ItemsTab:CreateParagraph({ Title = "Reach Status", Content = "Reach: OFF (normal distance)" })
    ItemsTab:CreateButton({
        Name = "Reach: rescan + report (F9)",
        Callback = function()
            task.spawn(function()
                pcall(reachScan)
                pcall(applyReach)
                local ns = 0
                for _, rec in pairs(TableOrig) do ns = ns + countKeys(rec) end
                print(("[Reach] hook=%s | prompts/clickers tracked %d | drag settings found %d | reach %s studs (%s)"):format(
                    tostring(HooksSupported), countKeys(PromptOrig), ns, tostring(Config.ReachDist), Config.Reach and "ON" or "OFF"))
            end)
        end,
    })
    ItemsTab:CreateButton({
        Name = "Reach: reset to normal",
        Callback = function()
            Config.Reach = false
            task.spawn(function()
                pcall(reachScan)
                pcall(Reach.restore)
                print("[Reach] everything set back to the game's normal distances")
            end)
        end,
    })

    ItemsTab:CreateSection("AIR WELD")
    ItemsTab:CreateToggle({
        Name = "Air weld (weld in the air)",
        CurrentValue = Config.AirWeld,
        Flag = "AirWeld",
        Callback = function(v)
            Config.AirWeld = v
        end,
    })
    ItemsTab:CreateSlider({
        Name = "Max train distance",
        Range = { 20, 300 },
        Increment = 10,
        Suffix = "studs",
        CurrentValue = Config.AirWeldRange,
        Flag = "AirWeldRange",
        Callback = function(v)
            Config.AirWeldRange = v
        end,
    })
    ItemsTab:CreateToggle({
        Name = "Log weld remote (F9)",
        CurrentValue = Config.LogWeld,
        Flag = "LogWeld",
        Callback = function(v)
            Config.LogWeld = v
        end,
    })
    AirParagraph = ItemsTab:CreateParagraph({ Title = "Air Weld Status", Content = "Air weld: off" })
    ItemsTab:CreateButton({
        Name = "Air weld: report (F9)",
        Callback = function()
            local p, d = nil, nil
            if AW.heldPos then p, d = nearestTrainPart(AW.heldPos) end
            print(("[AirWeld] hook=%s | train models found %d | holding %s | nearest train part %s (%s st)"):format(
                tostring(HooksSupported), countKeys(TrainModels),
                AW.held and GetFullName(AW.held) or "nothing",
                p and GetFullName(p) or "none", d and tostring(math.floor(d)) or "-"))
            for m in pairs(TrainModels) do print("   train model: " .. GetFullName(m)) end
        end,
    })

    ----------------------------------------------------------------
    -- SETTINGS TAB
    ----------------------------------------------------------------
    local SettingsTab = Window:CreateTab("Settings", 4483362458)

    SettingsTab:CreateSection("MENU")
    SettingsTab:CreateParagraph({
        Title = "BrN Hub Controls",
        Content = "Use Rayfield tabs above to navigate.\nUse Rayfield toggle keybind to hide/show the menu.",
    })

    SettingsTab:CreateSection("SCRIPT")
    SettingsTab:CreateToggle({
        Name = "Console output (debug)",
        CurrentValue = Console.on,
        Flag = "ConsoleOutput",
        Callback = function(v)
            Console.on = v
        end,
    })
    SettingsTab:CreateButton({
        Name = "Quit / Unload",
        Callback = function()
            Unload()
        end,
    })

    ----------------------------------------------------------------
    -- MAIN LOOP (never touches the camera)
    ----------------------------------------------------------------
    local lastPingUpdate = 0
    local lastPingSample = 0
    local lastVelTrack = 0
    local lastPick = 0
    local cachedPart, cachedNpc = nil, nil

    Connections.render = RunService.RenderStepped:Connect(function()
        Camera = Workspace.CurrentCamera
        local nowT = os.clock()
        if nowT - lastVelTrack > 1 / 30 then
            lastVelTrack = nowT
            trackVelocities()
        end
        if nowT - lastPingSample > 0.25 then
            lastPingSample = nowT
            samplePing()
        end
        if nowT - lastPingUpdate > 0.25 then
            lastPingUpdate = nowT
            local pTxt = ("Ping %d ms | net %d / data %d | lead %.3fs"):format(
                math.floor(PingMs + 0.5), math.floor(PingInfo.net + 0.5), math.floor(PingInfo.data + 0.5), autoLead())
            pcall(function()
                PingParagraph:Set({ Title = "Ping & Lead", Content = pTxt })
            end)
        end

        local mouse = UserInputService:GetMouseLocation()
        local inset = GuiService:GetGuiInset()
        Circle.Visible  = Config.ShowFOV and Config.Silent and not Config.Unlimited
        Circle.Size     = UDim2.fromOffset(Config.FOV * 2, Config.FOV * 2)
        Circle.Position = UDim2.fromOffset(mouse.X, mouse.Y - inset.Y)

        Silent.log = Config.LogRemotes
        Silent.active, Silent.point, Silent.part = false, nil, nil
        if not (Config.Silent and HooksSupported) then return end

        if nowT - lastPick > 1 / 30 then
            lastPick = nowT
            cachedPart, cachedNpc = pickTarget(mouse)
        end
        local part, npc = cachedPart, cachedNpc
        if part and not (part.Parent and npc and npc.humanoid.Health > 0) then
            part, npc = nil, nil
        end
        if part then
            local vel, lead = Vector3.zero, 0
            local st = npc and Track[npc.model]
            if Config.Lead and st then
                vel  = st.vel
                lead = Config.LeadTime
                if Config.AutoLead then lead = lead + autoLead() end
            end
            Silent.part, Silent.base, Silent.vel, Silent.lead, Silent.t = part, part.Position, vel, lead, os.clock()
            Silent.point, Silent.active = part.Position, true
        end
    end)
end

buildGui()
