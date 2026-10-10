local function outer()
  local a = 1
  local function mid()
    local function inner() return a end
    return inner
  end
  return mid()
end
print(outer()())
