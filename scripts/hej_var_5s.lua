-- Writes "hej" every 5 seconds.
-- Note: In Zoid job scheduler, cron has 1-minute resolution.
-- Run this script manually (zoid execute ...) when you want the 5s loop.

local function sleep(sec)
  -- Best-effort portable sleep without os/package.
  -- Uses a busy-wait on CPU time as a fallback.
  local target = sec
  local start = 0
  if type(zoid) == "table" and zoid.time and zoid.time.cpu then
    start = zoid.time.cpu()
    while (zoid.time.cpu() - start) < target do end
    return
  end
  -- Fallback: approximate with a tight loop.
  local t0 = 0
  local clock = (type(math) == "table" and math.clock) and math.clock or nil
  if clock then
    t0 = clock()
    while (clock() - t0) < target do end
  else
    -- Very rough fallback if even math.clock is unavailable.
    for _ = 1, 5000000 * sec do end
  end
end

while true do
  print("hej")
  sleep(5)
end
