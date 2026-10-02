--!strict
-- Doom's 16.16 fixed-point arithmetic.
--
-- The implementation deliberately keeps values in signed 32-bit range. Lua
-- numbers are doubles, so FixedMul splits the operands into 16-bit limbs rather
-- than relying on a potentially inexact 64-bit intermediate.

local module = {}

export type Fixed = number

local U32 = 4294967296
local I32 = 2147483648
local LIMB = 65536

module.FRACBITS = 16
module.FRACUNIT = LIMB
module.MININT = -I32
module.MAXINT = I32 - 1

local function wrap32(value: number): number
	local unsigned = value % U32
	return if unsigned >= I32 then unsigned - U32 else unsigned
end

local function magnitude(value: number): number
	local signed = wrap32(value)
	return if signed < 0 then -signed else signed
end

-- Convert a value to the signed representation used by fixed_t.
function module.wrap(value: number): Fixed
	return wrap32(value)
end

function module.toUnsigned(value: number): number
	local signed = wrap32(value)
	return if signed < 0 then signed + U32 else signed
end

function module.add(a: Fixed, b: Fixed): Fixed
	return wrap32(a + b)
end

function module.sub(a: Fixed, b: Fixed): Fixed
	return wrap32(a - b)
end

function module.neg(a: Fixed): Fixed
	return wrap32(-a)
end

-- This is the arithmetic equivalent of ((int64_t)a * b) >> FRACBITS.
-- For a negative product, C's arithmetic right shift rounds toward negative
-- infinity; that is why the non-zero remainder adds one before negation.
function module.mul(a: Fixed, b: Fixed): Fixed
	local aa, bb = magnitude(a), magnitude(b)
	local a0, a1 = aa % LIMB, math.floor(aa / LIMB)
	local b0, b1 = bb % LIMB, math.floor(bb / LIMB)
	local low = a0 * b0
	local middle = a1 * b0 + a0 * b1
	local shifted = math.floor(low / LIMB) + middle + a1 * b1 * LIMB
	local negative = (wrap32(a) < 0) ~= (wrap32(b) < 0)

	-- Every intermediate is below 2^53, so these operations are exact as
	-- Lua numbers. Only the final value is reduced to signed 32-bit.
	if negative then
		if low % LIMB ~= 0 then
			shifted += 1
		end
		return wrap32(-shifted)
	end
	return wrap32(shifted)
end

local function saturated(a: number, b: number): Fixed
	local negative = (a < 0) ~= (b < 0)
	return if negative then module.MININT else module.MAXINT
end

-- Doom's guard prevents the 16.16 quotient from overflowing. The quotient
-- itself truncates toward zero, matching the active FixedDiv2 C implementation.
function module.div(a: Fixed, b: Fixed): Fixed
	local aa, bb = wrap32(a), wrap32(b)
	if math.floor(magnitude(aa) / 16384) >= magnitude(bb) then
		return saturated(aa, bb)
	end
	return module.div2(aa, bb)
end

function module.div2(a: Fixed, b: Fixed): Fixed
	local aa, bb = wrap32(a), wrap32(b)
	if bb == 0 then
		error("FixedDiv2: divide by zero", 2)
	end
	local quotient = math.floor(magnitude(aa) * LIMB / magnitude(bb))
	if (aa < 0) ~= (bb < 0) then
		quotient = -quotient
	end
	return wrap32(quotient)
end

return module
