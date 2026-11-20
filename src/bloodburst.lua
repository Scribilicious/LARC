--
-- bloodburst.lua - screen-space blood spray on entity hits
-- LARC addition (no C++ counterpart). Particle positions are computed
-- analytically in the fragment shader from a time uniform - the same idea as
-- the love-fireworks reference shader - so no per-particle CPU work is done.
-- Each burst is anchored in the world and projected every frame, so the spray
-- stays at the impact point while the camera rotates. The droplets are flung
-- outwards and fade out in flight (a short, fast spray; nothing lands) and are
-- dimmed by the same fog weight the entities at that depth get.
--

local Config = require("src/config")
local Utils = require("src/utils")
local G = require("src/globals")
local Game = require("src/game")

local BloodBurst = {}

BloodBurst.MaxBursts = 12
BloodBurst.Lifetime = 0.22
BloodBurst.WorldRadius = 0.12
BloodBurst.Size = 1.0
-- 0 = hard pixel edges and stippled haze, 1 = the original soft spray
BloodBurst.Blur = 0

-- bursts use the game clock (advanced in the fixed-step tick, so pausing the
-- game freezes the effect)
BloodBurst.bursts = {}
BloodBurst.time = 0

local shader

local function initShader()
	shader = love.graphics.newShader([[
uniform vec2 uOrigin;
uniform float uRadius;
uniform float uTime;
uniform float uLife;
uniform float uSeed;
// fog weight of the impact depth, so the spray darkens with distance like the
// walls and entities it is drawn on top of
uniform float uShade;
// 0 = hard edged droplets, flat coverage steps and a per-pixel stippled haze;
// 1 = the smooth spray. Values in between blend the two
uniform float uBlur;

float hash(float n) { return fract(sin(n) * 43758.5453); }

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
	float t = uTime / uLife;
	if (t >= 1.0) { discard; }

	// 150 droplets; each one's position is a pure function of the age, so the
	// whole burst costs one loop and no state. One hash per droplet drives all
	// of its parameters. Coverage is summed, so overlapping droplets build up
	// to solid blood instead of one soft blob.
	float cover = 0.0;
	float tint = 0.0;
	for (int i = 1; i <= 150; ++i) {
		float fi = float(i);
		float h1 = hash(fi * 12.9898 + uSeed * 78.233);
		float a = h1 * 6.2831853;
		// a hard fling away from the impact point, in droplet radii per second
		float sp = 6.0 + fract(h1 * 37.77) * 10.0;
		// a few fat chunks riding along with a cloud of fine specks
		float sz = 0.05 + fract(h1 * 91.31) * 0.14;
		if (fi <= 8.0) {
			sz = 0.4 + fract(h1 * 91.31) * 0.45;
			sp = sp * 0.45;
		}
		// flung outwards and slightly down, decelerating as it goes; there is
		// no landing - the burst is over before anything could pool
		vec2 dir = vec2(cos(a), sin(a) * 0.75 - 0.3);
		vec2 offset = dir * (sp * uTime * (1.0 - 0.45 * t)) + vec2(0.0, 0.35 * t * t);
		// stretched along the flight path, shrinking as it dries out
		vec2 vdir = normalize(dir + vec2(0.0, 0.7 * t) + vec2(0.0, 0.0001));
		vec2 vn = vec2(-vdir.y, vdir.x);
		vec2 rel = sc - (uOrigin + offset * uRadius);
		float streak = 1.0 + 0.9 * t;
		float d = length(vec2(dot(rel, vdir) / streak, dot(rel, vn)));
		float rad = uRadius * sz * (1.0 - 0.45 * t);
		// hard disc where uBlur is 0, soft falloff towards the rim where it is 1
		float m = mix(step(d, rad), 1.0 - smoothstep(rad * 0.45, rad, d), uBlur);
		float w = m * (1.0 - t * t);
		cover = cover + w;
		tint = tint + w * fract(h1 * 13.37);
	}

	// gore haze: a puff that expands away fast, so the burst reads as one
	// short hit instead of a lingering cloud. At uBlur 0 it is stippled per
	// screen pixel instead of fading smoothly
	float mistDist = length(sc - uOrigin);
	float mistR = uRadius * (0.35 + 1.1 * t);
	float mist = (1.0 - smoothstep(mistR * 0.25, mistR, mistDist)) * 0.32 * (1.0 - t) * (1.0 - t);
	float stipple = hash(floor(sc.x) * 12.9898 + floor(sc.y) * 78.233 + uSeed * 3.71);
	mist = mix(step(stipple, mist), mist, uBlur);
	cover = cover + mist;
	tint = tint + mist * 0.25;

	if (cover < 0.02) { discard; }
	// dense overlaps go opaque, like a splat rather than smoke; at uBlur 0 the
	// coverage snaps to flat steps instead of shading a smooth ramp
	float alpha = 1.0 - exp(-cover * 1.5);
	alpha = mix(floor(alpha * 4.0 + 0.5) * 0.25, alpha, uBlur);
	vec3 col = mix(vec3(0.26, 0.01, 0.02), vec3(0.62, 0.05, 0.05), clamp(tint / cover, 0.0, 1.0));
	return vec4(col * uShade, alpha * 0.95);
}
]])
end

-- ------------------------------------------------------------------------
-- Init / clear / spawn / tick
-- ------------------------------------------------------------------------

function BloodBurst.Init()
	local ini = Config.loadINI(G.GameConfigFolder .. "EffectsConfig.ini")
	if ini then
		BloodBurst.MaxBursts = Config.getNumber(ini, "BLOODBURST", "MaxBursts", 12)
		BloodBurst.Lifetime = Config.getNumber(ini, "BLOODBURST", "Lifetime", 0.22)
		BloodBurst.WorldRadius = Config.getNumber(ini, "BLOODBURST", "WorldRadius", 0.12)
		BloodBurst.Size = Config.getNumber(ini, "BLOODBURST", "Size", 1.0)
		BloodBurst.Blur = Utils.clamp(Config.getNumber(ini, "BLOODBURST", "Blur", 0), 0, 1)
	end
	if not shader then
		initShader()
	end
end

function BloodBurst.Clear()
	BloodBurst.bursts = {}
end

-- world impact point (tile coordinates) and the wall-height fraction it was
-- hit at (0 = floor, 1 = ceiling)
function BloodBurst.Spawn(worldX, worldY, height)
	if not shader then initShader() end
	BloodBurst.bursts[#BloodBurst.bursts + 1] = {
		x = worldX,
		y = worldY,
		h = height,
		birth = BloodBurst.time,
		life = BloodBurst.Lifetime,
		seed = love.math.random() * 100,
		radius = BloodBurst.WorldRadius * BloodBurst.Size * (0.8 + love.math.random() * 0.5)
	}
	while #BloodBurst.bursts > BloodBurst.MaxBursts do
		table.remove(BloodBurst.bursts, 1)
	end
end

function BloodBurst.Tick(dt)
	BloodBurst.time = BloodBurst.time + dt
	for i = #BloodBurst.bursts, 1, -1 do
		if BloodBurst.time - BloodBurst.bursts[i].birth >= BloodBurst.bursts[i].life then
			table.remove(BloodBurst.bursts, i)
		end
	end
end

-- ------------------------------------------------------------------------
-- Rendering (after the entities: the spray is in front of the target)
-- ------------------------------------------------------------------------

function BloodBurst.Render()
	if #BloodBurst.bursts == 0 then return end
	if not shader then initShader() end

	local W, H = G.Canvas.Width, G.Canvas.Height
	local Player = Game.Player
	local VLT = H + G.VerticalLook
	local dirX, dirY = Player.Dir.X, Player.Dir.Y
	local planeX, planeY = G.Plane.X, G.Plane.Y
	local pp = planeX * planeX + planeY * planeY
	local fog = G.FogOfWarDistance
	local lighting = Game.Level.LightingFlag

	love.graphics.setShader(shader)
	love.graphics.setBlendMode("alpha")
	love.graphics.setColor(1, 1, 1, 1)

	for _, b in ipairs(BloodBurst.bursts) do
		local age = BloodBurst.time - b.birth
		if age < b.life then
			local vx, vy = b.x - Player.Pos.X, b.y - Player.Pos.Y
			local d = vx * dirX + vy * dirY
			if d > 0.06 then
				-- project the impact point: a point at wall height h and
				-- perpendicular distance d sits at VLT/2 + H/(2d) - h*H/d
				local cam = (vx * planeX + vy * planeY) / (d * pp)
				local sx = W / 2 * (1 + cam)
				local sy = VLT / 2 + H / (2 * d) - (H / d) * b.h
				local radius = math.min(b.radius * H / d, H * 0.9)
				-- same fog weight the entities at that depth get
				local shade = 1.0
				if lighting then
					local f = Utils.shadeFactor(d, fog)
					shade = (f == -1) and 0.0 or f
				end
				-- bounding box: a droplet thrown at the shader's top speed
				-- (16 radii/s, decelerating to 55%) stays inside this radius,
				-- plus room for its own size and the expanding haze puff
				local reach = radius * (16 * b.life * 0.55 + 1.3)
				local x0 = math.max(sx - reach, 0)
				local y0 = math.max(sy - reach, 0)
				local x1 = math.min(sx + reach, W)
				local y1 = math.min(sy + reach, H)
				if x1 > x0 and y1 > y0 then
					shader:send("uOrigin", { sx, sy })
					shader:send("uRadius", radius)
					shader:send("uTime", age)
					shader:send("uLife", b.life)
					shader:send("uSeed", b.seed)
					shader:send("uShade", shade)
					shader:send("uBlur", BloodBurst.Blur)
					love.graphics.rectangle("fill", x0, y0, x1 - x0, y1 - y0)
				end
			end
		end
	end

	love.graphics.setShader()
	love.graphics.setBlendMode("alpha")
	love.graphics.setColor(1, 1, 1, 1)
end

Game.BloodBurst = BloodBurst
return BloodBurst
