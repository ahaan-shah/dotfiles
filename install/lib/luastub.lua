-- Offline syntax check for hyprland.lua.
--
-- Hyprland's `hl` global does not exist outside the compositor, so this builds a
-- permissive metatable that answers any index and any call. Running the config
-- through it catches syntax errors and mid-file crashes — which matter a lot
-- here, because a crash partway through silently drops every bind after that
-- point rather than failing loudly.
--
-- Usage:  lua5.4 luastub.lua <path-to-hyprland.lua> [expected-bind-count]
local binds = 0
local function mk(name)
    return setmetatable({}, {
        __index = function(_, k) return mk(name .. "." .. k) end,
        __call  = function(_, ...)
            if name == "hl.bind" then binds = binds + 1 end
            return mk(name .. "()")
        end,
    })
end
hl = mk("hl")

local target = arg[1] or error("usage: luastub.lua <hyprland.lua> [expected-binds]")
local dir = target:match("^(.*)/[^/]*$") or "."
package.path = dir .. "/?.lua;" .. package.path

local ok, err = pcall(dofile, target)
if not ok then
    io.stderr:write("FAIL: " .. tostring(err) .. "\n")
    os.exit(1)
end

local expected = tonumber(arg[2])
if expected and binds ~= expected then
    io.stderr:write(("FAIL: expected %d binds, parsed %d\n"):format(expected, binds))
    os.exit(1)
end
print(("OK  parsed cleanly, hl.bind() calls = %d"):format(binds))
