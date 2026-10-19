-- control flow: if, loops, break, goto, and the scoping around them
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, "\t"))
end

local function classify(n)
  if n < 0 then return "negative" elseif n == 0 then return "zero" else return "positive" end
end
show(classify(-1), classify(0), classify(1))

local total = 0
for i = 1, 10 do total = total + i end
show(total)

for i = 10, 1, -2 do io.write(i, " ") end
print()

local steps = {}
for i = 1, 2, 0.25 do steps[#steps + 1] = string.format("%.2f", i) end
show(table.concat(steps, ","))

local n = 0
while n < 5 do n = n + 1 end
show(n)

n = 10
repeat n = n - 1 until n == 3
show(n)

local found = nil
for i = 1, 100 do
  if i * i > 50 then found = i break end
end
show(found)

local outer = 0
for i = 1, 3 do
  for j = 1, 3 do
    if j == 2 then break end
    outer = outer + 1
  end
end
show(outer)

-- goto forward, backward, out of loops
do
  local i = 0
  ::top::
  i = i + 1
  if i < 3 then goto top end
  show("goto loop", i)
end

do
  local reached = false
  for i = 1, 5 do
    if i == 3 then goto out end
  end
  ::out::
  reached = true
  show("escaped", reached)
end

-- scoping: a local shadows, and the shadow is gone after the block
local x = "outer"
do
  local x = "inner"
  show(x)
end
show(x)

for x = 1, 1 do show(x) end
show(x)

-- locals declared after a repeat's body are fresh each iteration
local captures = {}
for i = 1, 3 do
  captures[#captures + 1] = function() return i end
end
show(captures[1](), captures[2](), captures[3]())

-- and a while loop's body repeat
local while_captures = {}
local w = 0
while w < 3 do
  w = w + 1
  local w_local = w
  while_captures[#while_captures + 1] = function() return w_local end
end
show(while_captures[1](), while_captures[2](), while_captures[3]())

-- variable attributes
local constant <const> = 41
show(constant)
local closed_counter = 0
do
  local resource <close> = setmetatable({}, { __close = function() closed_counter = closed_counter + 1 end })
  show("inside", closed_counter)
end
show("closed", closed_counter)
