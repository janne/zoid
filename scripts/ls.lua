-- scripts/ls.lua
-- ls -l-like directory listing using Zoid's Lua API.
-- Usage:
--   zoid execute scripts/ls.lua
--   lua scripts/ls.lua [-a|--all] [path]

local function usage()
  print("Usage: ls.lua [-a|--all] [path]")
end

local function collect_args()
  if type(arg) ~= "table" then
    return {}
  end

  local indexed = {}
  for key, value in pairs(arg) do
    if type(key) == "number" and key > 0 and type(value) == "string" then
      table.insert(indexed, { key = key, value = value })
    end
  end

  table.sort(indexed, function(a, b)
    return a.key < b.key
  end)

  local values = {}
  for _, entry in ipairs(indexed) do
    table.insert(values, entry.value)
  end
  return values
end

local function has_bit(value, mask)
  return math.floor(value / mask) % 2 == 1
end

local function parse_octal(mode_str)
  if type(mode_str) ~= "string" or mode_str == "" then
    return 0
  end

  local value = 0
  for index = 1, #mode_str do
    local digit = string.byte(mode_str, index)
    if digit < 48 or digit > 55 then
      return 0
    end
    value = (value * 8) + (digit - 48)
  end
  return value
end

local function type_char(kind)
  if kind == "directory" then return "d" end
  if kind == "symlink" then return "l" end
  return "-"
end

local function permission_char(allowed, yes_char)
  if allowed then
    return yes_char
  end
  return "-"
end

local function execute_special_char(executable, special, on_exec, on_no_exec)
  if special then
    if executable then
      return on_exec
    end
    return on_no_exec
  end
  if executable then
    return "x"
  end
  return "-"
end

local function mode_to_rwx(mode_str)
  local mode = parse_octal(mode_str)
  local owner_exec = has_bit(mode, 64)
  local group_exec = has_bit(mode, 8)
  local other_exec = has_bit(mode, 1)

  return table.concat({
    permission_char(has_bit(mode, 256), "r"),
    permission_char(has_bit(mode, 128), "w"),
    execute_special_char(owner_exec, has_bit(mode, 2048), "s", "S"),
    permission_char(has_bit(mode, 32), "r"),
    permission_char(has_bit(mode, 16), "w"),
    execute_special_char(group_exec, has_bit(mode, 1024), "s", "S"),
    permission_char(has_bit(mode, 4), "r"),
    permission_char(has_bit(mode, 2), "w"),
    execute_special_char(other_exec, has_bit(mode, 512), "t", "T"),
  })
end

local function format_modified_at(value)
  if type(value) ~= "string" or value == "" then
    return "-"
  end
  local text = value:gsub("T", " ")
  return text:gsub("Z$", "")
end

local function pad_left(value, width)
  local text = tostring(value)
  if #text >= width then
    return text
  end
  return string.rep(" ", width - #text) .. text
end

local function pad_right(value, width)
  local text = tostring(value)
  if #text >= width then
    return text
  end
  return text .. string.rep(" ", width - #text)
end

local include_hidden = false
local target_path = "."
local target_set = false

for _, token in ipairs(collect_args()) do
  if token == "-a" or token == "--all" then
    include_hidden = true
  elseif token == "-h" or token == "--help" then
    usage()
    return
  elseif string.sub(token, 1, 1) == "-" then
    zoid.eprint("Unknown option:", token)
    usage()
    return
  elseif target_set then
    zoid.eprint("Only one path argument is supported.")
    usage()
    return
  else
    target_path = token
    target_set = true
  end
end

local directory
local ok_dir, dir_or_error = pcall(function()
  return zoid.dir(target_path)
end)

if not ok_dir then
  zoid.eprint("Failed to open directory metadata:", tostring(dir_or_error))
  return
end
directory = dir_or_error

local raw_entries
local ok_list, list_or_error = pcall(function()
  return directory:list()
end)

if not ok_list then
  zoid.eprint("Failed to list directory '" .. target_path .. "':", tostring(list_or_error))
  return
end
raw_entries = list_or_error

local entries = {}
for _, entry in ipairs(raw_entries) do
  local name = entry.name or ""
  if include_hidden or string.sub(name, 1, 1) ~= "." then
    table.insert(entries, entry)
  end
end

table.sort(entries, function(a, b)
  return (a.name or "") < (b.name or "")
end)

local owner_width = 1
local group_width = 1
local size_width = 1

for _, entry in ipairs(entries) do
  local owner = entry.owner
  if type(owner) ~= "string" or owner == "" then
    owner = "-"
  end
  local group = entry.group
  if type(group) ~= "string" or group == "" then
    group = "-"
  end
  local size = tostring(entry.size or 0)
  owner_width = math.max(owner_width, #owner)
  group_width = math.max(group_width, #group)
  size_width = math.max(size_width, #size)
end

for _, entry in ipairs(entries) do
  local name = entry.name or "?"
  local owner = entry.owner
  if type(owner) ~= "string" or owner == "" then
    owner = "-"
  end
  local group = entry.group
  if type(group) ~= "string" or group == "" then
    group = "-"
  end

  local listing = string.format(
    "%s%s %s %s %s %s %s %s",
    type_char(entry.type),
    mode_to_rwx(entry.mode),
    "1",
    pad_right(owner, owner_width),
    pad_right(group, group_width),
    pad_left(entry.size or 0, size_width),
    format_modified_at(entry.modified_at),
    name
  )
  print(listing)
end
