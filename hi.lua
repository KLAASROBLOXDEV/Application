local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local CONFIG = {
	REMOTE_NAME = "PickupRemote",

	PICKUP_TAG = "Pickupable",
	DEFAULT_TEST_NAME = "testpak",

	DEFAULT_WEIGHT = 1,
	DEFAULT_HOLD_DISTANCE = 8,

	MIN_HOLD_DISTANCE = 4,
	MAX_ATTRIBUTE_HOLD_DISTANCE = 15,

	MAX_PICKUP_DISTANCE = 18,
	MAX_HOLD_DISTANCE = 24,

	UPDATE_TIMEOUT = 0.9,
	HEAD_CLEARANCE = 2.25,

	DEBUG = false,
}

local remote = ReplicatedStorage:FindFirstChild(CONFIG.REMOTE_NAME)
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = CONFIG.REMOTE_NAME
	remote.Parent = ReplicatedStorage
end

local targetFolder = workspace:FindFirstChild("PickupTargets")
if not targetFolder then
	targetFolder = Instance.new("Folder")
	targetFolder.Name = "PickupTargets"
	targetFolder.Parent = workspace
end

type SavedPart = {
	part: BasePart,
	anchored: boolean,
	canCollide: boolean,
	networkOwner: Player?,
}

type PickupState = {
	container: Instance,
	rootPart: BasePart,
	targetPart: BasePart,
	cleanup: { Instance },
	savedParts: { SavedPart },
	lastUpdate: number,
	collisionRadius: number,
}

local heldByPlayer: { [Player]: PickupState } = {}
local heldByObject: { [Instance]: Player } = {}

local function debugSet(attributeName: string, value: any)
	if CONFIG.DEBUG then
		remote:SetAttribute(attributeName, value)
	end
end

local function rejectPickup(reason: string)
	debugSet("PickupServerLastReject", reason)
end

local function getNumberAttribute(
	instance: Instance,
	name: string,
	defaultValue: number,
	minValue: number,
	maxValue: number
): number
	local value = instance:GetAttribute(name)
	if typeof(value) ~= "number" then
		return defaultValue
	end

	return math.clamp(value, minValue, maxValue)
end

local function setDefaultAttribute(instance: Instance, name: string, value: any)
	if instance:GetAttribute(name) == nil then
		instance:SetAttribute(name, value)
	end
end

local function safeGetNetworkOwner(part: BasePart): Player?
	local owner: Player? = nil

	pcall(function()
		owner = part:GetNetworkOwner()
	end)

	return owner
end

local function safeSetNetworkOwner(part: BasePart, owner: Player?)
	pcall(function()
		part:SetNetworkOwner(owner)
	end)
end

local function destroyAll(instances: { Instance })
	for _, instance in ipairs(instances) do
		if instance and instance.Parent then
			instance:Destroy()
		end
	end
end

local function isPickupable(instance: Instance): boolean
	return instance:GetAttribute("Pickupable") == true
		or CollectionService:HasTag(instance, CONFIG.PICKUP_TAG)
end

local function getPickupContainer(instance: Instance): Instance?
	local current: Instance? = instance

	while current and current ~= workspace do
		if (current:IsA("BasePart") or current:IsA("Model")) and isPickupable(current) then
			return current
		end

		current = current.Parent
	end

	return nil
end

local function getRootPart(container: Instance): BasePart?
	if container:IsA("BasePart") then
		return container
	end

	if container:IsA("Model") then
		return container.PrimaryPart or container:FindFirstChildWhichIsA("BasePart", true)
	end

	return nil
end

local function getParts(container: Instance): { BasePart }
	if container:IsA("BasePart") then
		return { container }
	end

	local parts = {}

	if container:IsA("Model") then
		for _, descendant in ipairs(container:GetDescendants()) do
			if descendant:IsA("BasePart") then
				table.insert(parts, descendant)
			end
		end
	end

	return parts
end

local function getCollisionRadius(container: Instance): number
	local size = Vector3.new(1, 1, 1)

	if container:IsA("BasePart") then
		size = container.Size
	elseif container:IsA("Model") then
		local _, extents = container:GetBoundingBox()
		size = extents
	end

	return math.clamp(math.max(size.X, size.Y, size.Z) * 0.5 + 0.15, 0.6, 5)
end

local function markDefaultTestObject()
	local testObject = workspace:FindFirstChild(CONFIG.DEFAULT_TEST_NAME, true)
	if not testObject or not (testObject:IsA("BasePart") or testObject:IsA("Model")) then
		return
	end

	setDefaultAttribute(testObject, "Pickupable", true)
	setDefaultAttribute(testObject, "PickupWeight", CONFIG.DEFAULT_WEIGHT)
	setDefaultAttribute(testObject, "PickupHoldDistance", CONFIG.DEFAULT_HOLD_DISTANCE)

	if not CollectionService:HasTag(testObject, CONFIG.PICKUP_TAG) then
		CollectionService:AddTag(testObject, CONFIG.PICKUP_TAG)
	end
end

markDefaultTestObject()

workspace.DescendantAdded:Connect(function(instance)
	if instance.Name == CONFIG.DEFAULT_TEST_NAME then
		task.defer(markDefaultTestObject)
	end
end)

local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function getCharacterParts(character: Model?): { BasePart }
	local parts = {}

	if not character then
		return parts
	end

	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end

	return parts
end

local function getHeadPosition(player: Player, characterRoot: BasePart): Vector3
	local character = player.Character
	local head = character and character:FindFirstChild("Head")

	if head and head:IsA("BasePart") then
		return head.Position
	end

	return characterRoot.Position + Vector3.new(0, 1.6, 0)
end

local function cleanupPlayer(player: Player, notifyClient: boolean?)
	local state = heldByPlayer[player]
	if not state then
		return
	end

	heldByPlayer[player] = nil

	if state.container then
		heldByObject[state.container] = nil
	end

	destroyAll(state.cleanup)

	for _, saved in ipairs(state.savedParts) do
		local part = saved.part

		if part and part.Parent then
			part.Anchored = saved.anchored
			part.CanCollide = saved.canCollide
			safeSetNetworkOwner(part, saved.networkOwner)
		end
	end

	if state.targetPart and state.targetPart.Parent then
		state.targetPart:Destroy()
	end

	if notifyClient ~= false and player.Parent == Players then
		remote:FireClient(player, "Dropped")
	end
end

local function createPickupTarget(player: Player, startCFrame: CFrame): BasePart
	local targetPart = Instance.new("Part")
	targetPart.Name = string.format("PickupTarget_%d", player.UserId)
	targetPart.Size = Vector3.new(0.5, 0.5, 0.5)
	targetPart.Transparency = 1
	targetPart.Anchored = true
	targetPart.CanCollide = false
	targetPart.CanQuery = false
	targetPart.CanTouch = false
	targetPart.CFrame = startCFrame
	targetPart.Parent = targetFolder

	return targetPart
end

local function createPickupConstraints(
	rootPart: BasePart,
	targetPart: BasePart,
	weight: number,
	partCount: number
): { Instance }
	local cleanup = {}

	local rootAttachment = Instance.new("Attachment")
	rootAttachment.Name = "PickupRootAttachment"
	rootAttachment.Parent = rootPart
	table.insert(cleanup, rootAttachment)

	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "PickupTargetAttachment"
	targetAttachment.Parent = targetPart
	table.insert(cleanup, targetAttachment)

	local weightFactor = math.pow(weight, 0.45)
	local forceScale = math.max(1, partCount) * weight

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Name = "PickupSpringPosition"
	alignPosition.Mode = Enum.PositionAlignmentMode.TwoAttachment
	alignPosition.Attachment0 = rootAttachment
	alignPosition.Attachment1 = targetAttachment
	alignPosition.ApplyAtCenterOfMass = true
	alignPosition.RigidityEnabled = false
	alignPosition.Responsiveness = math.clamp(45 / weightFactor, 12, 60)
	alignPosition.MaxForce = math.clamp(65000 * forceScale, 15000, 2500000)
	alignPosition.MaxVelocity = math.clamp(150 / weightFactor, 24, 180)
	alignPosition.Parent = rootPart
	table.insert(cleanup, alignPosition)

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "PickupSpringOrientation"
	alignOrientation.Mode = Enum.OrientationAlignmentMode.TwoAttachment
	alignOrientation.Attachment0 = rootAttachment
	alignOrientation.Attachment1 = targetAttachment
	alignOrientation.RigidityEnabled = false
	alignOrientation.Responsiveness = math.clamp(18 / weightFactor, 3, 22)
	alignOrientation.MaxTorque = math.clamp(50000 * forceScale, 10000, 2000000)
	alignOrientation.MaxAngularVelocity = math.clamp(35 / weightFactor, 8, 45)
	alignOrientation.Parent = rootPart
	table.insert(cleanup, alignOrientation)

	return cleanup
end

local function preparePartsForPickup(
	player: Player,
	rootPart: BasePart,
	parts: { BasePart },
	characterParts: { BasePart }
): ({ Instance }, { SavedPart })
	local cleanup = {}
	local savedParts = {}

	for _, part in ipairs(parts) do
		table.insert(savedParts, {
			part = part,
			anchored = part.Anchored,
			canCollide = part.CanCollide,
			networkOwner = safeGetNetworkOwner(part),
		})

		part.Anchored = false
		part.CanCollide = true
		safeSetNetworkOwner(part, player)

		if part ~= rootPart then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "PickupTempWeld"
			weld.Part0 = rootPart
			weld.Part1 = part
			weld.Parent = rootPart
			table.insert(cleanup, weld)
		end

		for _, characterPart in ipairs(characterParts) do
			local noCollision = Instance.new("NoCollisionConstraint")
			noCollision.Name = "PickupNoPlayerPush"
			noCollision.Part0 = part
			noCollision.Part1 = characterPart
			noCollision.Parent = part
			table.insert(cleanup, noCollision)
		end
	end

	return cleanup, savedParts
end

local function tryPickup(player: Player, requestedInstance: any)
	debugSet("PickupServerLastReject", "")

	if heldByPlayer[player] then
		rejectPickup("player was already holding; dropped instead")
		cleanupPlayer(player)
		return
	end

	if typeof(requestedInstance) ~= "Instance" or not requestedInstance:IsDescendantOf(workspace) then
		rejectPickup("requested instance invalid")
		return
	end

	local container = getPickupContainer(requestedInstance)
	if not container then
		rejectPickup("instance is not pickupable")
		return
	end

	if heldByObject[container] then
		rejectPickup("object already held")
		return
	end

	local rootPart = getRootPart(container)
	if not rootPart then
		rejectPickup("no root part")
		return
	end

	local characterRoot = getCharacterRoot(player)
	if not characterRoot then
		rejectPickup("no character root")
		return
	end

	if (characterRoot.Position - rootPart.Position).Magnitude > CONFIG.MAX_PICKUP_DISTANCE then
		rejectPickup("too far away")
		return
	end

	local parts = getParts(container)
	if #parts == 0 then
		rejectPickup("no parts")
		return
	end

	local weight = getNumberAttribute(container, "PickupWeight", CONFIG.DEFAULT_WEIGHT, 0.1, 250)
	local holdDistance = getNumberAttribute(
		container,
		"PickupHoldDistance",
		CONFIG.DEFAULT_HOLD_DISTANCE,
		CONFIG.MIN_HOLD_DISTANCE,
		CONFIG.MAX_ATTRIBUTE_HOLD_DISTANCE
	)

	local characterParts = getCharacterParts(player.Character)
	local cleanup, savedParts = preparePartsForPickup(player, rootPart, parts, characterParts)

	local targetPart = createPickupTarget(player, rootPart.CFrame)
	local constraintCleanup = createPickupConstraints(rootPart, targetPart, weight, #parts)

	for _, instance in ipairs(constraintCleanup) do
		table.insert(cleanup, instance)
	end

	heldByPlayer[player] = {
		container = container,
		rootPart = rootPart,
		targetPart = targetPart,
		cleanup = cleanup,
		savedParts = savedParts,
		lastUpdate = os.clock(),
		collisionRadius = getCollisionRadius(container),
	}

	heldByObject[container] = player
	debugSet("PickupServerLastPicked", container:GetFullName())

	remote:FireClient(player, "Picked", container, rootPart, weight, holdDistance)
end

local function makeHoldRaycastParams(player: Player, state: PickupState): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	pcall(function()
		params.RespectCanCollide = true
	end)

	local filter = {}

	if player.Character then
		table.insert(filter, player.Character)
	end

	if state.container then
		table.insert(filter, state.container)
	end

	if state.targetPart then
		table.insert(filter, state.targetPart)
	end

	params.FilterDescendantsInstances = filter

	return params
end

local function keepCFrameAwayFromHead(
	player: Player,
	state: PickupState,
	requestedCFrame: CFrame,
	characterRoot: BasePart
): CFrame
	local rotationOnly = requestedCFrame - requestedCFrame.Position
	local headPosition = getHeadPosition(player, characterRoot)
	local offset = requestedCFrame.Position - headPosition
	local minDistance = state.collisionRadius + CONFIG.HEAD_CLEARANCE

	if offset.Magnitude >= minDistance then
		return requestedCFrame
	end

	local direction = if offset.Magnitude > 0.05 then offset.Unit else characterRoot.CFrame.LookVector
	return CFrame.new(headPosition + direction * minDistance) * rotationOnly
end

local function clampTargetCFrame(
	player: Player,
	state: PickupState,
	requestedCFrame: CFrame,
	characterRoot: BasePart
): CFrame
	requestedCFrame = keepCFrameAwayFromHead(player, state, requestedCFrame, characterRoot)

	local rotationOnly = requestedCFrame - requestedCFrame.Position
	local origin = getHeadPosition(player, characterRoot)
	local offset = requestedCFrame.Position - origin
	local distance = offset.Magnitude

	if distance <= 0.05 then
		return requestedCFrame
	end

	local direction = offset.Unit
	local radius = state.collisionRadius
	local params = makeHoldRaycastParams(player, state)
	local result = workspace:Raycast(origin, direction * (distance + radius), params)

	if result and result.Distance <= distance + radius then
		local safeDistance = math.max(2, result.Distance - radius - 0.1)
		local clampedPosition = origin + direction * math.min(distance, safeDistance)
		local clampedCFrame = CFrame.new(clampedPosition) * rotationOnly

		return keepCFrameAwayFromHead(player, state, clampedCFrame, characterRoot)
	end

	return keepCFrameAwayFromHead(player, state, requestedCFrame, characterRoot)
end

local function updateTarget(player: Player, requestedCFrame: any)
	local state = heldByPlayer[player]

	if not state or typeof(requestedCFrame) ~= "CFrame" then
		return
	end

	if not state.targetPart or not state.targetPart.Parent then
		cleanupPlayer(player)
		return
	end

	local characterRoot = getCharacterRoot(player)
	if not characterRoot then
		cleanupPlayer(player)
		return
	end

	local offset = requestedCFrame.Position - characterRoot.Position
	local rotationOnly = requestedCFrame - requestedCFrame.Position

	if offset.Magnitude > CONFIG.MAX_HOLD_DISTANCE then
		local direction = if offset.Magnitude > 0.05 then offset.Unit else characterRoot.CFrame.LookVector
		requestedCFrame = CFrame.new(characterRoot.Position + direction * CONFIG.MAX_HOLD_DISTANCE) * rotationOnly
	end

	state.targetPart.CFrame = clampTargetCFrame(player, state, requestedCFrame, characterRoot)
	state.lastUpdate = os.clock()
end

remote:SetAttribute("PickupServerReady", true)

remote.OnServerEvent:Connect(function(player: Player, action: any, payload: any)
	debugSet("PickupServerLastAction", tostring(action))

	if action == "Pickup" then
		tryPickup(player, payload)
	elseif action == "Drop" then
		cleanupPlayer(player)
	elseif action == "Update" then
		updateTarget(player, payload)
	else
		debugSet("PickupServerLastReject", "unknown action")
	end
end)

local function bindPlayer(player: Player)
	player.CharacterRemoving:Connect(function()
		cleanupPlayer(player)
	end)
end

for _, player in ipairs(Players:GetPlayers()) do
	bindPlayer(player)
end

Players.PlayerAdded:Connect(bindPlayer)

Players.PlayerRemoving:Connect(function(player)
	cleanupPlayer(player, false)
end)

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	local releaseList = {}

	for player, state in pairs(heldByPlayer) do
		local characterRoot = getCharacterRoot(player)

		if not characterRoot then
			table.insert(releaseList, player)
		elseif not state.rootPart or not state.rootPart.Parent then
			table.insert(releaseList, player)
		elseif now - state.lastUpdate > CONFIG.UPDATE_TIMEOUT then
			table.insert(releaseList, player)
		elseif (characterRoot.Position - state.rootPart.Position).Magnitude > CONFIG.MAX_HOLD_DISTANCE + 10 then
			table.insert(releaseList, player)
		end
	end

	for _, player in ipairs(releaseList) do
		cleanupPlayer(player)
	end
end)
