local M = {}
function M.a() return 1 end
function M.b.c() return 2 end
function M:d() return 3 end
print(M.a(), M.b.c(), M:d())
