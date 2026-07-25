gdebug.log_info("MoM-BN: main.")

local mod = game.mod_runtime[game.current_mod]

-- Load order matters: math shim and util first, then var storage and the U
-- runtime, then generated jmath, then generated EOCs, then hand-written EOC
-- overrides, hooks last.  Each step is pcall-wrapped: --check-mods swallows
-- Lua errors silently, so we log them explicitly.
local function step(name, fn)
  local ok, err = pcall(fn)
  if not ok then
    gdebug.log_error("MoM-BN: FAILED loading " .. name .. ": " .. tostring(err))
  end
  return ok
end

step("mom_math", function() mod.math = require("lua/mom_math") end)
step("mom_util", function() mod.util = require("lua/mom_util") end)
step("mom_vars", function() mod.vars = require("lua/mom_vars")(mod) end)
step("mom_u", function() mod.u = require("lua/mom_u")(mod) end)
step("gen_jmath", function() require("lua/gen_jmath")(mod) end)
step("gen_eoc", function()
  local gen_eocs, gen_conds = require("lua/gen_eoc")(mod)
  mod.eoc = gen_eocs
  mod.eoc_conds = gen_conds
end)
mod.eoc = mod.eoc or {}
step("mom_eoc", function()
  local hand = require("lua/mom_eoc")(mod)
  for k, v in pairs(hand) do
    mod.eoc[k] = v                      -- hand-finished versions win
  end
end)
step("gen_learn_map", function() require("lua/gen_learn_map")(mod) end)
step("mom_hooks", function() require("lua/mom_hooks")(mod) end)
step("storage", function()
  mod.vars.bind_storage(game.mod_storage[game.current_mod])
end)

local n = 0
for _ in pairs(mod.eoc) do n = n + 1 end
gdebug.log_info("MoM-BN: main loaded (" .. n .. " EOC handlers).")
