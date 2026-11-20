-- mom_prof: an on-demand profiler for MoM's per-turn Lua work.
--
-- BN's Lua has no clock (no os library), but debug.log stamps every line to
-- the millisecond.  So while it runs, this writes "MOMPROF" bracket lines
-- around MoM's per-turn tick and every recurring task inside it, and counts
-- how often each event hook fired during the turn.  tools/mom_prof_report.py
-- turns the brackets into totals: MoM's share of each turn versus the time
-- between turns (the engine's share), plus the Lua heap size (GC pressure).
--
-- Console (Debug menu > Lua console):
--   game.mod_runtime.mindovermatter_bn.prof.start(300)   -- next 300 turns
--   game.mod_runtime.mindovermatter_bn.prof.stop()       -- stop early
-- debug.log is written out when the game exits.
--
-- Built 2026-11-19 for the user's report of poor performance while standing
-- still.  Costs nothing while off: it only swaps wrappers in on start().
return function(mod)
  local P = {}
  mod.prof = P

  -- Hooks preload.lua dispatches as mod.<name>(params).  The high-frequency
  -- ones are counted only; the rest are also bracketed.
  local COUNT_ONLY = {
    on_mon_effect = true, on_effect_added = true, on_effect_removed = true,
    on_mon_effect_added = true, on_mon_effect_removed = true,
  }
  local HOOKS = {
    "on_effect_added", "on_effect_removed", "on_mon_effect_added", "on_mon_effect",
    "on_mon_effect_removed", "on_mon_death", "on_character_death", "on_shoot",
    "on_mapgen_postprocess", "on_melee_attacked", "on_weather_changed",
    "on_craft_result", "on_spell_try_cast", "on_spell_cast", "on_game_save",
  }

  local active, left = false, 0
  local orig_tick, orig_hooks, wrapped = nil, {}, {}
  local counts = {}

  local function log(s) gdebug.log_info("MOMPROF " .. s) end

  -- Run f(...) between brackets, keeping its results and re-raising its error.
  local function bracketed(name, f, ...)
    log("b " .. name)
    local res = table.pack(pcall(f, ...))
    log("e " .. name)
    if not res[1] then error(res[2], 0) end
    return table.unpack(res, 2, res.n)
  end

  local function wrap_recurring()
    for id, r in pairs(mod.recurring or {}) do
      if type(r) == "table" and r.fn and not wrapped[r] then
        local f = r.fn
        wrapped[r] = f
        r.fn = function(...) return bracketed("r:" .. id, f, ...) end
      end
    end
  end

  local function unwrap_recurring()
    for r, f in pairs(wrapped) do r.fn = f end
    wrapped = {}
  end

  local function locate_stats()
    local ok, s = pcall(function()
      local st = game.mod_storage[game.current_mod or "mindovermatter_bn"]
      st = st and st.locate
      local last = mod.locate and mod.locate._passive_state and mod.locate._passive_state()
      return string.format("locate n=%s ids_bytes=%d cats_bytes=%d backlog=%s",
        tostring(st and st.n), st and #(st.ids or "") or 0, st and #(st.cats or "") or 0,
        tostring(last and last.backlog))
    end)
    return ok and s or ("locate ?" .. tostring(s))
  end

  local function tick()
    wrap_recurring()
    local t = gapi.current_turn():to_turn()
    log(string.format("b tick %d kb=%d", t, math.floor(collectgarbage("count"))))
    local ok, err = pcall(orig_tick)
    local parts = {}
    for k, v in pairs(counts) do parts[#parts + 1] = k .. "=" .. v end
    counts = {}
    log("e tick " .. table.concat(parts, " "))
    left = left - 1
    if left <= 0 then P.stop() end
    if not ok then error(err, 0) end
  end

  function P.start(turns)
    if active then P.stop() end
    turns = math.floor(tonumber(turns) or 300)
    active, left = true, turns
    counts = {}
    orig_tick = mod.on_every_x
    mod.on_every_x = tick
    for _, name in ipairs(HOOKS) do
      local f = mod[name]
      if f then
        orig_hooks[name] = f
        if COUNT_ONLY[name] then
          mod[name] = function(...)
            counts[name] = (counts[name] or 0) + 1
            return f(...)
          end
        else
          mod[name] = function(...)
            counts[name] = (counts[name] or 0) + 1
            return bracketed("h:" .. name, f, ...)
          end
        end
      end
    end
    log(string.format("start turns=%d kb=%d %s", turns,
      math.floor(collectgarbage("count")), locate_stats()))
    gapi.add_msg(MsgType.info, "MoM profiler on for " .. turns .. " turns.")
  end

  function P.stop()
    if not active then return end
    active = false
    mod.on_every_x = orig_tick
    for name, f in pairs(orig_hooks) do mod[name] = f end
    orig_hooks = {}
    unwrap_recurring()
    log(string.format("stop kb=%d %s", math.floor(collectgarbage("count")), locate_stats()))
    gapi.add_msg(MsgType.info, "MoM profiler off.  Exit the game to write debug.log.")
  end

  return P
end
