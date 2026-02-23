-- Grep utility for Zoid workspace
-- Usage:
--   zoid run scripts/grep.lua <pattern> [path] [--no-recursive] [--max=N]
--   zoid run scripts/grep.lua "string" src --max=200
--
-- Notes:
-- - Uses the built-in filesystem_grep tool.
-- - Defaults: path="" (repo root), recursive=true, max_matches=5000
-- - Prints matches as: file:line: text

local argv = arg or {...}

local function starts_with(s, prefix)
  return s:sub(1, #prefix) == prefix
end

local function usage(msg)
  if msg then io.stderr:write(msg .. "\n\n") end
  io.stderr:write("Usage: grep.lua <pattern> [path] [--no-recursive] [--max=N]\n")
  error("usage")
end

if #argv < 1 then
  usage("Missing <pattern>.")
end

local pattern = argv[1]
local path = ""
local recursive = true
local max_matches = 5000

for i = 2, #argv do
  local a = argv[i]
  if a == "--no-recursive" then
    recursive = false
  elseif starts_with(a, "--max=") then
    local n = tonumber(a:sub(#"--max=" + 1))
    if not n or n < 1 or n > 5000 then
      usage("--max must be an integer between 1 and 5000")
    end
    max_matches = n
  elseif starts_with(a, "--") then
    usage("Unknown flag: " .. a)
  else
    if path == "" then
      path = a
    else
      usage("Unexpected extra argument: " .. a)
    end
  end
end

local res = fs.grep({
  path = path,
  pattern = pattern,
  recursive = recursive,
  max_matches = max_matches,
})

local matches = res.matches or {}
for _, m in ipairs(matches) do
  io.write(string.format("%s:%d: %s\n", m.path or "?", m.line or 0, m.text or ""))
end

io.stderr:write(string.format("%d match(es)\n", #matches))
