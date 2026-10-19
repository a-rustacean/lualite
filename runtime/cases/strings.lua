-- the string library, byte oriented, with patterns
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, "\t"))
end

show(#"hello", ("hello"):upper(), ("HELLO"):lower(), ("abc"):rep(3), ("ab"):rep(3, "-"))
show(("hello"):sub(2), ("hello"):sub(2, -2), ("hello"):sub(-3), ("hello"):sub(10))
show(("hello"):byte(), ("hello"):byte(2, 4), string.char(104, 105))
show(("hello"):reverse(), string.rep("", 5, "-"))
show(string.format("%d %i %u", -3, 4, 5))
show(string.format("%5.2f|%-5d|%05d|%x|%X|%o", 3.14159, 42, 42, 255, 255, 8))
show(string.format("%s|%q|%c", "text", 'a"b\n', 65))
show(string.format("%e|%g|%%", 12345.6789, 0.00001))
show(string.find("hello world", "world"))
show(string.find("hello world", "o w"), string.find("hello world", "o", 6))
show(string.find("hello", "l+"), string.find("hello", "^h"), string.find("hello", "o$"))
show(string.match("hello 42 world", "(%a+) (%d+)"))
show(string.match("2024-01-15", "(%d+)-(%d+)-(%d+)"))
show(string.match("key=value", "(%w+)=(%w+)"))
show(string.match("abc", "(a)(b)(c)"), string.match("hello", "()ll()"))
show(string.gsub("hello world", "o", "0"))
show(string.gsub("hello world", "o", "0", 1))
show(string.gsub("hello", "(l)(l)", "%2%1"))
show(string.gsub("abc", "%a", function(c) return c:upper() end))
show(string.gsub("$name is $age", "%$(%w+)", { name = "alice", age = "30" }))
show(string.match("  trim  ", "^%s*(.-)%s*$"))
show(string.find("hello", "%l+"), string.match("hello", "%u"))
show(string.match("2024", "%d+"), string.match("abc123", "%d+"))
show(string.match("a.b.c", "%.(.+)$"))
show(string.match("hello", "[aeiou]"), string.match("hello", "[^aeiou]+"))
show(string.match("ab12cd", "%a+"), string.match("ab12cd", "%a+%d+"))
show(string.match("aXbXc", "X.-X"))
show(string.match("(nested (parens))", "%b()"))
show(string.gsub("hello", "l", "L"))
show(string.gsub("abc", "", "-"))

local words = {}
for word in string.gmatch("one two three", "%a+") do words[#words + 1] = word end
show(table.concat(words, ","))

local pairs_found = {}
local text = "x=1, y=2"
for key, value in string.gmatch(text, "(%w+)=(%w+)") do
  pairs_found[#pairs_found + 1] = key .. ":" .. value
end
show(table.concat(pairs_found, " "))

show(string.find("abc", "b", 1, true))
show(string.match("a+b", "a+b", 1, true))
