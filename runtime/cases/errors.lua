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

-- indexing values that carry no __index: the message says where the value
-- came from, parenthesis is transparent, and the reported position is the
-- caller's own line even after an __index function has run
raises(function() local x; return x.y end)
raises(function() local x; return x[1] end)
raises(function() local x; return (function() return x.y end)() end)
raises(function() return no_such_global_name.x end)
raises(function() local t = {}; return t.a.b end)
raises(function() local t = {}; return t.a:method() end)
raises(function() return (5).x.y end)
raises(function() local t; return (t).x end)
raises(function() local x; x.y = 1 end)
raises(function() no_such_global_name.x = 1 end)
raises(function() local t = {}; t.a.b = 1 end)
raises(function() local s = "x"; s.y = 1 end)

local function nil_index() return nil end
raises(function()
  local t = setmetatable({}, { __index = nil_index })
  return t.a.b
end)

local chain_a, chain_b = {}, {}
setmetatable(chain_a, { __index = chain_b })
setmetatable(chain_b, { __index = chain_a })
raises(function() return chain_a.missing end)

local write_a, write_b = {}, {}
setmetatable(write_a, { __newindex = write_b })
setmetatable(write_b, { __newindex = write_a })
raises(function() write_a.missing = 1 end)

-- a global name is looked up through _ENV, and that binding is what a
-- type error names
raises(function() local _E = nil; local _ENV = _E; return print(1) end)
raises(function() local _E = nil; local _ENV = _E; some_global = 1 end)
raises(function()
  local _E = nil
  local _ENV = _E
  local function inner() return print(1) end
  return inner()
end)
raises(function()
  local _E = nil
  local _ENV = _E
  local function inner() some_global = 1 end
  return inner()
end)
