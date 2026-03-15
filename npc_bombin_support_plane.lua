if SERVER then
	AddCSLuaFile()
	util.AddNetworkString("BombinSupportPlane_FlareSpawned")
-- Server-side only
if SERVER then
	-- Tunable overkill values
	local BOMBIN_RPG_DAMAGE = 250
	local BOMBIN_RPG_RADIUS = 420

	-- Tag shells spawned by the support plane
	hook.Add("OnEntityCreated", "BombinSupportPlane_TagRPG", function(ent)
		timer.Simple(0, function()
			if not IsValid(ent) then return end
			if ent:GetClass() ~= "rpg_missile" then return end

			local owner = ent:GetOwner()
			if not IsValid(owner) then return end
			-- Our plane entity
			if owner:GetClass() == "ent_bombin_support_plane" then
				ent.BombinSupportShell = true
			end
		end)
	end)

	-- Brutalize explosion damage for tagged RPGs
	hook.Add("EntityTakeDamage", "BombinSupportPlane_RPGDamage", function(target, dmginfo)
		local inflictor = dmginfo:GetInflictor()
		if not IsValid(inflictor) or inflictor:GetClass() ~= "rpg_missile" then return end
		if not inflictor.BombinSupportShell then return end

		-- Stronger direct hit
		dmginfo:SetDamage(BOMBIN_RPG_DAMAGE)
		dmginfo:SetDamageType(DMG_BLAST)
	end)

	-- Big splash on detonation
	hook.Add("OnEntityCreated", "BombinSupportPlane_RPGDetHook", function(ent)
		-- The valve RPG missile removes itself on explode; we want an explicit explosion
		if ent:GetClass() ~= "rpg_missile" then return end

		-- Wrap the default behavior once: when the missile is about to die, blast
		if ent.BombinSupportHooked then return end
		ent.BombinSupportHooked = true

		-- Use Think to watch for impact and remove
		ent.Think = function(self)
			if self.BombinSupportShell and self:GetVelocity():Length() < 50 then
				local pos = self:GetPos()
				local owner = self:GetOwner()
				util.BlastDamage(self, IsValid(owner) and owner or self, pos, BOMBIN_RPG_RADIUS, BOMBIN_RPG_DAMAGE)

				local eff = EffectData()
				eff:SetOrigin(pos)
				eff:SetScale(1)
				util.Effect("Explosion", eff, true, true)

				self:Remove()
				return
			end

			self:NextThink(CurTime())
			return true
		end
	end)
end


	local SHARED_FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY)

	local cv_enabled  = CreateConVar("npc_bombinplane_enabled", "1", SHARED_FLAGS, "Enable/disable support plane calls.")
	local cv_chance   = CreateConVar("npc_bombinplane_chance", "0.12", SHARED_FLAGS, "Probability per check.")
	local cv_interval = CreateConVar("npc_bombinplane_interval", "12", SHARED_FLAGS, "Check interval.")
	local cv_cooldown = CreateConVar("npc_bombinplane_cooldown", "50", SHARED_FLAGS, "Cooldown.")
	local cv_max_dist = CreateConVar("npc_bombinplane_max_dist", "3000", SHARED_FLAGS, "Max distance.")
	local cv_min_dist = CreateConVar("npc_bombinplane_min_dist", "400", SHARED_FLAGS, "Min distance.")
	local cv_delay    = CreateConVar("npc_bombinplane_delay", "5", SHARED_FLAGS, "Delay after flare before plane arrives.")
	local cv_life     = CreateConVar("npc_bombinplane_lifetime", "40", SHARED_FLAGS, "Plane lifetime.")
	local cv_speed    = CreateConVar("npc_bombinplane_speed", "300", SHARED_FLAGS, "Plane forward speed.")
	local cv_radius   = CreateConVar("npc_bombinplane_radius", "3000", SHARED_FLAGS, "Orbit radius.")
	local cv_height   = CreateConVar("npc_bombinplane_height", "6000", SHARED_FLAGS, "Height above detected ground.")
	local cv_announce = CreateConVar("npc_bombinplane_announce", "0", SHARED_FLAGS, "Debug prints.")

	local CALLERS = {
		["npc_combine_s"] = true,
		["npc_metropolice"] = true,
		["npc_combine_elite"] = true,
	}

	local function BSP_Debug(msg)
		if not cv_announce:GetBool() then return end

		local full = "[Bombin Support Plane] " .. msg
		print(full)

		for _, ply in ipairs(player.GetHumans()) do
			if IsValid(ply) then
				ply:PrintMessage(HUD_PRINTCONSOLE, full)
			end
		end
	end

	local function CheckSkyAbove(pos)
		local trace = util.TraceLine({
			start = pos + Vector(0, 0, 50),
			endpos = pos + Vector(0, 0, 1050),
		})

		if trace.Hit and not trace.HitSky then
			trace = util.TraceLine({
				start = trace.HitPos + Vector(0, 0, 50),
				endpos = trace.HitPos + Vector(0, 0, 1000),
			})
		end

		return not (trace.Hit and not trace.HitSky)
	end

	local function ThrowSupportFlare(npc, targetPos)
		local npcEyePos = npc:EyePos()
		local toTarget = (targetPos - npcEyePos):GetNormalized()

		local flare = ents.Create("ent_bombin_flare_blue")
		if not IsValid(flare) then
			BSP_Debug("Flare spawn failed: ent_bombin_flare_blue invalid")
			return nil
		end

		flare:SetPos(npcEyePos + toTarget * 52)
		flare:SetAngles(npc:GetAngles())
		flare:Spawn()
		flare:Activate()

		local dir = targetPos - flare:GetPos()
		local dist = dir:Length()
		dir:Normalize()

		timer.Simple(0, function()
			if not IsValid(flare) then return end

			local phys = flare:GetPhysicsObject()
			if not IsValid(phys) then
				BSP_Debug("Flare physics invalid after spawn")
				return
			end

			phys:SetVelocity(dir * 700 + Vector(0, 0, dist * 0.25))
			phys:Wake()
		end)

		net.Start("BombinSupportPlane_FlareSpawned")
		net.WriteEntity(flare)
		net.Broadcast()

		BSP_Debug("Flare thrown successfully")
		return flare
	end

	local function SpawnSupportPlaneAtPos(centerPos, callDir)
		if not scripted_ents.GetStored("ent_bombin_support_plane") then
			BSP_Debug("Plane spawn failed: ent_bombin_support_plane is not registered")
			return false
		end

		local plane = ents.Create("ent_bombin_support_plane")
		if not IsValid(plane) then
			BSP_Debug("Plane spawn failed: ents.Create returned invalid entity")
			return false
		end

		plane:SetPos(centerPos)
		plane:SetAngles(callDir:Angle())
		plane:SetVar("CenterPos", centerPos)
		plane:SetVar("CallDir", callDir)
		plane:SetVar("Lifetime", cv_life:GetFloat())
		plane:SetVar("Speed", cv_speed:GetFloat())
		plane:SetVar("OrbitRadius", cv_radius:GetFloat())
		plane:SetVar("SkyHeightAdd", cv_height:GetFloat())
		plane:Spawn()
		plane:Activate()

		if not IsValid(plane) then
			BSP_Debug("Plane spawn failed: invalid after Spawn()")
			return false
		end

		BSP_Debug("Plane entity created")
		return true
	end

	local function FireBombinSupportPlane(npc, target)
		if not IsValid(npc) then
			BSP_Debug("Call rejected: npc invalid")
			return false
		end

		if not IsValid(target) or not target:IsPlayer() or not target:Alive() then
			BSP_Debug("Call rejected: target invalid")
			return false
		end

		local targetPos = target:GetPos() + Vector(0, 0, 36)
		if not CheckSkyAbove(targetPos) then
			BSP_Debug("Call rejected: no open sky above target")
			return false
		end

		local callDir = targetPos - npc:GetPos()
		callDir.z = 0

		if callDir:LengthSqr() <= 1 then
			callDir = npc:GetForward()
			callDir.z = 0
		end

		if callDir:LengthSqr() <= 1 then
			callDir = Vector(1, 0, 0)
		end

		callDir:Normalize()

		local flare = ThrowSupportFlare(npc, targetPos)
		if not IsValid(flare) then
			BSP_Debug("Call rejected: flare could not be created")
			return false
		end

		local fallbackPos = Vector(targetPos.x, targetPos.y, targetPos.z)
		local storedDir = Vector(callDir.x, callDir.y, callDir.z)

		BSP_Debug("Flare deployed, waiting " .. tostring(cv_delay:GetFloat()) .. " seconds before plane spawn")

		timer.Simple(cv_delay:GetFloat(), function()
			local centerPos = fallbackPos

			if IsValid(flare) then
				centerPos = flare:GetPos()
			end

			BSP_Debug("Attempting plane spawn at " .. tostring(centerPos))
			SpawnSupportPlaneAtPos(centerPos, storedDir)
		end)

		return true
	end

	timer.Create("BombinSupportPlane_Think", 0.5, 0, function()
		if not cv_enabled:GetBool() then return end

		local now = CurTime()
		local interval = math.max(1, cv_interval:GetFloat())

		for _, npc in ipairs(ents.GetAll()) do
			if not IsValid(npc) or not CALLERS[npc:GetClass()] then continue end

			if not npc.__bombinplane_hooked then
				npc.__bombinplane_hooked = true
				npc.__bombinplane_nextCheck = now + math.Rand(1, interval)
				npc.__bombinplane_lastCall = 0
			end

			if now < npc.__bombinplane_nextCheck then continue end

			local jitter = math.min(2, interval * 0.5)
			npc.__bombinplane_nextCheck = now + interval + math.Rand(-jitter, jitter)

			if now - npc.__bombinplane_lastCall < cv_cooldown:GetFloat() then continue end
			if npc:Health() <= 0 then continue end

			local enemy = npc:GetEnemy()
			if not IsValid(enemy) or not enemy:IsPlayer() or not enemy:Alive() then continue end

			local dist = npc:GetPos():Distance(enemy:GetPos())
			if dist > cv_max_dist:GetFloat() or dist < cv_min_dist:GetFloat() then continue end

			if math.random() > cv_chance:GetFloat() then continue end

			if FireBombinSupportPlane(npc, enemy) then
				npc.__bombinplane_lastCall = now
				BSP_Debug("Support plane call accepted for " .. tostring(enemy))
			end
		end
	end)
end

if CLIENT then
	local activeFlares = {}

	net.Receive("BombinSupportPlane_FlareSpawned", function()
		local flare = net.ReadEntity()
		if IsValid(flare) then
			activeFlares[flare:EntIndex()] = flare
		end
	end)

	hook.Add("Think", "BombinSupportPlane_FlareLight", function()
		for idx, flare in pairs(activeFlares) do
			if not IsValid(flare) then
				activeFlares[idx] = nil
				continue
			end

			local dlight = DynamicLight(flare:EntIndex())
			if dlight then
				dlight.Pos = flare:GetPos()
				dlight.r = 0
				dlight.g = 80
				dlight.b = 255
				dlight.Brightness = (math.random() > 0.4) and math.Rand(4.0, 6.0) or math.Rand(0.0, 0.2)
				dlight.Size = 55
				dlight.Decay = 3000
				dlight.DieTime = CurTime() + 0.05
			end
		end
	end)
end
