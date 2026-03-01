-- lib/gcloud.lua
-- Google Cloud REST helper for Zoid Lua scripts.
--
-- Recommended usage:
--   local gcloud = zoid.import("/lib/gcloud.lua")
--   local client = gcloud.from_config()
--   local page = client.compute.instances.list({ zone = "europe-west1-b" })
--   for _, item in ipairs(page.items or {}) do
--     print(item.name, item.status)
--   end
--
-- Supported config keys for from_config():
-- - GCLOUD_SERVICE_ACCOUNT_JSON (raw JSON string)
-- - GCLOUD_SERVICE_ACCOUNT_FILE (workspace path to service account JSON)
-- - GCLOUD_PROJECT_ID
-- - GCLOUD_SCOPES (comma-separated OAuth scopes)
-- - GCLOUD_ACCESS_TOKEN (optional pre-minted OAuth bearer token)

local gcloud = {}

local DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token"
local DEFAULT_SCOPES = {
  "https://www.googleapis.com/auth/cloud-platform",
}
local JWT_GRANT_TYPE = "urn:ietf:params:oauth:grant-type:jwt-bearer"

local SERVICE_ENDPOINTS = {
  compute = "https://compute.googleapis.com/compute",
  run = "https://run.googleapis.com",
  iam = "https://iam.googleapis.com",
  storage = "https://storage.googleapis.com/storage",
  cloudresourcemanager = "https://cloudresourcemanager.googleapis.com",
}

local client_methods = {}

local function is_non_empty_string(value)
  return type(value) == "string" and value ~= ""
end

local function shallow_copy_array(values)
  local out = {}
  for _, value in ipairs(values or {}) do
    table.insert(out, value)
  end
  return out
end

local function trim(value)
  if type(value) ~= "string" then
    return ""
  end
  local s = value:gsub("^%s+", "")
  return s:gsub("%s+$", "")
end

local function split_csv(value)
  local out = {}
  if type(value) ~= "string" then
    return out
  end
  for chunk in string.gmatch(value, "([^,]+)") do
    local cleaned = trim(chunk)
    if cleaned ~= "" then
      table.insert(out, cleaned)
    end
  end
  return out
end

local function decode_json_or_error(label, json_text)
  local ok, decoded = pcall(zoid.json.decode, json_text)
  if not ok then
    error(label .. " returned invalid JSON: " .. tostring(decoded))
  end
  return decoded
end

local function url_encode(value)
  return (string.gsub(tostring(value), "([^%w%-_%.~])", function(ch)
    return string.format("%%%02X", string.byte(ch))
  end))
end

local function encode_query(query)
  if type(query) ~= "table" then
    return ""
  end

  local parts = {}
  local entries = {}
  for key, _ in pairs(query) do
    table.insert(entries, {
      key = key,
      key_text = tostring(key),
    })
  end
  table.sort(entries, function(a, b)
    return a.key_text < b.key_text
  end)

  for _, entry in ipairs(entries) do
    local key = entry.key_text
    local value = query[entry.key]
    if value ~= nil then
      if type(value) == "table" then
        for _, item in ipairs(value) do
          table.insert(parts, url_encode(key) .. "=" .. url_encode(item))
        end
      else
        table.insert(parts, url_encode(key) .. "=" .. url_encode(value))
      end
    end
  end

  return table.concat(parts, "&")
end

local function merge_headers(base_headers, override_headers)
  local out = {}
  for key, value in pairs(base_headers or {}) do
    out[key] = value
  end
  for key, value in pairs(override_headers or {}) do
    out[key] = value
  end
  return out
end

local function normalize_scopes(scopes)
  if scopes == nil then
    return shallow_copy_array(DEFAULT_SCOPES)
  end

  if type(scopes) == "string" then
    local parsed = split_csv(scopes)
    if #parsed == 0 then
      error("scopes must contain at least one non-empty scope")
    end
    return parsed
  end

  if type(scopes) ~= "table" then
    error("scopes must be a string or an array")
  end

  local normalized = {}
  for _, scope in ipairs(scopes) do
    if is_non_empty_string(scope) then
      table.insert(normalized, scope)
    end
  end

  if #normalized == 0 then
    error("scopes must contain at least one non-empty scope")
  end
  return normalized
end

local function normalize_credentials(options)
  if type(options.credentials) == "table" then
    return options.credentials
  end

  if is_non_empty_string(options.credentials_json) then
    return decode_json_or_error("credentials_json", options.credentials_json)
  end

  if is_non_empty_string(options.credentials_path) then
    local text = zoid.file(options.credentials_path):read()
    return decode_json_or_error("credentials file", text)
  end

  error("missing credentials; set credentials/credentials_json/credentials_path")
end

local function ensure_credentials_shape(credentials)
  if type(credentials) ~= "table" then
    error("credentials must decode to an object")
  end
  if not is_non_empty_string(credentials.client_email) then
    error("service account credentials missing client_email")
  end
  if not is_non_empty_string(credentials.private_key) then
    error("service account credentials missing private_key")
  end
end

local function get_crypto_api()
  if type(zoid) ~= "table" then
    return nil
  end
  local crypto = zoid.crypto
  if type(crypto) ~= "table" then
    return nil
  end
  if type(crypto.base64url_encode) ~= "function" then
    return nil
  end
  if type(crypto.sign_rs256) ~= "function" then
    return nil
  end
  return crypto
end

local function summarize_body(body)
  local text = body or ""
  if #text > 600 then
    return string.sub(text, 1, 600) .. "...(truncated)"
  end
  return text
end

local function http_error(label, response)
  return label .. " failed with HTTP " .. tostring(response.status) .. ": " .. summarize_body(response.body)
end

local function normalize_request_body(body)
  if body == nil then
    return nil, nil
  end
  if type(body) == "string" then
    return body, nil
  end
  if type(body) == "table" then
    return zoid.json.encode(body), "application/json"
  end
  error("request body must be a string or table")
end

local function require_non_empty_option(options, key)
  local value = options[key]
  if not is_non_empty_string(value) then
    error("missing required option: " .. key)
  end
  return value
end

local function current_epoch()
  return tonumber(zoid.time()) or 0
end

local function build_jwt_assertion(client, now_epoch)
  local crypto = get_crypto_api()
  if crypto == nil then
    error("zoid.crypto is unavailable; set GCLOUD_ACCESS_TOKEN or run a zoid version with zoid.crypto support")
  end

  local header = {
    alg = "RS256",
    typ = "JWT",
  }
  local claims = {
    iss = client.credentials.client_email,
    scope = table.concat(client.scopes, " "),
    aud = client.token_uri,
    iat = now_epoch,
    exp = now_epoch + client.token_lifetime_seconds,
  }

  local encoded_header = crypto.base64url_encode(zoid.json.encode(header))
  local encoded_claims = crypto.base64url_encode(zoid.json.encode(claims))
  local signing_input = encoded_header .. "." .. encoded_claims
  local signature = crypto.sign_rs256(client.credentials.private_key, signing_input, "base64url")

  return signing_input .. "." .. signature
end

function client_methods:_fetch_access_token()
  local now_epoch = current_epoch()
  local assertion = build_jwt_assertion(self, now_epoch)
  local body = "grant_type=" ..
    url_encode(JWT_GRANT_TYPE) ..
    "&assertion=" ..
    url_encode(assertion)

  local response = zoid.uri(self.token_uri):post(body, {
    headers = {
      ["Content-Type"] = "application/x-www-form-urlencoded",
      Accept = "application/json",
    },
  })
  if not response.ok then
    error(http_error("OAuth token exchange", response))
  end

  local payload = decode_json_or_error("OAuth token exchange", response.body or "")
  local access_token = payload.access_token
  if not is_non_empty_string(access_token) then
    error("OAuth token exchange succeeded but no access_token was returned")
  end

  local expires_in = tonumber(payload.expires_in) or 3600
  if expires_in < 60 then
    expires_in = 60
  end

  self._access_token = access_token
  self._access_token_expires_at = now_epoch + math.floor(expires_in)
  return access_token
end

function client_methods:get_access_token()
  if is_non_empty_string(self.static_access_token) then
    return self.static_access_token
  end

  local now_epoch = current_epoch()
  if is_non_empty_string(self._access_token) and
    (self._access_token_expires_at - self.token_refresh_skew_seconds) > now_epoch then
    return self._access_token
  end
  return self:_fetch_access_token()
end

function client_methods:request(options)
  if type(options) ~= "table" then
    error("request(options) expects a table")
  end

  local method = string.upper(options.method or "GET")
  local host = options.host
  if not is_non_empty_string(host) then
    host = SERVICE_ENDPOINTS[options.service]
  end
  if not is_non_empty_string(host) then
    error("unknown service; provide options.host or a supported options.service")
  end

  local path = options.path
  if not is_non_empty_string(path) then
    error("request(options) requires a non-empty path")
  end
  if string.sub(path, 1, 1) ~= "/" then
    path = "/" .. path
  end

  local uri = host
  if is_non_empty_string(options.version) then
    uri = uri .. "/" .. options.version
  end
  uri = uri .. path

  local query = encode_query(options.query)
  if query ~= "" then
    uri = uri .. "?" .. query
  end

  local body_text, inferred_content_type = normalize_request_body(options.body)
  local headers = merge_headers(options.headers, {
    Authorization = "Bearer " .. self:get_access_token(),
    Accept = "application/json",
    ["User-Agent"] = self.user_agent,
  })
  if is_non_empty_string(self.quota_project) and
    headers["X-Goog-User-Project"] == nil and
    headers["x-goog-user-project"] == nil then
    headers["X-Goog-User-Project"] = self.quota_project
  end
  if inferred_content_type ~= nil and headers["Content-Type"] == nil and headers["content-type"] == nil then
    headers["Content-Type"] = inferred_content_type
  end

  local req = zoid.uri(uri)
  local response
  if method == "GET" then
    response = req:get({ headers = headers })
  elseif method == "DELETE" then
    response = req:delete({ headers = headers })
  elseif method == "POST" then
    response = req:post(body_text, { headers = headers })
  elseif method == "PUT" then
    response = req:put(body_text, { headers = headers })
  else
    error("unsupported method: " .. tostring(method))
  end

  local result = {
    ok = response.ok,
    status = response.status,
    headers = response.headers or {},
    body = response.body or "",
  }

  if options.parse_json ~= false and result.body ~= "" then
    local ok, parsed = pcall(zoid.json.decode, result.body)
    if ok then
      result.json = parsed
    end
  end

  if not result.ok and options.raise_on_error ~= false then
    error(http_error(method .. " " .. uri, response))
  end
  return result
end

local function return_json_or_result(result)
  if type(result.json) == "table" then
    return result.json
  end
  return result
end

local function build_compute_api(client)
  local api = {
    instances = {},
  }

  function api.instances.list(options)
    options = options or {}
    local project = options.project or client.default_project
    if not is_non_empty_string(project) then
      error("instances.list requires project (or default_project in client)")
    end
    local zone = require_non_empty_option(options, "zone")
    local result = client:request({
      service = "compute",
      version = "v1",
      method = "GET",
      path = "/projects/" .. url_encode(project) .. "/zones/" .. url_encode(zone) .. "/instances",
      query = options.query,
    })
    return return_json_or_result(result)
  end

  function api.instances.get(options)
    options = options or {}
    local project = options.project or client.default_project
    if not is_non_empty_string(project) then
      error("instances.get requires project (or default_project in client)")
    end
    local zone = require_non_empty_option(options, "zone")
    local instance = require_non_empty_option(options, "instance")
    local result = client:request({
      service = "compute",
      version = "v1",
      method = "GET",
      path = "/projects/" ..
        url_encode(project) ..
        "/zones/" ..
        url_encode(zone) ..
        "/instances/" ..
        url_encode(instance),
    })
    return return_json_or_result(result)
  end

  function api.instances.start(options)
    options = options or {}
    local project = options.project or client.default_project
    if not is_non_empty_string(project) then
      error("instances.start requires project (or default_project in client)")
    end
    local zone = require_non_empty_option(options, "zone")
    local instance = require_non_empty_option(options, "instance")
    local result = client:request({
      service = "compute",
      version = "v1",
      method = "POST",
      path = "/projects/" ..
        url_encode(project) ..
        "/zones/" ..
        url_encode(zone) ..
        "/instances/" ..
        url_encode(instance) ..
        "/start",
      body = options.body or {},
    })
    return return_json_or_result(result)
  end

  function api.instances.stop(options)
    options = options or {}
    local project = options.project or client.default_project
    if not is_non_empty_string(project) then
      error("instances.stop requires project (or default_project in client)")
    end
    local zone = require_non_empty_option(options, "zone")
    local instance = require_non_empty_option(options, "instance")
    local result = client:request({
      service = "compute",
      version = "v1",
      method = "POST",
      path = "/projects/" ..
        url_encode(project) ..
        "/zones/" ..
        url_encode(zone) ..
        "/instances/" ..
        url_encode(instance) ..
        "/stop",
      body = options.body or {},
    })
    return return_json_or_result(result)
  end

  function api.instances.delete(options)
    options = options or {}
    local project = options.project or client.default_project
    if not is_non_empty_string(project) then
      error("instances.delete requires project (or default_project in client)")
    end
    local zone = require_non_empty_option(options, "zone")
    local instance = require_non_empty_option(options, "instance")
    local result = client:request({
      service = "compute",
      version = "v1",
      method = "DELETE",
      path = "/projects/" ..
        url_encode(project) ..
        "/zones/" ..
        url_encode(zone) ..
        "/instances/" ..
        url_encode(instance),
      query = options.query,
    })
    return return_json_or_result(result)
  end

  function api.instances.aggregated_list(options)
    options = options or {}
    local project = options.project or client.default_project
    if not is_non_empty_string(project) then
      error("instances.aggregated_list requires project (or default_project in client)")
    end
    local result = client:request({
      service = "compute",
      version = "v1",
      method = "GET",
      path = "/projects/" .. url_encode(project) .. "/aggregated/instances",
      query = options.query,
    })
    return return_json_or_result(result)
  end

  return api
end

function gcloud.new(options)
  options = options or {}

  local static_access_token = options.access_token
  if static_access_token ~= nil and type(static_access_token) ~= "string" then
    error("access_token must be a string when provided")
  end

  local credentials = nil
  if not is_non_empty_string(static_access_token) then
    credentials = normalize_credentials(options)
    ensure_credentials_shape(credentials)
  end

  local scopes = normalize_scopes(options.scopes)

  local client = {
    credentials = credentials,
    scopes = scopes,
    default_project = options.project or (credentials and credentials.project_id) or nil,
    quota_project = options.quota_project or (credentials and credentials.quota_project_id) or nil,
    token_uri = options.token_uri or DEFAULT_TOKEN_URI,
    token_lifetime_seconds = options.token_lifetime_seconds or 3600,
    token_refresh_skew_seconds = options.token_refresh_skew_seconds or 60,
    user_agent = options.user_agent or "zoid-gcloud/0.1",
    static_access_token = static_access_token,
    _access_token = nil,
    _access_token_expires_at = 0,
  }

  setmetatable(client, { __index = client_methods })
  client.compute = build_compute_api(client)
  return client
end

function gcloud.from_config(options)
  options = options or {}
  local cfg = options.config or zoid.config()

  local init = {
    credentials = options.credentials,
    credentials_json = options.credentials_json,
    credentials_path = options.credentials_path,
    access_token = options.access_token,
    scopes = options.scopes,
    project = options.project,
    quota_project = options.quota_project,
    token_uri = options.token_uri,
    token_lifetime_seconds = options.token_lifetime_seconds,
    token_refresh_skew_seconds = options.token_refresh_skew_seconds,
    user_agent = options.user_agent,
  }

  if init.credentials == nil and init.credentials_json == nil and init.credentials_path == nil then
    local inline_json = cfg:get("GCLOUD_SERVICE_ACCOUNT_JSON")
    local file_path = cfg:get("GCLOUD_SERVICE_ACCOUNT_FILE")
    if is_non_empty_string(inline_json) then
      init.credentials_json = inline_json
    elseif is_non_empty_string(file_path) then
      init.credentials_path = file_path
    end
  end

  if init.project == nil then
    local cfg_project = cfg:get("GCLOUD_PROJECT_ID")
    if is_non_empty_string(cfg_project) then
      init.project = cfg_project
    end
  end

  if init.scopes == nil then
    local cfg_scopes = cfg:get("GCLOUD_SCOPES")
    if is_non_empty_string(cfg_scopes) then
      init.scopes = split_csv(cfg_scopes)
    end
  end

  if init.access_token == nil then
    local cfg_access_token = cfg:get("GCLOUD_ACCESS_TOKEN")
    if is_non_empty_string(cfg_access_token) then
      init.access_token = cfg_access_token
    end
  end

  return gcloud.new(init)
end

gcloud.DEFAULT_SCOPES = shallow_copy_array(DEFAULT_SCOPES)
gcloud.SERVICE_ENDPOINTS = SERVICE_ENDPOINTS

return gcloud
