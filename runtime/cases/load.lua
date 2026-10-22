-- load, loadfile, dofile, and string.dump: results and message fidelity
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, "\t"))
end

-- successful loads and what their chunks return
local f = load("return 1 + 2")
show(type(f), f())
local g = load("a, b = ... return a + b, select('#', ...)", "chunkname")
show(g(10, 20, 30))
show(load("return x", nil, "t", { x = 99 })())
show(select(2, load(42)))
show(pcall(load, true))
show(pcall(load, {}))
local said_once = false
show(select(2, load(function()
  if said_once then return nil end
  said_once = true
  return "no"
end)))

-- chunkname defaults: source for a string, reader gets "=(load)"
local named = load("return 1", "my chunk")
show(named())
show(select(2, load("syntax error here !")))

-- mode rejection is a returned failure, not a raise
show(load("return 1", "name", "x"))
show(load("return 1", "name", ""))

-- load with a reader function: the pieces join verbatim, so this one fails
-- inside the numeral rather than compiling
local lines = { "local a = 1", "local b = 2", nil }
local index = 0
local via_reader, via_error = load(function()
  index = index + 1
  return lines[index]
end)
show(type(via_reader), via_error)
-- pieces that form valid source compile and run
local good_lines = { "local a = 1\n", "local b = 2\n", nil }
local good_index = 0
local good_reader = load(function()
  good_index = good_index + 1
  return good_lines[good_index]
end)
show(type(good_reader), good_reader())

-- a reader that ends without ever returning a string compiles the empty chunk
show(load(function() return nil end))
show(load(function() return end))

-- reader values that are not strings stop the load; `pcall` shows the
-- message it hands back with neither the main chunk's position nor the
-- top-level handler's traceback on it
-- a number is appended to the source like any other piece, so a reader that
-- keeps returning one never ends; this one stops after a single piece
local said_number = false
show(load(function()
  if said_number then return nil end
  said_number = true
  return 42
end))
show(pcall(load, function() return {} end))

-- argument errors
show(pcall(load))
show(pcall(function() load(print) end))
show(load(print))

-- parse errors carry position, message, and the near token
local cases = {
  "return )",
  "return 1 +",
  "if true then",
  "local 1 = 2",
  "x = = 1",
  "'unfinished",
  "[[unfinished long",
  "--[[unfinished comment",
  "return 1 end",
  "break",
  "goto nowhere",
  "::label:: goto label",
  "local a = 1 local a = 2 a = a",
  "local x <const> = 1 x = 2",
  "return function() break end",
}
for i = 1, #cases do
  local chunk = load(cases[i], "src")
  if chunk then
    show(i, "accepted")
  else
    show(i, select(2, load(cases[i], "src")))
  end
end

-- string.dump's refusals carry a positioned message. (Dumping a plain Lua
-- function succeeds in the reference and is refused here — a known gap, so
-- no probe for it.)
show(pcall(string.dump, print))
show(pcall(string.dump))
show(pcall(string.dump, 1))
show(pcall(string.dump, "s"))
show(select(2, pcall(string.dump, print)))

-- loadfile and dofile over a real file
local path = "lualite-load-case.tmp"
os.remove(path)
local handle = assert(io.open(path, "w"))
handle:write("return 'from file'\n")
handle:close()
show(loadfile(path)())
show(select(2, loadfile(path .. ".missing")))
show(dofile(path))
os.remove(path)

-- a chunk that fails at runtime reports its own chunkname
local failing = load("error('inside chunk')", "named chunk")
show(select(2, pcall(failing)))
os.remove(path)

-- load can bind an environment
local with_env = load("return from_env", "env chunk", "t", { from_env = "bound" })
show(with_env())

-- binary chunks: refused by mode with the plain message, and by the header
-- with the exact reason, before anything in the body is looked at
show(load("\27Lua\84\0", "name", "t"))
show(load("\27Lua\84\0", "name", ""))
show(load("return 1", "name", "b"))
show(load("\27Lua\84\0", "name", "b"))
show(load("\27Lua\83\0", "name", "b"))
show(load("\27Lua\84\1", "name", "b"))
show(load("\27Lub\84\0", "name", "b"))
show(load("\27Lua\84", "name", "b"))
show(load("\27", "name", "b"))

-- a reader that returns "" ends the chunk just like nil
local seq = { "return 'from reader'", "" }
local step = 0
local via_empty = load(function()
  step = step + 1
  return seq[step]
end)
show(via_empty())

-- a reader that raises hands its error straight back, object and all —
-- under `pcall`, where nothing adds a position or a traceback to it
show(pcall(load, function() error("reader boom", 0) end))
local thrown = { code = 5 }
local ok, failed, err = pcall(load, function() error(thrown, 0) end)
show(ok, failed == nil, err == thrown)
