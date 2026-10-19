-- string.format: the C conversions lualite reproduces
local function show(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, "\t"))
end

-- integers
show(string.format("%d|%i|%u", -3, 4, 5))
show(string.format("%x|%X|%o", 255, 255, 8))
show(string.format("%05d|%-5d|%5d|%+d|% d", 42, 42, 42, 42, 42))
show(string.format("%#x|%#o", 255, 8))
show(string.format("%.4d|%.0d", 7, 0))

-- floats, fixed
show(string.format("%f|%.2f|%.6f", 3.14159, 3.14159, 3.14159))
show(string.format("%.0f|%.1f", 2.5, 0.05))
show(string.format("%08.2f|%-8.2f|%+.1f", 3.5, 3.5, 3.5))

-- floats, scientific
show(string.format("%e", 12345.6789))
show(string.format("%E", 0.00012345))
show(string.format("%.2e|%.0e", 12345.6789, 12345.6789))
show(string.format("%e", 0))
show(string.format("%e", -1.5))

-- floats, general
show(string.format("%g", 0.00001))
show(string.format("%g", 123456789))
show(string.format("%g", 1234567))
show(string.format("%g", 12345.6789))
show(string.format("%g", 0))
show(string.format("%g", 100))
show(string.format("%.3g|%.10g", 1234.5678, 3.14159265358979))
show(string.format("%G", 1e-7))

-- strings, width and precision
show(string.format("%s|%10s|%-10s|%.3s", "abc", "abc", "abc", "abcdef"))
show(string.format("%q", 'a"b\n'))
show(string.format("%q", "\r\t\1\1\1"))
show(string.format("%q", "\0\0001"))
show(string.format("%c%c", 72, 105))

-- a format built at runtime, and %% and trailing literal text
local format = "%s=%" .. "d;"
show(string.format(format, "n", 9) .. "end")
show(string.format("100%%"))
show(string.format("%x %s", 31, true))

-- %q over the other literal types
show(string.format("%q %q %q %q", 2.5, 7, nil, true))
show(string.format("%q %q", math.mininteger, 0.1))
show(string.format("%q", 1/0))

-- %p prints (null) for values lua_topointer refuses
show(string.format("%p %p", nil, 1))
local holder = {}
show(string.format("[%10p]", holder))

-- %c narrows to a byte like C's %c
show(string.format("%c%c%c", 65, 300, 256))

-- alternate forms and precision corners
show(string.format("%#o %#x %#X %#o", 8, 255, 255, 0))
show(string.format("%5.0d|%.0x|%#.0o", 0, 0, 0))
show(string.format("%5.3d|%-5.3d|", 42, 42))
show(string.format("%+.2e|% .2E|%#.0f|%#g", 12345.6789, 12345.6789, 2.5, 1.5))

-- %s renders anything, through tostring
show(string.format("%s %s %s", true, nil, 12.5))

-- rejected specifications
show(pcall(string.format, "%z", 1))
show(pcall(string.format, "%+s", "x"))
show(pcall(string.format, "%+q", "x"))
