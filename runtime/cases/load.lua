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
show(select(2, load(true)))
show(select(2, load({})))
show(select(2, load(function() return "no" end)))

-- chunkname defaults: source for a string, reader gets "=(load)"
local named = load("return 1", "my chunk")
show(named())
show(select(2, load("syntax error here !")))

-- mode rejection is a returned failure, not a raise
show(load("return 1", "name", "x"))
show(load("return 1", "name", ""))

-- load with a reader function
local lines = { "local a = 1", "local b = 2", nil }
local index = 0
local via_reader = load(function()
  index = index + 1
  return lines[index]
end)
show(type(via_reader), via_reader())

-- a reader that ends without ever returning a string compiles the empty chunk
show(load(function() return nil end))
show(load(function() return end))

-- reader values that are not strings stop with a returned failure
show(load(function() return 42 end))
show(load(function() return {} end))

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

-- string.dump refuses every function with a positioned message
show(pcall(string.dump, print))
local plain = load("return 1")
show(pcall(string.dump, plain))
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
