gdebug.log_info("MoM-BN: preload.")

local mod = game.mod_runtime[game.current_mod]

-- Hook registrations only; implementations live in main.lua's requires.
-- Valid hook names: CBN src/catalua_hooks.cpp (there is NO "on_every_x" hook).

-- Periodic dispatcher: recurring-EOC cadences + the queue_eocs scheduler.
-- Runs every turn; per-entry cadence is handled inside mod.on_every_x.
-- A callback that returns false would be unregistered, so never return false.
gapi.add_on_every_x_hook(TimeDuration.from_turns(1), function()
  if mod.on_every_x then mod.on_every_x() end
end)

-- Effect-linked EOCs.  NOTE: these only fire for effects whose JSON carries
-- the EFFECT_LUA_ON_ADDED / EFFECT_LUA_ON_REMOVED flags — the transpiler must
-- add those flags to every ported effect_type that has attached EOCs.
game.add_hook("on_character_effect_added", function(params)
  if mod.on_effect_added then return mod.on_effect_added(params) end
end)
game.add_hook("on_character_effect_removed", function(params)
  if mod.on_effect_removed then return mod.on_effect_removed(params) end
end)

-- Monster-side twins (params: mon, effect).  Without these, EOC-backed
-- spells cast AT monsters never dispatch: the marker effect lands on the
-- monster and the character hooks stay silent (QA round 3 — Degenerating
-- Touch, Oubliette).
game.add_hook("on_mon_effect_added", function(params)
  if mod.on_mon_effect_added then return mod.on_mon_effect_added(params) end
end)
game.add_hook("on_mon_effect_removed", function(params)
  if mod.on_mon_effect_removed then return mod.on_mon_effect_removed(params) end
end)

-- Monster death-effect bridge (params: mon, killer; monster.cpp:3422).  DDA's
-- death_function object could cast a fake_spell / run an EOC / print a custom
-- message on death; BN's death_function is only a list of hardcoded C++ fns, so
-- port_monsters routes those to lua/gen_mon_death.lua and we dispatch here.
game.add_hook("on_mon_death", function(params)
  if mod.on_mon_death then return mod.on_mon_death(params) end
end)

-- Melee combat auras (Blinding Radiance &c.): re-create the enchantment
-- hit_me_effect / hit_you_effect procs BN can't read off an effect_type.
-- params: char (attacker), target (victim), success (bool).
game.add_hook("on_creature_melee_attacked", function(params)
  if mod.on_melee_attacked then return mod.on_melee_attacked(params) end
end)

-- Weather tracking: BN has no current-weather getter binding, but this hook
-- reports every change (weather.cpp:1179).  U.is_weather reads mod.current_weather.
game.add_hook("on_weather_changed", function(params)
  mod.current_weather = params.weather_id
end)

-- EOC-activated items (matrix crystals, nether stones, zener deck...):
-- DDA use_action type effect_on_conditions -> BN Lua iuse actor.  Items carry
-- `"use_action": "MOM_EOC_ITEM"` (port_items.py); the per-item EOC spec lives
-- in lua/gen_iuse_map.lua; mom_hooks.iuse_eoc_item dispatches by item type id.
-- Must return charges-consumed (int); consumption is handled in Lua, so 0.
game.iuse_functions["MOM_EOC_ITEM"] = function(params)
  if mod.iuse_eoc_item then return mod.iuse_eoc_item(params) or 0 end
  return 0
end

-- Electrokinetic hacking interface: BN's native hacking is hardcoded to a
-- battery-powered electrohack item, so the psionic version reimplements the
-- card-reader / gun-safe outcomes in Lua (mom_hooks.iuse_hack).  Items carry
-- `"use_action": "MOM_HACK"` (port_items.py FORK_ITEM_OVERRIDES_PREFIX).
game.iuse_functions["MOM_HACK"] = function(params)
  if mod.iuse_hack then return mod.iuse_hack(params) or 0 end
  return 0
end

-- Contemplation recipes: crafting a "contemplation: <power>" recipe fires this
-- on completion; mod.on_craft_result runs the mapped study/learning EOC.
game.add_hook("on_craft_result", function(params)
  if mod.on_craft_result then return mod.on_craft_result(params) end
end)

-- See Mechanisms (Clairsentient): the lockpicking half is a real, timed,
-- interruptible activity (Character:assign_lua_activity, reusing the native
-- ACT_LOCKPICK activity_type) rather than an instant map edit, so it needs a
-- finish callback registered the same way vanilla's own Plumbing mod does
-- (CBN/data/json/lua/plumbing.lua -> game.activity_functions["PLUMBING_FINISH_WASH"]).
game.activity_functions["MOM_SEE_MECHANISMS_LOCKPICK_FINISH"] = function(params)
  if mod.see_mechanisms_lockpick_finish then return mod.see_mechanisms_lockpick_finish(params) end
end

-- Bootstrap (power-list registration, save migration).
game.add_hook("on_game_started", function(...)
  if mod.on_game_started then return mod.on_game_started(...) end
end)
game.add_hook("on_game_load", function(...)
  if mod.on_game_load then return mod.on_game_load(...) end
end)
game.add_hook("on_game_save", function(...)
  if mod.on_game_save then return mod.on_game_save(...) end
end)
