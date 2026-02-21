local path = "/Users/janandersson/.zshrc"

local f, err = io.open(path, "r")
if not f then
  io.stderr:write(("Kunde inte öppna %s: %s\n"):format(path, tostring(err)))
else
  io.write(f:read("*a"))
  f:close()
end
