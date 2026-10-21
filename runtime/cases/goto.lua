-- goto and labels at runtime: control flow, scope rules, continue patterns
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, "\t"))
end

-- forward and backward gotos
do
  local i = 1
  ::top::
  show("top", i)
  i = i + 1
  if i <= 3 then goto top end
  show("done", i)
end

-- goto continue: skipping the rest of a loop body
local sum = 0
for i = 1, 6 do
  if i % 2 == 0 then goto continue end
  sum = sum + i
  ::continue::
end
show("sum", sum)

-- goto out of nested loops
local escaped = false
for i = 1, 3 do
  for j = 1, 3 do
    if i * j >= 4 then
      escaped = true
      goto out
    end
  end
end
::out::
show("escaped", escaped)

-- a goto may skip a declaration that comes after the label
do
  local x = "outer"
  goto skip
  ::skip::
  local y = "declared after"
  show("skip", x, y)
end

-- a goto may not land inside a local's scope: the compiler refuses,
-- and the message is compared through load
local chunk, err = load([[
  goto done
  local a = 1
  ::done::
  return a
]])
show(chunk, err)

-- a valid goto that leaves a local's scope
local ok = load([[
  do
    local a = 1
    goto outside
  end
  ::outside::
  return "left"
]])
show(ok())

-- labels as plain jump targets with no gotos
do
  goto plain
  ::plain::
  show("plain")
end

-- break still works next to labels
for i = 1, 5 do
  if i == 3 then break end
  show("loop", i)
end

-- repeat/until with a goto back to its start
local attempts = 0
repeat
  attempts = attempts + 1
  if attempts < 3 then goto again end
  break
  ::again::
until false
show("attempts", attempts)

-- gotos inside functions are per-function
local function counter()
  local n = 0
  ::again::
  n = n + 1
  if n < 2 then goto again end
  return n
end
show(counter(), counter())

-- a label at the very end of a chunk
local tail = load("local x = 1 goto done ::done:: return x")
show(tail())

-- multiple gotos to one label
local order = {}
local function push(v) order[#order + 1] = v end
do
  push(1)
  if false then goto both end
  push(2)
  ::both::
  push(3)
end
show(table.concat(order, ","))

-- goto across an if into the enclosing block
do
  local steps = 0
  if true then
    steps = steps + 1
    goto after
  end
  steps = steps + 100
  ::after::
  show("after", steps)
end

-- while loop with a goto skip
local visited = {}
local w = 0
while w < 4 do
  w = w + 1
  if w == 2 then goto cont end
  visited[#visited + 1] = w
  ::cont::
end
show(table.concat(visited, ","))
