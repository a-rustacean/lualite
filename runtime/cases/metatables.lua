-- metatables: the hooks lualite implements
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, "\t"))
end

-- __index as a table and as a function
local base = { inherited = "base" }
local child = setmetatable({ own = "child" }, { __index = base })
show(child.own, child.inherited, rawget(child, "inherited"))

local fallback = setmetatable({}, { __index = function(_, key) return "fallback:" .. key end })
show(fallback.anything)

-- chained __index
local level2 = setmetatable({}, { __index = base })
local level1 = setmetatable({}, { __index = level2 })
show(level1.inherited)

-- __newindex as a table and as a function
local log = {}
local strict = setmetatable({}, { __newindex = function(t, k, v) rawset(t, k, v) log[#log + 1] = k end })
strict.first = 1
strict.second = 2
show(strict.first, strict.second, table.concat(log, ","))

local redirect = setmetatable({}, { __newindex = {} })
local target = getmetatable(redirect).__newindex
redirect.moved = 42
show(redirect.moved, target.moved)

-- __call
local callable = setmetatable({}, { __call = function(self, a, b) return a + b end })
show(callable(2, 3))

-- arithmetic hooks
local vector = {}
vector.__index = vector
vector.__add = function(a, b) return setmetatable({ x = a.x + b.x, y = a.y + b.y }, vector) end
vector.__sub = function(a, b) return setmetatable({ x = a.x - b.x, y = a.y - b.y }, vector) end
vector.__mul = function(a, b) return setmetatable({ x = a.x * b, y = a.y * b }, vector) end
vector.__unm = function(a) return setmetatable({ x = -a.x, y = -a.y }, vector) end
vector.__eq = function(a, b) return a.x == b.x and a.y == b.y end
vector.__lt = function(a, b) return a.x < b.x end
vector.__le = function(a, b) return a.x <= b.x end
local function vec(x, y) return setmetatable({ x = x, y = y }, vector) end

local v1, v2 = vec(1, 2), vec(3, 4)
local sum = v1 + v2
show(sum.x, sum.y, (v2 - v1).x, (v1 * 3).y, (-v1).x)
show(v1 == vec(1, 2), v1 == v2, v1 ~= v2)
show(v1 < v2, v1 <= v2, v2 > v1, v2 >= v1)

-- __concat and __len
local concat_meta = { __concat = function(a, b) return "joined" end, __len = function() return 99 end }
local joined = setmetatable({}, concat_meta)
show(joined .. "x", "x" .. joined, #joined)

-- __tostring
local shown = setmetatable({}, { __tostring = function() return "custom" end })
show(tostring(shown), shown)

-- __close
local closed = {}
do
  local resource <close> = setmetatable({}, { __close = function(_, err) closed[#closed + 1] = tostring(err) end })
end
show(#closed, closed[1])

-- __close receives the error on an error exit
local saw_error
local ok = pcall(function()
  local resource <close> = setmetatable({}, { __close = function(_, err) saw_error = err end })
  error("leaving")
end)
show(ok, saw_error)

-- protected metatables
local protected = setmetatable({}, { __metatable = "locked" })
show(getmetatable(protected))
show(pcall(setmetatable, protected, {}))

-- getmetatable of a string is the shared string metatable
show(getmetatable("x") == getmetatable("y"), type(getmetatable("x").__index))

-- __pairs
local custom_pairs = setmetatable({}, { __pairs = function()
  local done = false
  return function()
    if done then return nil end
    done = true
    return "only", "once"
  end
end })
for k, v in pairs(custom_pairs) do show(k, v) end
