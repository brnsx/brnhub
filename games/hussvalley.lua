-- huss-valley.luau
-- Huss Valley helper: auto farm, auto runner (with auto dash + camera follow), auto chaser, auto tackle, auto choice, anti-AFK, ESP.
-- Client-side only. Everything here is local to your own client.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local UserInputService = game:GetService("UserInputService")
local LocalPlayer = Players.LocalPlayer

local ChickenOrHero = game:GetService("ReplicatedStorage"):WaitForChild("ChickenOrHero")
local GameFolder = ChickenOrHero:WaitForChild("Game")
local MovementFolder = ChickenOrHero:WaitForChild("Movement")
local GearFolder = ChickenOrHero:FindFirstChild("Gear")
local Session = GameFolder:WaitForChild("Session")
local GameAction = GameFolder:WaitForChild("GameAction")
local PlayerPreferences = GameFolder:WaitForChild("PlayerPreferences")
local MeleeEvent = GameFolder:FindFirstChild("MeleeEvent")

local TacklePrediction: any
pcall(function()
	local mod: any = GameFolder:FindFirstChild("TacklePrediction")
	if mod then
		TacklePrediction = (require :: any)(mod)
	end
end)

local CombatPrediction: any
pcall(function()
	local mod: any = GameFolder:FindFirstChild("CombatPrediction")
	if mod then
		CombatPrediction = (require :: any)(mod)
	end
end)

local ContactCatchConfig: any
pcall(function()
	local mod: any = GameFolder:FindFirstChild("ContactCatchConfig")
	if mod then
		ContactCatchConfig = (require :: any)(mod)
	end
end)

local BoostInput: any
pcall(function()
	local mod: any = MovementFolder:FindFirstChild("BoostInput")
	if mod then
		BoostInput = (require :: any)(mod)
	end
end)

local GearPredictionClient: any
local GearCatalog: any
local AbilityRule: any
pcall(function()
	if GearFolder then
		local gpc = GearFolder:FindFirstChild("GearPredictionClient")
		if gpc then
			GearPredictionClient = (require :: any)(gpc)
		end
		local gc = GearFolder:FindFirstChild("GearCatalog")
		if gc then
			GearCatalog = (require :: any)(gc)
		end
	end
	local ar = GameFolder:FindFirstChild("AbilityRule")
	if ar then
		AbilityRule = (require :: any)(ar)
	end
end)

local STATE: any = (getfenv() :: any).STATE

local Cfg = {
	autoFarm = true,
	autoRun = false,
	autoDash = true,
	autoShield = true,
	dashPredictive = true,
	dashThreatRange = 14,
	useEscapeRoutes = true,
	autoCollect = true,
	collectRadius = 28,
	collectSafeCatcherDist = 38,
	cameraFollow = true,
	autoChase = false,
	autoTackle = true,
	autoMelee = true,
	autoChoice = true,
	playHero = false,
	antiAfk = true,
	evade = true,
	evadeRange = 28,
	speed = 34,
	tackleRange = 11,
	esp = false,
}

local Debug = {
	frames = 0,
	driven = 0,
	lastDir = Vector3.zero,
	tackles = 0,
	melees = 0,
	dashes = 0,
	lastDashReason = "none",
	shields = 0,
	lastShieldReason = "none",
	escapeLane = "center",
	collected = 0,
	collectTarget = "none",
	choices = 0,
	afkCleared = 0,
	errors = 0,
}

-- Disable Roblox/IdleReportClient idle connections so LocalPlayer.Idled never marks us AFK.
pcall(function()
	if getconnections then
		for _, conn in ipairs(getconnections(LocalPlayer.Idled)) do
			pcall(function()
				conn:Disable()
			end)
		end
	end
end)

-- ---------------------------------------------------------------- characters

local function getChar()
	local char = LocalPlayer.Character or workspace:FindFirstChild(LocalPlayer.Name)
	if not char then
		return nil
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not (hum and root) then
		return nil
	end
	return char, hum, root
end

local function rootOf(pl)
	local char = pl.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root then
		return root
	end
	local model = workspace:FindFirstChild(pl.Name)
	return model and model:FindFirstChild("HumanoidRootPart")
end

local function roleOf(pl)
	return pl:GetAttribute("GameRole")
end

local function isActive(pl)
	return pl:GetAttribute("RunState") == "Active"
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

local function getMovementStateTable(): any
	if not (BoostInput and BoostInput.turning and debug and debug.getupvalue) then
		return nil
	end
	local ok, val = pcall(debug.getupvalue, BoostInput.turning, 4)
	if ok and type(val) == "table" and val.travelHistory ~= nil then
		return val
	end
	return nil
end

-- ------------------------------------------------------------------- targets

local function currentField()
	local rawMapId = Session:GetAttribute("ActiveMapId")
	local mapId = (rawMapId == "Map1NoAbilities") and "Map1" or rawMapId
	local map = mapId and workspace:FindFirstChild(mapId)
	local field = map and map:FindFirstChild("Field")
	if field then
		return field, map
	end
	local _, _, myRoot = getChar()
	local refPos = myRoot and myRoot.Position or (workspace.CurrentCamera and workspace.CurrentCamera.CFrame.Position) or Vector3.zero
	local bestField, bestMap, bestDist
	for _, child in ipairs(workspace:GetChildren()) do
		local f = child:FindFirstChild("Field")
		if f then
			local sa = f:FindFirstChild("SafezoneASide") or f:FindFirstChild("Line") or f:FindFirstChildWhichIsA("BasePart")
			if sa and sa:IsA("BasePart") then
				local d = (sa.Position - refPos).Magnitude
				if not bestDist or d < bestDist then
					bestDist = d
					bestField = f
					bestMap = child
				end
			elseif not bestField then
				bestField = f
				bestMap = child
			end
		end
	end
	return bestField, bestMap
end

-- ============================================================================
-- 1. PLAYER MOVEMENT & ESCAPE ROUTE PREDICTION + 2. CHASER PREDICTION ENGINE
-- ============================================================================

local PRED_HORIZONS = { 1, 2, 3, 5 }
local SIM_STEP = 0.50 -- 10 steps up to 5.0s (exact hits at 1s, 2s, 3s, 5s with half the CPU cost)

local playerTrackers: { [Player]: any } = {}
local chaserPredictions: { [Player]: any } = {}
local chaseTarget, chaseUntil = nil, 0

local obstacleRayParams = RaycastParams.new()
obstacleRayParams.FilterType = Enum.RaycastFilterType.Exclude
obstacleRayParams.RespectCanCollide = true

local NAV_CELL = 5.5 -- 5.5-stud 2D grid resolution (~1,800-2,400 cells per map)
local learnedMapCache: { [string]: any } = {} -- Persistent per-map learned obstacle cache across streaming

local arenaBounds = {
	valid = false,
	mapId = nil :: string?,
	startSide = nil :: string?,
	targetSide = "B",
	field = nil :: Instance?,
	mapModel = nil :: Instance?,
	goalZone = nil :: BasePart?,
	startZone = nil :: BasePart?,
	centerPos = Vector3.new(135, 0, 0),
	goalCenter = Vector3.new(135, 0, -140),
	startCenter = Vector3.new(135, 0, 140),
	forwardDir = Vector3.new(0, 0, -1), -- Unit 2D vector from StartZone -> GoalZone
	rightDir = Vector3.new(1, 0, 0), -- Unit 2D vector perpendicular to forwardDir (across finish line width)
	halfWidth = 65, -- Usable half-width of the arena/finish line along rightDir
	halfLength = 155, -- Half-length of the arena along forwardDir
	spanLen = 260,
	gateMinLat = -60,
	gateMaxLat = 60,
	minX = 50,
	maxX = 220,
	minZ = -195,
	maxZ = 195,
	centerX = 135,
	centerZ = 0,
	floorY = 18,
	floorTopY = 15.5,
	goalZ = -140,
	openLanes = {}, -- Pre-verified unobstructed lanes across the finish line
	-- Learned 2D Navigation Grid & Dijkstra Flow-Field for the active map:
	navGrid = nil :: any,
	learnedPartCount = 0,
	learnedobstaclesCount = 0,
}

local wasLocalActive = false
local lockedCrossingTargetSide: string? = nil
local lastBoundsRefreshAt = 0
local lastFilterRefreshAt = 0
local lastStreamRequestAt = 0

local function isSafezoneOrBarrierPart(part: BasePart): boolean
	local name = part.Name
	local cg = part.CollisionGroup
	if cg == "CoHSafezone" or cg == "CoHBarrierA" or cg == "CoHBarrierB" then
		return true
	end
	if name:find("Safezone") or name:find("InvisWall") or name == "Line" or name == "Water" then
		return true
	end
	return false
end

local function refreshRaycastFilter(force: boolean?)
	local now = os.clock()
	if not force and (now - lastFilterRefreshAt) < 0.85 then
		return
	end
	lastFilterRefreshAt = now

	local _, _, myRoot = getChar()
	if myRoot then
		pcall(function()
			obstacleRayParams.CollisionGroup = myRoot.CollisionGroup
		end)
	end

	local ignore = {}
	for _, pl in ipairs(Players:GetPlayers()) do
		local c = pl.Character or workspace:FindFirstChild(pl.Name)
		if c then
			table.insert(ignore, c)
		end
	end

	local field, mapModel = arenaBounds.field, arenaBounds.mapModel
	if not field then
		field, mapModel = currentField()
	end
	if field then
		table.insert(ignore, field)
	end
	if mapModel then
		for _, d in ipairs(mapModel:GetDescendants()) do
			if d:IsA("BasePart") and isSafezoneOrBarrierPart(d) then
				table.insert(ignore, d)
			end
		end
	end
	for _, fxName in ipairs({
		"HV_PredictionMarkers",
		"LightsOutArrow",
		"LocalRunnerGems",
		"LocalRunnerCandyCorn",
		"LocalLocomotionRigs",
		"LocalShieldBubbles",
		"PredictedGearPresentation",
		"LocalGearEffects",
	}) do
		local fx = workspace:FindFirstChild(fxName)
		if fx then
			table.insert(ignore, fx)
		end
	end
	obstacleRayParams.FilterDescendantsInstances = ignore
end

local function learnMapFlowField(mapKey: string, mapModel: Instance?, field: Instance)
	local centerPos = arenaBounds.centerPos
	local forwardDir = arenaBounds.forwardDir
	local rightDir = arenaBounds.rightDir
	local halfW = math.max(24, arenaBounds.halfWidth)
	local halfL = math.max(60, arenaBounds.halfLength)
	local floorTopY = arenaBounds.floorTopY

	local nx = math.clamp(math.ceil((halfW * 2) / NAV_CELL), 12, 64)
	local nz = math.clamp(math.ceil((halfL * 2) / NAV_CELL), 16, 76)
	local minLat = -halfW
	local minLon = -halfL
	local cellW = (halfW * 2) / nx
	local cellL = (halfL * 2) / nz

	local cacheId = string.format("%s_%s_%dx%d", tostring(mapKey), tostring(arenaBounds.targetSide), nx, nz)
	local cached = learnedMapCache[cacheId]
	if not cached then
		cached = {
			blocked = table.create(nx * nz, false),
			wallPenalty = table.create(nx * nz, 0),
			partCount = 0,
		}
		learnedMapCache[cacheId] = cached
	end

	local blocked = cached.blocked
	local wallPenalty = cached.wallPenalty
	local partCount = 0
	local obsCount = 0

	if mapModel then
		local charPad = 2.45
		local softPad = 5.40
		for _, d in ipairs(mapModel:GetDescendants()) do
			if d:IsA("BasePart") then
				partCount = partCount + 1
				if d.CanCollide
					and not d:IsDescendantOf(field)
					and not isSafezoneOrBarrierPart(d)
					and d.Name ~= "Floor"
					and d.Name ~= "Grass"
					and d.Name ~= "Rock"
				then
					local cf = d.CFrame
					local sz = d.Size
					local halfSz = sz * 0.5
					local extY = math.abs(cf.RightVector.Y) * halfSz.X
						+ math.abs(cf.UpVector.Y) * halfSz.Y
						+ math.abs(cf.LookVector.Y) * halfSz.Z
					local minY = cf.Position.Y - extY
					local maxY = cf.Position.Y + extY

					if maxY >= (floorTopY + 1.35) and minY <= (floorTopY + 5.2) then
						if math.min(sz.X, sz.Z) < 160 then
							obsCount = obsCount + 1
							local rel2D = flat(cf.Position) - centerPos
							local pLat = rel2D:Dot(rightDir)
							local pLon = rel2D:Dot(forwardDir)

							local uxLat = cf.RightVector:Dot(rightDir)
							local uxLon = cf.RightVector:Dot(forwardDir)
							local uyLat = cf.UpVector:Dot(rightDir)
							local uyLon = cf.UpVector:Dot(forwardDir)
							local uzLat = cf.LookVector:Dot(rightDir)
							local uzLon = cf.LookVector:Dot(forwardDir)

							local aabbLat = math.abs(uxLat) * halfSz.X + math.abs(uyLat) * halfSz.Y + math.abs(uzLat) * halfSz.Z + softPad
							local aabbLon = math.abs(uxLon) * halfSz.X + math.abs(uyLon) * halfSz.Y + math.abs(uzLon) * halfSz.Z + softPad

							local ixMin = math.clamp(math.floor((pLat - aabbLat - minLat) / cellW) + 1, 1, nx)
							local ixMax = math.clamp(math.floor((pLat + aabbLat - minLat) / cellW) + 1, 1, nx)
							local izMin = math.clamp(math.floor((pLon - aabbLon - minLon) / cellL) + 1, 1, nz)
							local izMax = math.clamp(math.floor((pLon + aabbLon - minLon) / cellL) + 1, 1, nz)

							for iz = izMin, izMax do
								local cLon = minLon + (iz - 0.5) * cellL
								local rowOff = (iz - 1) * nx
								for ix = ixMin, ixMax do
									local cLat = minLat + (ix - 0.5) * cellW
									local worldPt = centerPos + rightDir * cLat + forwardDir * cLon + Vector3.new(0, math.clamp(floorTopY + 2.8, minY, maxY), 0)
									local localPt = cf:PointToObjectSpace(worldPt)
									local dx = math.max(0, math.abs(localPt.X) - halfSz.X)
									local dz = math.max(0, math.abs(localPt.Z) - halfSz.Z)
									local dy = math.max(0, math.abs(localPt.Y) - halfSz.Y)
									local distToBox = math.sqrt(dx * dx + dy * dy + dz * dz)

									local idx = rowOff + ix
									if distToBox <= charPad then
										blocked[idx] = true
									elseif distToBox <= softPad then
										local pen = (1 - (distToBox - charPad) / (softPad - charPad)) * 4.5
										if pen > (wallPenalty[idx] or 0) then
											wallPenalty[idx] = pen
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end

	cached.partCount = partCount
	arenaBounds.learnedPartCount = partCount
	arenaBounds.learnedobstaclesCount = obsCount

	local goalLon = (arenaBounds.goalCenter - centerPos):Dot(forwardDir)
	local goalIz = math.clamp(math.floor((goalLon - minLon) / cellL) + 1, 2, nz)

	local totalCells = nx * nz
	local distField = table.create(totalCells, math.huge)
	local goalLatForCell = table.create(totalCells, 0)
	local inQueue = table.create(totalCells, false)
	local queue = {}
	local qHead = 1
	local qTail = 0

	local gateMinLat = arenaBounds.gateMinLat
	local gateMaxLat = arenaBounds.gateMinLat and arenaBounds.gateMaxLat or halfW
	local gateMidLat = (gateMinLat + gateMaxLat) * 0.5

	local seededCount = 0
	for pass = 1, 2 do
		for ix = 2, nx - 1 do
			local cLat = minLat + (ix - 0.5) * cellW
			local inGate = (cLat >= gateMinLat - 4 and cLat <= gateMaxLat + 4)
			if pass == 2 or inGate then
				local idxGoal = (goalIz - 1) * nx + ix
				local idxPrev1 = (math.max(1, goalIz - 2) - 1) * nx + ix
				local idxPrev2 = (math.max(1, goalIz - 3) - 1) * nx + ix
				local approachOpen = not blocked[idxGoal] and not blocked[idxPrev1] and (pass == 2 or not blocked[idxPrev2])
				if approachOpen and distField[idxGoal] == math.huge then
					local gateBias = inGate and (math.abs(cLat - gateMidLat) * 0.04) or (12.0 + math.abs(cLat - gateMidLat) * 0.12)
					distField[idxGoal] = gateBias
					goalLatForCell[idxGoal] = cLat
					inQueue[idxGoal] = true
					qTail = qTail + 1
					queue[qTail] = idxGoal
					seededCount = seededCount + 1
					for izBehind = goalIz + 1, nz do
						local idxB = (izBehind - 1) * nx + ix
						if not blocked[idxB] and distField[idxB] == math.huge then
							distField[idxB] = gateBias
							goalLatForCell[idxB] = cLat
						end
					end
				end
			end
		end
		if seededCount >= 3 then
			break
		end
	end

	if seededCount == 0 then
		local midIx = math.clamp(math.floor((gateMidLat - minLat) / cellW) + 1, 2, nx - 1)
		for ix = math.max(1, midIx - 2), math.min(nx, midIx + 2) do
			local cLat = minLat + (ix - 0.5) * cellW
			local idxGoal = (goalIz - 1) * nx + ix
			blocked[idxGoal] = false
			distField[idxGoal] = math.abs(cLat - gateMidLat) * 0.05
			goalLatForCell[idxGoal] = cLat
			inQueue[idxGoal] = true
			qTail = qTail + 1
			queue[qTail] = idxGoal
		end
	end

	local diagCost = math.sqrt(cellW * cellW + cellL * cellL)
	local dirs8 = {
		{ dx = 0, dz = -1, cost = cellL },
		{ dx = 0, dz = 1, cost = cellL },
		{ dx = -1, dz = 0, cost = cellW },
		{ dx = 1, dz = 0, cost = cellW },
		{ dx = -1, dz = -1, cost = diagCost },
		{ dx = 1, dz = -1, cost = diagCost },
		{ dx = -1, dz = 1, cost = diagCost },
		{ dx = 1, dz = 1, cost = diagCost },
	}

	while qHead <= qTail do
		local curIdx = queue[qHead]
		qHead = qHead + 1
		inQueue[curIdx] = false
		local curCost = distField[curIdx]
		local curIz = math.floor((curIdx - 1) / nx) + 1
		local curIx = curIdx - (curIz - 1) * nx

		for _, st in ipairs(dirs8) do
			local nIx = curIx + st.dx
			local nIz = curIz + st.dz
			if nIx >= 1 and nIx <= nx and nIz >= 1 and nIz <= nz then
				local nIdx = (nIz - 1) * nx + nIx
				if not blocked[nIdx] then
					local cornerClear = true
					if st.dx ~= 0 and st.dz ~= 0 then
						local idxA = (curIz - 1) * nx + nIx
						local idxB = (nIz - 1) * nx + curIx
						if blocked[idxA] or blocked[idxB] then
							cornerClear = false
						end
					end
					if cornerClear then
						local edgePenalty = (nIx == 1 or nIx == nx) and 3.5 or 0
						local newCost = curCost + st.cost + (wallPenalty[nIdx] or 0) + edgePenalty
						if newCost + 0.05 < distField[nIdx] then
							distField[nIdx] = newCost
							goalLatForCell[nIdx] = goalLatForCell[curIdx]
							if not inQueue[nIdx] then
								inQueue[nIdx] = true
								qTail = qTail + 1
								queue[qTail] = nIdx
							end
						end
					end
				end
			end
		end
	end

	arenaBounds.navGrid = {
		nx = nx,
		nz = nz,
		minLat = minLat,
		minLon = minLon,
		cellW = cellW,
		cellL = cellL,
		goalIz = goalIz,
		blocked = blocked,
		wallPenalty = wallPenalty,
		distField = distField,
		goalLatForCell = goalLatForCell,
	}

	table.clear(arenaBounds.openLanes)
	local laneSpanMin = math.max(minLat + cellW, gateMinLat)
	local laneSpanMax = math.min(-minLat - cellW, gateMaxLat)
	local laneMid = (laneSpanMin + laneSpanMax) * 0.5
	local laneHalf = math.max(10, (laneSpanMax - laneSpanMin) * 0.46)
	local candidateDefs = {
		{ name = "far-left", frac = -0.90 },
		{ name = "mid-left", frac = -0.45 },
		{ name = "center", frac = 0.0 },
		{ name = "mid-right", frac = 0.45 },
		{ name = "far-right", frac = 0.90 },
	}
	for _, def in ipairs(candidateDefs) do
		local lat = laneMid + laneHalf * def.frac
		local ix = math.clamp(math.floor((lat - minLat) / cellW) + 1, 1, nx)
		local checkIz = math.clamp(goalIz - 2, 1, nz)
		local idx = (checkIz - 1) * nx + ix
		if not blocked[idx] and distField[idx] < math.huge then
			table.insert(arenaBounds.openLanes, {
				name = def.name,
				lat = lat,
				goalPoint = arenaBounds.goalCenter + rightDir * lat,
			})
		end
	end
	if #arenaBounds.openLanes == 0 then
		table.insert(arenaBounds.openLanes, {
			name = "center",
			lat = gateMidLat,
			goalPoint = arenaBounds.goalCenter + rightDir * gateMidLat,
		})
	end
end

local function isLearnedPosWalkable(pos2D: Vector3): boolean
	local grid = arenaBounds.navGrid
	if not grid or not arenaBounds.valid then
		return true
	end
	local rel = pos2D - arenaBounds.centerPos
	local lat = rel:Dot(arenaBounds.rightDir)
	local lon = rel:Dot(arenaBounds.forwardDir)
	local ix = math.floor((lat - grid.minLat) / grid.cellW) + 1
	local iz = math.floor((lon - grid.minLon) / grid.cellL) + 1
	if ix < 1 or ix > grid.nx or iz < 1 or iz > grid.nz then
		return false
	end
	local idx = (iz - 1) * grid.nx + ix
	return (not grid.blocked[idx]) and (grid.distField[idx] < math.huge)
end

local function sampleLearnedMapFlow(pos2D: Vector3): (Vector3?, Vector3?, number?)
	local grid = arenaBounds.navGrid
	if not grid or not arenaBounds.valid then
		return nil, nil, nil
	end

	local centerPos = arenaBounds.centerPos
	local rightDir = arenaBounds.rightDir
	local forwardDir = arenaBounds.forwardDir
	local rel = pos2D - centerPos
	local myLat = rel:Dot(rightDir)
	local myLon = rel:Dot(forwardDir)

	local nx, nz = grid.nx, grid.nz
	local curIx = math.clamp(math.floor((myLat - grid.minLat) / grid.cellW) + 1, 1, nx)
	local curIz = math.clamp(math.floor((myLon - grid.minLon) / grid.cellL) + 1, 1, nz)
	local curIdx = (curIz - 1) * nx + curIx

	if grid.blocked[curIdx] or grid.distField[curIdx] == math.huge then
		local bestNearCost = math.huge
		local foundIx, foundIz = curIx, curIz
		for r = 1, 4 do
			for dz = -r, r do
				for dx = -r, r do
					local nIx = curIx + dx
					local nIz = curIz + dz
					if nIx >= 1 and nIx <= nx and nIz >= 1 and nIz <= nz then
						local nIdx = (nIz - 1) * nx + nIx
						if not grid.blocked[nIdx] and grid.distField[nIdx] < bestNearCost then
							bestNearCost = grid.distField[nIdx]
							foundIx, foundIz = nIx, nIz
						end
					end
				end
			end
			if bestNearCost < math.huge then
				break
			end
		end
		curIx, curIz = foundIx, foundIz
		curIdx = (curIz - 1) * nx + curIx
	end

	if grid.distField[curIdx] == math.huge then
		return nil, nil, nil
	end

	local pathDist = grid.distField[curIdx]
	local targetGoalLat = grid.goalLatForCell[curIdx] or math.clamp(myLat, arenaBounds.gateMinLat, arenaBounds.gateMaxLat)
	local goalPos = arenaBounds.goalCenter + rightDir * targetGoalLat

	local stepIx, stepIz = curIx, curIz
	for _ = 1, 3 do
		if stepIz >= grid.goalIz then
			break
		end
		local bestNextCost = grid.distField[(stepIz - 1) * nx + stepIx]
		local nextIx, nextIz = stepIx, stepIz
		for dz = -1, 1 do
			for dx = -1, 1 do
				if not (dx == 0 and dz == 0) then
					local nIx = stepIx + dx
					local nIz = stepIz + dz
					if nIx >= 1 and nIx <= nx and nIz >= 1 and nIz <= nz then
						local nIdx = (nIz - 1) * nx + nIx
						local c = grid.distField[nIdx]
						if not grid.blocked[nIdx] and c < bestNextCost then
							local clearDiag = true
							if dx ~= 0 and dz ~= 0 then
								if grid.blocked[(stepIz - 1) * nx + nIx] or grid.blocked[(nIz - 1) * nx + stepIx] then
									clearDiag = false
								end
							end
							if clearDiag then
								bestNextCost = c
								nextIx, nextIz = nIx, nIz
							end
						end
					end
				end
			end
		end
		if nextIx == stepIx and nextIz == stepIz then
			break
		end
		stepIx, stepIz = nextIx, nextIz
	end

	local wpLat = grid.minLat + (stepIx - 0.5) * grid.cellW
	local wpLon = grid.minLon + (stepIz - 0.5) * grid.cellL
	local waypointPos = centerPos + rightDir * wpLat + forwardDir * wpLon

	if stepIz >= grid.goalIz - 1 then
		waypointPos = goalPos
	end

	local toWp = waypointPos - pos2D
	local flowDir = (toWp.Magnitude > 0.25) and toWp.Unit or forwardDir
	return flowDir, goalPos, pathDist
end

local function refreshArenaBounds(force: boolean?)
	local now = os.clock()
	local mapId = Session:GetAttribute("ActiveMapId")
	local startSide = Session:GetAttribute("StartSide")
	local localActive = isActive(LocalPlayer)

	local justBecameActive = localActive and not wasLocalActive
	wasLocalActive = localActive
	if not localActive then
		lockedCrossingTargetSide = nil
	end

	if not force
		and not justBecameActive
		and arenaBounds.valid
		and arenaBounds.mapId == mapId
		and arenaBounds.startSide == startSide
	then
		if (now - lastBoundsRefreshAt) < 2.0 then
			return
		end
		lastBoundsRefreshAt = now
		local fieldCheck, mapModelCheck = currentField()
		if fieldCheck == arenaBounds.field and mapModelCheck then
			local curCount = 0
			for _, d in ipairs(mapModelCheck:GetDescendants()) do
				if d:IsA("BasePart") then
					curCount = curCount + 1
				end
			end
			if math.abs(curCount - arenaBounds.learnedPartCount) < 5 then
				return
			end
		end
	end
	lastBoundsRefreshAt = now

	local field, mapModel = currentField()
	if not field then
		arenaBounds.valid = false
		return
	end

	local safeA = field:FindFirstChild("SafezoneASide")
	local safeB = field:FindFirstChild("SafezoneBSide")
	local floor = field:FindFirstChild("Floor") or field:FindFirstChild("Grass") or field:FindFirstChild("Rock")

	local innerModel = mapModel and mapModel:FindFirstChild("Model")
	local innerSafeA = innerModel and innerModel:FindFirstChild("SafezoneASide")
	local innerSafeB = innerModel and innerModel:FindFirstChild("SafezoneBSide")
	if not (safeA and safeA:IsA("BasePart")) and innerSafeA and innerSafeA:IsA("BasePart") then
		safeA = innerSafeA
	end
	if not (safeB and safeB:IsA("BasePart")) and innerSafeB and innerSafeB:IsA("BasePart") then
		safeB = innerSafeB
	end

	if not (safeA and safeA:IsA("BasePart") and safeB and safeB:IsA("BasePart")) then
		if not (floor and floor:IsA("BasePart")) then
			arenaBounds.valid = false
			return
		end
		if not (safeA and safeA:IsA("BasePart")) and not (safeB and safeB:IsA("BasePart")) then
			arenaBounds.valid = false
			return
		end
	end

	local targetSide = (startSide == "A") and "B" or "A"

	local _, _, myRoot = getChar()
	if myRoot and localActive then
		if justBecameActive or not lockedCrossingTargetSide or arenaBounds.startSide ~= startSide then
			local myPos = flat(myRoot.Position)
			if safeA and safeA:IsA("BasePart") and safeB and safeB:IsA("BasePart") then
				local dA = (flat(safeA.Position) - myPos).Magnitude
				local dB = (flat(safeB.Position) - myPos).Magnitude
				if math.abs(dA - dB) > 35 then
					lockedCrossingTargetSide = (dA < dB) and "B" or "A"
				else
					lockedCrossingTargetSide = targetSide
				end
			elseif safeA and safeA:IsA("BasePart") then
				local dA = (flat(safeA.Position) - myPos).Magnitude
				lockedCrossingTargetSide = (dA < 90) and "B" or "A"
			elseif safeB and safeB:IsA("BasePart") then
				local dB = (flat(safeB.Position) - myPos).Magnitude
				lockedCrossingTargetSide = (dB < 90) and "A" or "B"
			end
		end
		if lockedCrossingTargetSide then
			targetSide = lockedCrossingTargetSide
		end
	end

	local knownZone: BasePart = ((safeA and safeA:IsA("BasePart")) and safeA or safeB) :: BasePart
	local floorCenter2D = (floor and floor:IsA("BasePart")) and flat(floor.Position) or flat(knownZone.Position)

	local posA2D: Vector3
	local posB2D: Vector3
	if safeA and safeA:IsA("BasePart") and safeB and safeB:IsA("BasePart") then
		posA2D = flat(safeA.Position)
		posB2D = flat(safeB.Position)
	elseif safeA and safeA:IsA("BasePart") then
		posA2D = flat(safeA.Position)
		posB2D = floorCenter2D + (floorCenter2D - posA2D)
	else
		posB2D = flat((safeB :: BasePart).Position)
		posA2D = floorCenter2D + (floorCenter2D - posB2D)
	end

	local targetZone: BasePart = ((targetSide == "B") and (safeB or safeA) or (safeA or safeB)) :: BasePart
	local startZone: BasePart = ((targetSide == "B") and (safeA or safeB) or (safeB or safeA)) :: BasePart
	local startPos2D = (targetSide == "B") and posA2D or posB2D
	local goalPos2D = (targetSide == "B") and posB2D or posA2D

	if workspace.StreamingEnabled and (now - lastStreamRequestAt) > 2.5 then
		lastStreamRequestAt = now
		local streamY = (floor and floor:IsA("BasePart")) and floor.Position.Y or targetZone.Position.Y
		local goal3D = Vector3.new(goalPos2D.X, streamY, goalPos2D.Z)
		local mid3D = Vector3.new(floorCenter2D.X, streamY, floorCenter2D.Z)
		task.spawn(function()
			pcall(function()
				LocalPlayer:RequestStreamAroundAsync(mid3D, 2)
				LocalPlayer:RequestStreamAroundAsync(goal3D, 2)
			end)
		end)
	end

	local spanVec = goalPos2D - startPos2D
	local spanLen = spanVec.Magnitude
	local forwardDir = (spanLen > 0.5) and (spanVec / spanLen) or Vector3.new(0, 0, -1)
	local rightDir = Vector3.new(-forwardDir.Z, 0, forwardDir.X)
	local centerPos = (startPos2D + goalPos2D) * 0.5

	local zcf = targetZone.CFrame
	local zsz = targetZone.Size
	local zRight2D = flat(zcf.RightVector)
	local zLook2D = flat(zcf.LookVector)
	local zoneHalfWidth = (math.abs(zRight2D:Dot(rightDir)) * zsz.X + math.abs(zLook2D:Dot(rightDir)) * zsz.Z) * 0.46
	local zoneHalfDepth = (math.abs(zRight2D:Dot(forwardDir)) * zsz.X + math.abs(zLook2D:Dot(forwardDir)) * zsz.Z) * 0.5
	zoneHalfWidth = math.max(14, zoneHalfWidth)

	local gateMinLat = -zoneHalfWidth
	local gateMaxLat = zoneHalfWidth

	local innerTargetZone = (targetSide == "B") and innerSafeB or innerSafeA
	if innerTargetZone and innerTargetZone:IsA("BasePart") and innerTargetZone ~= targetZone then
		local icf = innerTargetZone.CFrame
		local isz = innerTargetZone.Size
		local iRight2D = flat(icf.RightVector)
		local iLook2D = flat(icf.LookVector)
		local innerHalfW = (math.abs(iRight2D:Dot(rightDir)) * isz.X + math.abs(iLook2D:Dot(rightDir)) * isz.Z) * 0.5
		local innerCenterLat = (flat(innerTargetZone.Position) - centerPos):Dot(rightDir)
		if innerHalfW >= 10 and innerHalfW < zoneHalfWidth * 0.85 then
			gateMinLat = math.max(gateMinLat, innerCenterLat - innerHalfW - 8)
			gateMaxLat = math.min(gateMaxLat, innerCenterLat + innerHalfW + 8)
		end
	end

	local spawnsFolder = mapModel and mapModel:FindFirstChild("Spawns")
	if spawnsFolder then
		local minSpawnLat = math.huge
		local maxSpawnLat = -math.huge
		local count = 0
		for _, grp in ipairs(spawnsFolder:GetChildren()) do
			if grp.Name:lower():find("runner") then
				for _, sp in ipairs(grp:GetChildren()) do
					if sp:IsA("BasePart") then
						local lat = (flat(sp.Position) - centerPos):Dot(rightDir)
						minSpawnLat = math.min(minSpawnLat, lat)
						maxSpawnLat = math.max(maxSpawnLat, lat)
						count = count + 1
					end
				end
			end
		end
		if count >= 4 and maxSpawnLat > minSpawnLat + 10 then
			gateMinLat = math.max(gateMinLat, minSpawnLat - 6)
			gateMaxLat = math.min(gateMaxLat, maxSpawnLat + 6)
		end
	end

	local floorTopY = targetZone.Position.Y - 2.6
	local floorY = targetZone.Position.Y
	if floor and floor:IsA("BasePart") then
		floorTopY = floor.Position.Y + floor.Size.Y * 0.5
		floorY = floorTopY + 2.6
	elseif myRoot then
		floorY = myRoot.Position.Y
		floorTopY = floorY - 2.6
	end

	local frontEdgeCenter = goalPos2D - forwardDir * math.max(0, zoneHalfDepth - 6.5)

	arenaBounds.valid = true
	arenaBounds.mapId = mapId
	arenaBounds.startSide = startSide
	arenaBounds.targetSide = targetSide
	arenaBounds.field = field
	arenaBounds.mapModel = mapModel
	arenaBounds.goalZone = targetZone
	arenaBounds.startZone = startZone
	arenaBounds.centerPos = centerPos
	arenaBounds.goalCenter = frontEdgeCenter
	arenaBounds.startCenter = startPos2D
	arenaBounds.forwardDir = forwardDir
	arenaBounds.rightDir = rightDir
	arenaBounds.halfWidth = zoneHalfWidth
	arenaBounds.halfLength = spanLen * 0.5 + zoneHalfDepth + 12
	arenaBounds.spanLen = spanLen
	arenaBounds.gateMinLat = gateMinLat
	arenaBounds.gateMaxLat = gateMaxLat
	arenaBounds.floorY = floorY
	arenaBounds.floorTopY = floorTopY
	arenaBounds.centerX = centerPos.X
	arenaBounds.centerZ = centerPos.Z
	arenaBounds.goalZ = frontEdgeCenter.Z
	arenaBounds.minX = math.min(startPos2D.X, goalPos2D.X) - zoneHalfWidth
	arenaBounds.maxX = math.max(startPos2D.X, goalPos2D.X) + zoneHalfWidth
	arenaBounds.minZ = math.min(startPos2D.Z, goalPos2D.Z) - zoneHalfWidth
	arenaBounds.maxZ = math.max(startPos2D.Z, goalPos2D.Z) + zoneHalfWidth

	refreshRaycastFilter(true)

	learnMapFlowField(tostring(mapId or (mapModel and mapModel.Name) or "Map1"), mapModel, field)
end

local function runTarget(root)
	refreshArenaBounds(false)
	if not arenaBounds.valid or not arenaBounds.goalZone then
		return nil
	end

	local pos = flat(root.Position)
	local flowDir, flowGoalPos, pathDist = sampleLearnedMapFlow(pos)
	if flowGoalPos then
		local dist = pathDist or (flowGoalPos - pos).Magnitude
		return flowGoalPos, dist, arenaBounds.goalZone, flowDir
	end

	local goalCenter = arenaBounds.goalCenter
	local rightDir = arenaBounds.rightDir
	local myLat = math.clamp((pos - arenaBounds.centerPos):Dot(rightDir), arenaBounds.gateMinLat, arenaBounds.gateMaxLat)
	local goalPos = goalCenter + rightDir * myLat
	local dist = (goalPos - pos).Magnitude
	return goalPos, dist, arenaBounds.goalZone, nil
end

local function stepGeometryAware(pos2D: Vector3, velDir: Vector3, stepDist: number, heightY: number, doRaycast: boolean?): (Vector3, Vector3, boolean)
	if stepDist <= 0.01 or velDir.Magnitude <= 0.01 then
		return pos2D, velDir, false
	end
	local dir = velDir.Unit
	local hitWall = false
	local nextPos = pos2D + dir * stepDist
	local nextDir = dir

	if doRaycast ~= false then
		local origin3D = Vector3.new(pos2D.X, heightY, pos2D.Z)
		local rayResult = workspace:Raycast(origin3D, Vector3.new(dir.X, 0, dir.Z) * (stepDist + 1.8), obstacleRayParams)

		if rayResult and rayResult.Instance and rayResult.Instance.CanCollide then
			local n = flat(rayResult.Normal)
			if n.Magnitude > 0.01 then
				n = n.Unit
				hitWall = true
				local slide = dir - n * dir:Dot(n)
				if slide.Magnitude > 0.05 then
					nextDir = slide.Unit
				else
					nextDir = Vector3.new(-n.Z, 0, n.X)
				end
				local safeAdvance = math.max(0, rayResult.Distance - 1.5)
				local remain = math.max(0, stepDist - safeAdvance)
				nextPos = pos2D + dir * safeAdvance + nextDir * (remain * 0.85)
			end
		end
	end

	if arenaBounds.valid then
		local center = arenaBounds.centerPos
		local rightDir = arenaBounds.rightDir
		local forwardDir = arenaBounds.forwardDir
		local maxLat = math.max(10, arenaBounds.halfWidth - 2.0)
		local maxLon = math.max(20, arenaBounds.halfLength - 2.0)

		local rel = nextPos - center
		local lat = rel:Dot(rightDir)
		local lon = rel:Dot(forwardDir)

		local clampedLat = math.clamp(lat, -maxLat, maxLat)
		local clampedLon = math.clamp(lon, -maxLon, maxLon)

		local hitSideLat = math.abs(clampedLat - lat) > 0.01
		local hitSideLon = math.abs(clampedLon - lon) > 0.01

		if hitSideLat or hitSideLon then
			hitWall = true
			nextPos = center + rightDir * clampedLat + forwardDir * clampedLon
			if hitSideLat and hitSideLon then
				local toGoal = arenaBounds.goalCenter - nextPos
				if toGoal.Magnitude > 0.05 then
					nextDir = toGoal.Unit
				end
			elseif hitSideLat then
				local fComp = nextDir:Dot(forwardDir)
				local fSign = (math.abs(fComp) > 0.05) and math.sign(fComp) or 1
				local inwardLat = (clampedLat < 0) and 0.16 or -0.16
				nextDir = (forwardDir * fSign + rightDir * inwardLat).Unit
			elseif hitSideLon then
				local rComp = nextDir:Dot(rightDir)
				local rSign = (math.abs(rComp) > 0.05) and math.sign(rComp) or ((clampedLat < 0) and 1 or -1)
				nextDir = rightDir * rSign
			end
		end
	end

	return nextPos, nextDir, hitWall
end

local function newPlayerTracker(pl: Player)
	return {
		player = pl,
		pos = Vector3.zero,
		pos3D = Vector3.zero,
		vel = Vector3.zero,
		velY = 0,
		accel = Vector3.zero,
		dir = Vector3.new(0, 0, 1),
		meanDir = Vector3.new(0, 0, 1),
		lookDir = Vector3.new(0, 0, 1),
		speed = 0,
		angularVel = 0,
		lastUpdate = 0,
		lastTurnSign = 0,
		lastTurnSignFlipAt = 0,
		lastSuddenTurnAt = 0,
		lastDashAt = 0,
		history = {},
		patterns = {
			suddenTurn = false,
			stopping = false,
			jumping = false,
			changingDirection = false,
			dashing = false,
			label = "Idle",
		},
		style = {
			samples = 0,
			avgSpeed = 32,
			jukeRate = 0,
			turnBias = 0,
			zigZagScore = 0,
			stopRate = 0,
			dashRate = 0,
		},
		predicted = {
			[1] = Vector3.zero,
			[2] = Vector3.zero,
			[3] = Vector3.zero,
			[5] = Vector3.zero,
		},
		trajectory = {},
		escapeRoutes = {},
		bestEscapeRoute = nil :: any,
	}
end

local function simulatePlayerTrajectory(tr: any, role: string?, useRaycast: boolean)
	local pos = tr.pos
	local speed = tr.speed
	local dir = tr.dir
	local meanDir = tr.meanDir
	local accel = tr.accel
	local style = tr.style
	local patterns = tr.patterns
	local heightY = tr.pos3D.Y

	table.clear(tr.trajectory)
	table.insert(tr.trajectory, { t = 0, pos = pos })

	if speed < 1.2 and accel.Magnitude < 4 then
		tr.predicted[1] = pos
		tr.predicted[2] = pos
		tr.predicted[3] = pos
		tr.predicted[5] = pos
		table.insert(tr.trajectory, { t = 5.0, pos = pos })
		return
	end

	local steadySpeed = speed
	if patterns.stopping and speed < 8 then
		steadySpeed = math.min(speed * 0.5, 4)
	elseif speed > 5 then
		steadySpeed = speed * 0.65 + style.avgSpeed * 0.35
	end

	local corridorDir = meanDir
	if role == "Runner" and arenaBounds.valid then
		local toGoal = arenaBounds.goalCenter - pos
		if toGoal:Dot(arenaBounds.forwardDir) > 4 then
			local latComp = meanDir:Dot(arenaBounds.rightDir) * 0.45
			local goalTrend = (arenaBounds.forwardDir + arenaBounds.rightDir * latComp).Unit
			local blended = meanDir * 0.55 + goalTrend * 0.45
			if blended.Magnitude > 0.01 then
				corridorDir = blended.Unit
			end
		end
	end

	local curPos = pos
	local curDir = dir
	local curSpeed = speed
	local effectiveYaw = math.clamp(tr.angularVel * (1 - style.zigZagScore * 0.7) + style.turnBias * 0.25, -3.2, 3.2)

	local totalSteps = math.floor(5.0 / SIM_STEP + 0.5)
	for stepIdx = 1, totalSteps do
		local t = stepIdx * SIM_STEP

		if t <= 0.5 then
			local stepVel = curDir * curSpeed + accel * (SIM_STEP * math.max(0, 1 - t * 1.4))
			if patterns.stopping then
				curSpeed = math.max(0, curSpeed - 28 * SIM_STEP)
			else
				curSpeed = math.clamp(stepVel.Magnitude, 0, 42)
				if stepVel.Magnitude > 1.5 then
					curDir = stepVel.Unit
				end
			end
		else
			curSpeed = curSpeed + (steadySpeed - curSpeed) * math.clamp(SIM_STEP * 2.2, 0, 1)
		end

		if t <= 0.75 and math.abs(effectiveYaw) > 0.15 and curSpeed > 4 then
			local yawStep = effectiveYaw * SIM_STEP * math.max(0, 1 - t)
			local c = math.cos(yawStep)
			local s = math.sin(yawStep)
			curDir = Vector3.new(curDir.X * c - curDir.Z * s, 0, curDir.X * s + curDir.Z * c).Unit
		elseif t > 0.5 and corridorDir.Magnitude > 0.01 then
			local pullWeight = math.clamp((0.25 + style.zigZagScore * 0.55) * SIM_STEP * 2.5, 0, 0.65)
			local blended = curDir:Lerp(corridorDir, pullWeight)
			if blended.Magnitude > 0.01 then
				curDir = blended.Unit
			end
		end

		local stepDist = curSpeed * SIM_STEP
		local nextPos, nextDir, _ = stepGeometryAware(curPos, curDir, stepDist, heightY, useRaycast)
		curPos = nextPos
		curDir = nextDir

		table.insert(tr.trajectory, { t = t, pos = curPos })

		if math.abs(t - 1.0) < 0.01 then
			tr.predicted[1] = curPos
		elseif math.abs(t - 2.0) < 0.01 then
			tr.predicted[2] = curPos
		elseif math.abs(t - 3.0) < 0.01 then
			tr.predicted[3] = curPos
		elseif math.abs(t - 5.0) < 0.01 then
			tr.predicted[5] = curPos
		end
	end
end

local function sampleTrajectoryAt(tr: any, targetTime: number): Vector3
	if not tr or not tr.trajectory or #tr.trajectory == 0 then
		return tr and tr.pos or Vector3.zero
	end
	if targetTime <= 0 then
		return tr.pos
	end
	local traj = tr.trajectory
	for i = 1, #traj - 1 do
		local a = traj[i]
		local b = traj[i + 1]
		if targetTime >= a.t and targetTime <= b.t then
			local alpha = (b.t > a.t) and ((targetTime - a.t) / (b.t - a.t)) or 0
			return a.pos:Lerp(b.pos, alpha)
		end
	end
	return traj[#traj].pos
end

local function predictEscapeRoutes(tr: any)
	local prevRouteName = tr.bestEscapeRoute and tr.bestEscapeRoute.name
	table.clear(tr.escapeRoutes)
	tr.bestEscapeRoute = nil
	if not arenaBounds.valid or not arenaBounds.goalZone then
		return
	end

	local pos = tr.pos
	local goalCenter = arenaBounds.goalCenter
	local forwardDir = arenaBounds.forwardDir
	local rightDir = arenaBounds.rightDir
	local halfW = arenaBounds.halfWidth * 0.90
	local heightY = tr.pos3D.Y

	local myLat = math.clamp((pos - goalCenter):Dot(rightDir), -halfW, halfW)
	local forwardRemain = math.max(0, (goalCenter - pos):Dot(forwardDir))
	local lookAheadLon = math.min(44, forwardRemain)

	local lanes = {}
	for _, openLane in ipairs(arenaBounds.openLanes) do
		table.insert(lanes, { name = openLane.name, lat = openLane.lat, goalPoint = openLane.goalPoint })
	end
	table.insert(lanes, {
		name = "direct",
		lat = myLat,
		goalPoint = goalCenter + rightDir * myLat,
	})

	local bestRoute = nil
	local bestScore = -math.huge

	for _, lane in ipairs(lanes) do
		local waypoint = pos + forwardDir * lookAheadLon + rightDir * (lane.lat - myLat)
		local toWaypoint = waypoint - pos
		local distToWp = toWaypoint.Magnitude
		local routeDir = (distToWp > 0.5) and toWaypoint.Unit or forwardDir

		local rayHit = workspace:Raycast(
			Vector3.new(pos.X, heightY, pos.Z),
			Vector3.new(routeDir.X, 0, routeDir.Z) * math.min(distToWp, 30),
			obstacleRayParams
		)
		local obstaclePenalty = 0
		if rayHit and rayHit.Instance and rayHit.Instance.CanCollide then
			obstaclePenalty = math.clamp(45 - rayHit.Distance, 15, 45)
		end

		local minChaserClearance = 90
		local runnerSpeed = math.max(tr.style.avgSpeed, 32)
		for _, pl in ipairs(Players:GetPlayers()) do
			if pl ~= tr.player and roleOf(pl) == "Catcher" and isActive(pl) then
				local cTr = playerTrackers[pl]
				if cTr then
					for _, sampleT in ipairs({ 0.5, 1.0, 1.6, 2.4 }) do
						local mySamplePos = pos + routeDir * (runnerSpeed * sampleT)
						local cSamplePos = sampleTrajectoryAt(cTr, sampleT)
						local d = (mySamplePos - cSamplePos).Magnitude
						if d < minChaserClearance then
							minChaserClearance = d
						end
					end
				end
			end
		end

		local detour = math.abs(lane.lat - myLat)
		local momentumAlign = routeDir:Dot(tr.dir)
		local keepBonus = (prevRouteName ~= nil and lane.name == prevRouteName) and 7.5 or 0
		local score = math.min(minChaserClearance, 55) * 1.65 - detour * 0.34 + momentumAlign * 5.0 + keepBonus - obstaclePenalty

		local routeEntry = {
			name = lane.name,
			waypoint = waypoint,
			goalPoint = lane.goalPoint,
			dir = routeDir,
			clearance = minChaserClearance,
			score = score,
		}
		table.insert(tr.escapeRoutes, routeEntry)

		if score > bestScore then
			bestScore = score
			bestRoute = routeEntry
		end
	end

	tr.bestEscapeRoute = bestRoute
end

local function updateChaserPredictions()
	local now = os.clock()
	local serverNow = workspace:GetServerTimeNow()
	local activeChasers = {}

	for _, chaser in ipairs(Players:GetPlayers()) do
		if roleOf(chaser) == "Catcher" and isActive(chaser) then
			local cTr = playerTrackers[chaser]
			local cChar = chaser.Character or workspace:FindFirstChild(chaser.Name)
			if cTr and cChar then
				activeChasers[chaser] = true
				local info = chaserPredictions[chaser]
				if not info then
					info = {
						chaser = chaser,
						targetPlayer = nil :: Player?,
						targetConfidence = 0,
						mode = "Patrolling",
						interceptPoint = nil :: Vector3?,
						interceptTime = math.huge,
						interceptDist = math.huge,
						willTurnSoon = false,
						anticipatedTurnDir = cTr.dir,
						turnReason = "",
						heading = cTr.dir,
						predicted = cTr.predicted,
					}
					chaserPredictions[chaser] = info
				end

				info.heading = cTr.dir
				info.predicted = cTr.predicted

				local reachTargetId = cChar:GetAttribute("ReachTargetUserId")
				local bestRunner: Player? = nil
				local bestRunnerTracker: any = nil
				local bestTargetScore = -math.huge

				for _, runner in ipairs(Players:GetPlayers()) do
					if runner ~= chaser and roleOf(runner) == "Runner" and isActive(runner) then
						local rTr = playerTrackers[runner]
						if rTr then
							local toRunner = rTr.pos - cTr.pos
							local dist = toRunner.Magnitude
							if dist < 180 and dist > 0.05 then
								local toUnit = toRunner.Unit
								local toPred1 = (rTr.predicted[1] - cTr.pos)
								local toPred1Unit = (toPred1.Magnitude > 0.05) and toPred1.Unit or toUnit

								local velAlign = (cTr.speed > 2) and math.max(cTr.dir:Dot(toUnit), cTr.dir:Dot(toPred1Unit)) or 0
								local lookAlign = math.max(cTr.lookDir:Dot(toUnit), cTr.lookDir:Dot(toPred1Unit))
								local closingSpeed = (cTr.vel - rTr.vel):Dot(toUnit)

								local score = (100 - math.min(dist, 100)) * 0.55
									+ velAlign * 32
									+ lookAlign * 22
									+ math.clamp(closingSpeed, -20, 40) * 0.65

								if reachTargetId == runner.UserId then
									score = score + 45
								end
								if info.targetPlayer == runner then
									score = score + 6
								end

								if score > bestTargetScore then
									bestTargetScore = score
									bestRunner = runner
									bestRunnerTracker = rTr
								end
							end
						end
					end
				end

				info.targetPlayer = bestRunner
				info.targetConfidence = math.clamp(bestTargetScore / 110, 0, 1)

				info.interceptPoint = nil
				info.interceptTime = math.huge
				info.interceptDist = math.huge
				info.willTurnSoon = false
				info.anticipatedTurnDir = cTr.dir
				info.turnReason = ""

				local tackleStart = cChar:GetAttribute("TackleStartedAt")
				local tackleDur = tonumber(cChar:GetAttribute("TackleDuration")) or 0.35
				local tackleRec = tonumber(cChar:GetAttribute("TackleRecovery")) or 0.65
				local isTackling = (cChar:GetAttribute("TackleActive") == true)
					or (cChar:GetAttribute("PhysicsController") == "PlayerTackle")
					or (type(tackleStart) == "number" and (serverNow - tackleStart) >= -0.05 and (serverNow - tackleStart) <= (tackleDur + 0.08))
				local reachPhase = cChar:GetAttribute("ReachPhase")
				local isMeleeing = (reachPhase == "Windup" or reachPhase == "Active")

				if bestRunner and bestRunnerTracker then
					local rTr = bestRunnerTracker
					local toRunner = rTr.pos - cTr.pos
					local currentDist = toRunner.Magnitude
					local toRunnerUnit = (currentDist > 0.05) and toRunner.Unit or cTr.dir

					local bestT = 0
					local bestGap = currentDist
					local bestPoint = rTr.pos
					local chaserMaxSpeed = math.max(cTr.speed, cTr.style.avgSpeed, 35)

					for sampleT = 0.25, 5.0, 0.25 do
						local rFuture = sampleTrajectoryAt(rTr, sampleT)
						local cFutureTraj = sampleTrajectoryAt(cTr, sampleT)
						local trajGap = (rFuture - cFutureTraj).Magnitude
						local directReachGap = math.max(0, (rFuture - cTr.pos).Magnitude - chaserMaxSpeed * sampleT)
						local effectiveGap = math.min(trajGap, directReachGap * 0.65 + trajGap * 0.35)

						if effectiveGap < bestGap then
							bestGap = effectiveGap
							bestT = sampleT
							bestPoint = rFuture
						end
						if trajGap <= 11.0 then
							bestGap = trajGap
							bestT = sampleT
							bestPoint = rFuture
							break
						end
					end

					info.interceptPoint = bestPoint
					info.interceptTime = bestT
					info.interceptDist = bestGap

					local aimDirect = cTr.dir:Dot(toRunnerUnit)
					local toPred1 = rTr.predicted[1] - cTr.pos
					local aimLead = (toPred1.Magnitude > 0.05) and cTr.dir:Dot(toPred1.Unit) or aimDirect

					local fDir = arenaBounds.forwardDir
					local rDir = arenaBounds.rightDir
					local runnerGoalLon = (arenaBounds.goalCenter - rTr.pos):Dot(fDir)
					local chaserPred1GoalLon = (arenaBounds.goalCenter - cTr.predicted[1]):Dot(fDir)
					local latDiff = math.abs((cTr.predicted[1] - rTr.predicted[1]):Dot(rDir))
					local cuttingCorridor = (chaserPred1GoalLon < runnerGoalLon + 8)
						and (latDiff < 22)
						and (aimLead > 0.45)

					if isTackling or isMeleeing then
						info.mode = "Attacking"
					elseif cuttingCorridor and aimLead > aimDirect + 0.02 and currentDist > 10 then
						info.mode = "CuttingOff"
					elseif aimLead > aimDirect + 0.03 and bestT > 0.25 and bestGap < 18 then
						info.mode = "Intercepting"
					elseif aimDirect > 0.55 or currentDist < 20 then
						info.mode = "Following"
					else
						info.mode = "Patrolling"
					end

					if (now - rTr.lastSuddenTurnAt) < 0.38 or (now - rTr.lastDashAt) < 0.38 then
						local newInterceptVec = (rTr.predicted[1] - cTr.pos)
						if newInterceptVec.Magnitude > 0.1 then
							local newDir = newInterceptVec.Unit
							if newDir:Dot(cTr.dir) < 0.86 then
								info.willTurnSoon = true
								info.anticipatedTurnDir = newDir
								info.turnReason = "reacting to runner juke"
							end
						end
					end

					if not isTackling and type(tackleStart) == "number" then
						local elapsed = serverNow - tackleStart
						if elapsed >= tackleDur and elapsed <= (tackleDur + tackleRec + 0.1) then
							info.willTurnSoon = true
							info.anticipatedTurnDir = toRunnerUnit
							info.turnReason = "post-dive recovery snap"
						end
					end
				else
					info.mode = "Patrolling"
				end
			end
		end
	end

	for pl in pairs(chaserPredictions) do
		if not activeChasers[pl] then
			chaserPredictions[pl] = nil
		end
	end
end

local lastTrackerStep = 0

local function stepPredictionEngine()
	local now = os.clock()
	if (now - lastTrackerStep) < 0.10 then
		return
	end
	local dt = math.clamp(now - lastTrackerStep, 0.02, 0.30)
	lastTrackerStep = now
	local serverNow = workspace:GetServerTimeNow()

	refreshArenaBounds(false)
	refreshRaycastFilter(false)

	local chaseTargetPlayer = (chaseTarget and chaseTarget.Parent) and Players:GetPlayerFromCharacter(chaseTarget.Parent) or nil

	local seen = {}
	for _, pl in ipairs(Players:GetPlayers()) do
		if pl == LocalPlayer or isActive(pl) then
			local char = pl.Character or workspace:FindFirstChild(pl.Name)
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if char and root and hum then
				seen[pl] = true
				local tr = playerTrackers[pl]
				if not tr then
					tr = newPlayerTracker(pl)
					tr.pos = flat(root.Position)
					tr.pos3D = root.Position
					tr.lastUpdate = now
					playerTrackers[pl] = tr
				end

				local playerDt = math.clamp(now - tr.lastUpdate, 0.02, 0.35)
				local newPos = flat(root.Position)
				local rawVel3D = root.AssemblyLinearVelocity
				local assemblyVel2D = flat(rawVel3D)

				local posDelta2D = newPos - tr.pos
				local posVel2D = (posDelta2D.Magnitude < 28) and (posDelta2D / playerDt) or Vector3.zero
				local posVelY = (math.abs(root.Position.Y - tr.pos3D.Y) < 18) and ((root.Position.Y - tr.pos3D.Y) / playerDt) or 0

				local newVel: Vector3
				local newVelY: number
				if assemblyVel2D.Magnitude >= posVel2D.Magnitude * 0.65 then
					newVel = assemblyVel2D
					newVelY = rawVel3D.Y
				else
					newVel = tr.vel:Lerp(posVel2D, math.clamp(playerDt * 14, 0, 1))
					newVelY = posVelY
				end

				local newSpeed = newVel.Magnitude
				local newLook = flat(root.CFrame.LookVector)
				if newLook.Magnitude > 0.01 then
					newLook = newLook.Unit
				else
					newLook = tr.lookDir
				end

				local rawAccel = (newVel - tr.vel) / playerDt
				if rawAccel.Magnitude > 220 then
					rawAccel = rawAccel.Unit * 220
				end
				tr.accel = tr.accel:Lerp(rawAccel, math.clamp(playerDt * 8, 0, 1))

				local prevDir = tr.dir
				local newDir = (newSpeed > 1.5) and newVel.Unit or newLook
				local crossY = prevDir:Cross(newDir).Y
				local dotDir = math.clamp(prevDir:Dot(newDir), -1, 1)
				local instYawRate = math.atan2(crossY, dotDir) / playerDt
				tr.angularVel = tr.angularVel + (instYawRate - tr.angularVel) * math.clamp(playerDt * 10, 0, 1)

				if newSpeed > 3 then
					local blendedMean = tr.meanDir:Lerp(newDir, math.clamp(playerDt * 2.8, 0, 1))
					if blendedMean.Magnitude > 0.01 then
						tr.meanDir = blendedMean.Unit
					end
				end

				tr.pos = newPos
				tr.pos3D = root.Position
				tr.vel = newVel
				tr.velY = newVelY
				tr.speed = newSpeed
				tr.dir = newDir
				tr.lookDir = newLook
				tr.lastUpdate = now

				table.insert(tr.history, {
					t = now,
					pos = newPos,
					vel = newVel,
					accel = tr.accel,
					dir = newDir,
					speed = newSpeed,
					yawRate = tr.angularVel,
				})
				while #tr.history > 1 and (now - tr.history[1].t) > 2.2 do
					table.remove(tr.history, 1)
				end

				local recentDirChange = 0
				local maxRecentSpeed = newSpeed
				for i = #tr.history, 1, -1 do
					local h = tr.history[i]
					local age = now - h.t
					if age <= 0.25 then
						local angle = math.acos(math.clamp(h.dir:Dot(newDir), -1, 1))
						if angle > recentDirChange then
							recentDirChange = angle
						end
					end
					if age <= 0.40 and h.speed > maxRecentSpeed then
						maxRecentSpeed = h.speed
					end
					if age > 0.45 then
						break
					end
				end

				local isDashing = (char:GetAttribute("MovementState") == "Boosting")
					or (char:GetAttribute("MovementState") == "Dashing")
					or (type(char:GetAttribute("DashUntil")) == "number" and (char:GetAttribute("DashUntil") :: number) > serverNow)
				if isDashing then
					tr.lastDashAt = now
				end

				local isJumping = (hum.FloorMaterial == Enum.Material.Air) or (math.abs(newVelY) > 6.5)
				local isSuddenTurn = (newSpeed > 8) and (math.abs(tr.angularVel) > 2.6 or recentDirChange > math.rad(40))
				if isSuddenTurn then
					tr.lastSuddenTurnAt = now
					local signNow = math.sign(tr.angularVel)
					if signNow ~= 0 and tr.lastTurnSign ~= 0 and signNow ~= tr.lastTurnSign then
						tr.lastTurnSignFlipAt = now
					end
					if signNow ~= 0 then
						tr.lastTurnSign = signNow
					end
				end

				local isChangingDir = (now - tr.lastTurnSignFlipAt) < 0.85 and newSpeed > 8
				local isStopping = (maxRecentSpeed > 15 and newSpeed < 6.5) or (newSpeed > 4 and tr.accel:Dot(newDir) < -34)

				tr.patterns.dashing = isDashing
				tr.patterns.jumping = isJumping
				tr.patterns.suddenTurn = isSuddenTurn
				tr.patterns.changingDirection = isChangingDir
				tr.patterns.stopping = isStopping

				if isDashing then
					tr.patterns.label = "Dash"
				elseif isJumping then
					tr.patterns.label = "Jump"
				elseif isChangingDir then
					tr.patterns.label = "ZigZag"
				elseif isSuddenTurn then
					tr.patterns.label = "Juke"
				elseif isStopping then
					tr.patterns.label = "Stop"
				elseif newSpeed > 5 then
					tr.patterns.label = "Run"
				else
					tr.patterns.label = "Idle"
				end

				local st = tr.style
				local learnAlpha = math.clamp(dt * 0.9, 0, 1)
				st.samples = st.samples + 1
				if newSpeed > 8 then
					st.avgSpeed = st.avgSpeed + (newSpeed - st.avgSpeed) * learnAlpha
					st.jukeRate = st.jukeRate + (math.min(math.abs(tr.angularVel), 8) - st.jukeRate) * learnAlpha
					st.turnBias = st.turnBias + (math.clamp(tr.angularVel, -4, 4) - st.turnBias) * (learnAlpha * 0.5)
				end
				st.zigZagScore = math.clamp(st.zigZagScore + ((isChangingDir and 1 or 0) - st.zigZagScore) * math.clamp(dt * 1.4, 0, 1), 0, 1)
				st.stopRate = math.clamp(st.stopRate + ((isStopping and 1 or 0) - st.stopRate) * (learnAlpha * 0.6), 0, 1)
				st.dashRate = math.clamp(st.dashRate + ((isDashing and 1 or 0) - st.dashRate) * (learnAlpha * 0.6), 0, 1)

				local role = roleOf(pl)
				local useRaycast = (pl == LocalPlayer) or (pl == chaseTargetPlayer) or (role == "Catcher")
				simulatePlayerTrajectory(tr, role, useRaycast)
			end
		end
	end

	for pl in pairs(playerTrackers) do
		if not seen[pl] then
			playerTrackers[pl] = nil
		end
	end

	local myTracker = playerTrackers[LocalPlayer]
	if myTracker and roleOf(LocalPlayer) == "Runner" and isActive(LocalPlayer) then
		predictEscapeRoutes(myTracker)
	end
	if chaseTargetPlayer and chaseTargetPlayer ~= LocalPlayer then
		local tTr = playerTrackers[chaseTargetPlayer]
		if tTr and isActive(chaseTargetPlayer) then
			predictEscapeRoutes(tTr)
		end
	end

	updateChaserPredictions()
end

local function pickRunner(root)
	local pos = flat(root.Position)
	local now = os.clock()

	if chaseTarget and chaseTarget.Parent and now < chaseUntil then
		local pl = Players:GetPlayerFromCharacter(chaseTarget.Parent)
		if pl and roleOf(pl) == "Runner" and isActive(pl) then
			local d = (flat(chaseTarget.Position) - pos).Magnitude
			if d < 150 then
				return chaseTarget, d
			end
		end
	end

	local best, bestDist
	for _, pl in ipairs(Players:GetPlayers()) do
		if pl ~= LocalPlayer and roleOf(pl) == "Runner" and isActive(pl) then
			local r = rootOf(pl)
			if r then
				local d = (flat(r.Position) - pos).Magnitude
				if not bestDist or d < bestDist then
					best = r
					bestDist = d
				end
			end
		end
	end

	chaseTarget = best
	chaseUntil = now + 0.8
	return best, bestDist
end

-- ------------------------------------------ multi-feeler obstacle avoidance

local wallFollowSide = 0
local wallFollowDir: Vector3? = nil
local wallFollowUntil = 0
local stuckSince = 0
local unstickDir: Vector3? = nil
local unstickUntil = 0

local AVOID_ANGLES = {
	math.rad(20), -math.rad(20),
	math.rad(38), -math.rad(38),
	math.rad(58), -math.rad(58),
	math.rad(78), -math.rad(78),
	math.rad(100), -math.rad(100),
}

local function rotate2D(v: Vector3, rad: number): Vector3
	local c = math.cos(rad)
	local s = math.sin(rad)
	return Vector3.new(v.X * c - v.Z * s, 0, v.X * s + v.Z * c)
end

local function steerAroundObstacles(root: BasePart, hum: Humanoid?, desiredDir: Vector3, goalPos: Vector3?): Vector3
	if desiredDir.Magnitude <= 0.01 then
		return desiredDir
	end
	local now = os.clock()
	local dir = desiredDir.Unit
	local pos2D = flat(root.Position)
	local right = Vector3.new(-dir.Z, 0, dir.X)
	local torsoOrigin = root.Position - Vector3.new(0, 0.4, 0)
	local kneeOrigin = root.Position - Vector3.new(0, 1.9, 0)

	local horizSpeed = flat(root.AssemblyLinearVelocity).Magnitude
	if now < unstickUntil and unstickDir then
		if hum and hum.FloorMaterial ~= Enum.Material.Air then
			hum.Jump = true
		end
		return unstickDir
	end

	if horizSpeed < 7.0 then
		if stuckSince == 0 then
			stuckSince = now
		elseif (now - stuckSince) > 0.20 then
			stuckSince = 0
			local bestOpenDir = -dir
			local bestOpenDist = -1
			for _, ang in ipairs({ math.rad(75), -math.rad(75), math.rad(105), -math.rad(105), math.rad(135), -math.rad(135) }) do
				local cand = rotate2D(dir, ang).Unit
				local hit = workspace:Raycast(torsoOrigin, Vector3.new(cand.X, 0, cand.Z) * 20, obstacleRayParams)
				local d = hit and hit.Distance or 20
				if d > bestOpenDist then
					bestOpenDist = d
					bestOpenDir = cand
					wallFollowSide = math.sign(ang)
				end
			end
			unstickDir = bestOpenDir
			unstickUntil = now + 0.42
			wallFollowDir = bestOpenDir
			wallFollowUntil = now + 0.85
			if hum then
				hum.Jump = true
			end
			return bestOpenDir
		end
	else
		stuckSince = 0
	end

	local lookDist = 22
	local shoulderDist = 15
	local dir3D = Vector3.new(dir.X, 0, dir.Z)
	local leftOrigin = torsoOrigin - Vector3.new(right.X, 0, right.Z) * 1.75
	local rightOrigin = torsoOrigin + Vector3.new(right.X, 0, right.Z) * 1.75

	local centerHit = workspace:Raycast(torsoOrigin, dir3D * lookDist, obstacleRayParams)
	local leftHit = workspace:Raycast(leftOrigin, dir3D * shoulderDist, obstacleRayParams)
	local rightHit = workspace:Raycast(rightOrigin, dir3D * shoulderDist, obstacleRayParams)
	local kneeHit = workspace:Raycast(kneeOrigin, dir3D * 9.5, obstacleRayParams)

	if kneeHit and not centerHit and kneeHit.Distance < 5.5 and hum and hum.FloorMaterial ~= Enum.Material.Air then
		hum.Jump = true
	end

	local anyBlocked = (centerHit ~= nil) or (leftHit ~= nil) or (rightHit ~= nil) or (kneeHit ~= nil and kneeHit.Distance < 6.5)

	if not anyBlocked then
		if now < wallFollowUntil and wallFollowDir then
			local remainFrac = math.clamp((wallFollowUntil - now) / 0.45, 0, 1)
			local blended = dir:Lerp(wallFollowDir, remainFrac * 0.85)
			if blended.Magnitude > 0.01 then
				return blended.Unit
			end
		end
		wallFollowSide = 0
		return dir
	end

	local goalUnit = (goalPos and (goalPos - pos2D).Magnitude > 0.5) and (goalPos - pos2D).Unit or dir
	local bestDir = dir
	local bestScore = -math.huge
	local bestSide = wallFollowSide

	for _, ang in ipairs(AVOID_ANGLES) do
		local cand = rotate2D(dir, ang).Unit
		local cand3D = Vector3.new(cand.X, 0, cand.Z)
		local candRight = Vector3.new(-cand.Z, 0, cand.X)
		local sideSign = math.sign(ang)

		local cHit = workspace:Raycast(torsoOrigin, cand3D * 26, obstacleRayParams)
		local clearDist = cHit and cHit.Distance or 26

		local innerShoulderOrigin = torsoOrigin - Vector3.new(candRight.X, 0, candRight.Z) * (sideSign * 1.65)
		local sHit = workspace:Raycast(innerShoulderOrigin, cand3D * 13, obstacleRayParams)
		if sHit and sHit.Distance < clearDist then
			clearDist = sHit.Distance * 0.85
		end

		if clearDist > 5.0 then
			local score = clearDist * 1.6 + cand:Dot(goalUnit) * 8.0 + cand:Dot(dir) * 4.0
			if wallFollowSide ~= 0 and sideSign == wallFollowSide then
				score = score + 11.0
			end
			if now < wallFollowUntil and wallFollowDir then
				score = score + cand:Dot(wallFollowDir) * 6.0
			end
			if arenaBounds.valid then
				local futurePos = pos2D + cand * 14
				local futureLat = math.abs((futurePos - arenaBounds.centerPos):Dot(arenaBounds.rightDir))
				if futureLat > arenaBounds.halfWidth * 0.94 then
					score = score - (futureLat - arenaBounds.halfWidth * 0.94) * 2.5
				end
			end

			if score > bestScore then
				bestScore = score
				bestDir = cand
				bestSide = sideSign
			end
		end
	end

	wallFollowSide = bestSide
	if now < wallFollowUntil and wallFollowDir then
		local smoothedWall = wallFollowDir:Lerp(bestDir, 0.45)
		wallFollowDir = (smoothedWall.Magnitude > 0.01) and smoothedWall.Unit or bestDir
	else
		wallFollowDir = bestDir
	end
	wallFollowUntil = now + 0.45
	return wallFollowDir
end

-- ------------------------------------------------------------------ steering

local function evadeVector(root, goalPos)
	local push = Vector3.zero
	local nearestCatcherDist = math.huge
	if not Cfg.evade then
		return push, nearestCatcherDist
	end
	local pos = flat(root.Position)
	local rightDir = arenaBounds.rightDir
	local forwardDir = arenaBounds.forwardDir

	for _, pl in ipairs(Players:GetPlayers()) do
		if pl ~= LocalPlayer and roleOf(pl) == "Catcher" and isActive(pl) then
			local r = rootOf(pl)
			if r then
				local cPos = flat(r.Position)
				local toCatcher = cPos - pos
				local dist = toCatcher.Magnitude
				if dist < nearestCatcherDist then
					nearestCatcherDist = dist
				end

				local cInfo = chaserPredictions[pl]
				if cInfo and cInfo.targetPlayer == LocalPlayer and cInfo.interceptPoint and cInfo.interceptTime < 2.2 then
					local toIntercept = cInfo.interceptPoint - pos
					local intDist = toIntercept.Magnitude
					if intDist > 0.5 and intDist < Cfg.evadeRange then
						local intWeight = ((Cfg.evadeRange - intDist) / Cfg.evadeRange) * 1.35
						local awayInt = -toIntercept.Unit
						local latComp = awayInt:Dot(rightDir) * 1.5
						local lonComp = awayInt:Dot(forwardDir) * 0.4
						push = push + (rightDir * latComp + forwardDir * lonComp) * intWeight
					end
				end

				if dist > 0.1 and dist < Cfg.evadeRange then
					local weight = (Cfg.evadeRange - dist) / Cfg.evadeRange
					local threatVec = toCatcher.Unit
					if cInfo and cInfo.willTurnSoon and cInfo.anticipatedTurnDir.Magnitude > 0.01 then
						threatVec = (threatVec * 0.6 + cInfo.anticipatedTurnDir * 0.4).Unit
					end
					local away = -threatVec
					local latComp = away:Dot(rightDir) * 1.4
					local lonComp = away:Dot(forwardDir) * 0.5
					local lateral = rightDir * latComp + forwardDir * lonComp
					if lateral.Magnitude > 0.01 then
						push = push + lateral.Unit * (weight * weight * 1.8)
					end
				end
			end
		end
	end
	return push, nearestCatcherDist
end

-- ------------------------------------------ gem & candy corn track collection

local currentCollectPart: BasePart? = nil
local currentCollectDist = math.huge

local function inspectCollectiblePart(inst: Instance): (boolean, number, string)
	if not inst:IsA("BasePart") then
		return false, 0, ""
	end
	local gui = inst:FindFirstChildOfClass("BillboardGui")
	if not gui or not gui.Enabled then
		return false, 0, ""
	end
	local gemIcon = gui:FindFirstChild("Gem")
	local candyIcon = gui:FindFirstChild("Candy")
	local icon = gemIcon or candyIcon
	if icon and icon:IsA("GuiObject") and not icon.Visible then
		return false, 0, ""
	end
	local kind = (candyIcon ~= nil) and "candy" or "gem"
	local amount = 1
	local amtLabel = gui:FindFirstChild("Amount")
	if amtLabel and amtLabel:IsA("TextLabel") then
		local parsed = tonumber(string.match(amtLabel.Text, "%d+"))
		if parsed and parsed > 0 then
			amount = parsed
		end
	end
	return true, amount, kind
end

local function findSafeCollectible(root: BasePart, goalDist: number, nearestCatcherDist: number): (Vector3?, string?, number?)
	if not Cfg.autoCollect then
		currentCollectPart = nil
		Debug.collectTarget = "none"
		return nil, nil, nil
	end

	local myPos = flat(root.Position)

	if currentCollectPart then
		local stillValid = currentCollectPart.Parent ~= nil and inspectCollectiblePart(currentCollectPart)
		if not stillValid then
			if currentCollectDist <= 6.5 then
				Debug.collected = Debug.collected + 1
			end
			currentCollectPart = nil
			currentCollectDist = math.huge
		end
	end

	if nearestCatcherDist < Cfg.collectSafeCatcherDist then
		currentCollectPart = nil
		Debug.collectTarget = "none"
		return nil, nil, nil
	end

	for _, pl in ipairs(Players:GetPlayers()) do
		if pl ~= LocalPlayer and roleOf(pl) == "Catcher" and isActive(pl) then
			local cInfo = chaserPredictions[pl]
			if cInfo and cInfo.targetPlayer == LocalPlayer then
				if (cInfo.mode == "Attacking" or cInfo.mode == "Intercepting" or cInfo.mode == "CuttingOff")
					and cInfo.interceptTime < 2.2
				then
					currentCollectPart = nil
					Debug.collectTarget = "none"
					return nil, nil, nil
				end
			end
		end
	end

	local gemsFolder = workspace:FindFirstChild("LocalRunnerGems")
	local candyFolder = workspace:FindFirstChild("LocalRunnerCandyCorn")
	if not gemsFolder and not candyFolder then
		Debug.collectTarget = "none"
		return nil, nil, nil
	end

	refreshRaycastFilter(false)

	local forwardDir = arenaBounds.forwardDir
	local rightDir = arenaBounds.rightDir
	local bestPart: BasePart? = nil
	local bestPos: Vector3? = nil
	local bestDist = math.huge
	local bestLabel: string? = nil
	local bestScore = -math.huge

	local folders = {}
	if gemsFolder then
		table.insert(folders, gemsFolder)
	end
	if candyFolder then
		table.insert(folders, candyFolder)
	end

	for _, folder in ipairs(folders) do
		for _, child in ipairs(folder:GetChildren()) do
			local active, amount, kind = inspectCollectiblePart(child)
			if active then
				local part = child :: BasePart
				local vertDiff = math.abs(part.Position.Y - root.Position.Y)
				if vertDiff <= 6.5 then
					local itemPos = flat(part.Position)
					local toItem = itemPos - myPos
					local itemDist = toItem.Magnitude
					local maxDist = Cfg.collectRadius + ((amount >= 5) and 4 or 0)

					if itemDist <= maxDist and (goalDist > 7 or itemDist <= 5.0) then
						local forwardDot = (itemDist > 0.25) and toItem.Unit:Dot(forwardDir) or 1.0
						local minForwardDot = (itemDist <= 11.0) and -0.35 or -0.08

						local withinArena = true
						if arenaBounds.valid then
							local itemLat = math.abs((itemPos - arenaBounds.centerPos):Dot(rightDir))
							if itemLat > arenaBounds.halfWidth * 0.96 then
								withinArena = false
							end
						end

						if forwardDot >= minForwardDot and withinArena then
							local itemSafeFromCatchers = true
							for _, pl in ipairs(Players:GetPlayers()) do
								if pl ~= LocalPlayer and roleOf(pl) == "Catcher" and isActive(pl) then
									local cRoot = rootOf(pl)
									if cRoot then
										local cPos = flat(cRoot.Position)
										local cDistToItem = (cPos - itemPos).Magnitude
										if cDistToItem < (Cfg.collectSafeCatcherDist - 4) or itemDist >= (cDistToItem - 12) then
											itemSafeFromCatchers = false
											break
										end
										local cTr = playerTrackers[pl]
										if cTr and cTr.predicted and cTr.predicted[1] then
											if (cTr.predicted[1] - itemPos).Magnitude < 30 then
												itemSafeFromCatchers = false
												break
											end
										end
									end
								end
							end

							if itemSafeFromCatchers then
								local clearSight = true
								if itemDist > 2.5 then
									local rayOrigin = Vector3.new(myPos.X, root.Position.Y, myPos.Z)
									local rayVec = Vector3.new(toItem.X, 0, toItem.Z)
									local hit = workspace:Raycast(rayOrigin, rayVec, obstacleRayParams)
									if hit and hit.Instance and hit.Instance.CanCollide then
										clearSight = false
									end
								end

								if clearSight then
									local score = (maxDist - itemDist) * 1.65
										+ forwardDot * 8.0
										+ math.min(amount, 8) * 1.8
										+ ((part == currentCollectPart) and 5.0 or 0)

									if score > bestScore then
										bestScore = score
										bestPart = part
										bestPos = itemPos
										bestDist = itemDist
										bestLabel = string.format("+%d %s", amount, kind)
									end
								end
							end
						end
					end
				end
			end
		end
	end

	currentCollectPart = bestPart
	currentCollectDist = bestDist
	Debug.collectTarget = bestLabel or "none"
	return bestPos, bestLabel, bestDist
end

local function runDirection(root, hum: Humanoid?)
	local goalPos, dist, zone, flowDir = runTarget(root)
	if not goalPos then
		return nil, nil, math.huge, nil, nil, nil, nil, nil
	end
	local pos = flat(root.Position)
	local delta = goalPos - pos
	if delta.Magnitude <= 0.5 then
		return nil, dist, math.huge, goalPos, zone, nil, nil, nil
	end

	local baseDir = (flowDir and flowDir.Magnitude > 0.05) and flowDir.Unit or delta.Unit
	local macroDir = baseDir

	local evadePush, nearestCatcherDist = evadeVector(root, goalPos)

	local collectPos, collectLabel, collectDist = findSafeCollectible(root, dist, nearestCatcherDist)
	if collectPos and isLearnedPosWalkable(collectPos) then
		local toCollect = collectPos - pos
		if toCollect.Magnitude > 0.25 then
			local collectDir = steerAroundObstacles(root, hum, toCollect.Unit, collectPos)
			return collectDir, dist, nearestCatcherDist, goalPos, zone, collectLabel, collectDist, macroDir
		end
	end

	local hasMapObstacles = (arenaBounds.learnedobstaclesCount or 0) > 2

	local myTracker = playerTrackers[LocalPlayer]
	if Cfg.useEscapeRoutes and myTracker and myTracker.bestEscapeRoute then
		local route = myTracker.bestEscapeRoute
		Debug.escapeLane = route.name
		if route.dir and route.dir.Magnitude > 0.05 then
			local rUnit = route.dir.Unit
			if isLearnedPosWalkable(pos + rUnit * 14) then
				local flowWeight = hasMapObstacles and 0.68 or 0.45
				local blended = baseDir * flowWeight + rUnit * (1 - flowWeight)
				if blended.Magnitude > 0.05 then
					baseDir = blended.Unit
				end
			end
		end
	end

	local dir = baseDir
	if evadePush.Magnitude > 0.02 then
		local cand = baseDir + evadePush
		if cand.Magnitude > 0.05 then
			local candUnit = cand.Unit
			if isLearnedPosWalkable(pos + candUnit * 10) then
				dir = candUnit
			end
		end
	end

	if arenaBounds.valid then
		local rightDir = arenaBounds.rightDir
		local forwardDir = arenaBounds.forwardDir
		local edgeLat = arenaBounds.halfWidth * 0.90
		local myLat = (pos - arenaBounds.centerPos):Dot(rightDir)
		local dirLat = dir:Dot(rightDir)
		local dirLon = dir:Dot(forwardDir)
		if myLat < -edgeLat and dirLat < 0 then
			dir = forwardDir * math.max(0.3, dirLon) + rightDir * 0.22
		elseif myLat > edgeLat and dirLat > 0 then
			dir = forwardDir * math.max(0.3, dirLon) - rightDir * 0.22
		end
	end

	if dir.Magnitude > 0.05 then
		dir = dir.Unit
	else
		dir = delta.Unit
	end

	dir = steerAroundObstacles(root, hum, dir, goalPos)
	return dir, dist, nearestCatcherDist, goalPos, zone, nil, nil, macroDir
end

local function leadPoint(root, target)
	local myPos = flat(root.Position)
	local targetPos = flat(target.Position)
	local dist = (targetPos - myPos).Magnitude
	local pl = Players:GetPlayerFromCharacter(target.Parent)
	local rTr = pl and playerTrackers[pl]

	if rTr and rTr.trajectory and #rTr.trajectory > 1 then
		local mySpeed = math.max(flat(root.AssemblyLinearVelocity).Magnitude, Cfg.speed, 34)
		local interceptT = math.clamp(dist / (mySpeed * 1.15), 0.08, 2.5)
		local trajPoint = sampleTrajectoryAt(rTr, interceptT)

		if rTr.bestEscapeRoute and (rTr.style.zigZagScore > 0.3 or rTr.patterns.changingDirection) and dist > 12 then
			local escapeWp = rTr.bestEscapeRoute.waypoint
			local cutWeight = math.clamp(rTr.style.zigZagScore * 0.45, 0.15, 0.45)
			trajPoint = trajPoint:Lerp(escapeWp, cutWeight)
		end
		return trajPoint
	end

	local vel = target.AssemblyLinearVelocity
	local leadTime = math.clamp(dist / 80, 0.04, 0.28)
	return targetPos + flat(vel) * leadTime
end

local function chaseDirection(root, hum: Humanoid?, target)
	local myPos = flat(root.Position)
	local aimPoint = leadPoint(root, target)
	local delta = aimPoint - myPos
	if delta.Magnitude < 0.3 then
		return nil
	end
	return steerAroundObstacles(root, hum, delta.Unit, aimPoint)
end

-- ---------------------------------------------------------- melee & tackles

local nextTackleAt = 0
local nextMeleeAt = 0

local function tryMelee(char, root, target)
	if not Cfg.autoMelee or not MeleeEvent then
		return
	end
	local now = os.clock()
	if now < nextMeleeAt then
		return
	end
	if char:GetAttribute("TackleActive") == true or char:GetAttribute("MovementLocked") == true then
		return
	end
	if char:GetAttribute("DaggerEquipped") == true and char:GetAttribute("DaggerState") ~= "Held" then
		return
	end

	local myPos = flat(root.Position)
	local targetPos = flat(target.Position)
	local dist = (targetPos - myPos).Magnitude
	if dist > 9.2 or dist < 0.1 then
		return
	end

	local pl = Players:GetPlayerFromCharacter(target.Parent)
	local rTr = pl and playerTrackers[pl]
	local aimPos = targetPos
	if rTr and rTr.speed > 2 then
		aimPos = sampleTrajectoryAt(rTr, 0.10)
	end
	local aimVec = aimPos - myPos
	local aimUnit = (aimVec.Magnitude > 0.05) and aimVec.Unit or (targetPos - myPos).Unit

	pcall(function()
		root.CFrame = CFrame.lookAt(root.Position, Vector3.new(aimPos.X, root.Position.Y, aimPos.Z))
	end)

	local serverNow = workspace:GetServerTimeNow()
	local guid = HttpService:GenerateGUID(false)
	nextMeleeAt = now + 0.52
	Debug.melees = Debug.melees + 1

	pcall(function()
		MeleeEvent:FireServer({
			id = guid,
			at = serverNow,
			direction = aimUnit,
			position = root.Position,
		})
		if CombatPrediction and ContactCatchConfig then
			CombatPrediction.begin({
				kind = "Melee",
				predicted = true,
				id = guid,
				character = char,
				startedAt = serverNow,
				starts = serverNow + (ContactCatchConfig.Windup or 0.12),
				ends = serverNow + (ContactCatchConfig.Windup or 0.12) + (ContactCatchConfig.ActiveDuration or 0.18),
				direction = aimUnit,
				box = CombatPrediction.meleeBox(char),
			})
		end
	end)
end

local function tryTackle(root, target)
	if not Cfg.autoTackle or not TacklePrediction then
		return
	end
	if os.clock() < nextTackleAt then
		return
	end
	local myPos = flat(root.Position)
	local targetPos = flat(target.Position)
	local delta = targetPos - myPos
	local dist = delta.Magnitude
	if dist > Cfg.tackleRange or dist < 0.1 then
		return
	end

	local pl = Players:GetPlayerFromCharacter(target.Parent)
	local rTr = pl and playerTrackers[pl]
	local aimPos = targetPos
	if rTr and rTr.speed > 2 then
		aimPos = sampleTrajectoryAt(rTr, math.clamp(dist / 58, 0.06, 0.18))
	end
	local aimDelta = aimPos - myPos
	local aimUnit = (aimDelta.Magnitude > 0.05) and aimDelta.Unit or delta.Unit

	pcall(function()
		root.CFrame = CFrame.lookAt(root.Position, Vector3.new(aimPos.X, root.Position.Y, aimPos.Z))
	end)
	local look = flat(root.CFrame.LookVector)
	if look.Magnitude < 0.1 or look.Unit:Dot(aimUnit) < 0.75 then
		return
	end
	nextTackleAt = os.clock() + 0.18
	Debug.tackles = Debug.tackles + 1
	pcall(TacklePrediction.request)
end

-- -------------------------------------------------------------------- dashes

local nextDashAt = 0
local dodgeDir: Vector3? = nil
local dodgeUntil = 0
local swingCache: { [Instance]: { at: number, val: boolean } } = {}

local function isCatcherSwingingAnimation(cChar): boolean
	local now = os.clock()
	local cached = swingCache[cChar]
	if cached and (now - cached.at) < 0.08 then
		return cached.val
	end
	local hum = cChar:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	if not animator then
		return false
	end
	local swinging = false
	for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
		if track.IsPlaying and track.WeightCurrent > 0.1 then
			local tName = string.lower(track.Name or "")
			local aName = track.Animation and string.lower(track.Animation.Name or "") or ""
			if tName:find("stab") or tName:find("windup") or tName:find("dive") or tName:find("tackle") or tName:find("swing")
				or aName:find("stab") or aName:find("windup") or aName:find("dive") or aName:find("tackle") or aName:find("swing")
			then
				swinging = true
				break
			end
		end
	end
	swingCache[cChar] = { at = now, val = swinging }
	return swinging
end

local function computeJukeDirection(myPos: Vector3, fromCatcher: Vector3, attackDir: Vector3, goalPos: Vector3?, _zone: BasePart?): Vector3
	local goalDir = (goalPos and (goalPos - myPos).Magnitude > 0.1) and (goalPos - myPos).Unit or attackDir
	local perp1 = Vector3.new(-attackDir.Z, 0, attackDir.X)
	if perp1.Magnitude < 0.01 then
		perp1 = Vector3.new(1, 0, 0)
	else
		perp1 = perp1.Unit
	end
	local perp2 = -perp1

	local function scoreSide(p: Vector3): number
		local score = 0
		local lateralOffset = fromCatcher:Dot(p)
		if math.abs(lateralOffset) > 0.4 then
			score = score + math.clamp(lateralOffset * 0.6, -2.5, 2.5)
		end
		score = score + p:Dot(goalDir) * 0.5
		if arenaBounds.valid then
			local futurePos = myPos + p * 11
			local futureLat = math.abs((futurePos - arenaBounds.centerPos):Dot(arenaBounds.rightDir))
			local maxLat = arenaBounds.halfWidth * 0.90
			if futureLat > maxLat then
				score = score - (futureLat - maxLat) * 0.85
			end
		end
		local hit = workspace:Raycast(
			Vector3.new(myPos.X, arenaBounds.floorY, myPos.Z),
			Vector3.new(p.X, 0, p.Z) * 11,
			obstacleRayParams
		)
		if hit and hit.Instance and hit.Instance.CanCollide then
			score = score - (12 - hit.Distance) * 1.2
		end
		return score
	end

	local bestPerp = (scoreSide(perp1) >= scoreSide(perp2)) and perp1 or perp2
	local blended = bestPerp * 0.82 + goalDir * 0.42
	if blended.Magnitude > 0.01 then
		return blended.Unit
	end
	return bestPerp
end

local function evaluateCatcherThreat(root, baseDir: Vector3, goalPos: Vector3?, zone: BasePart?): (boolean, Vector3, string)
	local myPos = flat(root.Position)
	local myVel = flat(root.AssemblyLinearVelocity)
	local serverNow = workspace:GetServerTimeNow()

	local bestReason: string? = nil
	local bestJuke: Vector3 = baseDir
	local bestPriority = 0

	for _, pl in ipairs(Players:GetPlayers()) do
		if pl ~= LocalPlayer and roleOf(pl) == "Catcher" and isActive(pl) then
			local cChar = pl.Character or workspace:FindFirstChild(pl.Name)
			local cRoot = cChar and cChar:FindFirstChild("HumanoidRootPart")
			if cChar and cRoot then
				local cPos = flat(cRoot.Position)
				local cTr = playerTrackers[pl]
				local cVel = (cTr and cTr.speed > 1.5) and cTr.vel or flat(cRoot.AssemblyLinearVelocity)
				local cLook = flat(cRoot.CFrame.LookVector)
				local fromCatcher = myPos - cPos
				local dist = fromCatcher.Magnitude
				local fromCatcherUnit = (dist > 0.05) and fromCatcher.Unit or baseDir

				local tackleStart = cChar:GetAttribute("TackleStartedAt")
				local tackleDur = tonumber(cChar:GetAttribute("TackleDuration")) or 0.35
				local tackleRec = tonumber(cChar:GetAttribute("TackleRecovery")) or 0.65
				local tackleActive = (cChar:GetAttribute("TackleActive") == true)
					or (cChar:GetAttribute("PhysicsController") == "PlayerTackle")
					or (type(tackleStart) == "number" and (serverNow - tackleStart) >= -0.05 and (serverNow - tackleStart) <= (tackleDur + 0.08))

				local inRecovery = false
				if not tackleActive and type(tackleStart) == "number" then
					local elapsed = serverNow - tackleStart
					if elapsed > tackleDur and elapsed < (tackleDur + tackleRec - 0.08) and dist > 4.5 then
						inRecovery = true
					end
				end

				if not inRecovery and dist <= 22 then
					local reachPhase = cChar:GetAttribute("ReachPhase")
					local reachStart = cChar:GetAttribute("ReachStartedAt")
					local reachTarget = cChar:GetAttribute("ReachTargetUserId")
					local isMeleeing = (reachPhase == "Windup" or reachPhase == "Active")
						or (type(reachStart) == "number" and (serverNow - reachStart) >= -0.05 and (serverNow - reachStart) <= 0.34)
						or (reachPhase == "Tracking" and reachTarget == LocalPlayer.UserId and dist <= 13.5)
						or isCatcherSwingingAnimation(cChar)

					local rocketUntil = cChar:GetAttribute("RocketUntil")
					local isRocketing = type(rocketUntil) == "number" and rocketUntil > serverNow

					local attackDir = fromCatcherUnit
					local tDir = cChar:GetAttribute("TackleDirection")
					local rDir = cChar:GetAttribute("ReachDirection")
					if tackleActive and typeof(tDir) == "Vector3" and flat(tDir).Magnitude > 0.01 then
						attackDir = flat(tDir).Unit
					elseif isMeleeing and typeof(rDir) == "Vector3" and flat(rDir).Magnitude > 0.01 then
						attackDir = flat(rDir).Unit
					elseif cVel.Magnitude > 4 then
						attackDir = cVel.Unit
					elseif cLook.Magnitude > 0.01 then
						attackDir = cLook.Unit
					end

					local attackDot = attackDir:Dot(fromCatcherUnit)
					local lookDot = (cLook.Magnitude > 0.01) and cLook.Unit:Dot(fromCatcherUnit) or 0
					local velDot = (cVel.Magnitude > 3) and cVel.Unit:Dot(fromCatcherUnit) or 0
					local bestAim = math.max(attackDot, lookDot, velDot)

					if (tackleActive or isMeleeing or isRocketing) and dist <= 19.5 and (bestAim >= 0.22 or dist <= 10.5) then
						local prio = 100 - dist
						if prio > bestPriority then
							bestPriority = prio
							local kind = isMeleeing and "melee" or (tackleActive and "dive" or "lunge")
							bestReason = string.format("dodge %s (%s %.0fm)", pl.Name, kind, dist)
							bestJuke = computeJukeDirection(myPos, fromCatcher, attackDir, goalPos, zone)
						end
					else
						local predCatcher = cPos + cVel * 0.18
						local predMe = myPos + myVel * 0.18
						local predDist = (predMe - predCatcher).Magnitude
						local closingSpeed = (cVel - myVel):Dot(fromCatcherUnit)
						local threatRange = Cfg.dashThreatRange

						local cInfo = chaserPredictions[pl]
						local interceptThreat = false
						local turnThreat = false
						local effectiveAttackDir = attackDir

						if cInfo and cInfo.targetPlayer == LocalPlayer then
							if (cInfo.mode == "Intercepting" or cInfo.mode == "CuttingOff")
								and cInfo.interceptTime <= 0.45
								and cInfo.interceptDist <= threatRange - 1.0
								and dist <= threatRange + 5.0
							then
								interceptThreat = true
							end
							if cInfo.willTurnSoon and dist <= threatRange + 1.5 and cInfo.anticipatedTurnDir:Dot(fromCatcherUnit) >= 0.45 then
								turnThreat = true
								effectiveAttackDir = cInfo.anticipatedTurnDir
							end
						end

						local closeStrike = (dist <= threatRange and bestAim >= 0.42 and (closingSpeed > -4 or dist <= 10.5))
						local fastIntercept = (dist <= threatRange + 4.5 and predDist <= threatRange - 1.2 and bestAim >= 0.52 and closingSpeed > 5)

						if closeStrike or fastIntercept or interceptThreat or turnThreat then
							local prio = 50 - predDist + (interceptThreat and 12 or 0) + (turnThreat and 8 or 0)
							if prio > bestPriority then
								bestPriority = prio
								local modeTag = (cInfo and cInfo.mode) or "close"
								bestReason = string.format("%s %s (%.0fm)", string.lower(modeTag), pl.Name, dist)
								bestJuke = computeJukeDirection(myPos, fromCatcher, effectiveAttackDir, goalPos, zone)
							end
						end
					end
				end
			end
		end
	end

	if bestReason then
		return true, bestJuke, bestReason
	end
	return false, baseDir, ""
end

local nextShieldAt = 0

local function canRunnerDashNow(char, root): boolean
	if not Cfg.autoDash or not BoostInput then
		return false
	end
	if os.clock() < nextDashAt then
		return false
	end
	local horizSpeed = flat(root.AssemblyLinearVelocity).Magnitude
	if horizSpeed < 15 then
		return false
	end
	local okAvail, isAvail = pcall(BoostInput.available, LocalPlayer)
	if not (okAvail and isAvail) then
		return false
	end
	local u132 = getMovementStateTable()
	if u132 then
		if u132.cooldown > 0.01 or u132.recoveryRemaining > 0.01 or u132.dashRemaining > 0.01 then
			return false
		end
	elseif char:GetAttribute("DashReady") ~= true then
		return false
	end
	return true
end

local function getEquippedRunnerAbilityId(): string
	local pg = LocalPlayer:FindFirstChild("PlayerGui")
	local ac = pg and pg:FindFirstChild("AbilityControls")
	local useBtn = ac and ac:FindFirstChild("Use")
	local title = useBtn and useBtn:FindFirstChild("Title")
	local titleText = (title and title:IsA("TextLabel")) and string.upper(title.Text) or ""
	if titleText ~= "" and GearCatalog and type(GearCatalog.Items) == "table" then
		for id, entry in pairs(GearCatalog.Items) do
			if type(entry) == "table" and entry.Kind == "Ability" and entry.UseRole == "Runner" then
				if string.upper(tostring(entry.Name or "")) == titleText then
					return id
				end
			end
		end
	end
	return "OneHitShield"
end

local function tryRunnerShield(char, root, dir: Vector3, goalPos: Vector3?, zone: BasePart?): Vector3
	if not Cfg.autoShield or not GearPredictionClient then
		return dir
	end
	local now = os.clock()
	if now < nextShieldAt then
		return dir
	end

	local serverNow = workspace:GetServerTimeNow()
	local moveState = char:GetAttribute("MovementState")
	if moveState == "Boosting" or moveState == "Dashing" or serverNow < (tonumber(char:GetAttribute("DashUntil")) or 0) then
		return dir
	end
	local u132 = getMovementStateTable()
	if u132 and (u132.dashRemaining or 0) > 0.02 then
		return dir
	end

	if serverNow < (tonumber(LocalPlayer:GetAttribute("AbilityReadyAt")) or 0) then
		return dir
	end
	local charges = LocalPlayer:GetAttribute("AbilityCharges")
	if type(charges) == "number" and charges <= 0 then
		return dir
	end
	if AbilityRule and type(AbilityRule.blocked) == "function" then
		local okBlocked, isBlocked = pcall(AbilityRule.blocked, LocalPlayer)
		if okBlocked and isBlocked then
			return dir
		end
	end

	local threatened, jukeDir, reason = evaluateCatcherThreat(root, dir, goalPos, zone)
	if not threatened then
		return dir
	end

	local abilityId = getEquippedRunnerAbilityId()
	nextShieldAt = now + 0.65
	local okReq, reqId = pcall(GearPredictionClient.request, abilityId, jukeDir, "UseAbility")
	if okReq and reqId then
		Debug.shields = Debug.shields + 1
		Debug.lastShieldReason = reason
		dodgeDir = jukeDir
		dodgeUntil = now + 0.25
		return jukeDir
	end
	return dir
end

local function tryRunnerDash(char, root, dir: Vector3, goalDist: number?, goalPos: Vector3?, zone: BasePart?): (Vector3, boolean)
	if not canRunnerDashNow(char, root) then
		return dir, false
	end
	local now = os.clock()
	local u132 = getMovementStateTable()

	local dashDir = dir
	local dashReason = "cooldown"

	if Cfg.dashPredictive then
		local threatened, jukeDir, reason = evaluateCatcherThreat(root, dir, goalPos, zone)
		if not threatened then
			return dir, false
		end
		dashDir = jukeDir
		dashReason = reason
		dodgeDir = jukeDir
		dodgeUntil = now + 0.28
	else
		if goalDist and goalDist < 10 then
			return dir, false
		end
	end

	if u132 then
		local perp = Vector3.new(-dashDir.Z, 0, dashDir.X)
		if perp.Magnitude > 0.01 then
			perp = perp.Unit
			u132.speed = math.max(u132.speed or 0, 35.6)
			table.insert(u132.travelHistory, {
				at = u132.travelClock or 0,
				direction = perp,
				speed = math.max(u132.speed, 35.6),
			})
		end
	end

	nextDashAt = now + 0.35
	Debug.dashes = Debug.dashes + 1
	Debug.lastDashReason = dashReason
	pcall(BoostInput.request, true)
	return dashDir, true
end

-- ------------------------------------------------------------------- driving

local statusLine = "idle"
local activeDir: Vector3? = nil
local smoothedMoveDir: Vector3? = nil
local macroCamDir: Vector3? = nil
local filteredCamTargetDir: Vector3? = nil
local camLookDir: Vector3? = nil
local camYaw: number? = nil
local camYawVel = 0
local camPitch: number? = nil
local lastSteerAt = 0

local CAM_BIND_NAME = "HV_CameraFollow"
local INPUT_BIND_NAME = "HV_InputDrive"

local function wrapAngle(a: number): number
	return math.atan2(math.sin(a), math.cos(a))
end

local function dirToYaw(v: Vector3): number
	return math.atan2(-v.X, -v.Z)
end

local function yawToDir(y: number): Vector3
	return Vector3.new(-math.sin(y), 0, -math.cos(y))
end

local function smoothDampAngle(current: number, target: number, vel: number, smoothTime: number, maxSpeed: number, dt: number): (number, number)
	local delta = wrapAngle(target - current)
	local targetUnwrapped = current + delta
	local st = math.max(0.001, smoothTime)
	local omega = 2.0 / st
	local x = omega * dt
	local exp = 1.0 / (1.0 + x + 0.48 * x * x + 0.235 * x * x * x)
	local change = current - targetUnwrapped
	local maxChange = maxSpeed * st
	change = math.clamp(change, -maxChange, maxChange)
	local tempTarget = current - change
	local temp = (vel + omega * change) * dt
	local newVel = (vel - omega * temp) * exp
	local output = tempTarget + (change + temp) * exp
	if (targetUnwrapped - current > 0) == (output > targetUnwrapped) then
		output = targetUnwrapped
		newVel = 0
	end
	return wrapAngle(output), newVel
end

local function computeSteering()
	local now = os.clock()
	local dt = math.clamp(now - ((lastSteerAt > 0) and lastSteerAt or (now - 0.016)), 0.001, 0.1)
	lastSteerAt = now

	activeDir = nil
	macroCamDir = nil
	local char, hum, root = getChar()
	if not char then
		smoothedMoveDir = nil
		return
	end
	Debug.frames = Debug.frames + 1
	if hum.Health <= 0 then
		smoothedMoveDir = nil
		return
	end
	if char:GetAttribute("MovementLocked") == true then
		smoothedMoveDir = nil
		return
	end
	if LocalPlayer:GetAttribute("RunState") ~= "Active" then
		smoothedMoveDir = nil
		return
	end
	if char:GetAttribute("TackleActive") == true or char:GetAttribute("GearMotion") == true then
		return
	end

	local dir: Vector3? = nil
	local calmDir: Vector3? = nil
	local role = roleOf(LocalPlayer)
	local wantChase = Cfg.autoChase or (Cfg.autoFarm and role == "Catcher")
	local wantRun = Cfg.autoRun or (Cfg.autoFarm and role == "Runner")

	if role == "Catcher" then
		if wantChase then
			local target, dist = pickRunner(root)
			if target then
				dir = chaseDirection(root, hum, target)
				local toTarget = flat(target.Position) - flat(root.Position)
				calmDir = (toTarget.Magnitude > 0.5) and toTarget.Unit or dir
				tryMelee(char, root, target)
				tryTackle(root, target)
				statusLine = string.format("chasing runner  %.0fm  (melees: %d  dives: %d)", dist, Debug.melees, Debug.tackles)
			else
				statusLine = "no active runner"
			end
		else
			statusLine = "chaser idle"
		end
	elseif role == "Runner" then
		if wantRun then
			local d, dist, _, goalPos, zone, collectLabel, collectDist, mDir = runDirection(root, hum)
			calmDir = mDir or d
			if now < dodgeUntil and dodgeDir then
				dir = dodgeDir
			else
				dir = d
			end
			if dir then
				local dashed = false
				dir, dashed = tryRunnerDash(char, root, dir, dist, goalPos, zone)
				if not dashed and not canRunnerDashNow(char, root) then
					dir = tryRunnerShield(char, root, dir, goalPos, zone)
				end
			end
			if collectLabel and collectDist then
				statusLine = string.format("collecting %s (%.0fm) -> %s  (picked: %d)", collectLabel, collectDist, arenaBounds.targetSide or "?", Debug.collected)
			else
				statusLine = dist and string.format("running  %.0fm -> %s  (dashes: %d  shields: %d)", dist, arenaBounds.targetSide or "?", Debug.dashes, Debug.shields) or "no safezone found"
			end
		else
			statusLine = "runner idle"
		end
	else
		statusLine = "not in a match (" .. tostring(role) .. ")"
	end

	if dir then
		if now < dodgeUntil or not smoothedMoveDir then
			smoothedMoveDir = dir
		else
			local moveAlpha = 1 - math.exp(-dt * 18)
			local blendedMove = smoothedMoveDir:Lerp(dir, moveAlpha)
			smoothedMoveDir = (blendedMove.Magnitude > 0.01) and blendedMove.Unit or dir
		end
		activeDir = smoothedMoveDir
		macroCamDir = calmDir or activeDir
		Debug.driven = Debug.driven + 1
		Debug.lastDir = activeDir
		hum:Move(activeDir, false)
	else
		smoothedMoveDir = nil
	end
end

RunService:BindToRenderStep(CAM_BIND_NAME, Enum.RenderPriority.Camera.Value - 1, function(dt)
	local cam = workspace.CurrentCamera
	if not Cfg.cameraFollow or not activeDir then
		if cam then
			local cfLook = flat(cam.CFrame.LookVector)
			if cfLook.Magnitude > 0.01 then
				camLookDir = cfLook.Unit
				camYaw = dirToYaw(camLookDir)
			end
			camPitch = cam.CFrame.LookVector.Y
		end
		camYawVel = 0
		filteredCamTargetDir = nil
		return
	end
	local _, hum, root = getChar()
	if not (hum and root and cam) then
		return
	end
	if cam.CameraType == Enum.CameraType.Scriptable or cam.CameraSubject ~= hum then
		return
	end

	local frameDt = math.clamp(dt, 0.001, 0.08)
	local curFlat = flat(cam.CFrame.LookVector)
	if not camYaw then
		local initDir = (curFlat.Magnitude > 0.01) and curFlat.Unit or activeDir
		camYaw = dirToYaw(initDir)
		camLookDir = initDir
		camYawVel = 0
	end

	local baseCamTarget = macroCamDir or activeDir
	local rawTarget = baseCamTarget:Lerp(activeDir, 0.22)
	rawTarget = (rawTarget.Magnitude > 0.01) and rawTarget.Unit or activeDir

	if not filteredCamTargetDir then
		filteredCamTargetDir = rawTarget
	else
		local targetAlpha = 1 - math.exp(-frameDt * 6.0)
		local b = filteredCamTargetDir:Lerp(rawTarget, targetAlpha)
		filteredCamTargetDir = (b.Magnitude > 0.01) and b.Unit or rawTarget
	end

	local desiredYaw = dirToYaw(filteredCamTargetDir)
	local activeYaw = dirToYaw(activeDir)

	local diffFromActive = wrapAngle(desiredYaw - activeYaw)
	local maxConeRad = math.rad(35)
	if math.abs(diffFromActive) > maxConeRad then
		desiredYaw = wrapAngle(activeYaw + math.sign(diffFromActive) * maxConeRad)
	end

	local curDiffActive = math.abs(wrapAngle(activeYaw - (camYaw :: number)))
	local curDiffDesired = wrapAngle(desiredYaw - (camYaw :: number))
	if curDiffActive < math.rad(25) and math.abs(curDiffDesired) < math.rad(8) then
		desiredYaw = wrapAngle((camYaw :: number) + curDiffDesired * 0.25)
	end

	local smoothTime = 0.30
	local maxYawSpeed = math.rad(105)
	if curDiffActive > math.rad(48) then
		local urgency = math.clamp((curDiffActive - math.rad(48)) / math.rad(45), 0, 1)
		smoothTime = 0.30 - urgency * 0.16
		maxYawSpeed = math.rad(105 + urgency * 135)
	end

	local nextYaw, nextVel = smoothDampAngle(camYaw :: number, desiredYaw, camYawVel, smoothTime, maxYawSpeed, frameDt)
	camYaw = nextYaw
	camYawVel = nextVel
	local lookDir = yawToDir(nextYaw)
	camLookDir = lookDir

	local rawPitch = math.clamp(cam.CFrame.LookVector.Y, -0.60, 0.10)
	if not camPitch then
		camPitch = math.clamp(rawPitch, -0.40, -0.14)
	else
		camPitch = camPitch + (rawPitch - camPitch) * (1 - math.exp(-frameDt * 6.0))
		camPitch = math.clamp(camPitch, -0.55, 0.05)
	end

	local sinPitch = camPitch :: number
	local cosPitch = math.sqrt(math.max(0, 1 - sinPitch * sinPitch))
	local look3 = lookDir * cosPitch + Vector3.new(0, sinPitch, 0)

	local focusPos = cam.Focus.Position
	if (focusPos - root.Position).Magnitude > 24 then
		focusPos = root.Position + Vector3.new(0, 1.5, 0)
	end
	local dist = math.clamp((cam.CFrame.Position - focusPos).Magnitude, 6, 18)
	cam.CFrame = CFrame.lookAt(focusPos - look3 * dist, focusPos)
end)

RunService:BindToRenderStep(INPUT_BIND_NAME, Enum.RenderPriority.Input.Value, function()
	pcall(computeSteering)
end)

local postDriveConnection = RunService.RenderStepped:Connect(function()
	if not activeDir then
		return
	end
	local char, hum, _ = getChar()
	if not (char and hum) then
		return
	end
	local moveState = char:GetAttribute("MovementState")
	if moveState == "Boosting" or moveState == "Dashing" then
		return
	end
	hum.WalkSpeed = math.max(hum.WalkSpeed, Cfg.speed)
	hum:Move(activeDir, false)
end)

local preSimConnection = RunService.PreSimulation:Connect(function()
	if not activeDir then
		return
	end
	local char, hum, root = getChar()
	if not (char and hum and root) then
		return
	end
	if hum.Health <= 0 or hum.Sit or hum.PlatformStand or root.Anchored then
		return
	end
	if char:GetAttribute("TackleActive") == true or char:GetAttribute("GearMotion") == true then
		return
	end
	local faceDir = camLookDir or activeDir
	if faceDir and faceDir.Magnitude > 0.01 then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + faceDir.Unit)
	end
end)

-- ---------------------------------------------------- auto-choice & anti-AFK

local nextAfkClear = 0
local nextChoiceAt = 0

local function stepSessionAutomation()
	local now = os.clock()
	local wantActive = Cfg.antiAfk or Cfg.autoFarm or Cfg.autoRun or Cfg.autoChase

	if wantActive and now >= nextAfkClear then
		if LocalPlayer:GetAttribute("AFK") == true
			and LocalPlayer:GetAttribute("InMatch") ~= true
			and (roleOf(LocalPlayer) or "Lobby") == "Lobby"
		then
			nextAfkClear = now + 2.0
			Debug.afkCleared = Debug.afkCleared + 1
			pcall(function()
				PlayerPreferences:FireServer("SetAFK", false)
			end)
		end
	end

	local wantChoice = Cfg.autoChoice or Cfg.autoFarm or Cfg.autoRun or Cfg.autoChase
	if wantChoice and now >= nextChoiceAt then
		local phase = Session:GetAttribute("Phase")
		if phase == "SelectHero" and Session:GetAttribute("LeadUserId") == LocalPlayer.UserId then
			for _, pl in ipairs(Players:GetPlayers()) do
				if pl ~= LocalPlayer and roleOf(pl) == "Runner" then
					nextChoiceAt = now + 1.2
					Debug.choices = Debug.choices + 1
					statusLine = "selecting runner: " .. pl.Name
					pcall(function()
						GameAction:FireServer("SelectHero", pl.UserId)
					end)
					break
				end
			end
		elseif phase == "HeroChoice" and Session:GetAttribute("SelectedUserId") == LocalPlayer.UserId then
			local pick = Cfg.playHero and "Hero" or "Chicken"
			nextChoiceAt = now + 1.2
			Debug.choices = Debug.choices + 1
			statusLine = "choosing " .. pick
			pcall(function()
				GameAction:FireServer("HeroChoice", pick)
			end)
		end
	end
end

-- ----------------------------------------------------------------------- ESP

local espTags = {}

pcall(function()
	local oldFolder = workspace:FindFirstChild("HV_PredictionMarkers")
	if oldFolder then
		oldFolder:Destroy()
	end
end)

local function destroyTag(pl)
	local tag = espTags[pl]
	if not tag then
		return
	end
	if tag.bg then
		tag.bg:Destroy()
	end
	if tag.hl then
		tag.hl:Destroy()
	end
	espTags[pl] = nil
end

local function makeTag(pl, root)
	local hl = Instance.new("Highlight")
	hl.Name = "HV_Highlight"
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.FillTransparency = 0.75
	hl.OutlineTransparency = 0
	hl.Parent = root.Parent

	local bg = Instance.new("BillboardGui")
	bg.Name = "HV_Tag"
	bg.Size = UDim2.fromOffset(220, 48)
	bg.StudsOffsetWorldSpace = Vector3.new(0, 2.8, 0)
	bg.AlwaysOnTop = true
	bg.Adornee = root
	bg.Parent = root.Parent

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.35
	label.Text = pl.Name
	label.Parent = bg

	espTags[pl] = {
		bg = bg,
		hl = hl,
		text = label,
	}
end

local lastEspStep = 0

local function updateEsp()
	if not Cfg.esp then
		return
	end
	local now = os.clock()
	if (now - lastEspStep) < 0.12 then
		return
	end
	lastEspStep = now

	local _, _, myRoot = getChar()
	local myPos = myRoot and flat(myRoot.Position)
	local seen = {}

	for _, pl in ipairs(Players:GetPlayers()) do
		if pl ~= LocalPlayer then
			local root = rootOf(pl)
			if root then
				seen[pl] = true
				local tag = espTags[pl]
				if not tag or not tag.bg.Parent or tag.bg.Adornee ~= root then
					destroyTag(pl)
					makeTag(pl, root)
					tag = espTags[pl]
				end
				local role = roleOf(pl) or "?"
				local color = Color3.fromRGB(200, 200, 200)
				if role == "Catcher" then
					color = Color3.fromRGB(255, 90, 90)
				elseif role == "Runner" then
					color = Color3.fromRGB(110, 230, 140)
				end
				local dist = myPos and math.floor((flat(root.Position) - myPos).Magnitude) or 0
				local state = isActive(pl) and "" or " (wait)"

				local tr = playerTrackers[pl]
				local patLabel = (tr and tr.patterns and tr.patterns.label) or "Idle"
				local subLine = string.format("[%s]", patLabel)

				if role == "Catcher" then
					local cInfo = chaserPredictions[pl]
					if cInfo and cInfo.targetPlayer then
						local tName = cInfo.targetPlayer.Name
						subLine = string.format("[%s -> %s]", cInfo.mode, tName)
					end
				elseif role == "Runner" and tr and tr.bestEscapeRoute then
					subLine = string.format("[%s | lane: %s]", patLabel, tr.bestEscapeRoute.name)
				end

				tag.text.Text = string.format("%s%s  [%s]  %dm\n%s", pl.Name, state, role, dist, subLine)
				tag.text.TextColor3 = color
				tag.hl.FillColor = color
				tag.hl.OutlineColor = color
			end
		end
	end

	for pl in pairs(espTags) do
		if not seen[pl] then
			destroyTag(pl)
		end
	end
end

local function clearEsp()
	for pl in pairs(espTags) do
		destroyTag(pl)
	end
	local oldFolder = workspace:FindFirstChild("HV_PredictionMarkers")
	if oldFolder then
		oldFolder:Destroy()
	end
end

local espConnection = RunService.Heartbeat:Connect(function()
	pcall(stepPredictionEngine)
	pcall(updateEsp)
end)

-- ------------------------------------------------------------------ unloading

local window
local mobileToggleGui: ScreenGui? = nil
local viewportScaleConn: RBXScriptConnection? = nil

local function teardown()
	pcall(function()
		RunService:UnbindFromRenderStep(CAM_BIND_NAME)
	end)
	pcall(function()
		RunService:UnbindFromRenderStep(INPUT_BIND_NAME)
	end)
	if postDriveConnection then
		postDriveConnection:Disconnect()
	end
	if preSimConnection then
		preSimConnection:Disconnect()
	end
	if espConnection then
		espConnection:Disconnect()
	end
	if viewportScaleConn then
		viewportScaleConn:Disconnect()
		viewportScaleConn = nil
	end
	clearEsp()
	pcall(function()
		if mobileToggleGui then
			mobileToggleGui:Destroy()
			mobileToggleGui = nil
		end
	end)
	pcall(function()
		if window and window.screenGui then
			window.screenGui:Destroy()
		end
	end)
end

if STATE then
	STATE.onCleanup(teardown)
end

-- ------------------------------------------------------------------------ UI

local Rayfield = loadstring(game:HttpGet("https://sirius.menu/gen2"))()

window = Rayfield:CreateWindow({
	name = "BrN Hub",
	subtitle = "By BreNo",
	showName = "BrN Hub",
	sidebarLayout = true,
})

local statusDot: Frame? = nil
pcall(function()
	local mainFrame = window and window.main
	if mainFrame and mainFrame:IsA("GuiObject") then
		local uiScale = mainFrame:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
		uiScale.Name = "BrNHubMobileScale"
		uiScale.Parent = mainFrame

		local function updateViewportScale()
			local cam = workspace.CurrentCamera
			if not cam then
				return
			end
			local vp = cam.ViewportSize
			if vp.X <= 0 or vp.Y <= 0 then
				return
			end
			local scaleX = (vp.X - 28) / 685
			local scaleY = (vp.Y - 44) / 450
			local scale = math.clamp(math.min(scaleX, scaleY, 1.0), 0.55, 1.0)
			uiScale.Scale = scale
		end

		updateViewportScale()
		local cam = workspace.CurrentCamera
		if cam then
			viewportScaleConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(updateViewportScale)
		end
	end

	local parentGui = (window and window.screenGui and window.screenGui.Parent) or LocalPlayer:WaitForChild("PlayerGui")
	local oldFloating = parentGui:FindFirstChild("HV_BrNHubFloating")
	if oldFloating then
		oldFloating:Destroy()
	end

	local floatGui = Instance.new("ScreenGui")
	floatGui.Name = "HV_BrNHubFloating"
	floatGui.DisplayOrder = 999
	floatGui.IgnoreGuiInset = true
	floatGui.ResetOnSpawn = false
	floatGui.Parent = parentGui
	mobileToggleGui = floatGui

	local pill = Instance.new("TextButton")
	pill.Name = "BrNHubToggle"
	pill.AnchorPoint = Vector2.new(0.5, 0)
	pill.Position = UDim2.new(0.5, 0, 0, 10)
	pill.Size = UDim2.fromOffset(128, 34)
	pill.BackgroundColor3 = Color3.fromRGB(20, 18, 28)
	pill.BackgroundTransparency = 0.08
	pill.BorderSizePixel = 0
	pill.AutoButtonColor = false
	pill.Text = ""
	pill.Parent = floatGui

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = pill

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(165, 120, 255)
	stroke.Thickness = 1.6
	stroke.Transparency = 0.15
	stroke.Parent = pill

	local grad = Instance.new("UIGradient")
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(38, 30, 56)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 18, 28)),
	})
	grad.Rotation = 35
	grad.Parent = pill

	local dot = Instance.new("Frame")
	dot.Name = "StatusDot"
	dot.AnchorPoint = Vector2.new(0, 0.5)
	dot.Position = UDim2.new(0, 12, 0.5, 0)
	dot.Size = UDim2.fromOffset(8, 8)
	dot.BackgroundColor3 = Color3.fromRGB(100, 235, 140)
	dot.BorderSizePixel = 0
	dot.Parent = pill
	statusDot = dot

	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = dot

	local lbl = Instance.new("TextLabel")
	lbl.Name = "BrandLabel"
	lbl.BackgroundTransparency = 1
	lbl.Position = UDim2.fromOffset(26, 0)
	lbl.Size = UDim2.new(1, -34, 1, 0)
	lbl.Font = Enum.Font.GothamBold
	lbl.TextSize = 13
	lbl.TextColor3 = Color3.fromRGB(245, 240, 255)
	lbl.TextXAlignment = Enum.TextXAlignment.Center
	lbl.Text = "BrN Hub"
	lbl.Parent = pill

	local dragging = false
	local dragInput: InputObject? = nil
	local dragStartPos = Vector2.zero
	local startPillPos = pill.Position
	local movedBeyondThreshold = false

	pill.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			movedBeyondThreshold = false
			dragInput = input
			dragStartPos = Vector2.new(input.Position.X, input.Position.Y)
			startPillPos = pill.Position
		end
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject)
		if dragging and (input == dragInput or input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local curPos = Vector2.new(input.Position.X, input.Position.Y)
			local delta = curPos - dragStartPos
			if delta.Magnitude > 6 then
				movedBeyondThreshold = true
			end
			if movedBeyondThreshold then
				pill.Position = UDim2.new(
					startPillPos.X.Scale,
					startPillPos.X.Offset + delta.X,
					startPillPos.Y.Scale,
					startPillPos.Y.Offset + delta.Y
				)
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject)
		if dragging and (input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			local wasDrag = movedBeyondThreshold
			dragging = false
			dragInput = nil
			if not wasDrag then
				pcall(function()
					if window and window.ToggleHide then
						window:ToggleHide()
					end
				end)
			end
		end
	end)
end)

local statusText

local farmTab = window:CreateTab({ name = "Farm" })
farmTab:CreateText({
	name = "BrN Hub  •  By BreNo",
	text = "Tap the floating BrN Hub button at the top of your screen (Mobile & PC) or press K to show/hide this menu.",
})
farmTab:CreateToggle({
	name = "Auto Farm",
	description = "Follows the round on its own: chases when you are the catcher, runs, dashes, and shields when you are a runner.",
	flag = "AutoFarm",
	value = Cfg.autoFarm,
	callback = function(v)
		Cfg.autoFarm = v
	end,
})
farmTab:CreateToggle({
	name = "Camera Follow Direction",
	description = "Smoothly rotates the camera toward your movement direction so your character always faces forward and never walks backwards.",
	flag = "CameraFollow",
	value = Cfg.cameraFollow,
	callback = function(v)
		Cfg.cameraFollow = v
	end,
})
farmTab:CreateToggle({
	name = "Auto Prompt Choice",
	description = "Automatically picks a runner when you are Lead Chaser and answers Chicken/Hero when challenged.",
	flag = "AutoChoice",
	value = Cfg.autoChoice,
	callback = function(v)
		Cfg.autoChoice = v
	end,
})
farmTab:CreateToggle({
	name = "Pick Hero (instead of Chicken)",
	description = "When challenged to Chicken or Hero, choose Hero for solo crossing bonus.",
	flag = "PlayHero",
	value = Cfg.playHero,
	callback = function(v)
		Cfg.playHero = v
	end,
})
farmTab:CreateToggle({
	name = "Anti-AFK (Auto Queue)",
	description = "Keeps AFK turned off in the lobby so you never sit out a match.",
	flag = "AntiAfk",
	value = Cfg.antiAfk,
	callback = function(v)
		Cfg.antiAfk = v
	end,
})
farmTab:CreateDivider()
statusText = farmTab:CreateText({
	name = "Status",
	text = "waiting",
})

local runnerTab = window:CreateTab({ name = "Runner" })
runnerTab:CreateToggle({
	name = "Auto Run",
	description = "Learns custom maps & obstacles and runs to the target safezone for each crossing.",
	flag = "AutoRun",
	value = Cfg.autoRun,
	callback = function(v)
		Cfg.autoRun = v
		if v then
			Cfg.autoChase = false
		end
	end,
})
runnerTab:CreateToggle({
	name = "Use Safe Escape Lanes",
	description = "Evaluates open safezone corridors against map obstacles and Catchers to pick the safest lane.",
	flag = "UseEscapeRoutes",
	value = Cfg.useEscapeRoutes,
	callback = function(v)
		Cfg.useEscapeRoutes = v
	end,
})
runnerTab:CreateToggle({
	name = "Auto Collect Gems & Candy",
	description = "Detours to pick up nearby Gems and Candy Corn on the track ONLY when no Catchers are nearby.",
	flag = "AutoCollect",
	value = Cfg.autoCollect,
	callback = function(v)
		Cfg.autoCollect = v
	end,
})
runnerTab:CreateSlider({
	name = "Collect Radius",
	description = "Max distance (studs) from your runner to grab a Gem or Candy Corn when safe.",
	flag = "CollectRadius",
	range = { 10, 50 },
	value = Cfg.collectRadius,
	callback = function(v)
		Cfg.collectRadius = v
	end,
})
runnerTab:CreateToggle({
	name = "Auto Dash",
	description = "Automatically uses runner dashes (RunBoost).",
	flag = "AutoDash",
	value = Cfg.autoDash,
	callback = function(v)
		Cfg.autoDash = v
	end,
})
runnerTab:CreateToggle({
	name = "Auto Shield (When No Dash)",
	description = "Automatically activates One Hit Shield (or equipped Runner ability) when a Catcher attacks/closes in and your dash is on cooldown.",
	flag = "AutoShield",
	value = Cfg.autoShield,
	callback = function(v)
		Cfg.autoShield = v
	end,
})
runnerTab:CreateToggle({
	name = "Predictive / Reactive Dash",
	description = "Only dashes when a chaser melees/dives at you or closes into strike range, juking sideways like a real player instead of spam-dashing.",
	flag = "DashPredictive",
	value = Cfg.dashPredictive,
	callback = function(v)
		Cfg.dashPredictive = v
	end,
})
runnerTab:CreateSlider({
	name = "Dash Threat Range",
	description = "Distance (studs) at which a closing chaser triggers a predictive juke dash or shield.",
	flag = "DashThreatRange",
	range = { 8, 24 },
	value = Cfg.dashThreatRange,
	callback = function(v)
		Cfg.dashThreatRange = v
	end,
})
runnerTab:CreateToggle({
	name = "Evade Catchers",
	description = "Steers laterally around nearby catchers while heading for the finish line.",
	flag = "Evade",
	value = Cfg.evade,
	callback = function(v)
		Cfg.evade = v
	end,
})
runnerTab:CreateSlider({
	name = "Evade Range",
	description = "How far away a catcher starts pushing you aside.",
	flag = "EvadeRange",
	range = { 6, 60 },
	value = Cfg.evadeRange,
	callback = function(v)
		Cfg.evadeRange = v
	end,
})
runnerTab:CreateDivider()
runnerTab:CreateText({
	name = "BrN Hub  •  Runner",
	text = "Auto Run learns every map's obstacles, rotates the camera smoothly, juke-dashes Catchers, and pops Shield when dash is unavailable.",
})

local chaserTab = window:CreateTab({ name = "Chaser" })
chaserTab:CreateToggle({
	name = "Auto Chase",
	description = "Intercepts the nearest active runner using obstacle-aware lead and movement-style tracking.",
	flag = "AutoChase",
	value = Cfg.autoChase,
	callback = function(v)
		Cfg.autoChase = v
		if v then
			Cfg.autoRun = false
		end
	end,
})
chaserTab:CreateToggle({
	name = "Auto Melee",
	description = "Predictive knife swing when within 9 studs (catches runners at full sprint without dive recovery lock).",
	flag = "AutoMelee",
	value = Cfg.autoMelee,
	callback = function(v)
		Cfg.autoMelee = v
	end,
})
chaserTab:CreateToggle({
	name = "Auto Tackle",
	description = "Leads the runner's trajectory and dives when within tackle range.",
	flag = "AutoTackle",
	value = Cfg.autoTackle,
	callback = function(v)
		Cfg.autoTackle = v
	end,
})
chaserTab:CreateSlider({
	name = "Tackle Range",
	description = "The game allows up to ~12 studs.",
	flag = "TackleRange",
	range = { 4, 12 },
	value = Cfg.tackleRange,
	callback = function(v)
		Cfg.tackleRange = v
	end,
})

local visualsTab = window:CreateTab({ name = "Visuals" })
visualsTab:CreateToggle({
	name = "Player ESP",
	description = "Highlights players with their name, role, distance, and current state.",
	flag = "Esp",
	value = Cfg.esp,
	callback = function(v)
		Cfg.esp = v
		if not v then
			clearEsp()
		end
	end,
})

local settingsTab = window:CreateTab({ name = "Settings" })
settingsTab:CreateSlider({
	name = "Move Speed",
	description = "Normal is 34. Higher than 34 gets rubber-banded by the server.",
	flag = "MoveSpeed",
	range = { 12, 60 },
	value = Cfg.speed,
	callback = function(v)
		Cfg.speed = v
	end,
})
settingsTab:CreateDivider()
settingsTab:CreateText({
	name = "BrN Hub",
	text = "BrN Hub — By BreNo. Mobile & PC friendly. Tap the floating BrN Hub button or press K to toggle the UI.",
})

if getgenv then
	getgenv().HussValley = {
		Hub = "BrN Hub",
		Cfg = Cfg,
		window = window,
		Debug = Debug,
		Prediction = {
			players = playerTrackers,
			chasers = chaserPredictions,
			bounds = arenaBounds,
		},
	}
end

task.spawn(function()
	while STATE == nil or STATE.alive() do
		pcall(stepSessionAutomation)
		if statusDot then
			local active = Cfg.autoFarm or Cfg.autoRun or Cfg.autoChase
			statusDot.BackgroundColor3 = active and Color3.fromRGB(100, 235, 140) or Color3.fromRGB(150, 150, 165)
		end
		if statusText then
			pcall(function()
				statusText:Set(string.format(
					"%s\nrole: %s   state: %s   dashes: %d   shields: %d",
					statusLine,
					tostring(roleOf(LocalPlayer)),
					tostring(LocalPlayer:GetAttribute("RunState")),
					Debug.dashes,
					Debug.shields
				))
			end)
		end
		task.wait(0.35)
	end
end)
