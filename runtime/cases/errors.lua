-- runtime error values: what pcall hands back, and error levels
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, "\t"))
end

local function raises(f)
  local ok, message = pcall(f)
  show(ok, message)
end

-- arithmetic on values that are not numbers
raises(function() return "x" + 1 end)
raises(function() return 1 + "x" end)
raises(function() return true + "x" end)
raises(function() return {} + 1 end)
raises(function() return 1 + {} end)
raises(function() return 1 + true end)
raises(function() return -"x" end)
raises(function() return "x" .. {} end)
raises(function() return {} .. "x" end)
raises(function() return 1 < nil end)
raises(function() return {} < {} end)
raises(function() return "a" < 1 end)

-- bitwise operands must have an integer representation
raises(function() return 3 & 1.5 end)
raises(function() return 1.5 | 1 end)
raises(function() return 1 ~ 1.5 end)
raises(function() return 1 << 0.5 end)
raises(function() return 1.5 >> 1 end)
raises(function() return ~1.5 end)
raises(function() return 3 & "x" end)
raises(function() return 3 & {} end)

-- division and modulo by zero only bite the integer halves
raises(function() return 7 // 0 end)
raises(function() return 7 % 0 end)
show(7.0 // 0, 7.0 % 0, -7.0 // 0)

-- error() levels: 0 has no prefix, 1 and up name the caller of the level
show(select(2, pcall(function() error("plain") end)))
show(select(2, pcall(function() error("no position", 0) end)))
show(select(2, pcall(function() error("level two", 2) end)))
show(select(2, pcall(function() error("level nine", 9) end)))
show(select(2, pcall(function() error({ code = 7 }) end)))

local function nested() error("from nested") end
local function middle() nested() end
show(select(2, pcall(middle)))
show(select(2, pcall(function() error("two up", 2) end)))

-- error values that are not strings pass through untouched
local marker = {}
local ok, value = pcall(function() error(marker) end)
show(ok, value == marker, type(value))

-- assert and its message
show(pcall(assert, false, "assertion message"))
show(pcall(assert, nil))
show(pcall(assert, false, 42))

-- xpcall runs the handler before unwinding
show(xpcall(function() error("boom") end, function(e) return "handled: " .. e end))
show(xpcall(function() return 1 end, function(e) return e end))

-- calls of non-functions
raises(function() local t = {} return t.missing() end)
raises(function() return (nil)() end)
