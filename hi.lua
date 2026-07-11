-- Connected Discord-GitHub
-- Roblox users: KlaasVHS, KlaasVHSDEV
-- Discord user: hond0967

-- Get Roblox services used by this server script
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

-- Main settings for the pickup system
local CONFIG = {
	-- Name of the RemoteEvent used for client-server communication
	REMOTE_NAME = "PickupRemote",

	-- Tag used to mark objects as pickupable
	PICKUP_TAG = "Pickupable",

	-- Default test object name that will automatically be made pickupable
	DEFAULT_TEST_NAME = "testpak",

	-- Default object weight
	DEFAULT_WEIGHT = 1,

	-- Default distance the object is held from the player
	DEFAULT_HOLD_DISTANCE = 8,

	-- Minimum hold distance allowed
	MIN_HOLD_DISTANCE = 4,

	-- Maximum hold distance allowed through object attributes
	MAX_ATTRIBUTE_HOLD_DISTANCE = 15,

	-- Maximum distance from which a player can pick up an object
	MAX_PICKUP_DISTANCE = 18,

	-- Maximum distance an object can be held away from the player
	MAX_HOLD_DISTANCE = 24,

	-- If the client stops sending updates for this long, the object is dropped
	UPDATE_TIMEOUT = 0.9,

	-- Extra space to keep objects away from the player's head
	HEAD_CLEARANCE = 2.25,

	-- When true, debug information is stored as attributes on the RemoteEvent
	DEBUG = false,
}

-- Find the RemoteEvent in ReplicatedStorage
local remote = ReplicatedStorage:FindFirstChild(CONFIG.REMOTE_NAME)

-- If the RemoteEvent does not exist, create it
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = CONFIG.REMOTE_NAME
	remote.Parent = ReplicatedStorage
end

-- Find the folder that stores invisible target parts
local targetFolder = workspace:FindFirstChild("PickupTargets")

-- If the folder does not exist, create it
if not targetFolder then
	targetFolder = Instance.new("Folder")
	targetFolder.Name = "PickupTargets"
	targetFolder.Parent = workspace
end

-- Stores the original settings of a part before it gets picked up
type SavedPart = {
	part: BasePart,
	anchored: boolean,
	canCollide: boolean,
	networkOwner: Player?,
}

-- Stores all data about an object currently being held
type PickupState = {
	container: Instance,
	rootPart: BasePart,
	targetPart: BasePart,
	cleanup: { Instance },
	savedParts: { SavedPart },
	lastUpdate: number,
	collisionRadius: number,
}

-- Keeps track of which player is holding which object
local heldByPlayer: { [Player]: PickupState } = {}

-- Keeps track of which object is already being held
local heldByObject: { [Instance]: Player } = {}

-- Sets debug attributes only when DEBUG is enabled
local function debugSet(attributeName: string, value: any)
	if CONFIG.DEBUG then
		remote:SetAttribute(attributeName, value)
	end
end

-- Stores the reason why a pickup was rejected
local function rejectPickup(reason: string)
	debugSet("PickupServerLastReject", reason)
end

-- Gets a number attribute safely
-- If the attribute is missing or not a number, it returns the default value
-- The value is clamped between minValue and maxValue
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

-- Sets a default attribute only if the attribute does not already exist
local function setDefaultAttribute(instance: Instance, name: string, value: any)
	if instance:GetAttribute(name) == nil then
		instance:SetAttribute(name, value)
	end
end

-- Safely gets the network owner of a part
-- pcall prevents the script from crashing if Roblox throws an error
local function safeGetNetworkOwner(part: BasePart): Player?
	local owner: Player? = nil

	pcall(function()
		owner = part:GetNetworkOwner()
	end)

	return owner
end

-- Safely sets the network owner of a part
local function safeSetNetworkOwner(part: BasePart, owner: Player?)
	pcall(function()
		part:SetNetworkOwner(owner)
	end)
end

-- Destroys all temporary instances in a list
local function destroyAll(instances: { Instance })
	for _, instance in ipairs(instances) do
		if instance and instance.Parent then
			instance:Destroy()
		end
	end
end

-- Checks if an object can be picked up
-- An object is pickupable if it has:
-- 1. Attribute Pickupable = true
-- OR
-- 2. The CollectionService tag "Pickupable"
local function isPickupable(instance: Instance): boolean
	return instance:GetAttribute("Pickupable") == true
		or CollectionService:HasTag(instance, CONFIG.PICKUP_TAG)
end

-- Finds the actual pickup container
-- This allows clicking a part inside a model and still picking up the full model
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

-- Gets the root part of the pickup object
-- If the object is a BasePart, that part is the root
-- If the object is a Model, it uses PrimaryPart or the first BasePart found
local function getRootPart(container: Instance): BasePart?
	if container:IsA("BasePart") then
		return container
	end

	if container:IsA("Model") then
		return container.PrimaryPart or container:FindFirstChildWhichIsA("BasePart", true)
	end

	return nil
end

-- Gets all BaseParts inside the pickup object
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

-- Calculates an estimated collision radius for the object
-- This is used to stop the object from clipping through walls or the player's head
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

-- Automatically makes the default test object pickupable
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

-- Try to mark the test object when the script starts
markDefaultTestObject()

-- If a new object named "testpak" is added later, mark it as pickupable too
workspace.DescendantAdded:Connect(function(instance)
	if instance.Name == CONFIG.DEFAULT_TEST_NAME then
		task.defer(markDefaultTestObject)
	end
end)

-- Gets the HumanoidRootPart of the player's character
local function getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Gets all BaseParts inside the player's character
-- These are used to prevent the held object from pushing the player
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

-- Gets the player's head position
-- If the Head part is missing, it uses a fallback position above the HumanoidRootPart
local function getHeadPosition(player: Player, characterRoot: BasePart): Vector3
	local character = player.Character
	local head = character and character:FindFirstChild("Head")

	if head and head:IsA("BasePart") then
		return head.Position
	end

	return characterRoot.Position + Vector3.new(0, 1.6, 0)
end

-- Drops the object held by a player and restores all original settings
local function cleanupPlayer(player: Player, notifyClient: boolean?)
	local state = heldByPlayer[player]
	if not state then
		return
	end

	-- Remove player from the holding table
	heldByPlayer[player] = nil

	-- Mark the object as no longer held
	if state.container then
		heldByObject[state.container] = nil
	end

	-- Destroy temporary constraints, attachments, welds, etc.
	destroyAll(state.cleanup)

	-- Restore every part to its original settings
	for _, saved in ipairs(state.savedParts) do
		local part = saved.part

		if part and part.Parent then
			part.Anchored = saved.anchored
			part.CanCollide = saved.canCollide
			safeSetNetworkOwner(part, saved.networkOwner)
		end
	end

	-- Destroy the invisible target part
	if state.targetPart and state.targetPart.Parent then
		state.targetPart:Destroy()
	end

	-- Tell the client the object was dropped
	if notifyClient ~= false and player.Parent == Players then
		remote:FireClient(player, "Dropped")
	end
end

-- Creates an invisible anchored target part
-- The held object will move toward this target part
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

-- Creates the AlignPosition and AlignOrientation constraints
-- These constraints pull the object toward the invisible target part
local function createPickupConstraints(
	rootPart: BasePart,
	targetPart: BasePart,
	weight: number,
	partCount: number
): { Instance }
	local cleanup = {}

	-- Attachment on the real object
	local rootAttachment = Instance.new("Attachment")
	rootAttachment.Name = "PickupRootAttachment"
	rootAttachment.Parent = rootPart
	table.insert(cleanup, rootAttachment)

	-- Attachment on the invisible target part
	local targetAttachment = Instance.new("Attachment")
	targetAttachment.Name = "PickupTargetAttachment"
	targetAttachment.Parent = targetPart
	table.insert(cleanup, targetAttachment)

	-- Heavier objects move more slowly and need more force
	local weightFactor = math.pow(weight, 0.45)
	local forceScale = math.max(1, partCount) * weight

	-- Controls the position movement of the object
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

	-- Controls the rotation movement of the object
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

-- Prepares all object parts for pickup
-- It saves original settings, unanchors parts, sets collision, assigns network owner,
-- welds model parts together, and prevents collision with the player
local function preparePartsForPickup(
	player: Player,
	rootPart: BasePart,
	parts: { BasePart },
	characterParts: { BasePart }
): ({ Instance }, { SavedPart })
	local cleanup = {}
	local savedParts = {}

	for _, part in ipairs(parts) do
		-- Save original settings so they can be restored later
		table.insert(savedParts, {
			part = part,
			anchored = part.Anchored,
			canCollide = part.CanCollide,
			networkOwner = safeGetNetworkOwner(part),
		})

		-- Make the part movable
		part.Anchored = false
		part.CanCollide = true

		-- Give network ownership to the player for smoother physics
		safeSetNetworkOwner(part, player)

		-- If this is not the root part, weld it to the root part
		if part ~= rootPart then
			local weld = Instance.new("WeldConstraint")
			weld.Name = "PickupTempWeld"
			weld.Part0 = rootPart
			weld.Part1 = part
			weld.Parent = rootPart
			table.insert(cleanup, weld)
		end

		-- Prevent the held object from colliding with the player's character
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

-- Tries to pick up an object for a player
local function tryPickup(player: Player, requestedInstance: any)
	debugSet("PickupServerLastReject", "")

	-- If the player is already holding something, drop it instead
	if heldByPlayer[player] then
		rejectPickup("player was already holding; dropped instead")
		cleanupPlayer(player)
		return
	end

	-- Make sure the requested object is a valid Instance inside workspace
	if typeof(requestedInstance) ~= "Instance" or not requestedInstance:IsDescendantOf(workspace) then
		rejectPickup("requested instance invalid")
		return
	end

	-- Find the actual pickup object
	local container = getPickupContainer(requestedInstance)
	if not container then
		rejectPickup("instance is not pickupable")
		return
	end

	-- Prevent two players from holding the same object
	if heldByObject[container] then
		rejectPickup("object already held")
		return
	end

	-- Get the main part of the object
	local rootPart = getRootPart(container)
	if not rootPart then
		rejectPickup("no root part")
		return
	end

	-- Get the player's HumanoidRootPart
	local characterRoot = getCharacterRoot(player)
	if not characterRoot then
		rejectPickup("no character root")
		return
	end

	-- Reject pickup if the object is too far away
	if (characterRoot.Position - rootPart.Position).Magnitude > CONFIG.MAX_PICKUP_DISTANCE then
		rejectPickup("too far away")
		return
	end

	-- Get all parts of the object
	local parts = getParts(container)
	if #parts == 0 then
		rejectPickup("no parts")
		return
	end

	-- Get object weight from attribute or use default
	local weight = getNumberAttribute(container, "PickupWeight", CONFIG.DEFAULT_WEIGHT, 0.1, 250)

	-- Get hold distance from attribute or use default
	local holdDistance = getNumberAttribute(
		container,
		"PickupHoldDistance",
		CONFIG.DEFAULT_HOLD_DISTANCE,
		CONFIG.MIN_HOLD_DISTANCE,
		CONFIG.MAX_ATTRIBUTE_HOLD_DISTANCE
	)

	-- Get player character parts for collision prevention
	local characterParts = getCharacterParts(player.Character)

	-- Prepare object parts for pickup
	local cleanup, savedParts = preparePartsForPickup(player, rootPart, parts, characterParts)

	-- Create invisible target part
	local targetPart = createPickupTarget(player, rootPart.CFrame)

	-- Create movement constraints
	local constraintCleanup = createPickupConstraints(rootPart, targetPart, weight, #parts)

	-- Add created constraints to cleanup list
	for _, instance in ipairs(constraintCleanup) do
		table.insert(cleanup, instance)
	end

	-- Save the full pickup state
	heldByPlayer[player] = {
		container = container,
		rootPart = rootPart,
		targetPart = targetPart,
		cleanup = cleanup,
		savedParts = savedParts,
		lastUpdate = os.clock(),
		collisionRadius = getCollisionRadius(container),
	}

	-- Mark object as being held
	heldByObject[container] = player

	-- Debug info
	debugSet("PickupServerLastPicked", container:GetFullName())

	-- Tell the client the pickup succeeded
	remote:FireClient(player, "Picked", container, rootPart, weight, holdDistance)
end

-- Creates RaycastParams for checking if the held object would hit something
local function makeHoldRaycastParams(player: Player, state: PickupState): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	-- RespectCanCollide may not exist in every environment, so it is wrapped in pcall
	pcall(function()
		params.RespectCanCollide = true
	end)

	local filter = {}

	-- Ignore the player's own character
	if player.Character then
		table.insert(filter, player.Character)
	end

	-- Ignore the held object itself
	if state.container then
		table.insert(filter, state.container)
	end

	-- Ignore the invisible target part
	if state.targetPart then
		table.insert(filter, state.targetPart)
	end

	params.FilterDescendantsInstances = filter

	return params
end

-- Keeps the target position away from the player's head
local function keepCFrameAwayFromHead(
	player: Player,
	state: PickupState,
	requestedCFrame: CFrame,
	characterRoot: BasePart
): CFrame
	-- Keep only the rotation part of the requested CFrame
	local rotationOnly = requestedCFrame - requestedCFrame.Position

	-- Get the head position
	local headPosition = getHeadPosition(player, characterRoot)

	-- Distance from the head to the requested position
	local offset = requestedCFrame.Position - headPosition

	-- Minimum safe distance from the head
	local minDistance = state.collisionRadius + CONFIG.HEAD_CLEARANCE

	-- If the object is already far enough from the head, keep the requested CFrame
	if offset.Magnitude >= minDistance then
		return requestedCFrame
	end

	-- Otherwise push the object away from the head
	local direction = if offset.Magnitude > 0.05 then offset.Unit else characterRoot.CFrame.LookVector
	return CFrame.new(headPosition + direction * minDistance) * rotationOnly
end

-- Clamps the target CFrame so the object does not go through walls or too close to the head
local function clampTargetCFrame(
	player: Player,
	state: PickupState,
	requestedCFrame: CFrame,
	characterRoot: BasePart
): CFrame
	-- First keep it away from the player's head
	requestedCFrame = keepCFrameAwayFromHead(player, state, requestedCFrame, characterRoot)

	local rotationOnly = requestedCFrame - requestedCFrame.Position
	local origin = getHeadPosition(player, characterRoot)
	local offset = requestedCFrame.Position - origin
	local distance = offset.Magnitude

	-- If the target is extremely close, keep it as-is
	if distance <= 0.05 then
		return requestedCFrame
	end

	local direction = offset.Unit
	local radius = state.collisionRadius
	local params = makeHoldRaycastParams(player, state)

	-- Raycast from the player's head toward the requested position
	local result = workspace:Raycast(origin, direction * (distance + radius), params)

	-- If something is in the way, move the target in front of the obstacle
	if result and result.Distance <= distance + radius then
		local safeDistance = math.max(2, result.Distance - radius - 0.1)
		local clampedPosition = origin + direction * math.min(distance, safeDistance)
		local clampedCFrame = CFrame.new(clampedPosition) * rotationOnly

		return keepCFrameAwayFromHead(player, state, clampedCFrame, characterRoot)
	end

	-- If nothing blocks the path, use the requested position
	return keepCFrameAwayFromHead(player, state, requestedCFrame, characterRoot)
end

-- Updates the invisible target part position
-- The client sends a CFrame, and the server validates/clamps it
local function updateTarget(player: Player, requestedCFrame: any)
	local state = heldByPlayer[player]

	-- Ignore invalid updates
	if not state or typeof(requestedCFrame) ~= "CFrame" then
		return
	end

	-- If the target part is missing, drop the object
	if not state.targetPart or not state.targetPart.Parent then
		cleanupPlayer(player)
		return
	end

	-- If the player has no character root, drop the object
	local characterRoot = getCharacterRoot(player)
	if not characterRoot then
		cleanupPlayer(player)
		return
	end

	local offset = requestedCFrame.Position - characterRoot.Position
	local rotationOnly = requestedCFrame - requestedCFrame.Position

	-- If the requested position is too far away, clamp it to the max hold distance
	if offset.Magnitude > CONFIG.MAX_HOLD_DISTANCE then
		local direction = if offset.Magnitude > 0.05 then offset.Unit else characterRoot.CFrame.LookVector
		requestedCFrame = CFrame.new(characterRoot.Position + direction * CONFIG.MAX_HOLD_DISTANCE) * rotationOnly
	end

	-- Move the invisible target part to the safe clamped CFrame
	state.targetPart.CFrame = clampTargetCFrame(player, state, requestedCFrame, characterRoot)

	-- Update the last time the server received a valid update
	state.lastUpdate = os.clock()
end

-- Mark the pickup server as ready
remote:SetAttribute("PickupServerReady", true)

-- Listen for actions sent from the client
remote.OnServerEvent:Connect(function(player: Player, action: any, payload: any)
	debugSet("PickupServerLastAction", tostring(action))

	if action == "Pickup" then
		-- Client wants to pick up an object
		tryPickup(player, payload)
	elseif action == "Drop" then
		-- Client wants to drop the object
		cleanupPlayer(player)
	elseif action == "Update" then
		-- Client is updating the held object's target position
		updateTarget(player, payload)
	else
		-- Unknown action
		debugSet("PickupServerLastReject", "unknown action")
	end
end)

-- Connect cleanup behavior for a player
local function bindPlayer(player: Player)
	player.CharacterRemoving:Connect(function()
		cleanupPlayer(player)
	end)
end

-- Bind all players already in the game
for _, player in ipairs(Players:GetPlayers()) do
	bindPlayer(player)
end

-- Bind players who join later
Players.PlayerAdded:Connect(bindPlayer)

-- Clean up when a player leaves the game
Players.PlayerRemoving:Connect(function(player)
	cleanupPlayer(player, false)
end)

-- Runs every heartbeat to check if held objects should be released
RunService.Heartbeat:Connect(function()
	local now = os.clock()
	local releaseList = {}

	for player, state in pairs(heldByPlayer) do
		local characterRoot = getCharacterRoot(player)

		-- Drop if the player has no character root
		if not characterRoot then
			table.insert(releaseList, player)

		-- Drop if the root part no longer exists
		elseif not state.rootPart or not state.rootPart.Parent then
			table.insert(releaseList, player)

		-- Drop if the client stopped sending updates
		elseif now - state.lastUpdate > CONFIG.UPDATE_TIMEOUT then
			table.insert(releaseList, player)

		-- Drop if the object gets too far away from the player
		elseif (characterRoot.Position - state.rootPart.Position).Magnitude > CONFIG.MAX_HOLD_DISTANCE + 10 then
			table.insert(releaseList, player)
		end
	end

	-- Drop all invalid held objects
	for _, player in ipairs(releaseList) do
		cleanupPlayer(player)
	end
end)
