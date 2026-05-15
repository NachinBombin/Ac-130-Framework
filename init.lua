AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local PASS_SOUNDS = {
	"killstreak_rewards/ac-130_105mm_fire.wav",
	"killstreak_rewards/ac-130_40mm_fire.wav",
	"killstreak_rewards/ac-130_25mm_fire.wav",
}

function ENT:Debug(msg)
	print("[Bombin Support Plane ENT] " .. msg)
end

-- =============== GUNSHIP CONFIG =====================

ENT.FireDuration       = 3
ENT.RestDuration       = 3
ENT.WeaponPickInterval = 10

ENT.AimConeDegrees     = 10

ENT.GAU_BurstSegment   = 1
ENT.GAU25_Delay        = 0.033
ENT.GAU25_Damage       = 15
ENT.GAU25_Force        = 4
ENT.GAU25_Spread       = Vector(0.0005, 0.0005, 0)

ENT.MuzzleForwardOffset = 250
ENT.MuzzleSideOffset    = -60

ENT.GUN40_Delay        = 0.5
ENT.GUN40_Velocity     = 1600

ENT.GUN105_Delay       = 6
ENT.GUN105_Velocity    = 1800

ENT.ShellClass         = "rpg_missile"

-- =============== OBSTACLE AVOIDANCE CONFIG ==========
-- Spawn-time radial probe (mirrors AN-71 ProbeOrbitRadius)
local OBS_PROBE_DIRS   = {}
for i = 0, 7 do
	local a = math.rad(i * 45)
	OBS_PROBE_DIRS[i + 1] = Vector(math.cos(a), math.sin(a), 0)
end
local OBS_PROBE_DIST   = 8192
local OBS_PROBE_MARGIN = 300

-- Runtime forward-cone avoidance
local FWD_PROBE_DIST   = 2500   -- how far ahead to check (HU)
local FWD_PROBE_ANGLES = { 0, 15, -15, 30, -30 }  -- degrees off forward
local AVOIDANCE_GAIN   = 1.8    -- how strongly to steer away
local AVOIDANCE_TURN   = 22     -- max extra yaw per second from avoidance (deg/s)

-- =============== ORBIT TUNING =======================
local ROLL_SUSTAINED_GAIN = 1.6
local ROLL_MAX            = 18.0
local ROLL_LERP_IN        = 0.06
local ROLL_LERP_OUT       = 0.010

-- =====================================================

local function ProbeOrbitRadius(centerPos, skyZ, requestedRadius)
	local origin  = Vector(centerPos.x, centerPos.y, skyZ)
	local minDist = OBS_PROBE_DIST
	for _, dir in ipairs(OBS_PROBE_DIRS) do
		local tr = util.TraceLine({
			start  = origin,
			endpos = origin + dir * OBS_PROBE_DIST,
			mask   = MASK_SOLID_BRUSHONLY,
		})
		if tr.Hit then
			local d = (tr.HitPos - origin):Length2D()
			if d < minDist then minDist = d end
		end
	end
	local safe = math.max(200, minDist - OBS_PROBE_MARGIN)
	if safe < requestedRadius then
		print(string.format("[AC-130] OrbitRadius capped %d -> %d (nearest wall %.0f HU)",
			requestedRadius, safe, minDist))
	end
	return math.min(requestedRadius, safe)
end

-- =====================================================

function ENT:Initialize()
	self.CenterPos    = self:GetVar("CenterPos", self:GetPos())
	self.CallDir      = self:GetVar("CallDir", Vector(1, 0, 0))
	self.Lifetime     = self:GetVar("Lifetime", 40)
	self.Speed        = self:GetVar("Speed", 300)
	self.OrbitRadius  = self:GetVar("OrbitRadius", 3000)
	self.SkyHeightAdd = self:GetVar("SkyHeightAdd", 6000)

	if self.CallDir:LengthSqr() <= 1 then
		self.CallDir = Vector(1, 0, 0)
	end
	self.CallDir.z = 0
	self.CallDir:Normalize()

	local ground = self:FindGround(self.CenterPos)
	if ground == -1 then
		self:Debug("FindGround failed")
		self:Remove()
		return
	end

	self.sky     = ground + self.SkyHeightAdd
	self.DieTime = CurTime() + self.Lifetime

	-- Probe geometry and cap orbit radius before spawning
	self.OrbitRadius = ProbeOrbitRadius(self.CenterPos, self.sky, self.OrbitRadius)

	self.NextPassSound = CurTime() + math.Rand(3, 6)

	local right   = Vector(-self.CallDir.y, self.CallDir.x, 0)
	local orbitDir = (math.random(2) == 1) and 1 or -1
	self.OrbitDirection = orbitDir

	local tangent = Vector(right.x * orbitDir, right.y * orbitDir, 0)
	tangent:Normalize()

	local spawnPos = self.CenterPos + tangent * (-self.OrbitRadius * math.Rand(0.55, 0.95))
	spawnPos = Vector(spawnPos.x, spawnPos.y, self.sky)

	if not util.IsInWorld(spawnPos) then
		self:Debug("Primary spawnPos OOB, using center fallback")
		spawnPos = Vector(self.CenterPos.x, self.CenterPos.y, self.sky)
	end
	if not util.IsInWorld(spawnPos) then
		self:Debug("Fallback spawnPos OOB too")
		self:Remove()
		return
	end

	self:SetModel("models/military2/air/air_130_l.mdl")
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
	self:SetPos(spawnPos)

	-- flightYaw: direction plane is currently heading
	self.flightYaw     = tangent:Angle().y
	self.PrevFlightYaw = self.flightYaw
	self.ang           = Angle(0, self.flightYaw, 0)

	-- Orbit controller params (mirrors AN-71)
	self.RadialGain    = 0.5
	self.MaxTurnRate   = 22     -- deg/s
	self.PrevTurnRate  = 0
	self.SmoothedRoll  = 0

	self:SetAngles(self.ang)

	self.PhysObj = self:GetPhysicsObject()
	if IsValid(self.PhysObj) then
		self.PhysObj:Wake()
		self.PhysObj:EnableGravity(false)
	end

	-- Background idle sound
	self.IdleLoop = CreateSound(game.GetWorld(), "ac-130_kill_sounds/AC130_idle_inside.mp3")
	if self.IdleLoop then
		self.IdleLoop:SetSoundLevel(60)
		self.IdleLoop:Play()
	end

	sound.Play(table.Random(PASS_SOUNDS), self.CenterPos, 75, 100, 0.7)
	self:Debug(string.format("Spawned at %s | OrbitRadius=%.0f | OrbitDir=%d",
		tostring(spawnPos), self.OrbitRadius, orbitDir))

	-- Gunship state
	self.NextWeaponPickTime   = CurTime()
	self.CurrentWeapon        = nil
	self.FireWindowEnd        = 0
	self.NextShotTime         = 0
	self.NextFireCycleTime    = CurTime()
	self.Firing               = false

	self.GAU_CurrentDir       = nil
	self.GAU_BurstStartTime   = 0
	self.GAU_SegmentIndex     = 0
	self.GAU_FirstDir         = nil
end

function ENT:Think()
	if CurTime() >= self.DieTime then self:Remove() return end

	if not IsValid(self.PhysObj) then
		self.PhysObj = self:GetPhysicsObject()
	end
	if IsValid(self.PhysObj) and self.PhysObj:IsAsleep() then
		self.PhysObj:Wake()
	end

	if CurTime() >= self.NextPassSound then
		sound.Play(table.Random(PASS_SOUNDS), self.CenterPos, 75, math.random(96, 104), 0.7)
		self.NextPassSound = CurTime() + math.Rand(4, 7)
	end

	self:HandleGunshipFiring()

	self:NextThink(CurTime())
	return true
end

-- =====================================================
-- OBSTACLE AVOIDANCE -- runtime forward cone probe
-- Returns an avoidance yaw delta (degrees) to blend into
-- the orbit controller.  0 = no obstacle detected.
-- =====================================================
function ENT:CalcAvoidanceYaw(pos, fwdYaw)
	local origin = pos
	local totalSteering = 0

	for _, offsetDeg in ipairs(FWD_PROBE_ANGLES) do
		local probeAng = Angle(0, fwdYaw + offsetDeg, 0)
		local probeDir = probeAng:Forward()
		probeDir.z = 0
		if probeDir:LengthSqr() < 0.001 then continue end
		probeDir:Normalize()

		local tr = util.TraceLine({
			start  = origin,
			endpos = origin + probeDir * FWD_PROBE_DIST,
			filter = self,
			mask   = MASK_SOLID_BRUSHONLY,
		})

		if tr.Hit then
			local hitDist = (tr.HitPos - origin):Length()
			-- Urgency increases as obstacle gets closer
			local urgency = 1 - (hitDist / FWD_PROBE_DIST)
			-- Steer away: negative offset -> steer right (+yaw), positive -> steer left (-yaw)
			local steer = -offsetDeg * urgency * AVOIDANCE_GAIN
			totalSteering = totalSteering + steer
		end
	end

	return math.Clamp(totalSteering, -AVOIDANCE_TURN, AVOIDANCE_TURN)
end

function ENT:PhysicsUpdate(phys)
	if not self.DieTime or not self.sky then return end
	if CurTime() >= self.DieTime then self:Remove() return end

	local pos = self:GetPos()
	local dt  = engine.TickInterval()

	-- ---- Orbit controller (AN-71 style) ----
	local flatPos    = Vector(pos.x, pos.y, 0)
	local flatCenter = Vector(self.CenterPos.x, self.CenterPos.y, 0)
	local toCenter   = flatCenter - flatPos
	local dist       = toCenter:Length()

	local radialDir = (dist > 1) and (toCenter / dist) or Vector(0, 0, 0)

	local tangentDir = Vector(
		-radialDir.y * self.OrbitDirection,
		 radialDir.x * self.OrbitDirection,
		0
	)
	if tangentDir:LengthSqr() < 0.001 then
		local fb = Angle(0, self.flightYaw, 0):Forward()
		tangentDir = Vector(fb.x, fb.y, 0)
	end
	tangentDir:Normalize()

	local radialError = 0
	if self.OrbitRadius > 0 then
		radialError = math.Clamp((dist - self.OrbitRadius) / self.OrbitRadius, -1, 1)
	end

	local desired2 = Vector(
		tangentDir.x + radialDir.x * radialError * self.RadialGain,
		tangentDir.y + radialDir.y * radialError * self.RadialGain,
		0
	)
	if desired2:LengthSqr() < 0.001 then desired2 = tangentDir end
	desired2:Normalize()

	local fwd3 = Angle(0, self.flightYaw, 0):Forward()
	local fwd2 = Vector(fwd3.x, fwd3.y, 0)
	fwd2:Normalize()

	local cross    = fwd2.x * desired2.y - fwd2.y * desired2.x
	local dot      = fwd2.x * desired2.x + fwd2.y * desired2.y
	local urgency  = math.max(0.15, (1 - dot) * 0.5)  -- floor at 0.15 to keep minimum authority
	local orbitTurn = math.Clamp(cross * urgency * self.MaxTurnRate * 2,
							   -self.MaxTurnRate, self.MaxTurnRate)

	-- ---- Runtime obstacle avoidance ----
	local avoidTurn = self:CalcAvoidanceYaw(pos, self.flightYaw)

	-- Blend: avoidance overrides orbit steering when significant
	local avoidWeight = math.Clamp(math.abs(avoidTurn) / AVOIDANCE_TURN, 0, 1)
	local turnRate = orbitTurn * (1 - avoidWeight * 0.8) + avoidTurn
	turnRate = math.Clamp(turnRate, -self.MaxTurnRate, self.MaxTurnRate)

	self.flightYaw = self.flightYaw + turnRate * dt

	-- ---- Roll (bank into turns) ----
	local turnRateDelta = turnRate - self.PrevTurnRate
	self.PrevTurnRate   = turnRate

	local sustained  = math.Clamp(turnRate * ROLL_SUSTAINED_GAIN, -ROLL_MAX, ROLL_MAX)
	local transient  = math.Clamp(turnRateDelta * 35.0, -10, 10)
	local rollTarget = math.Clamp(sustained + transient, -ROLL_MAX, ROLL_MAX)

	local building = (rollTarget * self.SmoothedRoll >= 0)
				   and (math.abs(rollTarget) > math.abs(self.SmoothedRoll))
	local lerpRate = building and ROLL_LERP_IN or ROLL_LERP_OUT
	self.SmoothedRoll = Lerp(lerpRate, self.SmoothedRoll, rollTarget)

	self.ang = Angle(0, self.flightYaw, self.SmoothedRoll)

	local fwdDir = Angle(0, self.flightYaw, 0):Forward()
	local newPos = pos + fwdDir * self.Speed * dt
	newPos.z     = self.sky

	-- OOB guard: steer toward center for this tick instead of removing
	if not util.IsInWorld(newPos) then
		self:Debug("OOB guard -- steering to center")
		local toC = flatCenter - Vector(pos.x, pos.y, 0)
		if toC:LengthSqr() < 0.001 then toC = Vector(-fwd2.x, -fwd2.y, 0) end
		toC:Normalize()
		local sCross = fwd2.x * toC.y - fwd2.y * toC.x
		self.flightYaw = self.flightYaw +
			math.Clamp(sCross * self.MaxTurnRate, -self.MaxTurnRate, self.MaxTurnRate) * dt
		self:SetPos(pos)
		self:SetAngles(Angle(0, self.flightYaw, self.SmoothedRoll))
		return
	end

	self:SetPos(newPos)
	self:SetAngles(self.ang)

	if IsValid(phys) then
		phys:SetVelocity(fwdDir * self.Speed)
	end
end

-- =====================================================
-- GUNSHIP FIRING
-- =====================================================

function ENT:HandleGunshipFiring()
	local ct = CurTime()

	if ct >= self.NextFireCycleTime then
		if not self.Firing then
			self.Firing        = true
			self.FireWindowEnd = ct + self.FireDuration

			if ct >= self.NextWeaponPickTime or not self.CurrentWeapon then
				self:PickRandomWeapon()
				self.NextWeaponPickTime = ct + self.WeaponPickInterval
			end

			self.NextShotTime       = ct
			self.GAU_CurrentDir     = nil
			self.GAU_FirstDir       = nil
			self.GAU_BurstStartTime = ct
			self.GAU_SegmentIndex   = 0
		else
			self.Firing            = false
			self.NextFireCycleTime = ct + self.RestDuration
		end
	end

	if not self.Firing or not self.CurrentWeapon then return end
	if ct > self.FireWindowEnd then return end
	if ct >= self.NextShotTime then self:FireCurrentWeapon() end
end

function ENT:PickRandomWeapon()
	local roll = math.random(1, 3)
	if roll == 1 then
		self.CurrentWeapon = "25mm"
	elseif roll == 2 then
		self.CurrentWeapon = "40mm"
	else
		self.CurrentWeapon = "105mm"
	end
	self:Debug("Picked weapon: " .. self.CurrentWeapon)
end

function ENT:GetPrimaryTarget()
	local closest, closestDist = nil, math.huge
	for _, ply in ipairs(player.GetAll()) do
		if not IsValid(ply) or not ply:Alive() then continue end
		local d = ply:GetPos():DistToSqr(self.CenterPos)
		if d < closestDist then
			closestDist = d
			closest = ply
		end
	end
	return closest
end

function ENT:GetMuzzlePos()
	local pos     = self:GetPos()
	local ang     = self:GetAngles()
	local forward = ang:Forward()
	local right   = ang:Right()
	local muzzle  = pos + forward * self.MuzzleForwardOffset + right * self.MuzzleSideOffset
	muzzle.z = self.sky
	return muzzle
end

function ENT:GetConeAimedDirection(baseConeDeg)
	local muzzlePos = self:GetMuzzlePos()
	local target    = self:GetPrimaryTarget()
	local targetPos
	if IsValid(target) then
		targetPos = target:EyePos()
	else
		targetPos = Vector(self.CenterPos.x, self.CenterPos.y, self.CenterPos.z + 8)
	end

	local aimDir = targetPos - muzzlePos
	if aimDir:LengthSqr() <= 1 then aimDir = self:GetAngles():Forward() end
	aimDir:Normalize()

	local cone  = math.rad(baseConeDeg)
	local yaw   = math.Rand(-cone, cone)
	local pitch = math.Rand(-cone * 0.5, cone * 0.5)

	local ang = aimDir:Angle()
	ang:RotateAroundAxis(ang:Up(), yaw)
	ang:RotateAroundAxis(ang:Right(), pitch)

	local dir = ang:Forward()
	dir:Normalize()
	return dir, muzzlePos
end

function ENT:UpdateGAUDirectionIfNeeded()
	local ct       = CurTime()
	local elapsed  = ct - self.GAU_BurstStartTime
	local seg      = math.min(math.floor(elapsed / self.GAU_BurstSegment), 2)

	if seg ~= self.GAU_SegmentIndex or not self.GAU_CurrentDir then
		self.GAU_SegmentIndex = seg
		local muzzlePos = self:GetMuzzlePos()
		local target = self:GetPrimaryTarget()
		local targetPos
		if IsValid(target) then
			targetPos = target:EyePos()
		else
			targetPos = Vector(self.CenterPos.x, self.CenterPos.y, self.CenterPos.z + 8)
		end

		local aimDir = targetPos - muzzlePos
		if aimDir:LengthSqr() <= 1 then aimDir = self:GetAngles():Forward() end
		aimDir:Normalize()

		if seg == 0 or not self.GAU_FirstDir then
			local ang = aimDir:Angle()
			ang:RotateAroundAxis(ang:Up(),    math.Rand(-math.rad(4), math.rad(4)))
			ang:RotateAroundAxis(ang:Right(), math.Rand(-math.rad(10), math.rad(10)))
			self.GAU_FirstDir   = ang:Forward()
			self.GAU_FirstDir:Normalize()
			self.GAU_CurrentDir = self.GAU_FirstDir
		else
			local baseAng = self.GAU_FirstDir:Angle()
			local sideSign = (math.random(0, 1) == 0) and -1 or 1
			baseAng:RotateAroundAxis(baseAng:Up(), math.rad(8 * sideSign))
			self.GAU_CurrentDir = baseAng:Forward()
			self.GAU_CurrentDir:Normalize()
		end
	end
end

function ENT:FireCurrentWeapon()
	local ct = CurTime()
	if self.CurrentWeapon == "25mm" then
		self:Fire25mm()
		self.NextShotTime = ct + self.GAU25_Delay
	elseif self.CurrentWeapon == "40mm" then
		self:Fire40mm()
		self.NextShotTime = ct + self.GUN40_Delay
	elseif self.CurrentWeapon == "105mm" then
		self:Fire105mm()
		self.NextShotTime = ct + self.GUN105_Delay
	end
end

function ENT:Fire25mm()
	self:UpdateGAUDirectionIfNeeded()
	if not self.GAU_CurrentDir then return end
	local muzzlePos = self:GetMuzzlePos()
	self:FireBullets({
		Src        = muzzlePos,
		Dir        = self.GAU_CurrentDir,
		Spread     = self.GAU25_Spread,
		Num        = 1,
		Damage     = self.GAU25_Damage,
		Force      = self.GAU25_Force,
		Tracer     = 1,
		TracerName = "HelicopterTracer",
	})
	sound.Play("killstreak_rewards/ac-130_25mm_fire.wav", self.CenterPos, 80, math.random(96, 104), 0.9)
end

function ENT:Fire40mm()
	local dir, muzzlePos = self:GetConeAimedDirection(self.AimConeDegrees)
	local shell = ents.Create(self.ShellClass)
	if not IsValid(shell) then return end
	shell:SetPos(muzzlePos)
	shell:SetAngles(dir:Angle())
	shell:SetOwner(self)
	shell:Spawn()
	shell:Activate()
	local phys = shell:GetPhysicsObject()
	if IsValid(phys) then phys:SetVelocity(dir * self.GUN40_Velocity) end
	sound.Play("killstreak_rewards/ac-130_40mm_fire.wav", self.CenterPos, 85, math.random(96, 104), 1.0)
end

function ENT:Fire105mm()
	local dir, muzzlePos = self:GetConeAimedDirection(self.AimConeDegrees)
	local shell = ents.Create(self.ShellClass)
	if not IsValid(shell) then return end
	shell:SetPos(muzzlePos)
	shell:SetAngles(dir:Angle())
	shell:SetOwner(self)
	shell:Spawn()
	shell:Activate()
	local phys = shell:GetPhysicsObject()
	if IsValid(phys) then phys:SetVelocity(dir * self.GUN105_Velocity) end
	sound.Play("killstreak_rewards/ac-130_105mm_fire.wav", self.CenterPos, 90, math.random(96, 104), 1.0)
end

function ENT:OnRemove()
	if self.IdleLoop then self.IdleLoop:Stop() end
end

function ENT:FindGround(centerPos)
	local startPos   = Vector(centerPos.x, centerPos.y, centerPos.z + 64)
	local endPos     = Vector(centerPos.x, centerPos.y, -16384)
	local filterList = { self }
	local maxNumber  = 0
	while maxNumber < 100 do
		local tr = util.TraceLine({ start = startPos, endpos = endPos, filter = filterList })
		if tr.HitWorld then return tr.HitPos.z end
		if IsValid(tr.Entity) then
			table.insert(filterList, tr.Entity)
		else
			break
		end
		maxNumber = maxNumber + 1
	end
	return -1
end
