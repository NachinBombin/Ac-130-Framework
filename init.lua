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

-- =============== GUNSHIP CONFIG =================----

-- Longer fire window so GAU can really run
ENT.FireDuration       = 3
ENT.RestDuration       = 3
ENT.WeaponPickInterval = 10

ENT.AimConeDegrees     = 10

-- GAU rake behavior
ENT.GAU_BurstSegment   = 1      -- seconds per straight line
ENT.GAU25_Delay        = 0.033
ENT.GAU25_Damage       = 15
ENT.GAU25_Force        = 4
ENT.GAU25_Spread       = Vector(0.0005, 0.0005, 0)

-- Muzzle offsets (relative to plane origin)
-- Move muzzle forward and slightly left so rounds appear near the nose
ENT.MuzzleForwardOffset = 250
ENT.MuzzleSideOffset    = -60   -- negative = left side (model-forward vs world-forward)

-- 40mm (faster cadence)
ENT.GUN40_Delay        = 0.5
ENT.GUN40_Velocity     = 1600

ENT.GUN105_Delay       = 6
ENT.GUN105_Velocity    = 1800

ENT.ShellClass         = "rpg_missile"

-- ===================================================

function ENT:Initialize()
	self.CenterPos     = self:GetVar("CenterPos", self:GetPos())
	self.CallDir       = self:GetVar("CallDir", Vector(1, 0, 0))
	self.Lifetime      = self:GetVar("Lifetime", 40)
	self.Speed         = self:GetVar("Speed", 300)
	self.OrbitRadius   = self:GetVar("OrbitRadius", 3000)
	self.SkyHeightAdd  = self:GetVar("SkyHeightAdd", 6000)

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

	self.sky           = ground + self.SkyHeightAdd
	self.DieTime       = CurTime() + self.Lifetime
	self.TurnDelay     = 0
	self.NextPassSound = CurTime() + math.Rand(3, 6)

	local spawnPos = self.CenterPos - self.CallDir * 2000
	spawnPos = Vector(spawnPos.x, spawnPos.y, self.sky)

	if not util.IsInWorld(spawnPos) then
		self:Debug("Primary spawnPos out of world, trying center fallback")
		spawnPos = Vector(self.CenterPos.x, self.CenterPos.y, self.sky)
	end

	if not util.IsInWorld(spawnPos) then
		self:Debug("Fallback spawnPos out of world too")
		self:Remove()
		return
	end

	self:SetModel("models/military2/air/air_130_l.mdl")
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
	self:SetPos(spawnPos)

	local ang = self.CallDir:Angle()
	self:SetAngles(Angle(0, ang.y - 90, 0))
	self.ang = self:GetAngles()

	self.PhysObj = self:GetPhysicsObject()
	if IsValid(self.PhysObj) then
		self.PhysObj:Wake()
		self.PhysObj:EnableGravity(false)
	end

	-- Background-style idle sound
	self.IdleLoop = CreateSound(game.GetWorld(), "ac-130_kill_sounds/AC130_idle_inside.mp3")
	if self.IdleLoop then
		self.IdleLoop:SetSoundLevel(60)
		self.IdleLoop:Play()
	end

	sound.Play(table.Random(PASS_SOUNDS), self.CenterPos, 75, 100, 0.7)
	self:Debug("Spawned at " .. tostring(spawnPos))

	-- Gunship state
	self.NextWeaponPickTime   = CurTime()
	self.CurrentWeapon        = nil
	self.FireWindowEnd        = 0
	self.NextShotTime         = 0
	self.NextFireCycleTime    = CurTime()
	self.Firing               = false

	-- GAU rake state
	self.GAU_CurrentDir       = nil
	self.GAU_BurstStartTime   = 0
	self.GAU_SegmentIndex     = 0
	self.GAU_FirstDir         = nil
end

function ENT:Think()
	if CurTime() >= self.DieTime then
		self:Remove()
		return
	end

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

	if ct >= self.NextShotTime then
		self:FireCurrentWeapon()
	end
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

-- Compute muzzle location based on model orientation
function ENT:GetMuzzlePos()
	local pos = self:GetPos()
	local ang = self:GetAngles()

	local forward = ang:Forward()
	local right   = ang:Right()

	local muzzle = pos
	muzzle = muzzle + forward * self.MuzzleForwardOffset
	muzzle = muzzle + right   * self.MuzzleSideOffset
	muzzle.z = self.sky

	return muzzle
end

function ENT:GetConeAimedDirection(baseConeDeg)
	local muzzlePos = self:GetMuzzlePos()

	local target = self:GetPrimaryTarget()
	local targetPos
	if IsValid(target) then
		targetPos = target:EyePos()
	else
		targetPos = Vector(self.CenterPos.x, self.CenterPos.y, self.CenterPos.z + 8)
	end

	local aimDir = targetPos - muzzlePos
	if aimDir:LengthSqr() <= 1 then
		aimDir = self:GetAngles():Forward()
	end
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

-- GAU lines: second segment walks off the first by yaw offset
function ENT:UpdateGAUDirectionIfNeeded()
	local ct = CurTime()
	local segmentDuration = self.GAU_BurstSegment

	local elapsed = ct - self.GAU_BurstStartTime
	local seg = math.floor(elapsed / segmentDuration)
	if seg > 2 then seg = 2 end

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
		if aimDir:LengthSqr() <= 1 then
			aimDir = self:GetAngles():Forward()
		end
		aimDir:Normalize()

		if seg == 0 or not self.GAU_FirstDir then
			-- First line: base rake
			local yawCone   = math.rad(4)
			local pitchCone = math.rad(10)

			local yaw   = math.Rand(-yawCone, yawCone)
			local pitch = math.Rand(-pitchCone, pitchCone)

			local ang = aimDir:Angle()
			ang:RotateAroundAxis(ang:Up(), yaw)
			ang:RotateAroundAxis(ang:Right(), pitch)

			self.GAU_FirstDir   = ang:Forward()
			self.GAU_FirstDir:Normalize()
			self.GAU_CurrentDir = self.GAU_FirstDir
		else
			-- Second/third segments: walk off first by small yaw
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

	local bullet = {}
	bullet.Src        = muzzlePos
	bullet.Dir        = self.GAU_CurrentDir
	bullet.Spread     = self.GAU25_Spread
	bullet.Num        = 1
	bullet.Damage     = self.GAU25_Damage
	bullet.Force      = self.GAU25_Force
	bullet.Tracer     = 1
	bullet.TracerName = "HelicopterTracer"

	self:FireBullets(bullet)
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
	if IsValid(phys) then
		phys:SetVelocity(dir * self.GUN40_Velocity)
	end

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
	if IsValid(phys) then
		phys:SetVelocity(dir * self.GUN105_Velocity)
	end

	sound.Play("killstreak_rewards/ac-130_105mm_fire.wav", self.CenterPos, 90, math.random(96, 104), 1.0)
end

function ENT:PhysicsUpdate(phys)
	if CurTime() >= self.DieTime then
		self:Remove()
		return
	end

	local pos = self:GetPos()
	self:SetPos(Vector(pos.x, pos.y, self.sky))
	self:SetAngles(self.ang)

	if IsValid(phys) then
		phys:SetVelocity(self:GetForward() * self.Speed)
	end

	local flatPos    = Vector(self.GetPos(self).x, self.GetPos(self).y, 0)
	local flatCenter = Vector(self.CenterPos.x, self.CenterPos.y, 0)
	local dist       = flatPos:Distance(flatCenter)

	if dist > self.OrbitRadius and self.TurnDelay < CurTime() then
		self.ang = self.ang + Angle(0, 0.1, 0)
		self.TurnDelay = CurTime() + 0.02
	end

	local tr = util.QuickTrace(self:GetPos(), self:GetForward() * 3000, self)
	if tr.HitSky then
		self.ang = self.ang + Angle(0, 0.3, 0)
	end

	if not self:IsInWorld() then
		self:Debug("Plane moved out of world")
		self:Remove()
	end
end

function ENT:OnRemove()
	if self.IdleLoop then
		self.IdleLoop:Stop()
	end
end

function ENT:FindGround(centerPos)
	local minheight = -16384
	local startPos  = Vector(centerPos.x, centerPos.y, centerPos.z + 64)
	local endPos    = Vector(centerPos.x, centerPos.y, minheight)
	local filterList = { self }

	local trace = {
		start  = startPos,
		endpos = endPos,
		filter = filterList
	}

	local maxNumber = 0
	local groundLocation = -1

	while maxNumber < 100 do
		local tr = util.TraceLine(trace)

		if tr.HitWorld then
			groundLocation = tr.HitPos.z
			break
		end

		if IsValid(tr.Entity) then
			table.insert(filterList, tr.Entity)
		else
			break
		end

		maxNumber = maxNumber + 1
	end

	return groundLocation
end
