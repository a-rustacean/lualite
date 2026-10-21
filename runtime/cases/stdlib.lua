-- stdlib argument errors and deterministic results across the libraries.
-- every failing call goes through pcall so the message is compared;
-- nothing here depends on the clock, the environment, or pairs order.
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, "\t"))
end

local function raises(...)
  show(pcall(...))
end

-- base
raises(type)
raises(tostring, nil, nil)
raises(tonumber, {}, 1)
raises(tonumber, "0x")
raises(select)
raises(select, 2)
show(select("#", select(2, "a", "b", "c")))
raises(error, {}, 1)
raises(rawlen, 1)
raises(rawget, 1, "k")
raises(rawset, 1, "k", "v")
raises(rawequal, 1)
raises(setmetatable, {}, 42)
raises(getmetatable, {})
show(getmetatable(""))
show(getmetatable(print) == nil)
raises(next, {})
raises(pairs, 1)
raises(ipairs, 1)
raises(ipairs, "s")
raises(pcall)
raises(xpcall, function() end)
raises(assert)
raises(assert, nil, 42)
raises(assert, false, {})

-- argument order and numbering through method syntax
local function badself()
  local t = setmetatable({}, { __index = {} })
  return t:nope(1)
end
raises(badself)

-- string
raises(string.len, {})
raises(string.sub, "abc", {})
raises(string.rep, "a", {})
raises(string.byte, "abc", 1, "x")
raises(string.char, 256)
raises(string.char, 1.5)
raises(string.format, "%")
raises(string.format, "%d", "s")
raises(string.format, "%#s", "x")
raises(string.find, "abc")
raises(string.find, "abc", "(", 1)
raises(string.gsub, "abc")
raises(string.gmatch, "abc")
raises(string.pack, "z")
raises(string.pack, "i")
raises(string.unpack, "i4", "abc")
raises(string.packsize, "i")
raises(string.dump, 1)
show(("abc"):len(), ("abc"):upper(), ("abc"):sub(2))
show(string.format("%5.2f|%+d|%q|%s", 3.14159, 7, "a\"b", "x"))
show(string.format("%a %A %e %E %g %G", 0.5, 0.5, 1234.5, 1234.5, 0.0001, 0.0001))
show(string.find("hello world", "o w"))
show(string.find("hello", "l+"))
show(string.match("key=value", "(%w+)=(%w+)"))
local collected = {}
for k, v in string.gmatch("a=1 b=2", "(%w+)=(%w+)") do
  collected[#collected + 1] = k .. ":" .. v
end
show(table.concat(collected, ","))
show(string.gsub("hello world", "o", "0"))
show(string.gsub("abc", "", "-"))
show(string.pack("i4", 7), string.unpack("i4", string.pack("i4", 7)))
show(string.packsize("i4 c3"))
show(string.pack(">I2", 258):byte(1, 2))
show(string.unpack("c3", "abcdef"))

-- table
raises(table.insert)
raises(table.insert, {})
raises(table.insert, { 1 }, 2, 3)
raises(table.remove, {})
raises(table.concat, { 1, "a" })
raises(table.concat, {}, ",")
raises(table.sort, { 1, "a" })
raises(table.sort, {})
raises(table.move, {}, 1, 2, 3, {})
show(select("#", table.pack()))
show(select("#", table.pack(1, nil, 3)))
show(table.unpack({ 1, 2, 3 }))
show(table.unpack({ 1, 2, 3 }, 2))
local sorted = { 3, 1, 2 }
table.sort(sorted)
show(table.concat(sorted, ","))
table.sort(sorted, function(a, b) return a > b end)
show(table.concat(sorted, ","))
local moved = { 1, 2, 3, 4, 5 }
table.move(moved, 1, 3, 3)
show(table.concat(moved, ","))

-- math
raises(math.abs, {})
raises(math.floor, {})
raises(math.max)
raises(math.min)
raises(math.fmod, 5, 0)
raises(math.ult, 1.5, 2)
raises(math.tointeger, {})
show(math.floor(-2.5), math.ceil(-2.5), math.fmod(7, 3))
show(math.max(1, 3, 2), math.min(1, -1, 0))
show(math.tointeger(3.0), math.tointeger("10"))
show(math.type(1), math.type(1.0), math.type("1"))
show(string.format("%.14g", math.sqrt(2)))
show(string.format("%.14g", math.sin(1)))
show(string.format("%.14g", math.log(8, 2)))
show(math.modf(3.7), math.modf(-3.7))
show(math.ult(1, 2), math.ult(2, 1))
show(math.pi > 3.14 and math.pi < 3.15, math.huge > 1e308)
show(math.maxinteger, math.mininteger)
show(math.maxinteger + 1 == math.mininteger)

-- seeded random so the two sides agree
math.randomseed(12345)
show(math.type(math.random(10)))
local r1, r2, r3 = math.random(10), math.random(10), math.random(10)
show(r1 >= 1 and r1 <= 10, r2 >= 1 and r2 <= 10, r3 >= 1 and r3 <= 10)
show(math.random(0) ~= nil)
local lo, hi = math.random(5, 5), math.random(-3, -1)
show(lo, hi >= -3 and hi <= -1)
local a, b = math.randomseed(99)
show(a, b)

-- utf8
raises(utf8.char, 0x110000)
raises(utf8.len, 1)
raises(utf8.codepoint, "abc", 0)
show(utf8.char(233, 32, 97))
show(utf8.len("héllo"))
show(utf8.codepoint("héllo", 1, 3))
show(utf8.offset("héllo", 3))
show(utf8.charpattern)

-- os: fixed values only, nothing that reads the clock or the host.
-- os.time(table) is deliberately not asserted: the reference resolves it in
-- local time and this runtime is UTC-only, so any concrete table would only
-- agree by luck. The error paths below do not depend on the timezone.
show(os.difftime(100, 40))
show(os.date("!*t", 0).year, os.date("!*t", 0).month, os.date("!*t", 0).day)
show(os.date("!%Y-%m-%d", 0))
show(os.date("!%H:%M:%S", 0))
show(os.date("!*t", 86400).day)
raises(os.time, { year = 2020 })
raises(os.time, { year = 2020, month = 1, day = 1, hour = 1.5 })
raises(os.time, 0.5)
raises(os.date, "%Y", {})
raises(os.difftime)
raises(os.date, "!", {})

-- collectgarbage modes that both sides answer
show(type(collectgarbage("count")))
show(collectgarbage("isrunning"))
collectgarbage("stop")
show(collectgarbage("isrunning"))
collectgarbage("restart")
show(collectgarbage("isrunning"))
show(collectgarbage("collect"))
show(collectgarbage("step"))
