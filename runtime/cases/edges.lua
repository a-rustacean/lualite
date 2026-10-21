-- mixed edges: coercion corners, float and NaN table keys, string indices,
-- io.read formats, metatable restrictions, and deep pcall nesting.
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  print(table.concat(parts, "\t"))
end
local function raises(...)
  show(pcall(...))
end

-- concat and tostring of numbers
show(1 .. 2)
show(1 .. 2.5)
show(1.0 .. "")
show(3 .. "" .. 4)
show(-0.0)
show(2 ^ 20)
show(1e15)
show(1e16)
show(0.1 + 0.2)
show(string.format("%.14g", 1/3))
show(tostring(1e309))
show(tostring(-1e309))
show(tostring(0/0))

-- float/integer key identity and rawequal
local t = {}
t[1] = "int"
show(t[1.0], t[1])
t[2.5] = "float"
show(t[2.5], t[2])
show(rawequal(1, 1.0))
show(rawequal(0/0, 0/0))
raises(function() local u = {} u[0/0] = 1 end)
raises(function() local u = {} u[1/0] = 1 end)
raises(function() local u = {} u[nil] = 1 end)
raises(function() local u = { [0/0] = 1 } end)
raises(rawset, {}, 0/0, 1)
raises(rawset, {}, nil, 1)
show(pcall(function() local u = {} u[0/0] = nil end))
show(pcall(function() local u = {} u[nil] = nil end))

-- string indices and wild ranges
show(("hello"):byte())
show(("hello"):byte(-1))
show(("hello"):byte(3, 100))
show(("hello"):byte(6))
show(("hello"):sub(-100, 100))
show(("hello"):sub(3, 2))
show(("hello"):sub(0))
show(("hello"):rep(0))
show(("hello"):rep(2, ","))
show(("hi"):len(), (""):len())
show(("abc"):reverse(), ("a"):upper(), ("AbC"):lower())
show(("hello"):find("xyz"))
show(("a.b.c"):gmatch("[^.]+")())
show(select(2, ("a.b.c"):gmatch("[^.]+")))

-- table length flavors
local arr = { 10, 20, 30 }
show(#arr)
arr[2] = nil
show(#arr >= 1 and #arr <= 3)
show(rawlen(arr))
local lenmt = setmetatable({ 1, 2 }, { __len = function() return 99 end })
show(#lenmt, rawlen(lenmt))
raises(rawlen, "str")
show(#"string", #"")

-- io.read formats: "n", "L" and friends
local path = "lualite-edges-case.tmp"
os.remove(path)
local w = assert(io.open(path, "w"))
w:write("42 3.5 rest\nsecond line\nno-newline")
w:close()
local f = assert(io.open(path, "r"))
show(f:read("n"))
f:seek("set", 0)
show(f:read("L"))
show(f:read("L"))
f:close()
f = assert(io.open(path, "r"))
local lines = {}
for line in f:lines() do lines[#lines + 1] = line end
show(#lines, lines[1])
f:close()
f = assert(io.open(path, "r"))
show(f:read(2), f:read(1))
show(f:read("*line"))
f:close()
os.remove(path)

-- metatable restrictions: only tables take one
local sm = getmetatable("")
show(sm.__index == string)
raises(function() setmetatable("", {}) end)
raises(function() setmetatable(42, {}) end)
show(getmetatable(nil))
show(getmetatable(42))

-- _G and _ENV basics
show(type(_G), _G == _G, _G.print == print)
local function envswap()
  local _ENV = { x = 5, print = print }
  return x, _ENV
end
show(envswap())
do
  local _ENV = setmetatable({}, { __index = _G })
  show(type(print))
end

-- select edge cases
show(select("#", nil))
show(select(1, "a", "b"))
show(select("#", select(2, "a", "b", "c")))
raises(select, 0, "a")
show(select(-3, "a", "b", "c"))

-- to-be-closed with nil/false values register nothing
do
  local log = {}
  local ok = pcall(function()
    local a <close> = false
    local b <close> = nil
    local c <close> = setmetatable({}, { __close = function() log[#log + 1] = "c" end })
    local d <close> = true
  end)
  show(ok, table.concat(log, ","))
end

-- numeric for with float bounds
local s = 0
for i = 1, 3, 1 do s = s + i end
show(s)
local s2 = 0
for i = 0.5, 2.5 do s2 = s2 + 1 end
show(s2)
local zstep = 0.0
raises(function() for i = 1, 10, zstep do end end)
local s3 = 0
for i = 3, 1, -1 do s3 = s3 + i end
show(s3)

-- vararg and select through methods
local obj = {}
function obj:each(...)
  local out = {}
  for i = 1, select("#", ...) do out[#out + 1] = tostring((select(i, ...))) end
  return table.concat(out, "-")
end
show(obj:each(1, nil, 3))

-- deep pcall nesting
local function depth(n)
  if n == 0 then error("bottom") end
  local ok, err = pcall(depth, n - 1)
  if not ok then return false, err end
  return true
end
show(depth(50))
show(depth(200))
