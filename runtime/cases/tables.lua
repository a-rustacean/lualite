-- tables: constructors, length, iteration and the library
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, "\t"))
end

local t = { 10, 20, 30, x = 1, ["y z"] = 2 }
show(#t, t[1], t.x, t["y z"], t[4])
t[4] = 40
show(#t, t[4])

local nested = { a = { b = { c = 3 } } }
show(nested.a.b.c, nested["a"]["b"]["c"])

local mixed = { 1, 2, nil, 4 }
show(mixed[2], mixed[4], rawlen(mixed))

table.insert(t, 50)
table.insert(t, 1, 5)
show(table.concat(t, ","))
show(table.remove(t), table.remove(t, 1), #t)

local packed = table.pack(7, nil, 9)
show(packed.n, packed[1], packed[2], packed[3])
show(table.unpack(packed, 1, packed.n))
show(table.unpack({ 1, 2, 3 }))

local moved = { 1, 2, 3, 4, 5 }
table.move(moved, 1, 3, 3)
show(table.concat(moved, ","))
local dest = {}
table.move({ 1, 2, 3 }, 1, 3, 1, dest)
show(table.concat(dest, ","))

local sorted = { 5, 2, 8, 1, 9, 3 }
table.sort(sorted)
show(table.concat(sorted, ","))
table.sort(sorted, function(a, b) return a > b end)
show(table.concat(sorted, ","))

local by_key = { b = 2, a = 1, c = 3, d = 4 }
local keys = {}
for key in pairs(by_key) do keys[#keys + 1] = key end
table.sort(keys)
for _, key in ipairs(keys) do io.write(key, "=", by_key[key], ";") end
print()

local list = { "x", "y", "z" }
for index, value in ipairs(list) do io.write(index, ":", value, " ") end
print()

-- next directly
local key, value = next({ 41, 42 })
show(key, value)
show(next({}))
show(next({ 1 }, 1))

-- integer keys are ordered, so this iteration is reproducible
local counters = {}
for i = 1, 5 do counters[i] = i * i end
local sum = 0
for k, v in pairs(counters) do sum = sum + k + v end
show(sum)

-- next's resume key: an integer inside the array part resumes without a
-- presence check, so a hole key works; every other absent key raises
local hole = { "a", nil, "c" }
show(next(hole, 2))
local keyed = { [1] = "a", [3] = "c" }
show(pcall(next, keyed, 2))
show(pcall(next, { 1, 2, 3 }, 4))
show(pcall(next, {}, 1))
show(pcall(next, { 1, 2, 3 }, 2.0))
show(pcall(next, { 1, 2, 3 }, 0))
show(pcall(next, { 1, 2, 3 }, -1))

-- integer keys past 2^32 are ordinary hash keys, not array indexes
local far = {}
far[4294967297] = "far"
show(far[4294967297])
show(pcall(next, far, 4294967297))
far[4294967297] = nil
show(far[4294967297])

-- ipairs walks through __index and stops only where __index yields nil
local base = { [1] = "a", [2] = "b", [3] = "c" }
local derived = setmetatable({}, { __index = base })
for i, v in ipairs(derived) do io.write(i, v, " ") end
print()
local counted = setmetatable({}, {
  __index = function(_, k) if k <= 3 then return k * 10 end end,
})
for i, v in ipairs(counted) do io.write(i, "=", v, " ") end
print()
