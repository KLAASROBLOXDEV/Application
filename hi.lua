local RunService = game:GetService("RunService")
local Lighting = game.Lighting

local DayLengthMinutes = 0.5
local CurrentTime = 6
local TimeIncrement = 0

local WeatherTypes = {"Clear", "Sunny", "Rain", "Cloudy"}
local CurrentWeather = "Sunny"
local WeatherDuration = 1
local WeatherTimer = 0

local IsDay = true 

local RainPart = workspace:WaitForChild("RainEmitterPart")
local RainEmitter = RainPart:WaitForChild("RainEmitter")
local RainChance = 0.7
local RainIntensity = 100
local IsRaining = false
RainEmitter.Enabled = false
IsRaining = false

local DEBUG_ENABLED = true

local Seasons = {
	"Spring",
	"Summer",
	"Autumn",
	"Winter"
}
local CurrentSeason  = "Spring"
local SeasonDuration  = 1
local SeasonTimer = 0

local LOG_LEVELS = {
	INFO = "INFO",
	WARNING = "WARNING",
	ERROR = "ERROR"
}

local function log(message, level)
	if not DEBUG_ENABLED then
		return
	end
	
	level = level or LOG_LEVELS.INFO
	local timestamp = os.date("%H:%M:%S")
	
	print("[" .. timestamp .. "][" .. level .. "] " .. message)
end

local function Lerp(a, b, t)
	return a + (b - a) * t
end

local function SmoothDayNightTransition()
	if IsDay then
		Lighting.Brightness = Lerp(Lighting.Brightness, 2, 0.01)
	else
		Lighting.Brightness = Lerp(Lighting.Brightness, 0.3, 0.01)
	end
end

local function FormatTime(time)
	local hours = math.floor(time)
	local minutes = math.floor((time - hours) * 60)
	return string.format("%02d:%02d", hours, minutes)
end

local function RandomWeather()
	local roll = math.random()
	if roll < 0.5 then
		return "Sunny"
	elseif roll < 0.7 then
		return "Clear"
	elseif roll < 0.8 then
		return "Rain"
	else 
		return "Cloudy"
	end 
end

local function RainStart()
	if not IsRaining then
		IsRaining = true
		RainEmitter.Enabled = true
		RainEmitter.Rate = RainIntensity
		print("It is raining")
	end
end

local function RainStop()
	if IsRaining then
		IsRaining = false
		RainEmitter.Enabled = false
		print("It has stoppt raining")
	end
end

local function UpdateTime(dt)
	TimeIncrement = 24/ (DayLengthMinutes * 60) * dt
	CurrentTime = CurrentTime + TimeIncrement
	
	if CurrentTime >= 24 then 
		CurrentTime = CurrentTime - 24
	end
end

local function OnDayStart()
	print("Day has started at " .. FormatTime(CurrentTime))
end

local function OnNightStart()
	print("Night has started at " .. FormatTime(CurrentTime))
end

local function CheckDayNicht()
	if CurrentTime >= 6 and CurrentTime < 18 then 
		if not IsDay then
			IsDay = true
			OnDayStart()
		end
	else
		if IsDay then
			IsDay = false
			OnNightStart()
		end
	end
end

local function ApplyWeatherEffects()
	if CurrentWeather == "Rain" then
		RainStart()
	else
		RainStop()
	end
end

local function UpdateWeather(dt)
	WeatherTimer = WeatherTimer + dt
	
	if WeatherTimer >= WeatherDuration then
		WeatherTimer = 0
		CurrentWeather = RandomWeather()
		log("Weather changed to " .. CurrentWeather, LOG_LEVELS.INFO)
		
		ApplyWeatherEffects()
	end
end

local function ApplyLighting()
	if CurrentWeather == "Rain" then
		Lighting.FogEnd = Lerp(Lighting.FogEnd, 100, 0.05)
	elseif CurrentWeather == "Cloudy" then
		Lighting.FogEnd = Lerp(Lighting.FogEnd, 300, 0.05)
	elseif CurrentWeather == "Sunny" then
		Lighting.FogEnd = Lerp(Lighting.FogEnd, 500, 0.05)
	elseif CurrentWeather == "Clear" then
		Lighting.FogEnd = Lerp(Lighting.FogEnd, 500, 0.05)
	end
end

local function ApplySeasonSettings()
	if CurrentSeason == "Spring" then
		RainChance = 0.4
		DayLengthMinutes = 1
	elseif CurrentSeason == "Summer" then
		RainChance = 0.2
		DayLengthMinutes = 0.5
	elseif CurrentSeason == "Autumn" then
		RainChance = 0.5
		DayLengthMinutes = 1.5
	elseif CurrentSeason == "Winter" then
		RainChance = 0.7
		DayLengthMinutes = 2
	end
end

local function OnSeasonChanged(oldSeason, newSeason)
	log("Season changed from " .. oldSeason .. " ro " .. newSeason, LOG_LEVELS.INFO)
end

local function ChangeSeason()
local oldSeason = CurrentSeason

local currentindex = table.find(Seasons, CurrentSeason)
local netindex = currentindex + 1

if netindex > #Seasons then
	netindex = 1
end

CurrentSeason = Seasons[netindex]
ApplySeasonSettings()

OnSeasonChanged(oldSeason, CurrentSeason)
end

local function UpdateSeason(dt)
	SeasonTimer = SeasonTimer + dt
	
	if SeasonTimer >= SeasonDuration then
		SeasonTimer = 0
		ChangeSeason()
	end
end

local lasttime = tick()

ApplySeasonSettings()
ApplyWeatherEffects()

RunService.Heartbeat:Connect(function()
	local now = tick()
	local dt = now - lasttime
	lasttime = now
	
	UpdateTime(dt)
	UpdateWeather(dt)
	ApplyLighting()
	UpdateSeason(dt)
	SmoothDayNightTransition()
	CheckDayNicht()
end)
