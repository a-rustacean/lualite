-- integer and float arithmetic, the split, and the coercions
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, "\t"))
end

show(1 + 2, 1 - 2, 2 * 3, 7 / 2, 7 // 2, 7 % 3, 2 ^ 10)
show(-7 // 2, -7 % 3, 7 // -2, 7 % -2, -7.5 % 3, 7.5 // 2)
show(math.type(1 + 2), math.type(1 / 2), math.type(2 ^ 2), math.type(1 + 0.5))
show(3 == 3.0, 3 < 3.5, 2 ^ 0.5 == math.sqrt(2))
show(math.maxinteger + 1 == math.mininteger)
show(0xffffffffffffffff, 0x10, 1e2, 1E2, 0xA.8p1)
show(1e15, 1e16, 1e-5, 2^53, 0.1 + 0.2, 1/0, -1/0)
show(math.tointeger(3.0), math.tointeger(3.5), math.tointeger("4"))
show(math.max(1, 2.5, 2), math.min(1, 2.5, 2), math.abs(-3), math.floor(-3.5), math.ceil(-3.5))
show(math.fmod(7, 3), math.modf(3.7))
show(5 & 3, 5 | 3, 5 ~ 3, ~5, 1 << 4, 256 >> 4, -1 >> 1)
show(math.ult(-1, 1), math.ult(1, -1))
show("10" + 5, "10" * "2", "10" / 4, "3" ^ 2, "0x10" + 0, " 7 " - 2, -"5")

local ok, err = pcall(function() return "x" + 1 end)
show(ok, err)
show(pcall(function() return 3 & 1.5 end))
