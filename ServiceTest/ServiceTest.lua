local S = Apollo.GetPackage("Module:Serialization-3.0").tPackage
local ServiceManager = Apollo.GetPackage("Module:ServiceManager-1.0").tPackage

local ServiceTest = {}

function ServiceTest:new(o)
	o = o or {}
	setmetatable(o, self)
	self.__index = self
	return o
end

function ServiceTest:Init()
	Apollo.RegisterAddon(self, false, "", {})
end

function ServiceTest:OnLoad()
	ServiceManager:RegisterService(self, "TestService", {
		channelType = ICCommLib.CodeEnumICCommChannelType.Global,
		rpcs = {
			["TestCall"] = {
				args = {S.VARSTRING},
				returns = {S.VARSTRING}
			},
			["TestBroadcast"] = {
				args = {S.VARSTRING}
			},
			["TestResponse"] = {
				args = {S.VARSTRING}
			},
			["TestCalculation"] = {
				args = {
					S.TUPLE(
						S.SIGNED(S.VARNUMBER),
						S.FRACTION(10, S.NUMBER(1))),
					S.TABULAR(
						S.TUPLE(S.STRING(3), S.VARSTRING),
						"a", "b"),
				},
				returns = {
					S.FRACTION(10, S.SIGNED(S.VARNUMBER)),
					S.VARSTRING,
				}
			},
		}
	})
	
	ServiceManager:Implement("TestService", "TestCall",
		function(caller, arg)
			return arg
		end)
	
	ServiceManager:Implement("TestService", "TestBroadcast",
		function(caller, arg)
			ServiceManager:RemoteCall(caller, "TestService", "TestResponse", nil, nil, arg)
		end)

	ServiceManager:Implement("TestService", "TestResponse",
		function(caller, arg)
			if arg == "test2 " then
				Print("Broadcast test succeeded.")
			else
				Print("Broadcast test returned unexpected value \"" .. arg .. "\"")
			end
		end)
		
	ServiceManager:Implement("TestService", "TestCalculation",
		function(caller, arg1, arg2)
			return arg1[1] + arg1[2], arg2.a .. arg2.b
		end)
	
	Apollo.RegisterSlashCommand("testservice", "OnTestService", self)
	Apollo.RegisterSlashCommand("testserialization", "OnTestSerialization", self)
end

local function ExpandString(value)
	if type(value) == "table" then
		local result = "{"
		for k, v in pairs(value) do
			result = result .. ExpandString(k) .. ":" .. ExpandString(v) .. ","
		end
		return result .. "}"
	else
		return tostring(value)
	end
end

local function Compare(a, b)
	if type(a) == "table" then
		local aSize = 0
		for k, v in pairs(a) do
			if not Compare(v, b[k]) then return false end
			aSize = aSize + 1
		end
		for k, v in pairs(b) do
			aSize = aSize - 1
		end
		return aSize == 0
	elseif type(a) == "number" and type(b) == "number" then
		return math.abs(a - b) < 0.001
	else
		return a == b
	end
end

function ServiceTest:OnTestService(strCmd, strArg)
	ServiceManager:RemoteCall(strArg, "TestService", "TestCall",
		function(result)
			if result == "test " then
				Print("Call test succeeded.")
			else
				Print("Call test returned unexpected value \"" .. result .. "\"")
			end
		end,
		function(err)
			Print("Call test failed with: " .. err)
		end,
		"test ")
	
	ServiceManager:RemoteCall(nil, "TestService", "TestBroadcast", nil, 
		function(err)
			Print("Broadcast test failed with: " .. err)
		end,
		"test2 ")
		
	ServiceManager:RemoteCall(strArg, "TestService", "TestCalculation",
		function(result1, result2)
			if result1 == -4.5 and result2 == "foobar" then
				Print("Calculation test succeeded.")
			else
				Print("Calculation test returned unexpected value(s) " .. result1 .. ", \"" .. result2 .. "\"")
			end
		end,
		function(err)
			Print("Calculation test failed with: " .. err)
		end,
		{-5, 0.5}, {a = "foo", b = "bar"})
		
	Print("Expecting 3 test results.")
end

local function CheckMarshal(testName, value, marshal)
	local result, encoding
	encoding = marshal:Encode(value, "", false)
	encoding = marshal:Encode(value, encoding, true)
	result, encoding = marshal:Decode(encoding, false)
	if not Compare(value, result) then
		Print(testName .. " converted " .. ExpandString(value) .. " to " .. ExpandString(result) .. " for first run")
	end
	result, encoding = marshal:Decode(encoding, true)
	if not Compare(value, result) then
		Print(testName .. " converted " .. ExpandString(value) .. " to " .. ExpandString(result) .. " for last run")
	end
	if encoding ~= "" then
		Print(testName .. " had leftover ".. encoding .. " when encoding " .. ExpandString(value))
	end
end

function ServiceTest:OnTestSerialization()
	-- numerics
	for i = 0, 93 do
		CheckMarshal("single digit number", i, S.NUMBER(1))
	end
	for i = 0, 94^2-1 do
		CheckMarshal("double digit number", i, S.NUMBER(2))
	end
	for i = 0, 48 do
		CheckMarshal("var-length number", i, S.VARNUMBER)
	end
	for i = 1, 50 do
		CheckMarshal("skipzero number", i, S.SKIPZERO(S.VARNUMBER))
	end
	for i = (94^2 / -2 + 1), (94^2 / 2) do
		CheckMarshal("signed fixed-length number", i, S.SIGNED(S.NUMBER(2)))
	end
	for i = -48, 48 do
		CheckMarshal("signed var-length number", i, S.SIGNED(S.VARNUMBER))
	end
	for i = 0, 93 do
		for j = 2, 10 do
			CheckMarshal("positive fraction", i / j, S.FRACTION(j, S.NUMBER(1)))
		end
	end
	for i = -20, 20, 0.2 do
		-- fraction must go outside, since signed needs an integer input
		CheckMarshal("signed fraction", i, S.FRACTION(5, S.SIGNED(S.VARNUMBER)))
	end

	-- strings
	for i = 32, 127 do
		CheckMarshal("1-string", string.char(i), S.STRING(1))
		CheckMarshal("varstring", string.char(i), S.VARSTRING)
	end
	for i = 0, 50 do
		local value = ""
		for j = 0, i do
			value = value .. "A"
		end

		CheckMarshal("fixedstring", value, S.STRING(string.len(value)))
		CheckMarshal("varstring", value, S.VARSTRING)
	end

	-- tabulars
	for i = 0, 7 do
		for j = 1, 4 do
			for k = 0, 255 do
				CheckMarshal("bitarray", {i, j, k}, S.BITARRAY(S.BITS(3), S.SKIPZERO(S.BITS(2)), S.BITS(8)))
			end
		end
	end
	for i = 1, 50 do
		local value = {}
		for j = 1, i do
			table.insert(value, j)
		end
		CheckMarshal("fixed array", value, S.ARRAY(i, S.VARNUMBER))
		CheckMarshal("vararray", value, S.VARARRAY(S.VARNUMBER))
	end
	CheckMarshal("vararray", {}, S.VARARRAY(S.VARNUMBER))
	CheckMarshal("tuple", {12345, {-1, 1, 1000}, "abcde"},
		S.TUPLE(
			S.VARNUMBER,
			S.TUPLE(S.SIGNED(S.VARNUMBER), S.SIGNED(S.VARNUMBER), S.SIGNED(S.VARNUMBER)),
			S.VARSTRING))
	CheckMarshal("table", {a = 12345, b = {x = -1, y = 1, z = 1000}, c = "abcde"},
		S.TABULAR(S.TUPLE(
				S.VARNUMBER,
				S.TABULAR(S.TUPLE(
					S.SIGNED(S.VARNUMBER), S.SIGNED(S.VARNUMBER), S.SIGNED(S.VARNUMBER)),
					"x", "y", "z"),
				S.VARSTRING),
				"a", "b", "c"))
	CheckMarshal("bittable", {a = 3, b = -2.6, c=123456789},
		S.TABULAR(S.BITARRAY(
			S.BITS(2),
			S.FRACTION(5, S.SIGNED(S.BITS(6))),
			S.BITS(30)),
		"a", "b", "c"))
	
	Print("Done!")
end

local ServiceTestInst = ServiceTest:new()
ServiceTestInst:Init()