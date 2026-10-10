-- The number rules, checked against a reference Lua 5.4.
--
-- This file is a Lua script and is run as one, writing what Lua makes of every
-- expression below. `differential/numbers.sh` regenerates `Number.golden.txt` by
-- running it, and `Number.golden.zig` runs the same lines through lualite's own
-- `Number` and compares. Nothing here is hand-checked, so a rule written down
-- wrongly in lualite shows up as a difference rather than as a belief.
--
-- Only literals and operators appear below, because that is what the evaluator
-- in `Number.golden.zig` knows without a VM. Anything needing a name is spelled
-- out instead, so both sides run the same text: `math.maxinteger` is written as
-- its own numeral, and the string conversion rules are reached through coercion
-- in arithmetic rather than through `tonumber`.
--
-- The two sides agree on the parts below this line: `show(v, kind)` writes the
-- value and its type, `bad(fn, wanted)` writes the message a call has to raise.
-- The Zig side skips to the first case rather than reading this.

local function show(value, kind)
  -- `math.type` rather than `type`, since `type` says `number` for both halves
  -- of a number and the split is the whole point of these lines
  local actual = math.type(value)
  if actual == nil then
    actual = type(value)
  end
  if actual ~= kind then
    error(("expected %s, got %s"):format(kind, actual))
  end
  io.write("ok\t", kind, "\t", tostring(value), "\n")
end

-- `expr` is the source of the expression rather than the expression, since a line
-- that has to raise would otherwise take the whole file down with it
local function bad(expr, wanted)
  local chunk = load("return " .. expr)
  local ok, err = pcall(chunk)
  if ok then
    error("expected an error from " .. expr)
  end
  if not tostring(err):find(wanted, 1, true) then
    error(("expected %q in %q"):format(wanted, tostring(err)))
  end
  io.write("err\t", wanted, "\n")
end

-- ==== cases start here ====

show(1, "integer")
show(1.0, "float")
show(0, "integer")
show(-0.0, "float")
show(0x10, "integer")
show(0xffffffffffffffff, "integer")
show(0x10000000000000000, "integer")
show(9223372036854775807, "integer")
show(9223372036854775808, "float")
show(-9223372036854775809, "float")
show(1e15, "float")
show(0x1p4, "float")
show(0xA.8p1, "float")

-- integer arithmetic wraps rather than becoming a float
show(9223372036854775807 + 1, "integer")
show(-9223372036854775807 - 2, "integer")
show(9223372036854775807 * 2, "integer")
show(-0x8000000000000000, "integer")
show(-9223372036854775807 - 1 // -1, "integer")
show(-9223372036854775807 - 1 % -1, "integer")

-- `/` and `^` are always floats; `+ - *` only when a side is one
show(4 / 2, "float")
show(7 // 2, "integer")
show(7.0 // 2, "float")
show(7 % 2, "integer")
show(-7 % 2, "integer")
show(7 % -2, "integer")
show(7.5 % 2, "float")
show(-7.5 % 2, "float")
show(1 + 1.0, "float")
show(2 ^ 2, "float")
show(2 ^ 63, "float")
show(-2 ^ 2, "float")
show(7.5 / 2.5, "float")

-- comparison crosses over, and `1 == 1.0` is true
show(1 < 1.0, "boolean")
show(1 == 1.0, "boolean")
show(2 > 1.5, "boolean")
show(1 == 1, "boolean")
show(1 <= 1, "boolean")
show(1 < (0/0), "boolean")

-- a float with an exact integer representation works for the bitwise operators
show(3.0 & 1, "integer")
show(3 ~ 1, "integer")
show(-1 ~ 0, "integer")
show(1 << 3, "integer")
show(256 >> 4, "integer")
show(1 << 64, "integer")
show(1 << 65, "integer")
show(-1 >> 1, "integer")
show(-8 >> 2, "integer")
show(-1 >> 63, "integer")
show(-1 >> 64, "integer")
bad("3.5 & 1", "number has no integer")
bad("3.5 ~ 1", "number has no integer")

-- division by zero is an error over integers and an infinity over floats
bad("1 // 0", "attempt to divide by zero")
bad("1 % 0", "attempt to perform")
show(1.0 // 0, "float")
show(-1.0 // 0, "float")
show(0.0 // 0, "float")
show(1.0 % 0, "float")

-- string conversion, which shares the numeral reader with a literal. It reaches
-- the arithmetic operators and not the bitwise ones, which is why the `bad` lines
-- below are about a string rather than about an integer representation.
show("10" + 5, "integer")
show("1.5" * 2, "float")
show("0x10" + 0, "integer")
show("  7  " + 0, "integer")
bad('"x" + 1', "attempt to")
bad('"3.5" & 1', "attempt to perform bitwise operation on a string")

-- what each type prints as, which is where the `.0` comes from
show(1.0, "float")
show(-1.0, "float")
show(0.1, "float")
show(1e14, "float")
show(1e15, "float")
show(1e16, "float")
show(1e-4, "float")
show(1e-5, "float")
show(1/3, "float")
show(1/0, "float")
show(-1/0, "float")
show(0/0, "float")
show(123456789012345, "integer")
show(9223372036854775807, "integer")
show(-9223372036854775807 - 1, "integer")
show(2 ^ 63, "float")
show(3, "integer")
show(3 .. "", "string")
show(3.5 .. "", "string")
show(1.0 .. "", "string")
show(1.0 + 0.0, "float")