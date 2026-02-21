-- gmail_latest_unread.lua
--
-- Reads Gmail OAuth credentials from Zoid config, exchanges refresh token for
-- an access token, and prints the latest unread inbox message.
--
-- Required config keys:
-- - GMAIL_CLIENT_ID
-- - GMAIL_CLIENT_SECRET
-- - GMAIL_REFRESH_TOKEN

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

local function fetch_unread_message_ids(access_token, limit)
  local query = url_encode("is:unread in:inbox")
  local list_uri = "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=" ..
    query ..
    "&maxResults=" ..
    tostring(limit)

  local list_response = zoid.uri(list_uri):get({
    headers = {
      Authorization = "Bearer " .. access_token,
      Accept = "application/json",
    },
  })
  if not list_response.ok then
    fail_http("List unread inbox messages", list_response)
  end

  local list_payload = decode_json("List unread inbox messages", list_response.body)
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
    error("Gmail list response did not include a valid message id")
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
    id = message_id,
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

local function fetch_latest_unread_messages(access_token, limit)
  local ids = fetch_unread_message_ids(access_token, limit)
  local entries = {}
  for _, message_id in ipairs(ids) do
    table.insert(entries, fetch_message_details(access_token, message_id))
  end
  return entries
end

local config = zoid.config()
local token = fetch_access_token(config)
local latest = fetch_latest_unread_messages(token, 50)

if #latest == 0 then
  print("No unread messages in inbox.")
  return
end

print("Latest unread messages (" .. tostring(#latest) .. "):")
for _, message in ipairs(latest) do
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
  if #message.label_ids > 0 then
    print("Labels:", table.concat(message.label_ids, ","))
  end
  if message.snippet ~= "" then
    print("Snippet:", message.snippet)
  end
end
