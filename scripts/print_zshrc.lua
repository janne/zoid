local home = os.getenv("HOME")
assert(home and #home > 0, "HOME is not set")

local path = home .. "/.zshrc"

local f, err = io.open(path, "r")
if not f then
  io.stderr:write(("Kunde inte öppna %s: %s\n"):format(path, tostring(err)))
  os.exit(1)
end

io.write(f:read("*a"))
f:close()
