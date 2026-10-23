-- utf8 library: the codec, strict versus lax checks, and position arithmetic.
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, "\t"))
end

local function hex(s)
  if type(s) ~= "string" then return tostring(s) end
  return (s:gsub(".", function(c) return string.format("%02X", c:byte()) end))
end

local function showhex(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if type(value) == "string" then
      parts[#parts + 1] = hex(value)
    else
      parts[#parts + 1] = tostring(value)
    end
  end
  print(table.concat(parts, "\t"))
end

local function errors(...)
  show(pcall(...))
end

-- encodings at each width boundary, surrogates allowed
showhex(utf8.char())
showhex(utf8.char(65))
showhex(utf8.char(0))
showhex(utf8.char(0x7F, 0x80, 0x7FF))
showhex(utf8.char(0x800, 0xFFFF))
showhex(utf8.char(0x10000, 0x10FFFF))
showhex(utf8.char(0xD800))
showhex(utf8.char(65, 0, 66))
showhex(utf8.char(0x1FFFFF, 0x200000, 0x3FFFFFF))
showhex(utf8.char(0x4000000, 0x7FFFFFFF))
errors(utf8.char, -1)
errors(utf8.char, "x")
errors(utf8.char, 1.5)
errors(utf8.char, 0x80000000)

-- lengths, positions and the first invalid byte
local s = "h\xC3\xA9llo"
showhex(utf8.len(s))
showhex(utf8.len(s, 2))
showhex(utf8.len(s, 2, 3))
showhex(utf8.len(s, -1))
showhex(utf8.len(s, 2, -2))
showhex(utf8.len("", 1))
showhex(utf8.len("a\0b"))
errors(utf8.len, s, 0)
errors(utf8.len, s, 8)
errors(utf8.len, s, 1, 7)
showhex(utf8.len("\xC3"))
showhex(utf8.len("\xC3\x28"))
showhex(utf8.len("ab\xC3\x28"))
showhex(utf8.len("\xF4\x90\x80\x80"))
showhex(utf8.len("\xE6\x97"))
showhex(utf8.len("a\x80b"))

-- lax mode still rejects overlong forms and stray continuations, but takes
-- surrogates and values beyond Unicode
showhex(utf8.len("\xED\xA0\x80"))
showhex(utf8.len("\xED\xA0\x80", 1, -1, true))
showhex(utf8.len("\xF4\x90\x80\x80", 1, -1, true))
showhex(utf8.len("\xF8\x88\x80\x80\x80", 1, -1, true))
showhex(utf8.len("\xC0\x80", 1, -1, true))
showhex(utf8.len("a\xC3", 2, 2, true))

-- codepoints over ranges and negative positions
showhex(utf8.codepoint(s))
showhex(utf8.codepoint(s, 2))
showhex(utf8.codepoint(s, 1, -1))
showhex(utf8.codepoint(s, -2, -1))
errors(utf8.codepoint, s, 0)
errors(utf8.codepoint, s, 7)
showhex(utf8.codepoint(s, 2, 1))
errors(utf8.codepoint, "\xC3")
errors(utf8.codepoint, s, 3)
errors(utf8.codepoint, "\xF4\x90\x80\x80")
showhex(utf8.codepoint("\xED\xA0\x80", 1, 1, true))
errors(utf8.codepoint, "\xED\xA0\x80", 1, 1)
showhex(utf8.codepoint("\xF8\x88\x80\x80\x80", 1, 1, true))
errors(utf8.codepoint, "\xF8\x88\x80\x80\x80", 1, 1)
errors(utf8.codepoint, "\xC0\x80", 1, 1, true)

-- offsets forward, backward, from continuation bytes and at the end
local t = "a\xC3\xA9\xE6\x97\xA5"
showhex(utf8.offset(t, 1))
showhex(utf8.offset(t, 2))
showhex(utf8.offset(t, 3))
showhex(utf8.offset(t, 4))
showhex(utf8.offset(t, 5))
showhex(utf8.offset(t, 0))
showhex(utf8.offset(t, 0, 2))
showhex(utf8.offset(t, 0, 3))
showhex(utf8.offset(t, 0, 4))
showhex(utf8.offset(t, 0, 5))
showhex(utf8.offset(t, 0, 7))
showhex(utf8.offset(t, -1))
showhex(utf8.offset(t, -2))
showhex(utf8.offset(t, -3))
showhex(utf8.offset(t, -4))
showhex(utf8.offset(t, 2, 2))
showhex(utf8.offset(t, 1, 4))
errors(utf8.offset, t, 1, 3)
errors(utf8.offset, t, 1, 0)
errors(utf8.offset, t, 1, 8)
errors(utf8.offset, t, 0, 0)
showhex(utf8.offset("", 1))
showhex(utf8.offset("", 0))
showhex(utf8.offset("", -1))

-- codes: strict and lax iteration, including the always-invalid sequences
local out = {}
for p, cp in utf8.codes(t) do out[#out + 1] = p .. ":" .. cp end
show(table.concat(out, " "))
errors(function()
  for _ in utf8.codes("a\xC3", true) do end
end)
errors(function()
  local acc = {}
  for p, cp in utf8.codes("a\x80b", true) do acc[#acc + 1] = p .. ":" .. cp end
  return table.concat(acc, " ")
end)
errors(function()
  for _ in utf8.codes("a\xC3") do end
end)
errors(function()
  for _ in utf8.codes("a\x80b") do end
end)
local laxed = {}
for p, cp in utf8.codes("\xED\xA0\x80", true) do laxed[#laxed + 1] = p .. ":" .. cp end
show(table.concat(laxed, " "))
errors(function()
  for _ in utf8.codes("\xED\xA0\x80") do end
end)
errors(function()
  for _ in utf8.codes("\x80abc") do end
end)

showhex(utf8.charpattern)
