-- scripts/gmail.lua
-- Gmail message listing utility using Zoid's HTTP + config APIs.
--
-- Required config keys:
-- - GMAIL_CLIENT_ID
-- - GMAIL_CLIENT_SECRET
-- - GMAIL_REFRESH_TOKEN
--
-- Usage:
--   zoid execute scripts/gmail.lua [options]
--   lua scripts/gmail.lua [options]
--
-- Options:
--   -q, --query <query>      Gmail search query (default: "is:unread in:inbox")
--   -n, --limit <count>      Number of messages to fetch (1-500, default: 20)
--   --id <message_id>        Fetch only one specific message id
--   --labels                 Include label ids in output
--   -h, --help               Show usage

local function usage()
  print("Usage: gmail.lua [options]")
  print("Options:")
  print("  -q, --query <query>      Gmail search query (default: \"is:unread in:inbox\")")
  print("  -n, --limit <count>      Number of messages to fetch (1-500, default: 20)")
  print("  --id <message_id>        Fetch only one specific message id")
  print("  --labels                 Include label ids in output")
  print("  -h, --help               Show usage")
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

local function parse_positive_integer(raw, flag_name)
  local value = tonumber(raw)
  if value == nil or value < 1 or value > 500 or math.floor(value) ~= value then
    zoid.eprint("Invalid value for", flag_name .. ":", tostring(raw), "(expected integer in range 1-500)")
    return nil
  end
  return value
end

local function parse_options()
  local options = {
    query = "is:unread in:inbox",
    limit = 20,
    include_labels = false,
    message_id = nil,
  }

  local args = collect_args()
  local index = 1
  while index <= #args do
    local token = args[index]

    if token == "-h" or token == "--help" then
      usage()
      return nil, true
    elseif token == "--labels" then
      options.include_labels = true
    elseif token == "-q" or token == "--query" then
      local value = args[index + 1]
      if type(value) ~= "string" or value == "" then
        zoid.eprint("Missing value for", token)
        usage()
        return nil, false
      end
      options.query = value
      index = index + 1
    elseif token == "-n" or token == "--limit" then
      local value = args[index + 1]
      if type(value) ~= "string" or value == "" then
        zoid.eprint("Missing value for", token)
        usage()
        return nil, false
      end
      local parsed = parse_positive_integer(value, token)
      if parsed == nil then
        usage()
        return nil, false
      end
      options.limit = parsed
      index = index + 1
    elseif token == "--id" then
      local value = args[index + 1]
      if type(value) ~= "string" or value == "" then
        zoid.eprint("Missing value for --id")
        usage()
        return nil, false
      end
      options.message_id = value
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

local function require_config(cfg, key)
  local value = cfg:get(key)
  if value == nil or value == "" then
    error("Missing required config key: " .. key)
  end
  return value
end

local function url_encode(value)
  return (string.gsub(value, "([^%w%-_%.~])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function decode_json(label, text)
  local ok, decoded = pcall(zoid.json.decode, text)
  if not ok then
    error(label .. " returned invalid JSON: " .. tostring(decoded))
  end
  return decoded
end

local function header_value(headers, name)
  local wanted = string.lower(name)
  for _, header in ipairs(headers or {}) do
    local header_name = header and header.name or ""
    if string.lower(header_name) == wanted then
      return header.value or ""
    end
  end
  return ""
end

local function has_label(label_ids, wanted)
  for _, label in ipairs(label_ids or {}) do
    if label == wanted then
      return true
    end
  end
  return false
end

local function detect_category(label_ids)
  local category_labels = {
    "CATEGORY_PRIMARY",
    "CATEGORY_SOCIAL",
    "CATEGORY_PROMOTIONS",
    "CATEGORY_UPDATES",
    "CATEGORY_FORUMS",
  }
  for _, category in ipairs(category_labels) do
    if has_label(label_ids, category) then
      return category
    end
  end
  return ""
end

local function fail_http(label, response)
  local body = response.body or ""
  if #body > 500 then
    body = string.sub(body, 1, 500) .. "...(truncated)"
  end
  error(label .. " failed with HTTP " .. tostring(response.status) .. ": " .. body)
end

local function fetch_access_token(cfg)
  local body = table.concat({
    "client_id=" .. url_encode(require_config(cfg, "GMAIL_CLIENT_ID")),
    "&client_secret=" .. url_encode(require_config(cfg, "GMAIL_CLIENT_SECRET")),
    "&refresh_token=" .. url_encode(require_config(cfg, "GMAIL_REFRESH_TOKEN")),
    "&grant_type=refresh_token",
  })

  local response = zoid.uri("https://oauth2.googleapis.com/token"):post(body, {
    headers = {
      ["Content-Type"] = "application/x-www-form-urlencoded",
      Accept = "application/json",
    },
  })

  if not response.ok then
    fail_http("OAuth token exchange", response)
  end

  local payload = decode_json("OAuth token exchange", response.body)
  local access_token = payload.access_token
  if type(access_token) ~= "string" or access_token == "" then
    error("OAuth token exchange succeeded but no access_token was returned")
  end
  return access_token
end

local function fetch_message_ids(access_token, query, limit)
  local list_uri = "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=" ..
    url_encode(query) ..
    "&maxResults=" ..
    tostring(limit)

  local list_response = zoid.uri(list_uri):get({
    headers = {
      Authorization = "Bearer " .. access_token,
      Accept = "application/json",
    },
  })
  if not list_response.ok then
    fail_http("List messages", list_response)
  end

  local list_payload = decode_json("List messages", list_response.body)
  local messages = list_payload.messages
  if messages == nil or #messages == 0 then
    return {}
  end

  local ids = {}
  for _, message in ipairs(messages) do
    local message_id = message.id
    if type(message_id) == "string" and message_id ~= "" then
      table.insert(ids, message_id)
    end
  end
  return ids
end

local function fetch_message_details(access_token, message_id)
  if type(message_id) ~= "string" or message_id == "" then
    error("Message id must be a non-empty string")
  end

  local detail_uri = "https://gmail.googleapis.com/gmail/v1/users/me/messages/" ..
    url_encode(message_id) ..
    "?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date"

  local detail_response = zoid.uri(detail_uri):get({
    headers = {
      Authorization = "Bearer " .. access_token,
      Accept = "application/json",
    },
  })
  if not detail_response.ok then
    fail_http("Fetch message details", detail_response)
  end

  local detail_payload = decode_json("Fetch message details", detail_response.body)
  local headers = {}
  if detail_payload.payload and detail_payload.payload.headers then
    headers = detail_payload.payload.headers
  end
  local label_ids = detail_payload.labelIds or {}
  local category = detect_category(label_ids)

  return {
    id = detail_payload.id or message_id,
    thread_id = detail_payload.threadId or "",
    from = header_value(headers, "From"),
    subject = header_value(headers, "Subject"),
    date = header_value(headers, "Date"),
    snippet = detail_payload.snippet or "",
    label_ids = label_ids,
    is_spam = has_label(label_ids, "SPAM"),
    is_important = has_label(label_ids, "IMPORTANT"),
    is_starred = has_label(label_ids, "STARRED"),
    category = category,
  }
end

local function fetch_messages(access_token, query, limit)
  local ids = fetch_message_ids(access_token, query, limit)
  local entries = {}
  for _, message_id in ipairs(ids) do
    table.insert(entries, fetch_message_details(access_token, message_id))
  end
  return entries
end

local function print_message(message, include_labels)
  print("---")
  print("ID:", message.id)
  print("Thread ID:", message.thread_id)
  print("From:", message.from)
  print("Subject:", message.subject)
  print("Date:", message.date)
  print("Spam:", tostring(message.is_spam))
  print("Important:", tostring(message.is_important))
  print("Starred:", tostring(message.is_starred))
  if message.category ~= "" then
    print("Category:", message.category)
  end
  if include_labels and #message.label_ids > 0 then
    print("Labels:", table.concat(message.label_ids, ","))
  end
  if message.snippet ~= "" then
    print("Snippet:", message.snippet)
  end
end

local options, did_help = parse_options()
if options == nil then
  if did_help then
    return
  end
  error("Invalid arguments")
end

local config = zoid.config()
local token = fetch_access_token(config)

if options.message_id ~= nil then
  print("Message details:")
  local message = fetch_message_details(token, options.message_id)
  print_message(message, options.include_labels)
  return
end

local messages = fetch_messages(token, options.query, options.limit)
if #messages == 0 then
  print("No messages matched query:", options.query)
  return
end

print("Messages (" .. tostring(#messages) .. ") for query: " .. options.query)
for _, message in ipairs(messages) do
  print_message(message, options.include_labels)
end
