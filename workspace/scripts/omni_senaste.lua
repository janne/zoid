-- Fetch "Senaste" headlines from omni.se using browser automation.
--
-- Usage:
--   zoid execute scripts/omni_senaste.lua [count]
--
-- Notes:
-- - Relies on browser support being installed (zoid browser install).
-- - Omni is heavily client-rendered; plain HTTP often doesn't contain the feed.

local function to_int(s)
  if not s then return nil end
  local n = tonumber(s)
  if not n then return nil end
  n = math.floor(n)
  if n < 1 then return nil end
  return n
end

local count = to_int(arg[1]) or 10
if count > 30 then count = 30 end

local url = "https://omni.se/senaste"

local res = zoid.browser.automate({
  start_url = url,
  timeout_seconds = 60,
  action_timeout_ms = 20000,
  max_extract_items = 500,
  max_text_chars = 200000,
  actions = {
    { action = "wait_for_timeout", ms = 2500 },
    { action = "extract_links", selector = "a", max_links = 500 },

    -- Extract visible page text; we then pick headline-like lines.
    { action = "extract_page_text" },
  },
})

if not res or res.ok == false then
  zoid.eprint("browser_automate failed\n")
  if res and res.error then zoid.eprint("error: ", tostring(res.error), "\n") end
  if res and res.stderr then zoid.eprint(res.stderr, "\n") end
  error("Browser automation failed")
end

local function norm_space(s)
  s = tostring(s or "")
  s = s:gsub("%s+", " ")
  s = s:gsub("^%s+", ""):gsub("%s+$", "")
  return s
end

local function looks_like_time(s)
  -- Omni shows relative times in Swedish like: "5 min", "1 tim", "2 tim", "Igår"
  if s:match("^%d+%s+min$") then return true end
  if s:match("^%d+%s+tim$") then return true end
  if s == "Igår" or s == "I går" then return true end
  return false
end

local function looks_like_section_title(s)
  local has_alpha = s:match("[%aÅÄÖåäö]") ~= nil
  if not has_alpha then return false end
  local upper = s:upper()
  return s == upper and #s <= 40
end

local function looks_like_headline(s)
  if #s < 18 or #s > 120 then return false end
  if looks_like_section_title(s) then return false end
  if s:match("^Läs fler ") then return false end
  if s:match("[%.%!%?].+[%.%!%?]") then return false end
  return true
end

local extracts = type(res.extracts) == "table" and res.extracts or {}
local page_text = nil
local link_items = {}

for _, ex in ipairs(extracts) do
  if type(ex) == "table" then
    if ex.kind == "page_text" and type(ex.value) == "string" and ex.value ~= "" then
      page_text = ex.value
    end
    if ex.kind == "links" and type(ex.items) == "table" then
      for _, item in ipairs(ex.items) do
        if type(item) == "table" then
          table.insert(link_items, item)
        end
      end
    end
  end
end

local function is_probable_headline(text, href)
  if text == "" then return false end
  if #text < 18 or #text > 180 then return false end
  if text:match("^%d+%s+min$") or text:match("^%d+%s+tim$") then return false end
  if text == "Omni" or text == "Senaste" or text == "Meny" then return false end
  if text:match("^Logga in$") or text:match("^Prenumerera$") then return false end
  if text:match("^Alla nyheter") then return false end
  if href == "" then return false end
  return true
end

local function to_abs_url(href)
  if href:match("^https?://") then return href end
  if href:sub(1, 1) == "/" then
    return "https://omni.se" .. href
  end
  return href
end

local function collect_link_headlines(require_article_link)
  local out = {}
  local seen = {}
  for _, item in ipairs(link_items) do
    local t = norm_space(item.text)
    local href = norm_space(item.href)
    local abs = to_abs_url(href)
    if require_article_link and not abs:find("/a/", 1, true) then
      goto continue
    end
    if is_probable_headline(t, href) and not seen[t] then
      seen[t] = true
      table.insert(out, { title = t, href = abs })
      if #out >= count then break end
    end
    ::continue::
  end
  return out
end

local link_headlines = collect_link_headlines(true)
if #link_headlines == 0 then
  link_headlines = collect_link_headlines(false)
end

-- Heuristic parser:
-- Split into lines and collect items as {title, time} where title is a line
-- followed by a time indicator somewhere shortly after.
local lines = {}
if type(page_text) == "string" and page_text ~= "" then
  for line in page_text:gmatch("([^\n]+)") do
    line = norm_space(line)
    if line ~= "" then table.insert(lines, line) end
  end
end

local items = {}
local seen_title = {}
for i = 1, #lines do
  if looks_like_time(lines[i]) then
    local when = lines[i]
    local chosen = nil
    for j = i - 1, math.max(1, i - 4), -1 do
      local cand = lines[j]
      if not looks_like_time(cand) and looks_like_headline(cand) then
        chosen = cand
        break
      end
    end
    if chosen and not seen_title[chosen] then
      seen_title[chosen] = true
      table.insert(items, { title = chosen, when = when })
    end
  end
  if #items >= count then break end
end

if #items > 0 then
  print("Omni – Senaste")
  print(url)
  print("")
  for idx, it in ipairs(items) do
    print(string.format("%2d) %s (%s)", idx, it.title, it.when))
    if idx >= count then break end
  end
  return
end

if #link_headlines > 0 then
  print("Omni – Senaste")
  print(url)
  print("")
  for idx, it in ipairs(link_headlines) do
    print(string.format("%2d) %s", idx, it.title))
    print("    " .. it.href)
    if idx >= count then break end
  end
  return
end

error("No usable extracts found (neither parseable page_text nor link headlines)")
