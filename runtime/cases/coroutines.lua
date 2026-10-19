-- coroutine library: creation, resume/yield transfer, statuses, wrap, close
local co = coroutine.create(function(a, b)
  print("body", a, b)
  local x, y = coroutine.yield(a + b, "yielded")
  print("back", x, y)
  return "done", 42
end)
print(type(co), coroutine.status(co), coroutine.isyieldable(co))
print(coroutine.resume(co, 1, 2))
print(coroutine.status(co))
print(coroutine.resume(co, 10, 20))
print(coroutine.status(co))
print(coroutine.resume(co))
print(coroutine.resume(co))
print(coroutine.close(co))
print(coroutine.status(co))
print(coroutine.close(co))

-- main thread
local main, is_main = coroutine.running()
print(type(main), is_main, coroutine.isyieldable())
print(coroutine.isyieldable())
print(coroutine.status(main))

-- yielding from pcall inside a coroutine works
local yielder = coroutine.create(function()
  local ok, value = pcall(function() return coroutine.yield("from pcall") end)
  print("pcall after yield", ok, value)
  return "end"
end)
print(coroutine.resume(yielder))
print(coroutine.resume(yielder, "again"))
print(coroutine.status(yielder))

-- wrap forwards arguments and results
local wrapper = coroutine.wrap(function(a, b)
  local c = coroutine.yield(a + b)
  return c * 2, "tail"
end)
print(wrapper(3, 4))
print(wrapper(10))

-- wrap errors carry the caller's position, and the thread dies
local broken = coroutine.wrap(function() error("boom") end)
print(pcall(broken))
print(pcall(broken))
local broken_table = coroutine.wrap(function() error({ code = 7 }) end)
local ok, err = pcall(broken_table)
print(ok, type(err), err.code)

-- errors raised inside a coroutine are reported by resume
local thrower = coroutine.create(function() error("inner") end)
print(coroutine.resume(thrower))
print(coroutine.status(thrower))
print(coroutine.close(thrower))

-- nested statuses
local outer
local inner = coroutine.create(function() print("inner sees", coroutine.status(outer)) end)
outer = coroutine.create(function()
  print("before", coroutine.status(inner))
  print(coroutine.resume(inner))
  print("after", coroutine.status(inner))
end)
print(coroutine.resume(outer))

-- a coroutine cannot resume itself or a resumer
local self_resumer = coroutine.create(function()
  print(coroutine.resume(self_resumer))
end)
print(coroutine.resume(self_resumer))

-- close runs pending close handlers with a nil error
local closing = coroutine.create(function()
  local guard <close> = setmetatable({}, { __close = function(_, e) print("closing", e) end })
  coroutine.yield("suspended")
  print("not reached")
end)
print(coroutine.resume(closing))
print(coroutine.close(closing))
print(coroutine.status(closing))

-- closing errors that a close handler raises
local failing_close = coroutine.create(function()
  local guard <close> = setmetatable({}, { __close = function() error("close failed") end })
  coroutine.yield()
end)
print(coroutine.resume(failing_close))
print(coroutine.close(failing_close))

-- close on a never-started coroutine is fine
local fresh = coroutine.create(function() error("never runs") end)
print(coroutine.close(fresh), coroutine.status(fresh))

-- yielding from the main thread is not allowed
print(pcall(function() coroutine.yield() end))

-- argument checking, both directly and through a native
print(pcall(coroutine.resume, 42))
print(pcall(function() coroutine.resume(42) end))
print(pcall(coroutine.status, 42))
print(pcall(function() coroutine.status(42) end))
print(pcall(coroutine.close, 42))
print(pcall(function() coroutine.close(42) end))
print(pcall(coroutine.create, 42))
print(pcall(function() coroutine.create(42) end))

-- closing a running or a normal coroutine is an error
print(pcall(function() coroutine.close(coroutine.running()) end))
local normal
normal = coroutine.create(function()
  print(pcall(function() coroutine.close(normal) end))
end)
print(coroutine.resume(normal))
