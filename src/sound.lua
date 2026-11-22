--
-- sound.lua - a sound effect that can play several samples at once
-- LARC addition (no C++ counterpart): the original keeps one Source per sound,
-- so a sample that is longer than the interval it is retriggered at (a shot
-- faster than its own tail, a footstep over a footstep) is cut off every time.
-- A Sound loads the file once and keeps a pool of static voices cloned from
-- that one SoundData, playing them round-robin.
--

local Config = require("src/config")

local Sound = {}

-- how many voices a Sound gets when the caller does not ask for a number
Sound.DefaultVoices = 8

local SoundMT = {}
SoundMT.__index = SoundMT

-- options: Voices (pool size), Volume, Pitch, PitchJitter (random pitch spread,
-- so stacked retriggers do not phase into one thick sample)
function Sound.New(file, options)
	options = options or {}
	local path = file and Config.fixPath(file)
	if not path or not love.filesystem.getInfo(path) then
		return nil
	end
	local template = love.audio.newSource(path, "static")
	local self = setmetatable({
		voices = {},
		nextVoice = 1,
		volume = options.Volume or 1,
		pitch = options.Pitch or 1,
		pitchJitter = options.PitchJitter or 0,
		duration = template:getDuration()
	}, SoundMT)
	for i = 1, math.max(1, math.floor(options.Voices or Sound.DefaultVoices)) do
		-- clones share the decoded data, so extra voices cost mixing only
		self.voices[i] = (i == 1) and template or template:clone()
		self.voices[i]:setVolume(self.volume)
	end
	return self
end

function SoundMT:GetDuration()
	return self.duration
end

function SoundMT:SetVolume(volume)
	self.volume = volume
	for _, voice in ipairs(self.voices) do
		voice:setVolume(volume)
	end
end

function SoundMT:IsPlaying()
	for _, voice in ipairs(self.voices) do
		if voice:isPlaying() then
			return true
		end
	end
	return false
end

-- plays a free voice; when the whole pool is busy the oldest one is restarted,
-- so running out of voices can never silence the ones started after it
function SoundMT:Play(volume, pitch)
	local voices = self.voices
	local count = #voices
	local index
	for i = 0, count - 1 do
		local candidate = (self.nextVoice - 1 + i) % count + 1
		if not voices[candidate]:isPlaying() then
			index = candidate
			break
		end
	end
	index = index or self.nextVoice
	self.nextVoice = index % count + 1

	local voice = voices[index]
	local p = pitch or self.pitch
	if self.pitchJitter > 0 then
		p = p * (1 - self.pitchJitter + love.math.random() * 2 * self.pitchJitter)
	end
	voice:stop()
	voice:setVolume(volume or self.volume)
	voice:setPitch(p)
	voice:play()
	return voice
end

function SoundMT:Stop()
	for _, voice in ipairs(self.voices) do
		voice:stop()
	end
end

return Sound
