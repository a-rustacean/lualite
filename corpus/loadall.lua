-- The reference side of the corpus harness: one process that loadfile's every
-- file in the list and prints a verdict per file.
--
-- A process per file would work and costs ~20k forks over the corpus, which is
-- slow enough to notice and buys nothing. This way the reference runs once and
-- the only thing crossing the process boundary is a line of output.
--
-- Input is the NUL-delimited path list run.sh built. The output is tab
-- separated, one record per file:
--
--     ok<TAB><path>
--     err<TAB><path><TAB><line><TAB><message>
--
-- Paths are passed through untouched. They can contain spaces, tabs are
-- therefore the only safe separator, and a path is never re-parsed by anything
-- that assumes whitespace. run.sh reads the first line of each record.

local list_path = ...

local list = assert(io.open(list_path, "rb"))
local raw = list:read("a")
list:close()

-- splitting on NUL rather than a newline, so that a path with a newline in it
-- cannot break the record apart
local paths = {}
for path in (raw .. "\0"):gmatch("([^\0]*)\0") do
  if #path > 0 then
    paths[#paths + 1] = path
  end
end

-- Lua reports an error as "<chunkname>:<line>: <message>", chunkname being the
-- path as it was given to loadfile. The line is what makes a wrong-but-refusing
-- answer detectable, so it is pulled out rather than left inside the message.
local function parse_error(message)
  -- a path may itself contain colons, so the split is not simply on the first
  -- one. The pattern works anyway: the chunkname is lazy, and it only stops
  -- where a run of digits is followed by ": ", which is what separates the line
  -- number from the message. A colon inside a path is followed by something
  -- else, so it cannot match.
  local _, prefix_line, rest = message:match("^(.-):(%d+): (.*)$")
  if not prefix_line then
    return nil, message
  end

  -- The prefix line is where the parser had got to, which for a semantic error
  -- is past the construct: `goto x` on line 1 followed by four blank lines and
  -- a `print` reports the prefix as line 6 and the message as "at line 1". The
  -- line inside the message is the construct's, which is the one worth
  -- comparing against, so it wins when it is there.
  local line = tonumber(rest:match("at line (%d+)"))
  return line or tonumber(prefix_line), rest
end

io.write(("%d\t%s\n"):format(#paths, _VERSION))

for i = 1, #paths do
  local path = paths[i]
  -- loadfile returns nil plus the reason, so nothing is ever executed
  local chunk, err = loadfile(path)
  if chunk then
    io.write("ok\t", path, "\n")
  else
    local line, message = parse_error(err or "failed with no message")
    io.write("err\t", path, "\t", line or "", "\t", (message or ""):gsub("[\r\n]+", " "), "\n")
  end

  -- flushing every record would cost a write syscall per file; the harness is
  -- interactive while this runs, so a partial flush on a timer is the useful
  -- middle ground
  if i % 500 == 0 then
    io.stdout:flush()
  end
end

io.stdout:flush()
