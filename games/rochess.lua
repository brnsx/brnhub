--[[
    BrN Hub - RoChess! Engine Hub (Rayfield Edition)
    Root-Cause Fix:
    1. Builds the exact live board state via Engine (supporting both UCI and SAN history)
       and passes the resulting live FEN directly to Bot.analyse(liveFen, {}) so the
       engine NEVER evaluates a stale position or the opponent's pieces.
    2. Uses Rayfield Paragraph for live telemetry (Eval, Best Moves, Turn, Clocks).
    3. Multi-method move execution (onBoardMove + playMove) for reliable Autopilot.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Chess = ReplicatedStorage:WaitForChild("Chess")
local Client = ReplicatedStorage:WaitForChild("ChessClient")

local Engine = require(Chess:WaitForChild("Engine"))
local Bot = require(Chess:WaitForChild("Bot"))
local VortexBot = require(Chess:WaitForChild("VortexBot"))
local App = require(Client:WaitForChild("App"))

local GENV = getgenv()
GENV.__BrNHubGen = (GENV.__BrNHubGen or 0) + 1
local GEN = GENV.__BrNHubGen

if GENV.__BrNHubConn then
    pcall(function() GENV.__BrNHubConn:Disconnect() end)
end

local CFG = {
    DEPTH = 15,
    SECONDS = 0.6,
    CHILD_DEPTH = 7,
    CHILD_SECONDS = 0.04,
    VK_SHIFT = 160,
    PROMO = { q = 5, r = 4, b = 3, n = 2 },
    ARROW_1 = Color3.fromRGB(129, 182, 76),  -- Green (Best)
    ARROW_2 = Color3.fromRGB(96, 156, 240),  -- Blue (2nd Best)
    ARROW_3 = Color3.fromRGB(240, 200, 70),  -- Yellow (3rd Best)
}

local PRESETS = {
    Legit = {
        source = "local",
        mode = "elo",
        elo = 1450,
        noise = 0.35,
        blunder = 0.05,
        delayMin = 2.0,
        delayMax = 5.5,
        smartClock = true,
    },
    SemiLegit = {
        source = "vortex",
        mode = "elo",
        elo = 1950,
        noise = 0.15,
        blunder = 0.01,
        delayMin = 0.8,
        delayMax = 2.5,
        smartClock = true,
    },
    Rage = {
        source = "vortex",
        mode = "best",
        elo = 2600,
        noise = 0,
        blunder = 0,
        delayMin = 0.1,
        delayMax = 0.35,
        smartClock = false,
    },
}

local RUNTIME = {
    SHOW_ARROW = true,
    SHOW_MULTI_ARROWS = true,
    EVAL_BAR = true,
    AUTO = false,
    HUMANIZE = true,
    SMART_CLOCK = true,
    AUTO_REMATCH = false,
    SOURCE = "local",
    MODE = "elo",
    ELO = 1500,
    NOISE = 0.32,
    BLUNDER = 0.06,
    DELAY_MIN = 2.0,
    DELAY_MAX = 5.5,
}
GENV.__BrNHub = RUNTIME

local S = {
    ply = -1,
    reqId = 0,
    sessionId = nil,
    liveFen = nil,
    best = nil,
    san = nil,
    score = 0,
    depth = 0,
    second = nil,
    third = nil,
    secondSan = nil,
    thirdSan = nil,
    legalCount = 0,
    busy = false,
    thinkAt = 0,
    retryAt = 0,
    status = "Waiting for game...",
    lastEval = nil,
    rematchCooldown = 0,
}

local ARROW_KEYS = { "rc1", "rc2", "rc3" }

local function alive()
    return GENV.__BrNHubGen == GEN
end

-- ============================================================================
-- BOARD & ENGINE RECONSTRUCTION (UCI + SAN FALLBACK)
-- ============================================================================

local function clearArrows()
    local board = App.board
    if not board or type(board.setArrow) ~= "function" then return end
    for _, key in ipairs(ARROW_KEYS) do
        pcall(function()
            board:setArrow(key, nil)
            board:setTint(key, nil)
        end)
    end
    pcall(function()
        board:setArrow("rocheese", nil)
        board:setTint("rocheese", nil)
    end)
end

local function drawArrow(key, uci, color, tint)
    local board = App.board
    if not board or type(uci) ~= "string" or #uci < 4 then return end
    local from = Engine.algToIndex64(uci:sub(1, 2))
    local to = Engine.algToIndex64(uci:sub(3, 4))
    if not from or not to then return end
    pcall(function()
        board:setArrow(key, from, to, color, 0.12)
        if tint then
            board:setTint(key, to, color, 0.26)
        end
    end)
end

local function buildCurrentEngine(session)
    if not session then return nil end
    local engine = Engine.new(session.startFen)
    if not engine then return nil end

    local ucis = session.ucis
    local sans = session.sans
    local count = (type(ucis) == "table" and #ucis) or (type(sans) == "table" and #sans) or 0

    for i = 1, count do
        local played = false

        if type(ucis) == "table" and ucis[i] ~= nil then
            local entry = ucis[i]
            if type(entry) == "string" then
                local mv = engine:moveFromUci(entry)
                if mv then
                    engine:play(mv)
                    played = true
                end
            else
                local ok = pcall(function() engine:play(entry) end)
                if ok then played = true end
            end
        end

        if not played and type(sans) == "table" and type(sans[i]) == "string" then
            local targetSan = sans[i]:gsub("[+#?!]", "")
            for _, mv in ipairs(engine:legalMoves()) do
                local mvSan = engine:moveToSan(mv)
                if mvSan and mvSan:gsub("[+#?!]", "") == targetSan then
                    engine:play(mv)
                    played = true
                    break
                end
            end
        end

        if not played then
            break
        end
    end

    return engine
end

local function sanOf(engine, uci)
    if not engine or not uci then return nil end
    local want = string.lower(uci)
    for _, mv in ipairs(engine:legalMoves()) do
        local u = engine:moveToUci(mv)
        if u and string.lower(u) == want then
            return engine:moveToSan(mv)
        end
    end
    return uci
end

local function analyseLiveFen(liveFen)
    if not liveFen then return nil end
    if RUNTIME.SOURCE == "vortex" then
        local ok, res = pcall(VortexBot.analyse, liveFen, {}, CFG.SECONDS, CFG.DEPTH)
        if ok and type(res) == "table" and type(res.best) == "string" and #res.best >= 4 then
            return res
        end
    end
    local ok, res = pcall(Bot.analyse, liveFen, {}, CFG.SECONDS, CFG.DEPTH)
    if ok and type(res) == "table" and type(res.best) == "string" and #res.best >= 4 then
        return res
    end
    return nil
end

local function rankContinuationsFen(liveFen, skipUci, expectedReqId)
    local engine = Engine.new(liveFen)
    if not engine then return nil end

    local legalMoves = engine:legalMoves()
    local isWhiteTurn = (string.split(liveFen, " ")[2] == "w")
    local scored = {}

    for i, mv in ipairs(legalMoves) do
        if not alive() or S.reqId ~= expectedReqId then
            return nil
        end

        local uci = engine:moveToUci(mv)
        if uci and (not skipUci or string.lower(uci) ~= string.lower(skipUci)) then
            local child = Engine.new(liveFen)
            local cmv = child and child:moveFromUci(uci)
            if child and cmv then
                child:play(cmv)
                local childFen = child:getFen()
                local ok, cres = pcall(Bot.analyse, childFen, {}, CFG.CHILD_SECONDS, CFG.CHILD_DEPTH)
                if ok and type(cres) == "table" and cres.score ~= nil then
                    local rawScore = tonumber(cres.score) or 0
                    local perspectiveScore = isWhiteTurn and rawScore or -rawScore
                    table.insert(scored, {
                        uci = uci,
                        san = engine:moveToSan(mv),
                        score = perspectiveScore,
                    })
                end
            end
        end

        if i % 3 == 0 then
            task.wait()
        end
    end

    table.sort(scored, function(a, b)
        return a.score > b.score
    end)
    return scored
end

local function pickMove(liveFen)
    if RUNTIME.MODE == "elo" and liveFen then
        local ok, uci = pcall(Bot.think, liveFen, {}, {
            rating = RUNTIME.ELO,
            noise = RUNTIME.NOISE,
            blunder = RUNTIME.BLUNDER,
            time = 0.45,
            depth = 13,
        })
        if ok and type(uci) == "string" and #uci >= 4 then
            return uci
        end
    end
    return S.best
end

-- ============================================================================
-- MOVE EXECUTION & SMART DELAY
-- ============================================================================

local function tapInput()
    if not RUNTIME.HUMANIZE then return end
    if type(keyclick) == "function" then
        if type(isrbxactive) ~= "function" or isrbxactive() then
            pcall(keyclick, CFG.VK_SHIFT)
        end
    end
end

local function playUci(uci)
    local session = App.session
    if not session or session.over then return false, "No active game" end
    if type(uci) ~= "string" or #uci < 4 then return false, "Invalid UCI" end

    local from = Engine.algToIndex64(uci:sub(1, 2))
    local to = Engine.algToIndex64(uci:sub(3, 4))
    if not from or not to then return false, "Invalid squares" end

    local promo = CFG.PROMO[uci:sub(5, 5):lower()] or 0
    local before = type(session.ucis) == "table" and #session.ucis or 0
    tapInput()

    pcall(function()
        App.onBoardMove(from, to, promo, nil)
    end)

    local after1 = type(session.ucis) == "table" and #session.ucis or 0
    if after1 == before and type(App.playMove) == "function" then
        pcall(function()
            App.playMove(uci)
        end)
    end

    local after2 = type(session.ucis) == "table" and #session.ucis or 0
    if after2 == before and type(App.playMove) == "function" then
        pcall(function()
            local eng = buildCurrentEngine(session)
            local mvObj = eng and eng:moveFromUci(uci)
            if mvObj then
                App.playMove(mvObj)
            end
        end)
    end

    local finalCount = type(session.ucis) == "table" and #session.ucis or 0
    return (finalCount > before), uci
end

local function computeSmartDelay(session, ply)
    local lo = math.min(RUNTIME.DELAY_MIN, RUNTIME.DELAY_MAX)
    local hi = math.max(RUNTIME.DELAY_MIN, RUNTIME.DELAY_MAX)
    local baseDelay = (hi - lo < 0.1) and lo or (lo + math.random() * (hi - lo))

    if S.legalCount == 1 then
        return math.min(baseDelay, 0.45)
    end

    if RUNTIME.SMART_CLOCK and session and session.clocks and session.myColor then
        local myMs = session.clocks[session.myColor]
        if type(myMs) == "number" then
            if myMs < 10000 then
                return math.min(baseDelay, 0.25)
            elseif myMs < 25000 then
                return baseDelay * 0.4
            end
        end
    end

    if ply < 4 then
        return baseDelay * 0.65
    end

    return baseDelay
end

-- ============================================================================
-- FORMATTING & NATIVE EVAL BAR
-- ============================================================================

local function evalText(score)
    local abs = math.abs(score)
    if abs >= 29900 then
        local moves = math.max(1, math.floor((30000 - abs) / 100 + 0.5))
        return string.format("Mate in %d (%s)", moves, score > 0 and "White" or "Black")
    end
    local pawns = score / 100
    return string.format("%s%.2f", pawns >= 0 and "+" or "", pawns)
end

local function formatClock(ms)
    if type(ms) ~= "number" then return "--:--" end
    ms = math.max(0, ms)
    local total = math.floor(ms / 1000)
    return string.format("%d:%02d", math.floor(total / 60), total % 60)
end

local function pushEval()
    local session = App.session
    if not RUNTIME.EVAL_BAR or not session or session.kind == "idle" then
        S.lastEval = nil
        return
    end
    if S.busy or not S.best then return end
    if S.lastEval == S.score then return end

    S.lastEval = S.score
    local mate = nil
    if math.abs(S.score) >= 29900 then
        mate = math.max(1, math.floor((30000 - math.abs(S.score)) / 100 + 0.5))
    end
    pcall(function()
        App.setEval(S.score, mate)
    end)
end

-- ============================================================================
-- RAYFIELD UI (BrN Hub)
-- ============================================================================

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()

local Window = Rayfield:CreateWindow({
    Name = "BrN Hub",
    Icon = 0,
    LoadingTitle = "BrN Hub",
    LoadingSubtitle = "Smart Chess Analysis & Autopilot",
    Theme = "Default",
    DisableRayfieldPrompts = true,
    DisableBuildWarnings = true,
    ConfigurationSaving = {
        Enabled = false,
    },
    Keybind = Enum.KeyCode.RightShift
})

local TabMain = Window:CreateTab("Main", "cpu")
local TabEngine = Window:CreateTab("Engine & Humanizer", "sliders")
local TabVisual = Window:CreateTab("Visuals & Tools", "eye")

-- Main Tab
TabMain:CreateSection("Live Match Telemetry")

local MonitorParagraph = TabMain:CreateParagraph({
    Title = "Status: Waiting for game...",
    Content = "Eval: 0.00 (Depth 0)\n1st: - | 2nd: - | 3rd: -\nClocks: You --:-- | Opponent --:--"
})

TabMain:CreateSection("Autopilot Controls")

local ToggleAuto = TabMain:CreateToggle({
    Name = "Enable Autopilot (Auto Play)",
    CurrentValue = RUNTIME.AUTO,
    Flag = "AutoplayToggle",
    Callback = function(Value)
        RUNTIME.AUTO = Value
        S.retryAt = 0
        if Value and App.session then
            local ply = type(App.session.ucis) == "table" and #App.session.ucis or 0
            S.thinkAt = os.clock() + computeSmartDelay(App.session, ply)
        end
    end,
})

TabMain:CreateButton({
    Name = "Play Best Move Now",
    Callback = function()
        local session = App.session
        if not session or session.over then
            Rayfield:Notify({ Title = "BrN Hub", Content = "No active game running.", Duration = 2.5 })
            return
        end
        if S.busy or not S.best then
            Rayfield:Notify({ Title = "BrN Hub", Content = "Engine is still calculating...", Duration = 2.5 })
            return
        end
        local uci = pickMove(S.liveFen)
        local ok, msg = playUci(uci)
        Rayfield:Notify({
            Title = ok and "Move Played" or "Move Sent",
            Content = "Move: " .. (S.san or tostring(msg)),
            Duration = 2
        })
    end,
})

TabMain:CreateSection("Quick Presets")

local DropdownSource, DropdownMode, SliderElo, SliderNoise, SliderBlunder, SliderDelayMin, SliderDelayMax, ToggleSmartClock

local function applyPreset(presetName)
    local p = PRESETS[presetName]
    if not p then return end

    RUNTIME.SOURCE = p.source
    RUNTIME.MODE = p.mode
    RUNTIME.ELO = p.elo
    RUNTIME.NOISE = p.noise
    RUNTIME.BLUNDER = p.blunder
    RUNTIME.DELAY_MIN = p.delayMin
    RUNTIME.DELAY_MAX = p.delayMax
    RUNTIME.SMART_CLOCK = p.smartClock
    S.ply = -1

    if DropdownSource then DropdownSource:Set({ p.source == "vortex" and "Vortex (Server)" or "Local (Client)" }) end
    if DropdownMode then DropdownMode:Set({ p.mode == "best" and "Best Move" or "Rating Simulation (ELO)" }) end
    if SliderElo then SliderElo:Set(p.elo) end
    if SliderNoise then SliderNoise:Set(p.noise) end
    if SliderBlunder then SliderBlunder:Set(p.blunder) end
    if SliderDelayMin then SliderDelayMin:Set(p.delayMin) end
    if SliderDelayMax then SliderDelayMax:Set(p.delayMax) end
    if ToggleSmartClock then ToggleSmartClock:Set(p.smartClock) end

    Rayfield:Notify({
        Title = "BrN Hub - Preset: " .. presetName,
        Content = string.format("Mode: %s | ELO: %d | Delay: %.1fs-%.1fs", p.mode:upper(), p.elo, p.delayMin, p.delayMax),
        Duration = 3
    })
end

TabMain:CreateButton({
    Name = "Preset: Legit (Human 1450 ELO + Natural Mistakes)",
    Callback = function() applyPreset("Legit") end,
})

TabMain:CreateButton({
    Name = "Preset: Semi-Legit (Vortex 1950 ELO + Fast)",
    Callback = function() applyPreset("SemiLegit") end,
})

TabMain:CreateButton({
    Name = "Preset: Rage / Crusher (Vortex Best Move)",
    Callback = function() applyPreset("Rage") end,
})

-- Engine & Humanizer Tab
TabEngine:CreateSection("Engine Settings")

DropdownSource = TabEngine:CreateDropdown({
    Name = "Engine Source",
    Options = { "Local (Client)", "Vortex (Server)" },
    CurrentOption = { "Local (Client)" },
    MultipleOptions = false,
    Flag = "EngineSource",
    Callback = function(Options)
        local choice = Options[1]
        RUNTIME.SOURCE = (choice == "Vortex (Server)") and "vortex" or "local"
        S.ply = -1
    end,
})

DropdownMode = TabEngine:CreateDropdown({
    Name = "Move Selection Mode",
    Options = { "Rating Simulation (ELO)", "Best Move" },
    CurrentOption = { "Rating Simulation (ELO)" },
    MultipleOptions = false,
    Flag = "PlayMode",
    Callback = function(Options)
        local choice = Options[1]
        RUNTIME.MODE = (choice == "Best Move") and "best" or "elo"
    end,
})

SliderElo = TabEngine:CreateSlider({
    Name = "Target Rating (ELO Mode)",
    Range = { 400, 2800 },
    Increment = 50,
    Suffix = " ELO",
    CurrentValue = RUNTIME.ELO,
    Flag = "TargetElo",
    Callback = function(Value)
        RUNTIME.ELO = Value
    end,
})

SliderNoise = TabEngine:CreateSlider({
    Name = "Inaccuracy / Noise",
    Range = { 0, 1 },
    Increment = 0.02,
    Suffix = "",
    CurrentValue = RUNTIME.NOISE,
    Flag = "NoiseVal",
    Callback = function(Value)
        RUNTIME.NOISE = Value
    end,
})

SliderBlunder = TabEngine:CreateSlider({
    Name = "Blunder Chance",
    Range = { 0, 0.30 },
    Increment = 0.01,
    Suffix = "",
    CurrentValue = RUNTIME.BLUNDER,
    Flag = "BlunderVal",
    Callback = function(Value)
        RUNTIME.BLUNDER = Value
    end,
})

TabEngine:CreateSection("Timing & Human Behavior")

SliderDelayMin = TabEngine:CreateSlider({
    Name = "Minimum Move Delay",
    Range = { 0, 15 },
    Increment = 0.5,
    Suffix = "s",
    CurrentValue = RUNTIME.DELAY_MIN,
    Flag = "DelayMin",
    Callback = function(Value)
        RUNTIME.DELAY_MIN = Value
        if RUNTIME.DELAY_MAX < Value then
            RUNTIME.DELAY_MAX = Value
            if SliderDelayMax then SliderDelayMax:Set(Value) end
        end
    end,
})

SliderDelayMax = TabEngine:CreateSlider({
    Name = "Maximum Move Delay",
    Range = { 0, 20 },
    Increment = 0.5,
    Suffix = "s",
    CurrentValue = RUNTIME.DELAY_MAX,
    Flag = "DelayMax",
    Callback = function(Value)
        RUNTIME.DELAY_MAX = Value
        if RUNTIME.DELAY_MIN > Value then
            RUNTIME.DELAY_MIN = Value
            if SliderDelayMin then SliderDelayMin:Set(Value) end
        end
    end,
})

ToggleSmartClock = TabEngine:CreateToggle({
    Name = "Smart Clock Management (Speed up in time trouble)",
    CurrentValue = RUNTIME.SMART_CLOCK,
    Flag = "SmartClock",
    Callback = function(Value)
        RUNTIME.SMART_CLOCK = Value
    end,
})

TabEngine:CreateToggle({
    Name = "Simulate Key Input (Anti-AFK / Legit)",
    CurrentValue = RUNTIME.HUMANIZE,
    Flag = "HumanizeInput",
    Callback = function(Value)
        RUNTIME.HUMANIZE = Value
    end,
})

-- Visuals & Tools Tab
TabVisual:CreateSection("Board Visuals")

local ToggleArrows = TabVisual:CreateToggle({
    Name = "Show Best Move Arrows",
    CurrentValue = RUNTIME.SHOW_ARROW,
    Flag = "ShowArrows",
    Callback = function(Value)
        RUNTIME.SHOW_ARROW = Value
        if not Value then clearArrows() end
    end,
})

TabVisual:CreateToggle({
    Name = "Show 2nd & 3rd Best Arrows (Blue / Yellow)",
    CurrentValue = RUNTIME.SHOW_MULTI_ARROWS,
    Flag = "MultiArrows",
    Callback = function(Value)
        RUNTIME.SHOW_MULTI_ARROWS = Value
        if not Value then
            local board = App.board
            if board then
                pcall(function()
                    board:setArrow(ARROW_KEYS[2], nil)
                    board:setArrow(ARROW_KEYS[3], nil)
                end)
            end
        end
    end,
})

TabVisual:CreateToggle({
    Name = "Enable Native Evaluation Bar",
    CurrentValue = RUNTIME.EVAL_BAR,
    Flag = "EvalBar",
    Callback = function(Value)
        RUNTIME.EVAL_BAR = Value
        if Value then
            S.lastEval = nil
            pushEval()
        end
    end,
})

TabVisual:CreateSection("Automation & Utilities")

TabVisual:CreateToggle({
    Name = "Auto-Rematch vs Bot (Continuous Practice)",
    CurrentValue = RUNTIME.AUTO_REMATCH,
    Flag = "AutoRematch",
    Callback = function(Value)
        RUNTIME.AUTO_REMATCH = Value
    end,
})

TabVisual:CreateButton({
    Name = "Start Practice Game vs Bot (Jasper)",
    Callback = function()
        local ok, err = pcall(function()
            App.startBotGame("jasper", "white")
        end)
        Rayfield:Notify({
            Title = "BrN Hub",
            Content = ok and "Practice game started!" or ("Error: " .. tostring(err)),
            Duration = 2.5
        })
    end,
})

TabVisual:CreateButton({
    Name = "Copy FEN & Move History (PGN)",
    Callback = function()
        local session = App.session
        if not session then
            Rayfield:Notify({ Title = "BrN Hub", Content = "No active game.", Duration = 2 })
            return
        end
        local fen = S.liveFen or session.startFen or ""
        local sans = type(session.sans) == "table" and table.concat(session.sans, " ") or ""
        pcall(setclipboard, fen .. "\n" .. sans)
        Rayfield:Notify({ Title = "BrN Hub", Content = "FEN and moves copied to clipboard.", Duration = 2.5 })
    end,
})

TabVisual:CreateLabel("Hotkeys: [End] Autopilot | [Home] Arrows | [RightShift] Menu")

-- ============================================================================
-- HOTKEYS
-- ============================================================================

GENV.__BrNHubConn = UserInputService.InputBegan:Connect(function(input, processed)
    if processed or UserInputService:GetFocusedTextBox() then return end

    if input.KeyCode == Enum.KeyCode.End then
        ToggleAuto:Set(not RUNTIME.AUTO)
        Rayfield:Notify({
            Title = "BrN Hub - Autopilot",
            Content = RUNTIME.AUTO and "ENABLED" or "DISABLED",
            Duration = 1.5
        })
    elseif input.KeyCode == Enum.KeyCode.Home then
        ToggleArrows:Set(not RUNTIME.SHOW_ARROW)
    end
end)

-- ============================================================================
-- MAIN ANALYSIS & AUTOPILOT LOOP
-- ============================================================================

task.spawn(function()
    while alive() do
        local session = App.session
        local sid = session and session.id or nil

        if session and sid ~= S.sessionId then
            S.sessionId = sid
            S.lastEval = nil
            S.ply = -1
            S.reqId = S.reqId + 1
            S.busy = false
            S.retryAt = 0
            pcall(function() Bot.clearTT() end)
        end

        if RUNTIME.AUTO_REMATCH and session and session.over and session.kind == "bot" then
            if os.clock() > S.rematchCooldown then
                S.rematchCooldown = os.clock() + 4
                task.delay(2, function()
                    if alive() and RUNTIME.AUTO_REMATCH and App.session and App.session.over then
                        pcall(function() App.startBotGame("jasper", "white") end)
                    end
                end)
            end
        end

        if session and not session.over and session.kind ~= "idle" then
            local ply = (type(session.ucis) == "table" and #session.ucis) or (type(session.sans) == "table" and #session.sans) or 0
            local myTurn = session:isMyTurn()

            if ply ~= S.ply then
                S.ply = ply
                S.reqId = S.reqId + 1
                local myReqId = S.reqId

                S.best = nil
                S.san = nil
                S.second = nil
                S.third = nil
                S.secondSan = nil
                S.thirdSan = nil
                S.retryAt = 0
                clearArrows()

                local curEngine = buildCurrentEngine(session)
                local targetFen = curEngine and curEngine:getFen() or session.startFen
                S.liveFen = targetFen
                S.legalCount = curEngine and #curEngine:legalMoves() or 0
                S.thinkAt = os.clock() + computeSmartDelay(session, ply)

                S.busy = true
                S.status = "Analyzing..."

                task.spawn(function()
                    local res = analyseLiveFen(targetFen)
                    if not alive() or S.reqId ~= myReqId then
                        return
                    end

                    S.busy = false
                    if type(res) ~= "table" or not res.best then
                        S.status = "Analysis failed"
                        return
                    end

                    S.best = res.best
                    S.score = tonumber(res.score) or 0
                    S.depth = tonumber(res.depth) or 0
                    S.status = "Ready"

                    local eng = Engine.new(targetFen)
                    S.san = sanOf(eng, res.best)

                    if RUNTIME.SHOW_MULTI_ARROWS and S.legalCount > 1 then
                        task.spawn(function()
                            local ranked = rankContinuationsFen(targetFen, res.best, myReqId)
                            if not alive() or not ranked or S.reqId ~= myReqId then
                                return
                            end

                            S.second = ranked[1] and ranked[1].uci or nil
                            S.secondSan = ranked[1] and ranked[1].san or nil
                            S.third = ranked[2] and ranked[2].uci or nil
                            S.thirdSan = ranked[2] and ranked[2].san or nil
                        end)
                    end
                end)
            end

            local isViewingLatest = (session.viewPly == nil or session.viewPly == ply)
            if RUNTIME.SHOW_ARROW and isViewingLatest then
                if S.best then
                    drawArrow(ARROW_KEYS[1], S.best, CFG.ARROW_1, true)
                end
                if RUNTIME.SHOW_MULTI_ARROWS then
                    if S.second then drawArrow(ARROW_KEYS[2], S.second, CFG.ARROW_2, false) end
                    if S.third then drawArrow(ARROW_KEYS[3], S.third, CFG.ARROW_3, false) end
                end
            else
                clearArrows()
            end

            local autoExtra = ""
            if RUNTIME.AUTO and myTurn and isViewingLatest and not S.busy and S.best then
                local now = os.clock()
                local rem = S.thinkAt - now
                if rem > 0 then
                    autoExtra = string.format(" | Auto in %.1fs", rem)
                elseif now >= S.retryAt then
                    S.retryAt = now + 0.65
                    local uci = pickMove(S.liveFen)
                    autoExtra = " | Playing " .. tostring(uci)
                    if type(uci) == "string" and #uci >= 4 then
                        task.spawn(function()
                            if alive() and App.session == session and not session.over and session:isMyTurn() then
                                playUci(uci)
                            end
                        end)
                    end
                end
            end

            local sideStr = (session.myColor == 1) and "White" or "Black"
            local turnText = myTurn and ("Your Turn (" .. sideStr .. ")") or "Opponent's Turn"
            local evalLine = S.busy and "Eval: Calculating..." or string.format("Eval: %s (Depth %d)", evalText(S.score), S.depth)

            local m1 = S.best and string.format("%s (%s)", S.san or "?", S.best) or "-"
            local m2 = S.second and (S.secondSan or S.second) or "-"
            local m3 = S.third and (S.thirdSan or S.third) or "-"

            local myClock, oppClock = "--:--", "--:--"
            if session.clocks and session.myColor then
                myClock = formatClock(session.clocks[session.myColor])
                oppClock = formatClock(session.clocks[-session.myColor])
            end

            pcall(function()
                MonitorParagraph:Set({
                    Title = string.format("Status: %s | %s%s", S.status, turnText, autoExtra),
                    Content = string.format(
                        "%s\n1st: %s | 2nd: %s | 3rd: %s\nClocks: You %s | Opponent %s",
                        evalLine, m1, m2, m3, myClock, oppClock
                    )
                })
            end)
            pushEval()
        else
            clearArrows()
            pcall(function()
                MonitorParagraph:Set({
                    Title = "Status: No active game",
                    Content = "Eval: - (Depth 0)\n1st: - | 2nd: - | 3rd: -\nClocks: You --:-- | Opponent --:--"
                })
            end)
        end

        task.wait(0.1)
    end
end)

Rayfield:Notify({
    Title = "BrN Hub Loaded",
    Content = "Press RightShift to toggle the menu.",
    Duration = 4
})
