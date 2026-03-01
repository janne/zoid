-- scripts/gcloud.lua
-- Small Google Cloud CLI helper built on lib/gcloud.lua.
--
-- Usage:
--   zoid execute scripts/gcloud.lua compute instances list [options]
--
-- Options for `compute instances list`:
--   -p, --project <project_id>   Override project id
--   -z, --zone <zone>            Restrict to one zone (skip aggregated list)
--   -n, --limit <count>          Max instances to print (1-2000, default: 200)
--   -h, --help                   Show usage

local gcloud = zoid.require("gcloud")

local function usage()
  print("Usage:")
  print("  gcloud.lua compute instances list [options]")
  print("")
  print("Options for `compute instances list`:")
  print("  -p, --project <project_id>   Override project id")
  print("  -z, --zone <zone>            Restrict to one zone (skip aggregated list)")
  print("  -n, --limit <count>          Max instances to print (1-2000, default: 200)")
  print("  -h, --help                   Show usage")
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

local function parse_positive_integer(raw, min_value, max_value)
  local value = tonumber(raw)
  if value == nil or value < min_value or value > max_value or math.floor(value) ~= value then
    return nil
  end
  return value
end

local function parse_options(tokens, start_index)
  local options = {
    project = nil,
    zone = nil,
    limit = 200,
  }

  local index = start_index
  while index <= #tokens do
    local token = tokens[index]
    if token == "-h" or token == "--help" then
      usage()
      return nil, true
    elseif token == "-p" or token == "--project" then
      local value = tokens[index + 1]
      if type(value) ~= "string" or value == "" then
        zoid.eprint("Missing value for", token)
        usage()
        return nil, false
      end
      options.project = value
      index = index + 1
    elseif token == "-z" or token == "--zone" then
      local value = tokens[index + 1]
      if type(value) ~= "string" or value == "" then
        zoid.eprint("Missing value for", token)
        usage()
        return nil, false
      end
      options.zone = value
      index = index + 1
    elseif token == "-n" or token == "--limit" then
      local value = tokens[index + 1]
      if type(value) ~= "string" or value == "" then
        zoid.eprint("Missing value for", token)
        usage()
        return nil, false
      end
      local parsed = parse_positive_integer(value, 1, 2000)
      if parsed == nil then
        zoid.eprint("Invalid value for", token .. ":", tostring(value), "(expected integer in range 1-2000)")
        usage()
        return nil, false
      end
      options.limit = parsed
      index = index + 1
    elseif string.sub(token, 1, 1) == "-" then
      zoid.eprint("Unknown option:", token)
      usage()
      return nil, false
    else
      zoid.eprint("Unexpected argument:", token)
      usage()
      return nil, false
    end
    index = index + 1
  end

  return options, false
end

local function parse_zone_from_scope(scope)
  if type(scope) ~= "string" then
    return ""
  end
  local zone = string.match(scope, "^zones/(.+)$")
  if zone ~= nil and zone ~= "" then
    return zone
  end
  return scope
end

local function basename(value)
  if type(value) ~= "string" or value == "" then
    return ""
  end
  local head = value
  local slash = string.find(head, "?", 1, true)
  if slash ~= nil then
    head = string.sub(head, 1, slash - 1)
  end
  local name = string.match(head, ".*/([^/]+)$")
  if name ~= nil and name ~= "" then
    return name
  end
  return head
end

local function sort_instances(instances)
  table.sort(instances, function(a, b)
    local a_zone = a.zone or ""
    local b_zone = b.zone or ""
    if a_zone ~= b_zone then
      return a_zone < b_zone
    end

    local a_name = a.name or ""
    local b_name = b.name or ""
    if a_name ~= b_name then
      return a_name < b_name
    end

    local a_id = tostring(a.id or "")
    local b_id = tostring(b.id or "")
    return a_id < b_id
  end)
end

local function collect_instances_aggregated(client, project, limit)
  local out = {}
  local page_token = nil

  while #out < limit do
    local remaining = limit - #out
    local query = { maxResults = math.min(remaining, 500) }
    if type(page_token) == "string" and page_token ~= "" then
      query.pageToken = page_token
    end

    local payload = client.compute.instances.aggregated_list({
      project = project,
      query = query,
    })

    local items = payload.items or {}
    for scope, scoped in pairs(items) do
      local zone = parse_zone_from_scope(scope)
      local scoped_instances = scoped and scoped.instances or {}
      for _, instance in ipairs(scoped_instances) do
        table.insert(out, {
          id = instance.id,
          name = instance.name,
          status = instance.status,
          machine_type = basename(instance.machineType),
          zone = zone,
        })
        if #out >= limit then
          return out
        end
      end
    end

    page_token = payload.nextPageToken
    if type(page_token) ~= "string" or page_token == "" then
      break
    end
  end

  return out
end

local function collect_instances_by_zone(client, project, zone, limit)
  local out = {}
  local page_token = nil

  while #out < limit do
    local remaining = limit - #out
    local query = { maxResults = math.min(remaining, 500) }
    if type(page_token) == "string" and page_token ~= "" then
      query.pageToken = page_token
    end

    local payload = client.compute.instances.list({
      project = project,
      zone = zone,
      query = query,
    })

    local items = payload.items or {}
    for _, instance in ipairs(items) do
      table.insert(out, {
        id = instance.id,
        name = instance.name,
        status = instance.status,
        machine_type = basename(instance.machineType),
        zone = zone,
      })
      if #out >= limit then
        return out
      end
    end

    page_token = payload.nextPageToken
    if type(page_token) ~= "string" or page_token == "" then
      break
    end
  end

  return out
end

local function print_instances(project, zone, instances)
  if #instances == 0 then
    if zone ~= nil and zone ~= "" then
      print("No compute instances found for project:", project, "zone:", zone)
    else
      print("No compute instances found for project:", project)
    end
    return
  end

  if zone ~= nil and zone ~= "" then
    print("Compute instances for project:", project, "(zone:", zone .. ")")
  else
    print("Compute instances for project:", project)
  end
  print("")

  sort_instances(instances)
  for index, instance in ipairs(instances) do
    local name = instance.name or "-"
    local state = instance.status or "-"
    local machine = instance.machine_type or "-"
    local instance_zone = instance.zone or "-"
    print(string.format("%3d) %s  zone=%s  status=%s  machine=%s", index, name, instance_zone, state, machine))
  end

  print("")
  print("Total:", tostring(#instances))
end

local function main()
  local tokens = collect_args()
  if #tokens == 0 then
    usage()
    return
  end

  if tokens[1] == "-h" or tokens[1] == "--help" then
    usage()
    return
  end

  if #tokens < 3 then
    zoid.eprint("Missing command. Expected: compute instances list")
    usage()
    error("Invalid command")
  end

  local group = tokens[1]
  local resource = tokens[2]
  local action = tokens[3]

  if group ~= "compute" or resource ~= "instances" or action ~= "list" then
    zoid.eprint("Unsupported command:", group, resource, action)
    usage()
    error("Unsupported command")
  end

  local options, did_help = parse_options(tokens, 4)
  if options == nil then
    if did_help then
      return
    end
    error("Invalid arguments")
  end

  local client = gcloud.from_config({ project = options.project })
  local project = options.project or client.default_project
  if type(project) ~= "string" or project == "" then
    error("Missing project. Set GCLOUD_PROJECT_ID or pass --project <project_id>")
  end

  local instances
  if options.zone ~= nil and options.zone ~= "" then
    instances = collect_instances_by_zone(client, project, options.zone, options.limit)
  else
    instances = collect_instances_aggregated(client, project, options.limit)
  end

  print_instances(project, options.zone, instances)
end

main()
