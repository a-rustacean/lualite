-- functions, closures, varargs and multiple results
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, "\t"))
end

local function identity(...) return ... end
show(identity(1, 2, 3))
show((identity(1, 2, 3)))

local a, b, c, d = identity(1, 2)
show(a, b, c, d)

local function count(...) return select("#", ...) end
show(count(), count(1), count(nil, nil), count(1, nil, 3))

local function tail(...) return select(2, ...) end
show(tail(1, 2, 3, 4))

-- varargs in a table constructor, only expanded at the end
local adjusted = { (identity(1, 2, 3)) }
show(#adjusted, adjusted[1])
local list = { identity(1, 2, 3), identity(4, 5, 6) }
show(#list, list[1], list[2], list[3])
local all = { 0, identity(1, 2, 3) }
show(#all, all[4])

local function counter()
  local n = 0
  return function() n = n + 1 return n end
end
local c1, c2 = counter(), counter()
show(c1(), c1(), c2(), c1())

-- two closures over the same local share it
local function make_pair()
  local shared = 0
  return function() shared = shared + 1 return shared end,
         function() return shared end
end
local bump, peek = make_pair()
bump()
bump()
show(peek())

-- recursion
local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
show(fact(10))

-- mutual recursion through a forward local
local is_even, is_odd
function is_even(n) if n == 0 then return true end return is_odd(n - 1) end
function is_odd(n) if n == 0 then return false end return is_even(n - 1) end
show(is_even(10), is_odd(7))

-- a function returning another function calling table functions
local function apply(f, ...) return f(...) end
show(apply(function(x, y) return x * y end, 6, 7))

-- method definitions and calls
local object = { value = 10 }
function object:get() return self.value end
function object:add(n) self.value = self.value + n return self end
show(object:get(), object:add(5):get())
show(object.get(object))

-- call sugar
local function tagged(t) return t.tag end
show(tagged { tag = "table sugar" })

local function chars(s) return #s end
show(chars "string sugar")

-- pcall, xpcall and error values
local ok, message = pcall(function() error("boom") end)
show(ok, message)
local ok2, value = pcall(function() error({ code = 42 }) end)
show(ok2, type(value), value.code)
show(pcall(function() return 1, 2, 3 end))
show(pcall(error))
show(pcall(error, nil))
show(select(2, pcall(function() error("multi", 0) end)))
show(select(2, pcall(function() error("multi", 2) end)))
local handled = xpcall(function() error("inner") end, function(e) return "handled: " .. e end)
show(handled)
show(xpcall(function() error("x") end, function(e) return e .. "!" end, "extra"))

-- assert
show(pcall(assert, false, "assertion message"))
show(pcall(assert, nil))
show(assert(true, "unused"), assert(1, 2, 3))

-- a deep chain of ordinary calls still has to come back
local function down(n)
  if n == 0 then return "done" end
  return down(n - 1)
end
show(down(200))
