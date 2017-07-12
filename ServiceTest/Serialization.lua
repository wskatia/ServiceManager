local MAJOR, MINOR = "Module:Serialization-2.0", 1
local APkg = Apollo.GetPackage(MAJOR)
if APkg and (APkg.nVersion or 0) >= MINOR then
  return -- no upgrade needed
end
local Serialization = APkg and APkg.tPackage or {}
local _ENV = nil -- blocking globals in Lua 5.2
Serialization.null = setmetatable ({}, {
  __toinn = function () return "null" end
})

function Serialization.SerializeNumber(number, digits)
	local result = ""
	for i=1,digits do
		local digitValue = number % 94
		result = result .. string.char(digitValue + 33)
		number = math.floor(number / 94)
	end
	return result
end

function Serialization.DeserializeNumber(code)
	local result = 0
	for i=#code,1,-1 do
		result = result * 94 + (string.byte(string.sub(code,i,i)) - 33)
	end
	return result
end

--------------------
-- arg/return marshallers for rpcs
--------------------

-- supports values from 0 to 94^length - 1
function Serialization.NUMBER(length)
	return {
		chars = length,
		Encode = function(marshal, value, code, last)
			if value ~= math.floor(value) or value < 0 or value >= 94^length then
				error("bad input " .. tostring(value) .. " for number marshal of length " .. length)
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
			return code .. Serialization.SerializeNumber(value, math.ceil(math.log(value + 1) / math.log(94)))
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
	}
end

-- supports fixed length strings
function Serialization.STRING(length)
	return {
		chars = length,
		Encode = function(marshal, value, code, last)
			if type(value) ~= "string" or string.len(value) ~= marshal.chars then
				error("bad input " .. tostring(value) .. " for fixed length string marshal")
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
-- specify # bits to spend on each number, follow with (true) if zero-skipping
function Serialization.BITARRAY(...)
	local result = {
		size = 0,
		elements = {},
		Encode = function(marshal, value, code, last)
			if #value ~= #marshal.elements then
				error("bad input " .. tostring(value) .. " for bitarray marshal")
			end
			local total = 0
			for i = 1, #marshal.elements do
				if i > 1 then
					total = total * 2^(marshal.elements[i].bits)
				end
				total = total + value[i] + marshal.elements[i].offset
			end
			return code .. Serialization.SerializeNumber(total, marshal.size)
		end,
		Decode = function(marshal, code, last)
			local result = {}
			local total = Serialization.DeserializeNumber(string.sub(code, 1, marshal.size))
			for i = #marshal.elements, 1, -1 do
				result[i] = (total % 2^(marshal.elements[i].bits)) - marshal.elements[i].offset
				total = math.floor(total / 2^(marshal.elements[i].bits))
			end
			return result, string.sub(code, marshal.size + 1)
		end,
		FixedLength = function(marshal)
			return true
		end,
	}
	for _, a in ipairs(arg) do
		if a == true then
			result.elements[#result.elements].offset = -1
		else
			table.insert(result.elements, {bits = a, offset = 0})
			result.size = result.size + a
		end
	end
	result.size = math.ceil(math.log(2 ^ result.size) / math.log(94))
	return result
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
function Serialization.TABLE(...)
	if #arg % 2 ~= 0 then error("Arguments to table marshal must be key-value pairs") end
	return {
		subMarshals = arg,
		Encode = function(marshal, value, code, last)
			if type(value) ~= "table" then
				error("bad input " .. tostring(value) .. " for table marshal")
			end
			for i = 1, #marshal.subMarshals - 1, 2 do
				code = marshal.subMarshals[i+1]:Encode(value[marshal.subMarshals[i]], code, last and i == #marshal.subMarshals - 1)
			end
			return code
		end,
		Decode = function(marshal, code, last)
			local result = {}
			for i = 1, #marshal.subMarshals - 1, 2 do
				result[marshal.subMarshals[i]], code = marshal.subMarshals[i+1]:Decode(code, last and i == #marshal.subMarshals - 1)
			end
			return result, code
		end,
		FixedLength = function(marshal)
			for i = 2, #marshal.subMarshals, 2 do
				if not marshal.subMarshals[i]:FixedLength() then
					return false
				end
			end
			return true
		end,
	}
end

Apollo.RegisterPackage(Serialization, MAJOR, MINOR, {})