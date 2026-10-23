-- metamethods in full: every arithmetic hook, the index and call chains,
-- tostring and name in errors, and to-be-closed variables.
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  print(table.concat(parts, "\t"))
end
local function raises(...)
  show(pcall(...))
end

local mt = {}
local proxy = setmetatable({}, mt)
for _, name in ipairs({ "__add", "__sub", "__mul", "__div", "__mod", "__pow", "__unm", "__idiv", "__concat", "__len", "__index", "__newindex", "__eq", "__lt", "__le", "__call", "__tostring", "__name" }) do
  mt[name] = function() return "mm:" .. name end
end
show(proxy + 1)
show(1 + proxy)
show(proxy - 1)
show(proxy * 2)
show(proxy / 2)
show(proxy // 2)
show(proxy % 2)
show(proxy ^ 2)
show(-proxy)
show(proxy .. "x")
show(#proxy)
show(proxy[1])
raises(function() proxy[1] = 2 end)
show(proxy == {})
show(proxy < {})
show(proxy <= {})
show(proxy())
show(tostring(proxy))
raises(function() error(proxy) end)

-- __index chain depth
local base = { a = 1, b = 2 }
local mid = setmetatable({ c = 3 }, { __index = base })
local leaf = setmetatable({ d = 4 }, { __index = mid })
show(leaf.a, leaf.b, leaf.c, leaf.d, leaf.e)

-- __newindex table target and rawset inside
local written = {}
local target = {}
local writer = setmetatable({}, {
  __newindex = function(t, k, v) written[#written + 1] = k .. "=" .. tostring(v); rawset(target, k, v) end,
  __index = target,
})
writer.x = 10
show(writer.x, target.x, written[1])

-- __index function returning multiple values through select
local fmm = setmetatable({}, { __index = function() return 1, 2, 3 end })
show(select("#", fmm.k))

-- __call chains and errors in __call
local c1 = setmetatable({}, { __call = function(self, ...) return "called", ... end })
show(c1(7, 8))
local c2 = setmetatable({}, { __call = function() error("in call", 2) end })
raises(c2)
raises(function() c2() end)

-- __tostring error formatting
local e = setmetatable({}, { __tostring = function() return "custom tostring" end })
raises(error, e)
show(tostring(e))

-- __name in type errors
local n = setmetatable({}, { __name = "MyType" })
raises(math.sin, n)
raises(rawlen, n)

-- __metatable protection
local prot = setmetatable({}, { __metatable = "locked" })
show(getmetatable(prot))
raises(setmetatable, prot, {})

-- __close: to-be-closed variables close in reverse order
do
  local log = {}
  local function closer(name)
    return setmetatable({}, { __close = function() log[#log + 1] = name end })
  end
  do
    local a <close> = closer("a")
    local b <close> = closer("b")
    log[#log + 1] = "body"
  end
  show(table.concat(log, ","))
end
-- a close during unwinding still runs, and the original error survives
do
  local log = {}
  local function closer(name)
    return setmetatable({}, { __close = function() log[#log + 1] = name end })
  end
  local ok, err = pcall(function()
    local a <close> = closer("a")
    error("boom")
  end)
  show(ok, err, table.concat(log, ","))
end
raises(function()
  local x <close> = 42
end)
-- an error raised by __close replaces a normal exit
do
  local log = {}
  local ok1, err1 = pcall(function()
    local c3 <close> = setmetatable({}, { __close = function() log[#log + 1] = "3" end })
  end)
  show(ok1, tostring(err1):gsub(".*: ", ""), table.concat(log, ","))
  local ok2, err2 = pcall(function()
    local c1 <close> = setmetatable({}, { __close = function() log[#log + 1] = "1" end })
    local c2 <close> = setmetatable({}, { __close = function() log[#log + 1] = "2"; error("close fail") end })
  end)
  show(ok2, tostring(err2):gsub(".*: ", ""), table.concat(log, ","))
end

-- string/number coercion in arithmetic and comparison
show("10" + 5, "3.5" * 2, "0x10" + 0)
show("10" == 10, " 10" + 0)
raises(function() return "10" < 10 end)
raises(function() return "10" + "20" end)
raises(function() return "abc" + 1 end)
show(10 // "3", 10 % "3")
show("1e2" + 1, "  7  " + 0)

-- integer/float arithmetic edges
show(7 // 2, -7 // 2, 7 // -2, -7 // -2)
show(7 % 2, -7 % 2, 7 % -2, -7 % -2)
show(3.0 == 3, math.type(3.0), math.type(3))
show(2^53, 2^53 + 1, 1e308 * 10)
show(math.maxinteger // 2, math.mininteger // -1 == math.mininteger)
raises(function() return math.mininteger // -1 end)
raises(function() return 0 // 0 end)
raises(function() return 7 // 0 end)
raises(function() return 7 % 0 end)
raises(function() return 7 / 0 end)
show(7 / 0, -7 / 0)

-- varargs
local function count(...) return select("#", ...) end
show(count(), count(nil), count(nil, nil), count(1, nil, 3))
local function pack_all(...) return table.pack(...) end
show(select("#", pack_all(nil, nil, nil)))
local function pass(...) return ... end
show(pass(1, 2, 3))
show(select(-1, "a", "b", "c"))
raises(select, -2, "a", "b")

-- generic for over custom iterator with state/control
local function iter(t, i)
  i = i + 1
  if t[i] then return i, t[i] end
end
local acc = {}
for i, v in iter, { 10, 20 }, 0 do acc[#acc + 1] = i .. ":" .. v end
show(table.concat(acc, ","))

-- numeric for edges
local sum = 0
for i = 1, 3 do sum = sum + i end
show(sum)
local cnt = 0
for i = 10, 1, -2 do cnt = cnt + 1 end
show(cnt)
local fl = 0
for i = 1, 2, 0.5 do fl = fl + i end
show(fl)
raises(function() for i = 1, "x" do end end)
raises(function() for i = 1, 10, 0 do end end)
local zs = 0
raises(function() for i = 1, 3, zs do end end)
local zf = 0.0
raises(function() for i = 1, 3, zf do end end)
local brk = 0
for i = 1, 10 do brk = i; if i == 3 then break end end
show(brk)

-- load edge cases
show(select("#", load("return 1, 2, 3")))
show(load("return 1, 2, 3")())
show(load("this is not lua"))
local once42 = false
show(load(function()
  if once42 then return nil end
  once42 = true
  return "return 42"
end)())
show(pcall(load, function() error("reader fail") end))
show(load(""))
show(load("return"))
show(select("#", load("return")()))
local env = { x = 99 }
local f = load("return x", "chunk", "t", env)
show(f(), env.x)
env.x = 100
show(f())
show(load("\x1bLua garbage"))
show(load("return = 1"))
show(load("local a = 1 return a +", "name", "t"))
show(load("return function() return 'inner' end")()())
raises(load, 42)
local vf = load("local t = ... return select('#', ...), t")
show(vf(1, 2, 3))

-- a metatable's __name is the type every runtime error reports, the way
-- luaT_objtypename prefers it over the basic type
local named = setmetatable({}, { __name = "Widget" })
raises(function() return named + 1 end)
raises(function() return named .. "x" end)
raises(function() return #named end)
raises(function() return named() end)
raises(function() return named < named end)
raises(function() return named ^ 2 end)
raises(function() local x = 1; for i = 1, named do end end)
raises(function() return named.missing.deeper end)
raises(function() return named & 1 end)
raises(function() return -named end)
