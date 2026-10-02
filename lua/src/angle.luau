--!strict
-- Deterministic Binary Angle Measurement (BAM) helpers.
--
-- Doom normally obtains sine/cosine and atan values from tables.c. These
-- helpers use integer CORDIC iterations with the same 32-bit BAM domain instead
-- of host floating-point trig, so the result is repeatable on every runtime.
-- The values are close to the original lookup tables, but are not a byte-for-
-- byte replacement for finesine/tantoangle.

local module = {}

local U32 = 4294967296
local ANGLETOFINE = 524288 -- 2^ANGLETOFINESHIFT, from tables.h
local FINEANGLES = 8192
local FINEMASK = FINEANGLES - 1
local FRACUNIT = 65536

module.FINEANGLES = FINEANGLES
module.FINEMASK = FINEMASK
module.ANGLETOFINESHIFT = 19
module.ANG45 = 0x20000000
module.ANG90 = 0x40000000
module.ANG180 = 0x80000000
module.ANG270 = 0xC0000000
module.SLOPERANGE = 2048
module.SLOPEBITS = 11
module.DBITS = 5
module.FRACUNIT = FRACUNIT

-- atan(2^-i), represented as BAM turns. These are integer constants, not
-- generated with math.atan, and are enough for gameplay-resolution angles.
local cordicAngles = {
	0x20000000,
	0x12E4051E,
	0x09FB385B,
	0x051111D4,
	0x028B0D43,
	0x0145D7E1,
	0x00A2F61E,
	0x00517C55,
	0x0028BE53,
	0x00145F2E,
	0x000A2F98,
	0x000517CC,
	0x00028BE6,
	0x000145F3,
	0x0000A2F9,
	0x0000517C,
	0x000028BE,
	0x0000145F,
	0x00000A2F,
	0x00000517,
}
local CORDIC_GAIN = 39797 -- round(1 / 1.646760258 * FRACUNIT)

local function normalize(angle: number): number
	return angle % U32
end

local function signedAngle(angle: number): number
	local value = normalize(angle)
	return if value >= module.ANG180 then value - U32 else value
end

local function arithmeticShift(value: number, places: number): number
	return math.floor(value / 2 ^ places)
end

-- Rotate a unit vector by a BAM angle. Returns 16.16 sine and cosine.
local function rotate(angle: number): (number, number)
	local value = normalize(angle)
	if value == 0 then
		return 0, FRACUNIT
	end
	if value == module.ANG90 then
		return FRACUNIT, 0
	end
	if value == module.ANG180 then
		return 0, -FRACUNIT
	end
	if value == module.ANG270 then
		return -FRACUNIT, 0
	end

	local remaining = signedAngle(value)
	local negate = false
	if remaining > module.ANG90 then
		remaining -= module.ANG180
		negate = true
	elseif remaining < -module.ANG90 then
		remaining += module.ANG180
		negate = true
	end

	local x, y = CORDIC_GAIN, 0
	for i, turn in cordicAngles do
		local shiftedX = arithmeticShift(x, i - 1)
		local shiftedY = arithmeticShift(y, i - 1)
		if remaining >= 0 then
			x -= shiftedY
			y += shiftedX
			remaining -= turn
		else
			x += shiftedY
			y -= shiftedX
			remaining += turn
		end
	end
	if negate then
		x, y = -x, -y
	end
	return y, x
end

function module.normalize(angle: number): number
	return normalize(angle)
end

function module.signed(angle: number): number
	return signedAngle(angle)
end

function module.fineIndex(angle: number): number
	return math.floor(normalize(angle) / ANGLETOFINE) % FINEANGLES
end

function module.sine(angle: number): number
	local sine = rotate(angle)
	return sine
end

function module.cosine(angle: number): number
	local _, cosine = rotate(angle)
	return cosine
end

function module.fineSine(index: number): number
	local sine = rotate((index % FINEANGLES) * ANGLETOFINE)
	return sine
end

function module.fineCosine(index: number): number
	local cosine = rotate(((index + FINEANGLES / 4) % FINEANGLES) * ANGLETOFINE)
	return cosine
end

-- The same unsigned division used by tables.c. Inputs are unsigned in the C
-- API; normalization here makes that contract explicit for Lua callers.
function module.slopeDiv(num: number, den: number): number
	local unsignedNum, unsignedDen = normalize(num), normalize(den)
	if unsignedDen < 512 then
		return module.SLOPERANGE
	end
	local denominator = math.floor(unsignedDen / 256)
	local answer = math.floor(((unsignedNum * 8) % U32) / denominator)
	return math.min(answer, module.SLOPERANGE)
end

-- Integer vectoring CORDIC, returning an unsigned BAM angle.
function module.vectorToAngle(dx: number, dy: number): number
	if dx == 0 and dy == 0 then
		return 0
	end
	if dx == 0 then
		return if dy > 0 then module.ANG90 else module.ANG270
	end
	if dy == 0 then
		return if dx > 0 then 0 else module.ANG180
	end

	local x, y = dx, dy
	local result = 0
	if x < 0 then
		x, y = -x, -y
		result = module.ANG180
	end

	for i, turn in cordicAngles do
		local shiftedY = arithmeticShift(y, i - 1)
		if y > 0 then
			local oldX = x
			x += shiftedY
			y -= arithmeticShift(oldX, i - 1)
			result += turn
		elseif y < 0 then
			local oldX = x
			x -= shiftedY
			y += arithmeticShift(oldX, i - 1)
			result -= turn
		else
			break
		end
	end
	return normalize(result)
end

-- Accept either a vector (dx, dy) or two points (x1, y1, x2, y2).
function module.pointToAngle(a: number, b: number, c: number?, d: number?): number
	if c == nil or d == nil then
		return module.vectorToAngle(a, b)
	end
	return module.vectorToAngle(c - a, d - b)
end

return module
