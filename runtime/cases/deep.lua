-- coroutines under load, string and table depth, error levels, upvalues.
-- object addresses appear in a few strings; the harness normalises them.
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  print(table.concat(parts, "\t"))
end
local function raises(...)
  show(pcall(...))
end

-- coroutine lifecycle and failure
local co = coroutine.create(function(a, b)
  local c = coroutine.yield(a + b, a - b)
  return c * 2
end)
show(coroutine.status(co))
show(coroutine.resume(co, 5, 3))
show(coroutine.status(co))
show(coroutine.resume(co, 10))
show(coroutine.status(co))
show(coroutine.resume(co))
show(coroutine.isyieldable())
show(coroutine.running())
raises(coroutine.resume, coroutine.create(function() error("co-err") end))
local bad = coroutine.create(function() return 1 end)
coroutine.resume(bad)
raises(coroutine.resume, bad)
local wrap = coroutine.wrap(function(a) return a + 1 end)
show(wrap(41))
raises(coroutine.wrap, function() error("wrap-err") end)
local w2 = coroutine.wrap(function() error("wrap-err2") end)
raises(w2)
show(coroutine.close(coroutine.create(function() end)))
-- closing a suspended coroutine runs its to-be-closed variables
local closelog = {}
local cc = coroutine.create(function()
  local t <close> = setmetatable({}, { __close = function() closelog[#closelog + 1] = "closed" end })
  coroutine.yield("y")
end)
coroutine.resume(cc)
coroutine.close(cc)
show(table.concat(closelog, ","), coroutine.status(cc))
-- yield inside pcall inside a coroutine
local co2 = coroutine.create(function()
  local ok, v = pcall(function() return coroutine.yield("from-pcall") end)
  return ok, v
end)
show(coroutine.resume(co2))
show(coroutine.resume(co2))
-- one yield per resume, driven by varargs
local co3 = coroutine.create(function(...)
  for i = 1, select("#", ...) do coroutine.yield(select(i, ...)) end
end)
show(coroutine.resume(co3, "x", "y"))
show(coroutine.resume(co3))
show(coroutine.resume(co3))
show(coroutine.resume(co3))

-- string.format %q and escapes
show(string.format("%q", "line1\nline2\ttab\\back\"quote"))
show(string.format("%q", "null\0byte"))
show(string.format("%s %d %i %u", "x", 42, -7, 5))
show(string.format("%5.3f|%05.2f|%-5.2f|%+.1f", 3.14159, 3.1, 3.1, -2.5))
show(string.format("%x %X %o %e %g", 255, 255, 8, 1234.5, 0.0001))
show(string.format("%c%c", 72, 105))
show(string.format("%%literal%%"))
raises(string.format, "%d", 1.5)
raises(string.format, "%s")
show(string.format("%q", 42))
show(string.format("%q", 3.5))

-- string.pack/unpack breadth
show(string.pack("b", -1):byte())
show(string.pack("B", 255):byte())
show(string.pack("h", -2):byte(1, 2))
show(string.pack("H", 258):byte(1, 2))
show(string.pack("i4", -1):byte(1, 4))
show(string.pack("I8", 1):byte(1, 8))
show(string.pack("f", 1.0):byte(1, 4))
show(string.pack("d", 1.0):byte(1, 8))
show(string.pack(">i2", 258):byte(1, 2))
show(string.pack("<i2", 258):byte(1, 2))
show(string.unpack("b", string.pack("b", -1)))
show(string.unpack(">i2 i2", string.pack(">i2 i2", 1, 2)))
show(string.packsize("b h i4 d"))
show(string.packsize("<i8"))
raises(string.pack, "i0", 1)
raises(string.pack, "q", 1)
raises(string.unpack, "i4", "abc")

-- gsub anchors and gmatch edges
show(string.gsub("hello world", "o", "0", 1))
show(string.gsub("^abcabc", "^abc", "X"))
show(string.gsub("aaa", "a", "b", 2))
show(string.gsub("abc", "z", "Y"))
show(string.gsub("", "a?", "-"))
local gcollect = {}
for w in string.gmatch("", ".") do gcollect[#gcollect + 1] = w end
show(#gcollect)
local g2 = {}
for s in string.gmatch("abc", "") do g2[#g2 + 1] = "[" .. s .. "]" end
show(table.concat(g2))
local g3 = {}
for k in string.gmatch("a1b22c333", "%d+") do g3[#g3 + 1] = k end
show(table.concat(g3, ","))
show(string.find("aaa", "a-", 1))
show(string.find("abc", "a*c"))
show(("abc"):find("b"))
show(("hello"):match("l+"))
show(("hello"):gsub("l", "L", 1))

-- table algorithms under stress
local t = { 5, 3, 1, 4, 2 }
table.sort(t)
show(table.concat(t, ","))
table.sort(t, function(a, b) return a > b end)
show(table.concat(t, ","))
raises(table.sort, { 1, 2, 3 }, function(a, b) error("cmp fail") end)
raises(table.sort, { 1, 2 }, function(a, b) return a < b and b < a end)
local m = { 1, 2, 3, 4, 5 }
table.move(m, 2, 4, 1)
show(table.concat(m, ","))
local m2 = { 1, 2, 3, 4, 5 }
table.move(m2, 1, 3, 3)
show(table.concat(m2, ","))
local ins = { 1, 2, 3 }
table.insert(ins, 1, 9)
show(table.concat(ins, ","))
table.insert(ins, 4, 8)
show(table.concat(ins, ","))
table.remove(ins, 1)
show(table.concat(ins, ","))
show(select("#", table.remove({})))
local sparse = {}
sparse[1] = 1
sparse[2] = nil
sparse[3] = 3
show(#sparse >= 1 and #sparse <= 3)
raises(table.insert, {}, 1, 2, 3)
raises(table.concat, { 1, "a" })
show(table.unpack({ 1, 2, 3 }, 1, 3))
show(select("#", table.unpack({ 1, nil, 3 }, 1, 3)))

-- error levels and messages
raises(error, "plain")
raises(error, "withlevel", 0)
local function lvl2() error("at2", 2) end
local function lvl1() lvl2() end
raises(lvl1)
local function direct() error("direct") end
raises(direct)
raises(error, 42)
raises(error, {})
local okp, errp = pcall(function() error({ code = 5 }) end)
show(okp == false, errp.code)
raises(xpcall, function() error("x") end, function(e) return "handled: " .. e end)
show(select("#", xpcall(function() error("x", 0) end, function(e) return e end)))
local traced = xpcall(function() error("x") end, function(e) return type(e) end)
show(traced)
raises(xpcall, function() error("x") end, 42)
raises(assert, false, "msg", 2)
raises(function() assert(nil) end)

-- upvalue semantics
local function counter()
  local n = 0
  return function() n = n + 1 return n end
end
local c1, c2 = counter(), counter()
show(c1(), c1(), c2())
local up = {}
for i = 1, 3 do
  up[i] = function() return i end
end
show(up[1](), up[2](), up[3]())
local shared_a, shared_b
do
  local x = 10
  shared_a = function() x = x + 1 return x end
  shared_b = function() return x end
end
show(shared_a(), shared_a(), shared_b())
local function make_env()
  local _ENV = { print = print, pairs = pairs, k = "env" }
  local function inner() return k end
  return inner()
end
show(make_env())
local t2 <close> = nil
show(t2)
