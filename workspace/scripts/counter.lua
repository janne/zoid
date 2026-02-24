-- scripts/counter.lua
-- Creates counter.txt with 1 if missing, otherwise increments its integer content.

local counter = zoid.file("counter.txt")

local function parse_integer(text)
  if type(text) ~= "string" then
    return nil
  end

  local trimmed = text:match("^%s*(.-)%s*$")
  if trimmed == "" then
    return 0
  end

  if not trimmed:match("^[-+]?%d+$") then
    return nil
  end

  return tonumber(trimmed)
end

local current = 0
local ok_read, read_result = pcall(function()
  return counter:read()
end)

if ok_read then
  local parsed = parse_integer(read_result)
  if parsed == nil then
    io.stderr:write("counter.txt does not contain an integer.\n")
    return
  end
  current = parsed
else
  local err = tostring(read_result)
  if not err:find("FileNotFound", 1, true) then
    io.stderr:write("Failed to read counter.txt: ", err, "\n")
    return
  end
end

local next_value = current + 1

local ok_write, write_error = pcall(function()
  counter:write(tostring(next_value))
end)

if not ok_write then
  io.stderr:write("Failed to write counter.txt: ", tostring(write_error), "\n")
  return
end
