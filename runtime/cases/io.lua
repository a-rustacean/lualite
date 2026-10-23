-- io library: files, defaults, formats, and the errors they raise.
-- file handles are never printed: the reference stringifies them as
-- FILE* (0x...) and a table cannot match that shape.
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, "\t"))
end

local path = "lualite-io-case.tmp"
os.remove(path)

-- write a fixture
local w = assert(io.open(path, "w"))
w:write("12 alpha\n34 beta\n")
w:write("no-newline-tail")
w:close()

-- open in read mode and pull the lines back
local f = assert(io.open(path, "r"))
show(io.type(f))
show(f:read("l"))
show(f:read("l"))
show(f:read("l"))
show(f:read("l"))
f:seek("set", 0)
show(f:read("L"))
show(f:read("L"))
f:seek("end")
show(f:read("l"), f:read("l"))
f:seek("set", 0)
show(f:read(3))
show(f:read(1))
f:seek("set", 0)
local a, b, c = f:read("*a")
show(#a, b, c)
f:close()

-- closed-file errors
show(pcall(function() return f:read("l") end))
show(pcall(function() f:write("x") end))
show(io.type(f))

-- reopen for update: the two sides share one position. C requires a
-- positioning call between a read and a write on an update stream, so
-- the case does what programs must do anyway.
local u = assert(io.open(path, "r+"))
local wrote = u:write("AB")
show(wrote ~= nil)
show(u:read("l"))
u:seek("cur")
show(u:write("CD") ~= nil)
show(u:read("l", "l"))
u:close()

-- append mode starts at the end
local ap = assert(io.open(path, "a"))
ap:write("+appended\n")
ap:close()
local check = assert(io.open(path, "r"))
show(check:read("a"))
check:close()

-- truncating write
local tw = assert(io.open(path, "w"))
tw:write("short\n")
tw:close()
check = assert(io.open(path, "r"))
show(check:read("a"))
check:close()

-- seeking: whence set/cur/end and the resulting positions
local s = assert(io.open(path, "r"))
show(s:seek("set", 2))
show(s:read(3))
show(s:seek("cur"))
show(s:seek("cur", -3))
show(s:seek("end"))
show(s:seek("end", -2))
show(pcall(function() return s:seek("bad") end))
s:close()

-- line iterators
for line in io.lines(path) do
  print("line", line)
end

-- io.lines over a missing name raises
show(pcall(io.lines, path .. ".missing"))

-- default input and output move independently of the caches
local previous_input = io.input()
io.input(path)
show(io.read("l"))
io.input(previous_input)
local previous_output = io.output()
io.output(path)
show(io.write("default-output\n") == io.output())
io.close()
check = assert(io.open(path, "r"))
show(check:read("a"))
check:close()
io.output(previous_output)

-- io.read through the default input
io.input(path)
show(io.read(5))
show(io.read("l"))
io.input(previous_input)

-- argument errors and type names
show(pcall(io.open))
show(pcall(io.open, path, "z"))
local okf = io.open(path)
show(io.type(okf))
okf:close()
show(pcall(io.write))
show(pcall(io.close, 42))
show(io.type(42))
show(io.type("s"))
show(io.type(nil))
show(io.type(io.stdin))
show(select(2, io.stdout:seek("set", 0)) ~= nil)

-- tmpfile is a readable read/write file
local tf = assert(io.tmpfile())
show(io.type(tf))
show(tf:write("temp data") ~= nil)
show(tf:seek("set"))
show(tf:read("l"))
tf:close()

-- flush on a fresh file is fine
local fl = assert(io.open(path, "a"))
show(fl:flush())
fl:close()

-- setvbuf accepts the documented modes
local sb = assert(io.open(path, "r"))
show(pcall(function() return sb:setvbuf("full") end))
show(pcall(function() return sb:setvbuf("line", 1024) end))
show(pcall(function() return sb:setvbuf("no") end))
show(pcall(function() return sb:setvbuf("bad") end))
sb:close()

os.remove(path)

-- numeral scanning takes only a numeral's prefix and leaves the rest of the
-- stream alone; a line that cannot begin one consumes nothing
local np = "lualite-io-scan.tmp"
local nf = io.open(np, "w")
nf:write("line one\nnum 42 1.5\n0x1p3z 12abc 1e .\n   42rest\n")
nf:close()
nf = assert(io.open(np, "r"))
show(nf:read("n"))
show(nf:read("l"))
show(nf:read("n"))
show(nf:read("l"))
show(nf:read("n"))
show(string.format("%q", nf:read(2)))
show(nf:read("n"))
show(nf:read("l"))
show(nf:read("n"))
show(nf:read("n"))
show(nf:read("l"))
show(nf:seek("set", 0))
show(nf:read(0))
show(nf:read("n"))
show(nf:read("l"))
nf:close()
os.remove(np)

-- update streams keep stdio's read-ahead when a write follows a read
local up = "lualite-io-update.tmp"
local uf = assert(io.open(up, "w"))
uf:write(string.rep("A", 20) .. "B")
uf:close()
uf = assert(io.open(up, "r+"))
show(uf:read(4))
uf:write("XXXX")
show(uf:seek())
uf:close()
uf = assert(io.open(up, "r+"))
show(uf:read(2))
show(uf:flush())
uf:write("YY")
show(uf:seek())
uf:close()
local all = assert(io.open(up, "r"))
show(all:read("a"))
all:close()
os.remove(up)

-- a read at least a block long bypasses the read-ahead
local big = "lualite-io-update-big.tmp"
local bf = assert(io.open(big, "w"))
bf:write(string.rep("A", 10000))
bf:close()
bf = assert(io.open(big, "r+"))
show(bf:read(4))
bf:write("XXXX")
show(bf:seek())
bf:close()
bf = assert(io.open(big, "r+"))
show(#bf:read(5000))
bf:write("YYYY")
show(bf:seek())
bf:close()
os.remove(big)

-- append streams start at the end and write there whatever the position says
local ap = "lualite-io-append.tmp"
local af = assert(io.open(ap, "w"))
af:write("ABCDE")
af:close()
af = assert(io.open(ap, "a+"))
show(af:seek())
show(af:read(1))
show(af:seek("set", 0))
af:write("XY")
show(af:seek())
show(af:read("a"))
af:close()
os.remove(ap)

-- writing a stream that was opened for reading fails like fwrite does
local rp = "lualite-io-readonly.tmp"
local rf = assert(io.open(rp, "w"))
rf:write("abc")
rf:close()
rf = assert(io.open(rp, "r"))
show(rf:write("x"))
show(pcall(function() return rf:write("x", 2) end))
show(pcall(function() return rf:write({}) end))
show(rf:write() == rf)
rf:close()
os.remove(rp)

-- only '+', then only 'b's, may follow the first mode character
local mp = "lualite-io-modes.tmp"
local mf = assert(io.open(mp, "w"))
mf:write("abc")
mf:close()
show(io.type(assert(io.open(mp, "rbb"))))
show(io.type(assert(io.open(mp, "r+bb"))))
show(pcall(io.open, mp, "rb+"))
show(pcall(io.open, mp, "r+b+"))
show(pcall(io.open, mp, ""))
os.remove(mp)
