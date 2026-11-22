--
-- bloodhud.lua - HUD blood splatter and low-health damage tint
-- LARC addition (no C++ counterpart): replaces the fixed
-- GFX/Effects/Bloodstains.png overlay of Game_Effects.hpp, which drew one
-- premade splatter texture at a counter-driven alpha whenever the player was
-- hit. Here every hit spawns its own screen-space splat, built the way the
-- impact bursts (src/bloodburst.lua) and the wall stains (src/bloodstain.lua)
-- are: the droplets are placed by hash in the fragment shader, so no textures
-- are involved.
--
--  * splats: a hash-placed splash flung out of a random point near the screen
--    edge whose drops run down the screen, fading after a hold phase
--    (FadeTime / Hold)
--  * low-health tint: a red vignette that ramps up once the player's health
--    drops below LowHealthThreshold, with an optional heartbeat pulse
--
-- Every value lives in the [BLOODHUD] section of EffectsConfig.ini.
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")
local Game = require("src/game")

local BloodHud = {}

BloodHud.Enabled = true
-- seconds a splat lives, Hold is the fraction of that time it keeps full
-- strength before it starts fading
BloodHud.FadeTime = 8
BloodHud.Hold = 0.35
-- splats spawned per hit at 10 damage; heavier hits throw proportionally more
BloodHud.Splats = 2
-- splat radius as a fraction of the canvas height
BloodHud.Radius = 0.22
-- 0 = hard pixel droplets, 1 = soft spray
BloodHud.Blur = 0
-- how far (in splat radii) the fastest drop runs down the screen over one
-- FadeTime; 0 keeps the splash frozen where it landed
BloodHud.Slide = 1.6
BloodHud.MaxSplats = 24
BloodHud.LowHealthEnabled = true
-- fraction of the maximum health below which the tint starts ramping in
BloodHud.LowHealthThreshold = 0.1
BloodHud.LowHealthStrength = 0.55
BloodHud.LowHealthPulse = true

-- splats use the game clock (advanced in the fixed-step tick, so pausing the
-- game freezes them)
BloodHud.splats = {}
BloodHud.Time = 0

local splatShader
local tintShader

-- ------------------------------------------------------------------------
-- Shaders
-- ------------------------------------------------------------------------

local function initShaders()
	-- the splat pattern: drops thrown out of an impact core, then creeping
	-- down the screen. Drawn over the splat's bounding box only.
	splatShader = love.graphics.newShader([[
uniform vec2 uOrigin;
uniform float uRadius;
uniform float uSeed;
uniform float uFade;
uniform float uBlur;
// age and lifetime in seconds, and how far (in splat radii) the fastest drop
// runs down the screen over one lifetime
uniform float uTime;
uniform float uLife;
uniform float uSlide;

float hash(float n) { return fract(sin(n) * 43758.5453); }

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
	// local space: the splat radius is 1.0
	vec2 local = (sc - uOrigin) / uRadius;
	// the splash lives inside 1.4 radii, plus whatever the drops ran below
	if (local.x > 1.45 || local.x < -1.45 || local.y < -1.5 || local.y > uSlide + 1.5) { discard; }

	// blood creeps before it runs: slow start, then it picks up speed
	float t = clamp(uTime / max(uLife, 0.0001), 0.0, 1.0);
	float glide = pow(t, 1.6);

	// 150 drops; each one's landing spot and run speed is a pure function of
	// the seed, so the whole splat costs one loop and no state. Coverage is
	// summed, so drops piling up build a solid splat instead of one blob.
	float cover = 0.0;
	float tint = 0.0;
	for (int i = 1; i <= 150; ++i) {
		float fi = float(i);
		float h1 = hash(fi * 12.9898 + uSeed * 78.233);
		float h2 = hash(fi * 39.3467 + uSeed * 11.135);
		float h3 = fract(h1 * 91.31);
		float h4 = hash(fi * 71.719 + uSeed * 47.53);
		float ang = h1 * 6.2831853;
		vec2 dir = vec2(cos(ang), sin(ang));
		// thrown out of the core: most drops land close by, a few far out
		float spread = pow(h2, 1.8);
		vec2 center = dir * (0.05 + spread * 0.9);
		float rad = mix(0.07, 0.005, spread) * (0.4 + 1.4 * h3);
		if (fi <= 10.0) {
			// the merged mass at the point of impact
			center = dir * spread * 0.25;
			rad = 0.05 + 0.06 * h3;
		}
		// most drops cling where they landed, some run the whole way; "run" is
		// the share of uSlide this one travels
		float run = pow(h4, 1.5);
		float head = center.y + run * uSlide * glide;
		// the streak dragged above the head, growing as the drop runs: a round
		// drop on impact, a long thin drip once it is under way
		float tail = rad * (1.0 + 5.0 * run * glide);
		float halfHeight = (rad + tail) * 0.5;
		vec2 rel = vec2(local.x - center.x, local.y - (head + (rad - tail) * 0.5));
		float d = length(vec2(rel.x / rad, rel.y / halfHeight));
		// hard edged drops where uBlur is 0, soft ones where it is 1
		float m = mix(step(d, 1.0), 1.0 - smoothstep(0.45, 1.0, d), uBlur);
		float w = m * mix(1.0, 0.6, spread);
		cover = cover + w;
		tint = tint + w * fract(h1 * 13.37);
	}

	// the wet spray around the impact point dries out as the rest runs
	float mist = (1.0 - smoothstep(0.0, 0.45, length(local))) * 0.16 * (1.0 - t);
	cover = cover + mist;
	tint = tint + mist * 0.3;

	// dense overlaps go opaque, like a splat rather than smoke; at uBlur 0 the
	// coverage snaps to flat steps instead of shading a smooth ramp
	float alpha = 1.0 - exp(-cover * 1.4);
	alpha = mix(floor(alpha * 4.0 + 0.5) * 0.25, alpha, uBlur);
	vec3 col = mix(vec3(0.24, 0.01, 0.015), vec3(0.62, 0.05, 0.05),
		clamp(tint / max(cover, 0.0001), 0.0, 1.0));
	// flat per-texel grain so the splat reads as painted pixels, not a blob
	float grain = hash(floor(local.x * 28.0) * 12.9898 + floor(local.y * 28.0) * 78.233 + uSeed * 5.1);
	return vec4(col * (1.0 - 0.16 * (1.0 - uBlur) * grain), alpha * uFade * 0.95);
}
]])

	-- low-health tint: a screen hugging vignette, clear in the middle so the
	-- view stays readable, with an optional heartbeat pulse
	tintShader = love.graphics.newShader([[
uniform vec2 uViewport;
uniform float uLevel;
uniform float uStrength;
uniform float uTime;
uniform float uPulse;

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
	vec2 p = (sc / uViewport) * 2.0 - 1.0;
	float vig = smoothstep(0.55, 1.35, length(p));
	// ~72 BPM: a slow throb, not a blink
	float beat = 1.0 - uPulse * 0.3 * (0.5 + 0.5 * sin(uTime * 7.54));
	return vec4(0.52, 0.02, 0.02, vig * uStrength * uLevel * beat);
}
]])
end

-- ------------------------------------------------------------------------
-- Settings
-- ------------------------------------------------------------------------

function BloodHud.Init()
	local ini = Config.loadINI(G.GameConfigFolder .. "EffectsConfig.ini")
	if ini then
		BloodHud.Enabled = Config.getBoolean(ini, "BLOODHUD", "Enabled", BloodHud.Enabled)
		BloodHud.FadeTime = Config.getNumber(ini, "BLOODHUD", "FadeTime", BloodHud.FadeTime)
		BloodHud.Hold = Utils.clamp(Config.getNumber(ini, "BLOODHUD", "Hold", BloodHud.Hold), 0, 0.95)
		BloodHud.Splats = Config.getNumber(ini, "BLOODHUD", "Splats", BloodHud.Splats)
		BloodHud.Radius = Config.getNumber(ini, "BLOODHUD", "Radius", BloodHud.Radius)
		BloodHud.Blur = Utils.clamp(Config.getNumber(ini, "BLOODHUD", "Blur", BloodHud.Blur), 0, 1)
		BloodHud.Slide = Config.getNumber(ini, "BLOODHUD", "Slide", BloodHud.Slide)
		BloodHud.MaxSplats = Config.getNumber(ini, "BLOODHUD", "MaxSplats", BloodHud.MaxSplats)
		BloodHud.LowHealthEnabled = Config.getBoolean(ini, "BLOODHUD", "LowHealthEnabled", BloodHud.LowHealthEnabled)
		BloodHud.LowHealthThreshold = Config.getNumber(ini, "BLOODHUD", "LowHealthThreshold", BloodHud.LowHealthThreshold)
		BloodHud.LowHealthStrength = Config.getNumber(ini, "BLOODHUD", "LowHealthStrength", BloodHud.LowHealthStrength)
		BloodHud.LowHealthPulse = Config.getBoolean(ini, "BLOODHUD", "LowHealthPulse", BloodHud.LowHealthPulse)
	end
	initShaders()
end

-- ------------------------------------------------------------------------
-- Clear / spawn / tick
-- ------------------------------------------------------------------------

function BloodHud.Clear()
	BloodHud.splats = {}
end

-- the player took damageDealt hit points; heavier hits throw more splatter
function BloodHud.Spawn(damageDealt)
	if not BloodHud.Enabled or BloodHud.FadeTime <= 0 then return end

	local count = math.max(1, math.floor(BloodHud.Splats * Utils.clamp((damageDealt or 10) / 10, 0.5, 2) + 0.5))
	for _ = 1, count do
		-- flung out of the middle towards the border, so the crosshair and the
		-- centre of the view stay readable
		local angle = love.math.random() * math.pi * 2
		local spread = 0.45 + love.math.random() * 0.55
		BloodHud.splats[#BloodHud.splats + 1] = {
			fx = Utils.clamp(0.5 + math.cos(angle) * 0.62 * spread, -0.05, 1.05),
			fy = Utils.clamp(0.5 + math.sin(angle) * 0.58 * spread, -0.05, 1.05),
			radius = BloodHud.Radius * (0.7 + love.math.random() * 0.6),
			seed = love.math.random() * 100,
			birth = BloodHud.Time
		}
	end
	while #BloodHud.splats > BloodHud.MaxSplats do
		table.remove(BloodHud.splats, 1)
	end
end

function BloodHud.Tick(dt)
	BloodHud.Time = BloodHud.Time + dt
	local oldest = BloodHud.Time - BloodHud.FadeTime
	for index = #BloodHud.splats, 1, -1 do
		if BloodHud.splats[index].birth <= oldest then
			table.remove(BloodHud.splats, index)
		end
	end
end

-- ------------------------------------------------------------------------
-- Rendering (last: the splatter lies over the whole HUD)
-- ------------------------------------------------------------------------

-- strength of the low-health tint: 0 at and above the threshold, ramping to 1
-- at zero hitpoints
local function lowHealthLevel()
	if not BloodHud.LowHealthEnabled or not Game.Player then return 0 end
	local maxHitpoints = Game.Player.MaxHitpoints or 100
	local threshold = BloodHud.LowHealthThreshold
	if maxHitpoints <= 0 or threshold <= 0 then return 0 end
	local fraction = math.max(Game.Player.Hitpoints, 0) / maxHitpoints
	if fraction >= threshold then return 0 end
	return Utils.clamp((threshold - fraction) / threshold, 0, 1)
end

function BloodHud.Render()
	if not splatShader then initShaders() end

	local W, H = G.Canvas.Width, G.Canvas.Height
	local hold = BloodHud.Hold
	local fadeSpan = math.max(1 - hold, 0.0001)

	love.graphics.setBlendMode("alpha")

	if #BloodHud.splats > 0 then
		love.graphics.setShader(splatShader)
		splatShader:send("uBlur", BloodHud.Blur)
		love.graphics.setColor(1, 1, 1, 1)
		for _, splat in ipairs(BloodHud.splats) do
			local age = BloodHud.Time - splat.birth
			if age < BloodHud.FadeTime then
				-- full strength through the hold phase, then a linear fade
				local t = age / BloodHud.FadeTime
				local fade = 1.0
				if t > hold then
					fade = Utils.clamp((1 - t) / fadeSpan, 0, 1)
				end
				if fade > 0.002 then
					-- the splat is anchored to the canvas by fraction, so it
					-- survives a resolution / format change
					local radius = H * splat.radius
					local cx, cy = splat.fx * W, splat.fy * H
					-- the box covers the splash plus the stretch the drops ran down
					local reach = radius * 1.45
					local drop = radius * (1.4 + BloodHud.Slide)
					local x0 = math.max(cx - reach, 0)
					local y0 = math.max(cy - reach, 0)
					local x1 = math.min(cx + reach, W)
					local y1 = math.min(cy + drop, H)
					if x1 > x0 and y1 > y0 then
						splatShader:send("uOrigin", { cx, cy })
						splatShader:send("uRadius", radius)
						splatShader:send("uSeed", splat.seed)
						splatShader:send("uFade", fade)
						splatShader:send("uTime", age)
						splatShader:send("uLife", BloodHud.FadeTime)
						splatShader:send("uSlide", BloodHud.Slide)
						love.graphics.rectangle("fill", x0, y0, x1 - x0, y1 - y0)
					end
				end
			end
		end
	end

	local danger = lowHealthLevel()
	if danger > 0 then
		love.graphics.setShader(tintShader)
		tintShader:send("uViewport", { W, H })
		tintShader:send("uLevel", danger)
		tintShader:send("uStrength", BloodHud.LowHealthStrength)
		tintShader:send("uTime", BloodHud.Time)
		tintShader:send("uPulse", BloodHud.LowHealthPulse and 1 or 0)
		love.graphics.setColor(1, 1, 1, 1)
		love.graphics.rectangle("fill", 0, 0, W, H)
	end

	love.graphics.setShader()
	love.graphics.setColor(1, 1, 1, 1)
end

Game.BloodHud = BloodHud
return BloodHud
