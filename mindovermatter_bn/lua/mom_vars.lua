-- mom_vars (V): DDA-style variable storage for translated EOCs.
-- u_/n_ character vars persist on the creature via set_value/get_value
-- (string store, catalua_bindings_creature.cpp:301); globals live in
-- game.mod_storage (persisted with the save) under .globals.
-- Called from main.lua as require("lua/mom_vars")(mod).
return function(mod)
  local V = {}
  local PREFIX = "mom_"
  local globals = {}  -- rebound to mod storage by V.bind_storage

  function V.bind_storage(storage)
    storage.globals = storage.globals or {}
    globals = storage.globals
  end

  -- Cold-start defaults for vars that multiply into ranges/damage/delays.
  -- nether_attunement_power_scaling is only written by the 30-second
  -- periodic EOC; before its first tick an unset read of 0 collapses every
  -- ppm-scaled range to 0 and turns self-rescheduling drain delays into
  -- run-every-turn loops (QA round 3).
  V.defaults = {
    nether_attunement_power_scaling = 1.0,
  }

  -- numeric character var (missing -> default or 0, like DDA math)
  function V.uget(who, name)
    if not who then return 0 end
    local v = tonumber(who:get_value(PREFIX .. name))
    if v ~= nil then return v end
    return V.defaults[name] or 0
  end

  function V.uset(who, name, v)
    if not who then return end
    who:set_value(PREFIX .. name, tostring(v))
  end

  -- string character var
  function V.ustr(who, name)
    if not who then return '' end
    return who:get_value(PREFIX .. name) or ''
  end

  function V.usets(who, name, s)
    if not who then return end
    who:set_value(PREFIX .. name, s)
  end

  function V.uhas(who, name)
    if not who then return false end
    local s = who:get_value(PREFIX .. name)
    return s ~= nil and s ~= ''
  end

  -- globals
  function V.gget(name)
    local v = globals[name]
    return tonumber(v) or 0
  end

  function V.gset(name, v)
    globals[name] = v
  end

  function V.gstr(name)
    local v = globals[name]
    return v ~= nil and tostring(v) or ''
  end

  function V.ghas(name)
    return globals[name] ~= nil
  end

  return V
end
