-- list_keys.lua
-- Lists all keys in the current Zoid config, without values.

-- Zoid provides config via the built-in `config` tool in this environment.
-- We'll call it through the global `zoid` bindings if present; otherwise error.

local function list_keys_via_tool()
  -- Expect a global `config` function/table exposed by the runner.
  -- In this environment, tools are not available directly inside Lua.
  return nil
end

-- As tools aren't callable from Lua here, keep script as a placeholder that
-- would work in a full Zoid runtime where `require('config')` exists.
print("ERROR: This Lua runner does not expose Zoid config APIs to Lua.")
