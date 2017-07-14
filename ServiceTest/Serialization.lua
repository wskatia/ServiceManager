local MAJOR, MINOR = "Module:Serialization-3.0", 1
local APkg = Apollo.GetPackage(MAJOR)
if APkg and (APkg.nVersion or 0) >= MINOR then
  return -- no upgrade needed
end
local Serialization = APkg and APkg.tPackage or {}
local _ENV = nil -- blocking globals in Lua 5.2
Serialization.null = setmetatable ({}, {
  __toinn = function () return "null" end
})

local kZeroChar = 33
local kNumChars = 94

function Serialization.SerializeNumber(number, digits)
	local result = ""
	for i=1,digits do
		local digitValue = number % kNumChars
		result = result .. string.char(digitValue + kZeroChar)
		number = math.floor(number / kNumChars)
	end
	return result
end

function Serialization.DeserializeNumber(code)
	local result = 0
	for i=#code,1,-1 do
		result = result * kNumChars + (string.byte(string.sub(code,i,i)) - kZeroChar)
	end
	return result
end

--------------------
-- arg/return marshallers for rpcs
--------------------

-- supports values from 0 to kNumChars^length - 1
function Serialization.NUMBER(length)
	return {
		chars = length,
		Encode = function(marshal, value, code, last)
			if value ~= math.floor(value) or value < 0 or value >= kNumChars^marshal.chars then
				error("bad input " .. tostring(value) .. " for number marshal of length " .. marshal.chars)
			end
			return code .. Serialization.SerializeNumber(value, marshal.chars)
		end,
		Decode = function(marshal, code, last)
			return Serialization.DeserializeNumber(string.sub(code, 1, marshal.chars)),
				string.sub(code, marshal.chars + 1)
		end,
		FixedLength = function(marshal)
			return true
		end,
	}
end

-- supports integer values >= 0
Serialization.VARNUMBER = {
	Encode = function(marshal, value, code, last)
		if value ~= math.floor(value) or value < 0 then
			error("bad input " .. tostring(value) .. " for varnumber marshal")
		end
		if last then
			return code .. Serialization.SerializeNumber(value, math.ceil(math.log(value + 1) / math.log(kNumChars)))
		else
			local result = Serialization.SerializeNumber(value % 47, 1)
			value = math.floor(value / 47)
			while value > 0 do
				local digit = value % 47 + 47
				result = Serialization.SerializeNumber(digit, 1) .. result
				value = math.floor(value / 47)
			end
			return code .. result
		end
	end,
	Decode = function(marshal, code, last)
		if last then
			return Serialization.DeserializeNumber(code), ""
		else
			local result = 0
			while true do
				local digit = Serialization.DeserializeNumber(string.sub(code, 1, 1))
				code = string.sub(code, 2)
				if digit >= 47 then
					result = result * 47 + (digit - 47)
				else
					result = result * 47 + digit
					break
				end
			end
			return result, code
		end
	end,
	FixedLength = function(marshal)
		return false
	end,
}

-- use only with unsigned integer marshals, skips zero to save space
function Serialization.SKIPZERO(elementMarshal)
	return {
		subMarshal = elementMarshal,
		Encode = function(marshal, value, code, last)
			if value ~= math.floor(value) or value < 1 then
				error("bad input " .. tostring(value) .. " for skipzero marshal")
			end
			return marshal.subMarshal:Encode(value - 1, code, last)
		end,
		Decode = function(marshal, code, last)
			local value, code = marshal.subMarshal:Decode(code, last)
			return value + 1, code
		end,
		FixedLength = function(marshal)
			return marshal.subMarshal:FixedLength()
		end,
		BitCount = function(marshal)
			return marshal.subMarshal:BitCount()
		end,
	}
end

-- adds signed support to the submarshal, assumes integer values
function Serialization.SIGNED(elementMarshal)
	return {
		subMarshal = elementMarshal,
		Encode = function(marshal, value, code, last)
			if value ~= math.floor(value) then
				error("bad input " .. tostring(value) .. " for signed marshal")
			end
			local designedValue = math.abs(value) * 2
			if value > 0 then designedValue = designedValue - 1 end
			return marshal.subMarshal:Encode(designedValue, code, last)
		end,
		Decode = function(marshal, code, last)
			local value, code = marshal.subMarshal:Decode(code, last)
			local signedValue = math.floor((value + 1) / 2)
			if value % 2 == 0 then signedValue = signedValue * -1 end
			return signedValue, code
		end,
		FixedLength = function(marshal)
			return marshal.subMarshal:FixedLength()
		end,
		BitCount = function(marshal)
			return marshal.subMarshal:BitCount()
		end,
	}
end

-- uses an underlying integer marshal to support fractions
function Serialization.FRACTION(denominator, elementMarshal)
	return {
		divideBy = denominator,
		subMarshal = elementMarshal,
		Encode = function(marshal, value, code, last)
			if type(value) ~= "number" then
				error("bad input " .. tostring(value) .. " for fraction marshal")
			end
			local enlargedValue = math.floor(value * marshal.divideBy + 0.5)
			return marshal.subMarshal:Encode(enlargedValue, code, last)
		end,
		Decode = function(marshal, code, last)
			local value, code = marshal.subMarshal:Decode(code, last)
			return value / marshal.divideBy, code
		end,
		FixedLength = function(marshal)
			return marshal.subMarshal:FixedLength()
		end,
		BitCount = function(marshal)
			return marshal.subMarshal:BitCount()
		end,
	}
end

-- supports fixed length strings
function Serialization.STRING(length)
	return {
		chars = length,
		Encode = function(marshal, value, code, last)
			if type(value) ~= "string" or string.len(value) ~= marshal.chars then
				error("bad input " .. tostring(value) .. " for fixed length string marshal " .. marshal.chars)
			end
			return code .. string.sub(value, 1, marshal.chars)
		end,
		Decode = function(marshal, code, last)
			return string.sub(code, 1, marshal.chars),
				string.sub(code, marshal.chars + 1)
		end,
		FixedLength = function(marshal)
			return true
		end,
	}
end

-- supports strings of any length
Serialization.VARSTRING = {
	Encode = function(marshal, value, code, last)
		if type(value) ~= "string" then
			error("bad input " .. tostring(value) .. " for varstring marshal")
		end
		if last then
			return code .. value
		else
			local length = string.len(value)
			return Serialization.VARNUMBER:Encode(length, code, false) .. value
		end
	end,
	Decode = function(marshal, code, last)
		if last then
			return code, ""
		else
			local length, code = Serialization.VARNUMBER:Decode(code, false)
			return string.sub(code, 1, length), string.sub(code, length+1)
		end
	end,
	FixedLength = function(marshal)
		return false
	end,
}

-- more compact encoding for an array of small numbers
-- pass an array of BITS
function Serialization.BITARRAY(...)
	local result = {
		chars = 0,
		subMarshals = arg,
		Encode = function(marshal, value, code, last)
			if #value ~= #marshal.subMarshals then
				error("bad input " .. tostring(value) .. " for bitarray marshal")
			end
			local total = 0
			for i, subMarshal in ipairs(marshal.subMarshals) do
				total = subMarshal:Encode(value[i], total, i == #value)
			end
			return code .. Serialization.SerializeNumber(total, marshal.chars)
		end,
		Decode = function(marshal, code, last)
			local result = {}
			local total = Serialization.DeserializeNumber(string.sub(code, 1, marshal.chars))
			for i = #marshal.subMarshals, 1, -1 do
				result[i], total = marshal.subMarshals[i]:Decode(total, i == #marshal.subMarshals)
			end
			return result, string.sub(code, marshal.chars + 1)
		end,
		FixedLength = function(marshal)
			return true
		end,
	}
	local bits = 0
	for _, marshal in ipairs(arg) do
		bits = bits + marshal:BitCount()
	end
	result.chars = math.ceil(math.log(2^bits) / math.log(kNumChars))
	return result
end

-- special submarshal only for use with BITARRAY
-- builds up a number, not a codestring, so do not use as a regular marshal
-- can be encased in any numeric marshal modifiers
function Serialization.BITS(length)
	return {
		bits = length,
		Encode = function(marshal, value, total, last)
			if value ~= math.floor(value) or value < 0 or value >= 2^marshal.bits then
				error("bad input " .. tostring(value) .. " for bits marshal of length " .. marshal.bits)
			end
			return total * (2^marshal.bits) + value
		end,
		Decode = function(marshal, total, last)
			return total % (2^marshal.bits), math.floor(total / (2^marshal.bits))
		end,
		FixedLength = function(marshal)
			return true
		end,
		BitCount = function(marshal)
			return marshal.bits
		end,
	}
end

-- fixed length array, all elements must be of same type
function Serialization.ARRAY(length, elementMarshal)
	return {
		elements = length,
		subMarshal = elementMarshal,
		Encode = function(marshal, value, code, last)
			if #value ~= marshal.elements then
				error("bad input " .. tostring(value) .. " for array marshal")
			end
			for i = 1, marshal.elements do
				code = marshal.subMarshal:Encode(value[i], code, last and i == marshal.elements)
			end
			return code
		end,
		Decode = function(marshal, code, last)
			local result = {}
			for i = 1, marshal.elements do
				result[i], code = marshal.subMarshal:Decode(code, last and i == marshal.elements)
			end
			return result, code
		end,
		FixedLength = function(marshal)
			return elementMarshal:FixedLength()
		end,
	}
end

-- variable length array
function Serialization.VARARRAY(elementMarshal)
	return {
		subMarshal = elementMarshal,
		Encode = function(marshal, value, code, last)
			if type(value) ~= "table" then
				error("bad input " .. tostring(value) .. " for vararray marshal")
			end
			if last and #value == 0 then return code end
			if not last or not marshal.subMarshal:FixedLength() then
				code = Serialization.VARNUMBER:Encode(#value, code, false)
			end
			for i = 1, #value do
				code = marshal.subMarshal:Encode(value[i], code, false)
			end
			return code
		end,
		Decode = function(marshal, code, last)
			local result = {}
			if not last or not marshal.subMarshal:FixedLength() then
				local length
				length, code = Serialization.VARNUMBER:Decode(code, false)
				for i = 1, length do
					result[i], code = marshal.subMarshal:Decode(code, false)
				end
			else
				local element
				while code ~= "" do
					element, code = marshal.subMarshal:Decode(code, false)
					table.insert(result, element)
				end
			end
			return result, code
		end,
		FixedLength = function(marshal)
			return false
		end,
	}
end

-- fixed length array with elements of different pre-determined types
function Serialization.TUPLE(...)
	return {
		subMarshals = arg,
		Encode = function(marshal, value, code, last)
			if type(value) ~= "table" then
				error("bad input " .. tostring(value) .. " for tuple marshal")
			end
			for i = 1, #marshal.subMarshals do
				code = marshal.subMarshals[i]:Encode(value[i], code, last and i == #marshal.subMarshals)
			end
			return code
		end,
		Decode = function(marshal, code, last)
			local result = {}
			for i = 1, #marshal.subMarshals do
				result[i], code = marshal.subMarshals[i]:Decode(code, last and i == #marshal.subMarshals)
			end
			return result, code
		end,
		FixedLength = function(marshal)
			for i = 1, #marshal.subMarshals do
				if not marshal.subMarshals[i]:FixedLength() then
					return false
				end
			end
			return true
		end,
	}
end

-- indexed table
function Serialization.TABULAR(subEncoder, ...)
	return {
		subMarshal = subEncoder,
		keys = arg,
		Encode = function(marshal, value, code, last)
			if type(value) ~= "table" then
				error("bad input " .. tostring(value) .. " for table marshal")
			end
			local valueArray = {}
			for _, key in ipairs(marshal.keys) do
				local subValue = value[key]
				if not subValue then
					error("input to table marshal was missing value for " .. key)
				end
				table.insert(valueArray, subValue)
			end
			return marshal.subMarshal:Encode(valueArray, code, last)
		end,
		Decode = function(marshal, code, last)
			local resultArray, code = marshal.subMarshal:Decode(code, last)
			local result = {}
			for i = 1, #marshal.keys do
				result[marshal.keys[i]] = resultArray[i]
			end
			return result, code
		end,
		FixedLength = function(marshal)
			return marshal.subMarshal:FixedLength()
		end,
	}
end

Apollo.RegisterPackage(Serialization, MAJOR, MINOR, {})