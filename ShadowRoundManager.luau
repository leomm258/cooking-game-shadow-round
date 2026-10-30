-- Discord : Leorizoto Roblox : Leorizoto

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local ShadowRound = {}
local currentSession
local stopping = false
local random = Random.new()

-- settings holds object references so moving or renaming a map object does not break the round
-- each tagged station point has a shadowprop reference to the visual prop it uses
local settings = script:WaitForChild("Settings")
-- only properties changed by the mask are saved so unrelated humanoid settings stay untouched
local DISPLAY_PROPERTIES = {
	"DisplayDistanceType", "HealthDisplayType", "NameDisplayDistance",
	"HealthDisplayDistance", "DisplayName", "WalkSpeed",
}
local PART_PROPERTIES = { "Color", "Material", "Transparency", "CastShadow" }

-- object references survive renames unlike a chain of child names
local function readReference(container, name, className)
	local reference = container:FindFirstChild(name)
	local object = reference and reference:IsA("ObjectValue") and reference.Value
	assert(object and object:IsA(className), "Invalid shadow reference " .. name)
	return object
end

-- reject invalid values at startup so bad editor settings cannot create an endless movement loop
local function readNumber(name, minimum)
	local value = settings:GetAttribute(name)
	assert(typeof(value) == "number" and value >= minimum and value < math.huge, "Invalid setting " .. name)
	return value
end

local function readConfig()
	-- resolve dependencies once at the round boundary rather than searching the map in every loop
	local config = {
		template = readReference(settings, "Template", "Model"),
		spawnArea = readReference(settings, "SpawnArea", "BasePart"),
		appearance = readReference(settings, "Appearance", "HumanoidDescription"),
		animation = readReference(settings, "WalkAnimation", "Animation"),
		target = math.floor(readNumber("TargetSilhouettes", 0)),
		speed = readNumber("WalkSpeed", 0),
		transparency = readNumber("BodyTransparency", 0),
		moveTimeout = readNumber("MoveTimeout", 0.1),
		pauseMin = readNumber("PauseMin", 0),
		pauseMax = readNumber("PauseMax", 0),
		spacing = readNumber("SpawnSpacing", 0),
		color = settings:GetAttribute("ShadowColor"),
		stationTag = settings:GetAttribute("StationTag"),
		group = settings:GetAttribute("CollisionGroup"),
		playerGroup = settings:GetAttribute("PlayerCollisionGroup"),
	}
	assert(config.transparency <= 1 and config.pauseMax >= config.pauseMin, "Invalid shadow ranges")
	assert(config.appearance.Archivable, "Shadow appearance must be clonable")
	assert(typeof(config.color) == "Color3", "Missing shadow color")
	for _, key in { "stationTag", "group", "playerGroup" } do
		assert(typeof(config[key]) == "string" and config[key] ~= "", "Missing setting " .. key)
	end
	return config
end

local function isCurrent(session)
	-- the session identity invalidates old tasks even if another round has already started
	return currentSession == session and session.active
end

-- disconnecting listeners releases the session captured by their callbacks
local function disconnectAll(connections)
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

-- copy the original values so later changes cannot overwrite the snapshot
local function copyProperties(instance, names)
	local values = {}
	for _, name in names do
		values[name] = instance[name]
	end
	return values
end

-- restoration uses the same property keys as capture
local function setProperties(instance, values)
	for name, value in values do
		instance[name] = value
	end
end

local function hideDisplay(humanoid, config)
	-- both name and health displays must be hidden or they reveal the real player
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.NameDisplayDistance = 0
	humanoid.HealthDisplayDistance = 0
	humanoid.DisplayName = " "
	humanoid.WalkSpeed = config.speed
end

local function styleCharacter(character, config)
	for _, object in character:GetDescendants() do
		if object:IsA("Decal") then
			object.Transparency = 1
			continue
		end
		if not object:IsA("BasePart") then
			continue
		end
		object.Color = config.color
		object.Material = Enum.Material.SmoothPlastic
		object.CastShadow = false
		-- root and head names are rig conventions rather than references to map objects
		object.Transparency = config.transparency
		if object.Name == "HumanoidRootPart" then
			object.Transparency = 1
		elseif object.Name == "Head" then
			object.Transparency = 0
		end
	end
end

local function captureAppearance(character, humanoid)
	-- keep the original description before applying the mask so repeated starts cannot save the mask
	local record = {
		character = character,
		humanoid = humanoid,
		description = humanoid:GetAppliedDescription(),
		display = copyProperties(humanoid, DISPLAY_PROPERTIES),
		parts = {},
		decals = {},
		visuals = {},
		busy = true,
	}
	-- held items can move into the backpack so keep their instances instead of their current paths
	for _, object in character:GetDescendants() do
		if object:IsA("BasePart") then
			record.visuals[object] = copyProperties(object, PART_PROPERTIES)
		elseif object:IsA("Decal") then
			record.visuals[object] = { Transparency = object.Transparency }
		end
	end
	for _, part in character:GetChildren() do
		if not part:IsA("BasePart") then
			continue
		end
		-- avatar loading can replace body parts so save their rig names rather than only old instances
		record.parts[part.Name] = copyProperties(part, PART_PROPERTIES)
		for _, decal in part:GetChildren() do
			if decal:IsA("Decal") then
				table.insert(record.decals, { part = part.Name, name = decal.Name, value = decal.Transparency })
			end
		end
	end
	return record
end

local function restoreAppearance(record)
	local character = record.character
	local humanoid = record.humanoid
	-- reset is needed because tinting the parts changes appearance outside the description api
	local ok, err = pcall(function()
		if character.Parent and humanoid.Parent then
			humanoid:ApplyDescriptionResetAsync(record.description)
		end
	end)
	record.description:Destroy()
	-- restore surviving items even if the character was removed or the item was unequipped
	for object, values in record.visuals do
		if object.Parent then
			setProperties(object, values)
		end
	end
	if not ok then
		warn("Shadow appearance restore failed", err)
	end
	if not character.Parent or not humanoid.Parent then
		return
	end
	setProperties(humanoid, record.display)
	for name, values in record.parts do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			setProperties(part, values)
		end
	end
	-- restoring saved values avoids making originally invisible body parts visible
	for _, saved in record.decals do
		local part = character:FindFirstChild(saved.part)
		local decal = part and part:FindFirstChild(saved.name)
		if decal and decal:IsA("Decal") then
			decal.Transparency = saved.value
		end
	end
end

local function applyPlayer(session, player, character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or session.players[character] or not isCurrent(session) then
		return
	end
	local ok, record = pcall(captureAppearance, character, humanoid)
	if not ok then
		warn("Shadow appearance snapshot failed", record)
		return
	end
	session.players[character] = record
	record.player = player
	local description
	-- this call yields so stop waits for busy to clear before restoring the original avatar
	-- asset loading can fail so keep that failure local to this character
	local applied, err = pcall(function()
		description = session.config.appearance:Clone()
		assert(description, "Shadow appearance could not be cloned")
		humanoid:ApplyDescriptionResetAsync(description)
		-- after the yield check both the round and the character to avoid masking an old respawn
		if isCurrent(session) and player.Character == character and character.Parent then
			styleCharacter(character, session.config)
			hideDisplay(humanoid, session.config)
		end
	end)
	-- release the wait flag on every outcome so stop cannot get stuck after an apply error
	record.busy = false
	if description then
		description:Destroy()
	end
	if not applied and isCurrent(session) then
		warn("Shadow appearance apply failed", err)
	end
end

local function schedulePlayer(session, player, character)
	task.spawn(function()
		-- wait for the normal avatar load or its accessories could arrive after the mask
		local deadline = os.clock() + 10
		while isCurrent(session) and player.Character == character and not player:HasAppearanceLoaded() do
			if os.clock() >= deadline then
				return
			end
			task.wait(0.1)
		end
		if isCurrent(session) and player.Character == character then
			applyPlayer(session, player, character)
		end
	end)
end

local function watchPlayer(session, player)
	-- the join event and the initial player list can reach the same player so bind only once
	if session.playerConnections[player] then
		return
	end
	session.playerConnections[player] = {
		player.CharacterAdded:Connect(function(character)
			schedulePlayer(session, player, character)
		end),
		player.CharacterAppearanceLoaded:Connect(function(character)
			-- a slow avatar load can finish after the initial bounded wait
			if isCurrent(session) and player.Character == character then
				applyPlayer(session, player, character)
			end
		end),
	}
	if player.Character then
		schedulePlayer(session, player, player.Character)
	end
end

local function prepareCollision(config)
	for _, name in { config.group, config.playerGroup } do
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			PhysicsService:RegisterCollisionGroup(name)
		end
	end
	-- preserve collision with the floor while letting silhouettes pass through each other
	PhysicsService:CollisionGroupSetCollidable(config.group, config.group, false)
	PhysicsService:CollisionGroupSetCollidable(config.group, config.playerGroup, false)
	PhysicsService:CollisionGroupSetCollidable(config.group, "Default", true)
end

local function configurePart(part, config)
	if not part:IsA("BasePart") then
		return
	end
	-- group rules prevent player collisions without disabling contact with the floor
	part.CollisionGroup = config.group
	part.CanTouch = false
end

local function bindStation(session, point)
	if not point:IsA("BasePart") or not point:IsDescendantOf(Workspace) then
		return
	end
	-- each station provides its own prop instead of choosing one from the station name
	local reference = point:FindFirstChild("ShadowProp")
	local prop = reference and reference:IsA("ObjectValue") and reference.Value
	if not prop or not prop:IsA("BasePart") then
		warn("Shadow station has no valid prop reference", point:GetFullName())
		return
	end
	-- store the point itself so station names and hierarchy do not matter to the ai
	-- instance keys distinguish stations even when they share a name
	session.targets[point] = prop
end

local function watchStations(session)
	-- tag signals keep targets current when stations are added or removed during a round
	local tag = session.config.stationTag
	table.insert(session.connections, CollectionService:GetInstanceAddedSignal(tag):Connect(function(point)
		bindStation(session, point)
	end))
	table.insert(session.connections, CollectionService:GetInstanceRemovedSignal(tag):Connect(function(point)
		session.targets[point] = nil
	end))
	for _, point in CollectionService:GetTagged(tag) do
		bindStation(session, point)
	end
end

local function releaseTarget(session, decoy)
	local point = decoy.target
	-- check ownership because an old task must never release another decoy reservation
	if point and session.reservations[point] == decoy then
		session.reservations[point] = nil
	end
	decoy.target = nil
end

local function reserveTarget(session, decoy)
	local available = {}
	for point in session.targets do
		if point:IsDescendantOf(Workspace) and not session.reservations[point] then
			table.insert(available, point)
		end
	end
	-- wait when every station is occupied instead of selecting an invalid random index
	if #available == 0 then
		return nil
	end
	-- select and reserve without yielding so two workers cannot choose the same station
	local point = available[random:NextInteger(1, #available)]
	session.reservations[point] = decoy
	decoy.target = point
	return point
end

local function clearProp(decoy)
	if decoy.prop then
		decoy.prop:Destroy()
		decoy.prop = nil
	end
end

local function equipProp(decoy, template)
	-- these are standard hand names for r15 and r6 rigs
	local hand = decoy.model:FindFirstChild("RightHand") or decoy.model:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") then
		return
	end
	-- the asset stores its grip so changing a prop does not require another branch in the ai
	local grip = template:GetAttribute("Grip")
	if typeof(grip) ~= "CFrame" then
		warn("Shadow prop is missing its grip", template.Name)
		return
	end
	clearProp(decoy)
	-- clone a configured asset instead of rebuilding each recipe from sizes in this script
	local prop = template:Clone()
	prop.Anchored = false
	prop.CanCollide = false
	prop.CanTouch = false
	prop.CanQuery = false
	prop.Massless = true
	-- apply the grip in hand space so the offset follows the hand orientation
	prop.CFrame = hand.CFrame * grip
	local weld = Instance.new("WeldConstraint")
	-- the weld keeps the prop attached without a per frame position update
	weld.Part0 = hand
	weld.Part1 = prop
	weld.Parent = prop
	prop.Parent = decoy.model
	decoy.prop = prop
end

local function cleanupDecoy(session, decoy)
	if decoy.removed then
		return
	end
	-- mark removal first because destroying instances can resume other callbacks
	decoy.removed = true
	-- the balancing worker must stop counting the removed silhouette
	session.decoys[decoy] = nil
	releaseTarget(session, decoy)
	disconnectAll(decoy.connections)
	clearProp(decoy)
	if decoy.track then
		decoy.track:Stop()
		decoy.track:Destroy()
		decoy.track = nil
	end
	decoy.model:Destroy()
end

local function decoyIsActive(session, decoy)
	return isCurrent(session) and not decoy.removed and decoy.model.Parent ~= nil
end

local function waitActive(session, decoy, duration)
	-- short waits make stop responsive without cancelling a thread in the middle of cleanup
	local deadline = os.clock() + duration
	while decoyIsActive(session, decoy) and os.clock() < deadline do
		task.wait(math.min(0.1, math.max(0, deadline - os.clock())))
	end
	return decoyIsActive(session, decoy)
end

local function moveDecoy(session, decoy, point)
	local arrived = false
	local finished = false
	-- subscribe before issuing the move so an immediate completion cannot be missed
	local connection = decoy.humanoid.MoveToFinished:Connect(function(success)
		arrived = success
		finished = true
	end)
	table.insert(decoy.connections, connection)
	-- a station point is already at floor height so only horizontal variation is added
	local position = point.Position + Vector3.new(random:NextNumber(-1.2, 1.2), 0, random:NextNumber(-1.2, 1.2))
	decoy.humanoid:MoveTo(position)
	if decoy.track then
		decoy.track:Play()
	end
	local deadline = os.clock() + session.config.moveTimeout
	while decoyIsActive(session, decoy) and session.targets[point] and not finished and os.clock() < deadline do
		task.wait(0.1)
	end
	connection:Disconnect()
	-- remove finished listeners from the cleanup list so it does not grow on every trip
	local index = table.find(decoy.connections, connection)
	if index then
		table.remove(decoy.connections, index)
	end
	if decoy.track then
		decoy.track:Stop()
	end
	if decoyIsActive(session, decoy) and not arrived then
		decoy.humanoid:MoveTo(decoy.root.Position)
	end
	return arrived and decoyIsActive(session, decoy) and session.targets[point] ~= nil
end

local function faceStation(decoy, point)
	-- keep the target at root height so the character turns without tilting
	local position = decoy.root.Position
	local target = Vector3.new(point.Position.X, position.Y, point.Position.Z)
	if (target - position).Magnitude <= 0.1 then
		return
	end
	-- preserve the difference between root and model pivot when rotating the whole rig
	local offset = decoy.root.CFrame:ToObjectSpace(decoy.model:GetPivot())
	decoy.model:PivotTo(CFrame.lookAt(position, target) * offset)
end

local function runDecoy(session, decoy)
	while decoyIsActive(session, decoy) do
		local point = reserveTarget(session, decoy)
		if not point then
			waitActive(session, decoy, 0.2)
			continue
		end
		-- the fake prop is visual only and never awards food or invokes cooking remotes
		equipProp(decoy, session.targets[point])
		if moveDecoy(session, decoy, point) then
			faceStation(decoy, point)
			waitActive(session, decoy, random:NextNumber(session.config.pauseMin, session.config.pauseMax))
		end
		-- release on failure too so a blocked route cannot reserve a station forever
		clearProp(decoy)
		releaseTarget(session, decoy)
		waitActive(session, decoy, random:NextNumber(0.3, 0.8))
	end
	cleanupDecoy(session, decoy)
end

local function prepareDecoy(session, decoy, index)
	local config = session.config
	local model = decoy.model
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	assert(humanoid, "Decoy template needs a Humanoid")
	local description = config.appearance:Clone()
	local ok, err = pcall(function()
		humanoid:ApplyDescriptionResetAsync(description)
	end)
	description:Destroy()
	assert(ok, err)
	if not decoyIsActive(session, decoy) then
		return false
	end
	local root = humanoid.RootPart
	assert(root, "Decoy template needs a root part")
	decoy.humanoid = humanoid
	decoy.root = root
	model.PrimaryPart = root
	styleCharacter(model, config)
	hideDisplay(humanoid, config)
	for _, part in model:GetDescendants() do
		configurePart(part, config)
	end
	-- appearance changes can add parts so handle additions rather than rescanning every half second
	table.insert(decoy.connections, model.DescendantAdded:Connect(function(part)
		configurePart(part, config)
	end))
	-- center the spawn slots around the configured area
	local x = (index - (config.target + 1) * 0.5) * config.spacing
	-- place the root above the floor using the rig height rather than a fixed height
	local height = humanoid.HipHeight + root.Size.Y * 0.5
	local target = config.spawnArea.CFrame * CFrame.new(x, height, 0)
	model:PivotTo(target * root.CFrame:ToObjectSpace(model:GetPivot()))
	local canSetOwnership = root:CanSetNetworkOwnership()
	if canSetOwnership then
		-- server ownership keeps decoy movement independent of the nearest player
		root:SetNetworkOwner(nil)
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	-- reuse one track for every trip instead of loading a new animation at each station
	decoy.track = animator:LoadAnimation(config.animation)
	decoy.track.Looped = true
	return true
end

local function spawnDecoy(session, index)
	local model = session.config.template:Clone()
	-- template scripts belong to the customer system and must not run inside a fake player
	for _, object in model:GetDescendants() do
		if object:IsA("BaseScript") then
			object:Destroy()
		elseif object:IsA("BillboardGui") then
			object:Destroy()
		end
	end
	model:SetAttribute("ShadowDecoy", true)
	model:SetAttribute("IsCustomer", false)
	model.Parent = session.folder
	-- register before loading appearance because stop may run while the request yields
	local decoy = { model = model, connections = {}, removed = false }
	session.decoys[decoy] = true
	-- a failed asset or template still needs its partially created decoy cleaned up
	local ok, ready = pcall(prepareDecoy, session, decoy, index)
	if not ok or not ready then
		if isCurrent(session) and not ok then
			warn("Shadow decoy setup failed", ready)
		end
		cleanupDecoy(session, decoy)
		return false
	end
	task.spawn(function()
		local success, err = pcall(runDecoy, session, decoy)
		cleanupDecoy(session, decoy)
		if not success and isCurrent(session) then
			warn("Shadow decoy movement failed", err)
		end
	end)
	return true
end

local function balanceDecoys(session)
	-- allow only one balancing worker so concurrent player joins cannot create duplicate decoys
	if session.balancing or not isCurrent(session) then
		return
	end
	session.balancing = true
	task.spawn(function()
		while isCurrent(session) do
			-- players already count as silhouettes so fill only the missing amount
			local wanted = math.max(0, session.config.target - #Players:GetPlayers())
			local list = {}
			for decoy in session.decoys do
				table.insert(list, decoy)
			end
			if #list == wanted then
				break
			end
			if #list > wanted then
				cleanupDecoy(session, list[#list])
			-- stop retrying a broken template instead of flooding the server with failures
			elseif not spawnDecoy(session, #list + 1) then
				break
			end
		end
		session.balancing = false
	end)
end

function ShadowRound.Start()
	-- duplicate start requests must not snapshot an already masked avatar
	if currentSession then
		return
	end
	while stopping do
		task.wait()
	end
	if currentSession then
		return
	end
	-- validate before activating the session so startup failure leaves the module restartable
	local config = readConfig()
	prepareCollision(config)
	local folder = Instance.new("Folder")
	folder.Name = "ShadowRoundDecoys"
	folder.Parent = Workspace
	local session = {
		active = true, config = config, folder = folder,
		players = {}, playerConnections = {}, connections = {},
		decoys = {}, targets = {}, reservations = {},
	}
	-- each round owns its connections and reservations instead of sharing leftovers
	currentSession = session
	watchStations(session)
	-- subscribe before enumerating so a player joining at startup is not missed
	table.insert(session.connections, Players.PlayerAdded:Connect(function(player)
		watchPlayer(session, player)
		balanceDecoys(session)
	end))
	table.insert(session.connections, Players.PlayerRemoving:Connect(function(player)
		local connections = session.playerConnections[player]
		if connections then
			disconnectAll(connections)
			session.playerConnections[player] = nil
		end
		-- playerremoving runs before the player list changes so rebalance on the next task step
		task.defer(function()
			balanceDecoys(session)
		end)
	end))
	for _, player in Players:GetPlayers() do
		watchPlayer(session, player)
	end
	balanceDecoys(session)
end

function ShadowRound.Stop()
	while stopping do
		task.wait()
	end
	local session = currentSession
	if not session then
		return
	end
	-- finish restoring avatars before another round can snapshot their appearance
	stopping = true
	currentSession = nil
	session.active = false
	-- invalidate the session before disconnecting so a resumed task cannot create more work
	disconnectAll(session.connections)
	for _, connections in session.playerConnections do
		disconnectAll(connections)
	end
	table.clear(session.playerConnections)
	for decoy in session.decoys do
		cleanupDecoy(session, decoy)
	end
	session.folder:Destroy()
	table.clear(session.reservations)
	for _, record in session.players do
		-- an in flight avatar request must finish before its saved appearance is restored
		while record.busy do
			task.wait()
		end
		-- one failed restoration must not prevent other players from being restored
		local ok, err = pcall(restoreAppearance, record)
		if not ok then
			record.description:Destroy()
			warn("Shadow player cleanup failed", err)
		end
	end
	table.clear(session.players)
	stopping = false
end

return ShadowRound
