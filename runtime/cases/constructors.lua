-- literal constructors size their array part exactly, while tables built by
-- insertion grow by powers of two; the difference is visible through next's
-- invalid-key rule and through where a keyed field ends up.
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, "\t"))
end

local function at(t, k)
  local ok, a, b = pcall(next, t, k)
  if not ok then return "raise:" .. tostring(a) end
  if a == nil then return "end" end
  return tostring(a) .. "=" .. tostring(b)
end

local function f2() return 10, 11 end
local function f3() return 10, 20, 30 end
local function unpack300()
  local u = {}
  for i = 1, 300 do u[i] = i end
  return table.unpack(u)
end
local function varg(...) return { ... } end

-- {1,2,f2()}: the multret field counts once up front, and the list run then
-- grows the array to exactly the four values it writes
show(at({ 1, 2, f2() }, 4), at({ 1, 2, f2() }, 5))
-- {f3()}: three values written into an array that starts at size zero
show(at({ f3() }, 3), at({ f3() }, 4))
-- {...}: no static size at all, so the array matches the vararg count
show(at(varg(), 1))
show(at(varg(7), 2))
show(at(varg(7, 8, 9), 4))
-- record fields are not list elements: the array stays at two
show(at({ 1, 2, x = 3 }, 3))
-- a keyed field under the list count lands in the array and the list value
-- that follows overwrites it
local b = { [4] = "X", 1, 2, f2() }
local keys = {}
for k in pairs(b) do keys[#keys + 1] = k end
table.sort(keys)
for _, k in ipairs(keys) do io.write(k, "=", tostring(b[k]), ";") end
print()
b[4] = nil
local after = {}
for k in pairs(b) do after[#after + 1] = k end
table.sort(after)
show(table.concat(after, ","))
-- and a keyed field past the count stays in the hash
local c = { [3] = "X", 1, 2 }
show(c[3], at(c, 3))

-- long lists keep the exact size too, instead of rounding to a power of two
local lit60 = {1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32,33,34,35,36,37,38,39,40,41,42,43,44,45,46,47,48,49,50,51,52,53,54,55,56,57,58,59,60}
show(at(lit60, 61))
show(at({ unpack300() }, 301))
