if SERVER then return end

local ADDON_CATEGORY = "Bombin Addons"

hook.Add("PopulateToolMenu", "BombinSupportPlane_PopulateMenu", function()
	spawnmenu.AddToolMenuOption(
		"Options",
		ADDON_CATEGORY,
		"npc_bombin_support_plane_settings",
		"NPC Support Plane",
		"", "",
		function(panel)
			panel:ClearControls()
			panel:AddControl("Header", { Description = "NPC Support Plane Settings", Height = "40" })

			panel:CheckBox("Enable Plane Calls", "npc_bombinplane_enabled")
			panel:CheckBox("Debug Announce in Console", "npc_bombinplane_announce")

			panel:AddControl("Label", { Text = "" })
			panel:AddControl("Header", { Description = "Probability & Timing", Height = "30" })

			panel:NumSlider("Call Chance", "npc_bombinplane_chance", 0, 1, 2)
			panel:NumSlider("Check Interval (seconds)", "npc_bombinplane_interval", 1, 60, 0)
			panel:NumSlider("Call Cooldown (seconds)", "npc_bombinplane_cooldown", 10, 180, 0)
			panel:NumSlider("Delay After Flare", "npc_bombinplane_delay", 1, 15, 0)
			panel:NumSlider("Plane Lifetime", "npc_bombinplane_lifetime", 5, 120, 0)

			panel:AddControl("Label", { Text = "" })
			panel:AddControl("Header", { Description = "Flight Behavior", Height = "30" })

			panel:NumSlider("Plane Speed", "npc_bombinplane_speed", 100, 1200, 0)
			panel:NumSlider("Orbit Radius", "npc_bombinplane_radius", 500, 8000, 0)
			panel:NumSlider("Preferred Height Above Ground", "npc_bombinplane_height", 500, 6000, 0)

			panel:AddControl("Label", { Text = "" })
			panel:AddControl("Header", { Description = "Engagement Range", Height = "30" })

			panel:NumSlider("Max Distance", "npc_bombinplane_max_dist", 500, 8000, 0)
			panel:NumSlider("Min Distance", "npc_bombinplane_min_dist", 0, 1000, 0)
		end
	)
end)
