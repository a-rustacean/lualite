local k, v = 1, 2
local t = { k, named = k, [k] = v }
print(t[1], t.named, t[k])
