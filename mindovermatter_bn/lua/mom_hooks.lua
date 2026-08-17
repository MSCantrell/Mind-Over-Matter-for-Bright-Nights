-- mom_hooks: wires the hook stubs preload.lua registered to real handlers.
-- Called from main.lua as require("lua/mom_hooks")(mod).
return function(mod)
  local util = mod.util

  -- Recurring-EOC registry: id -> {fn, min_turns, max_turns, next_turn, deactivate}
  mod.recurring = mod.recurring or {}

  function mod.on_every_x()
    -- Integer turn numbers throughout: TimePoint has __lt/__eq but no __le,
    -- so >= on TimePoints is unsafe (catalua_bindings.cpp:971).
    local turn = gapi.current_turn():to_turn()
    local you = gapi.get_avatar()

    -- Drain the queue_eocs scheduler.
    local q = util.queue
    for i = #q, 1, -1 do
      if turn >= q[i].fire_turn then
        local entry = table.remove(q, i)
        entry.fn(entry.you or you)
      end
    end

    -- Fire due recurring EOCs on their randomized cadence.
    for id, r in pairs(mod.recurring) do
      if r.next_turn == nil then
        r.next_turn = turn + gapi.rng(r.min_turns, r.max_turns)
      elseif turn >= r.next_turn then
        if r.deactivate and r.deactivate(you) then
          mod.recurring[id] = nil
        else
          r.fn(you)
          r.next_turn = turn + gapi.rng(r.min_turns, r.max_turns)
        end
      end
    end

    -- BN's activity_type has no "do_turn_eoc" key (DDA-only); MoM has
    -- exactly one use of it (ACT_PSI_STUDYING_POWER -> EOC_PSI_STUDYING_POWER,
    -- the contemplation grind's per-turn spell-exp tick), so it's dispatched
    -- directly here rather than building a whole activity/EOC manifest for
    -- one entry. The EOC's own condition already gates on
    -- effect_psi_studying_power, so this is a no-op the rest of the time.
    if mod.eoc['EOC_PSI_STUDYING_POWER'] then
      mod.eoc['EOC_PSI_STUDYING_POWER'](you, nil, {})
    end

    -- No Go Zone (original fork power): per-turn telekinetic exclusion field.
    -- The tick self-gates on effect_telekinetic_nogozone, so it's a single
    -- has_effect check the rest of the time.
    if mod.eoc['EOC_TELEKIN_NOGOZONE_TICK'] then
      mod.eoc['EOC_TELEKIN_NOGOZONE_TICK'](you, nil, {})
    end

    -- Warped Strikes (teleport): keep the wielded weapon's reach flags in sync
    -- with the buff.  BN has no MELEE_RANGE_MODIFIER enchantment, so reach must
    -- be maintained on the item itself; see mod.warped_strikes_maintain below.
    -- Self-gates cheaply for non-teleporters, so it's ~free the rest of the time.
    if mod.warped_strikes_maintain then
      local ok, err = pcall(mod.warped_strikes_maintain, you)
      if not ok then gdebug.log_error("MoM-BN: warped_strikes: " .. tostring(err)) end
    end

    -- Integrated armor (trait -> worn item): BN has no `integrated_armor`
    -- mutation field, so traits that work by granting a worn item need the
    -- garment put on from here.  Self-throttles to one sweep a minute and gates
    -- on a single has_trait, so it is ~free for non-Photokinetics.
    if mod.u and mod.u.integrated_armor_maintain then
      local ok, err = pcall(mod.u.integrated_armor_maintain, you)
      if not ok then gdebug.log_error("MoM-BN: integrated_armor: " .. tostring(err)) end
    end

    -- Nullification.  pcall-guarded: this one touches the spellbook, so a bad
    -- turn must never escape and take on_every_x (and the restore) down with it.
    if mod.nullification_poll then
      local ok, err = pcall(mod.nullification_poll, you)
      if not ok then gdebug.log_error("MoM-BN: nullification: " .. tostring(err)) end
    end
  end

  -- effect_type-linked EOC dispatch tables, keyed by effect type id string.
  -- Hooks fire only for effects carrying the EFFECT_LUA_ON_ADDED /
  -- EFFECT_LUA_ON_REMOVED flags (see preload.lua).
  -- params keys per character_turn.cpp:609: char (Character), effect (Effect).
  mod.effect_added_handlers = mod.effect_added_handlers or {}
  mod.effect_removed_handlers = mod.effect_removed_handlers or {}

  local function effect_key(params)
    -- get_id() -> EffectTypeId; :str() for the bare id (tostring() would
    -- give "EffectTypeId[...]").  TODO 3 resolved: catalua_bindings_effect.cpp:20.
    return params.effect:get_id():str()
  end

  -- Every add/remove the hooks see invalidates mom_math's turn-scoped
  -- maintained_count cache (perf fix 2026-08-14) — this is what catches a
  -- flagged maintained effect expiring naturally, which no Lua write path sees.
  function mod.on_effect_added(params)
    mod.math.maintained_dirty()
    local h = mod.effect_added_handlers[effect_key(params)]
    if h then return h(params.char or params.character, params.effect) end
  end

  function mod.on_effect_removed(params)
    mod.math.maintained_dirty()
    local h = mod.effect_removed_handlers[effect_key(params)]
    if h then return h(params.char or params.character, params.effect) end
  end

  -- Monster twins (params key is `mon`, catalua_bindings.cpp:816); the same
  -- handler tables serve both, so a marker landing on a monster dispatches
  -- its EOC with you = the monster.
  function mod.on_mon_effect_added(params)
    mod.math.maintained_dirty()
    local h = mod.effect_added_handlers[effect_key(params)]
    if h then return h(params.mon, params.effect) end
  end

  function mod.on_mon_effect_removed(params)
    mod.math.maintained_dirty()
    local h = mod.effect_removed_handlers[effect_key(params)]
    if h then return h(params.mon, params.effect) end
  end

  -- Monster death-effect bridge.  gen_mon_death: mon id -> { spell?, level?,
  -- eoc?, message? } (from DDA death_function objects BN's loader can't hold).
  -- Fired by preload's on_mon_death hook; guarded so a dying-monster edge case
  -- never surfaces a debugmsg.
  local U = mod.U
  local mon_death = require("lua/gen_mon_death")
  function mod.on_mon_death(params)
    local mon = params.mon
    if not mon then return end
    -- `:str()`, NOT tostring(): luna's to_string for a string_id is
    -- "%s[%s]" % (usertype name, id) (catalua_bindings_ids_common.h:55), so
    -- tostring() gives "MtypeId[mon_foo]" and misses every key in mon_death.
    -- This silently disabled all 22 death payloads until 2026-08-01.
    local ok, id = pcall(function() return mon:get_type():str() end)
    if not ok then return end
    local d = mon_death[id]
    if not d then return end
    if d.message then
      local name = "creature"
      pcall(function() name = mon:get_name() end)
      -- DDA death messages use printf %s / %1$s for the monster's name.
      local msg = d.message:gsub("%%1%$s", name):gsub("%%s", name)
      pcall(function() gapi.add_msg(MsgType.warning, msg) end)
    end
    if d.spell then
      pcall(function() U.cast_spell(mon, d.spell, d.level or 0, nil) end)
    end
    if d.eoc then
      local fn = mod.eoc and mod.eoc[d.eoc]
      if fn then pcall(function() fn(mon, mon, {}) end) end
    end
  end

  -- Melee combat auras (Phase 4): upstream delivered "blind/zap/burn whoever
  -- attacks you (or whoever you attack)" via enchantment hit_me_effect /
  -- hit_you_effect procs attached to a maintained aura effect.  BN effect_types
  -- carry no enchantments, and the leaf attack spells were dropped from the
  -- port, so we re-create the procs off the on_creature_melee_attacked hook.
  --   params (melee.cpp:1762 / monster.cpp:2322): char = attacker,
  --   target = victim, success = did the blow land.
  -- hit_me: the avatar is the victim  -> proc centred on the attacker.
  -- hit_you: the avatar is the attacker -> proc centred on the victim.
  local m, U, J, V = mod.math, mod.u, mod.jmath, mod.vars
  -- Shared INT/nether scaling factor the upstream damage/aoe formulas multiply
  -- through (scaling_factor(int) * nether_attunement_power_scaling).
  local function power_scale(you)
    return J.scaling_factor(you, nil, {}, m.int(you))
         * (V.uget(you, "nether_attunement_power_scaling") or 1)
  end
  -- proc signature: (you, foe, hit_me).  `foe` is the other creature (the
  -- attacker for hit_me, the victim for hit_you); `hit_me` is true when the
  -- avatar was the one struck.
  mod.melee_auras = {
    -- Blinding Radiance (photokinetic_blinding_glare): blast-blind the foe and
    -- everything around it, radius scaled by level/INT/nether, 1-in-3 per hit
    -- (enchant_photokin_blinding_glare hit_you/hit_me, once_in 3).
    {
      effect = "effect_photokin_blinding_glare",
      once_in = 3, hit_me = true, hit_you = true,
      proc = function(you, foe)
        local lvl = math.max(m.spell_level(you, "photokinetic_blinding_glare"), 0)
        local radius = math.min((lvl * 1.2 + 5) * power_scale(you), 40)
        -- Blinding a monster is silent (its "You're blinded!" apply_message is
        -- player-only), so announce a fresh blind ourselves — otherwise the
        -- power looks inert even though effect_cache[VISION_IMPAIRED] is set.
        local fresh = not foe:has_effect(EffectTypeId.new("blind"))
        -- photokin_blinding_glare_attack applied `blind` for 500..2000 "moves"
        -- (add_effect_to_target divides by 100 -> 5..20 turns).
        U.effect_around(foe:get_pos_ms(), radius, "blind",
                        TimeDuration.from_turns(U.rng(5, 20)))
        if fresh then
          U.msg(you, "Your blinding radiance floods " .. foe:get_name() ..
                "'s eyes!", MsgType.good)
        end
      end,
    },
    -- Electric Aura (effect_electrokin_zap_enemies): electric thorns when a
    -- foe hits you, 1-in-2 (enchant_electrokin_zap_enemies, range 1).  Damage
    -- uses upstream's exact level id `electrokinesis_zap_enemies` — which is
    -- unknown (-> level -1), so like upstream it stays a flat ~1-5 hit.
    {
      effect = "effect_electrokin_zap_enemies",
      once_in = 2, hit_me = true, hit_you = false,
      proc = function(you, foe)
        if foe:is_elec_immune() then return end
        local lvl = m.spell_level(you, "electrokinesis_zap_enemies")
        local sc = power_scale(you)
        U.deal_flat_damage(foe, U.rng((lvl / 4 + 1) * sc, (lvl / 2 + 5) * sc), you)
      end,
    },
    -- (Voltaic Strikes melee-electrify proc removed 2026-07-12: the power was
    -- cut in the Electrokinetic retune, replaced by electrokinetic_lightning_strike.)
    -- Fire Aura (effect_pyrokinetic_aura): heat damage + ignite on every hit,
    -- either direction (pyro_aura_attack/attacked, 5-15 / 5-20 * nether).
    {
      effect = "effect_pyrokinetic_aura",
      once_in = 1, hit_me = true, hit_you = true,
      proc = function(you, foe)
        local nether = V.uget(you, "nether_attunement_power_scaling") or 1
        U.deal_flat_damage(foe, U.rng(5, 18) * nether, you)
        foe:add_effect(EffectTypeId.new("onfire"),
                       TimeDuration.from_turns(U.rng(2, 4)), nil, nil)
      end,
    },
    -- Reactive Displacement (effect_teleport_reactive_displacement): blink the
    -- attacker away on every hit.  Reuses the ported EOC verbatim — foe as the
    -- teleport target (`you`), avatar as the caster (`npc`).
    {
      effect = "effect_teleport_reactive_displacement",
      once_in = 1, hit_me = true, hit_you = false,
      proc = function(you, foe)
        local fn = mod.eoc["EOC_TELEPORT_DISPLACEMENT_CHECK"]
        if fn then fn(foe, you, {}) end
      end,
    },
    -- Warper Combat / Flickerflash Stance (effect_teleport_loci_establishment):
    -- 1-in-3, you flicker away when struck (hit_me, hit_self) or blink the enemy
    -- when you land a blow (hit_you).  Upstream cast short_range_teleport spells;
    -- the attacker one is picker-registered (mom_eoc), so both directions reuse
    -- the picker-free random blink instead.  (The upstream DIMENSIONAL_ANCHOR
    -- guard on the enchantment is not modelled — accepted simplification.)
    {
      effect = "effect_teleport_loci_establishment",
      once_in = 3, hit_me = true, hit_you = true,
      proc = function(you, foe, hit_me)
        U.cast_spell(hit_me and you or foe, "teleport_blink_real", 10, nil)
      end,
    },
    -- Cyan Elixir shock-back (effect_electrokin_potion): the electrokinesis
    -- potion's `enchant_electrokin_potion` had a hit_me_effect (electro_potion_
    -- attacked: 3-7 * nether electric + a brief daze) that BN's enchantment-less
    -- effects dropped on the floor.  Reproduce it here — jolt + daze anything
    -- that melees you while the elixir is active, every hit.  Elec-immune foes
    -- shrug it off, matching the Electric Aura proc above.
    {
      effect = "effect_electrokin_potion",
      once_in = 1, hit_me = true, hit_you = false,
      proc = function(you, foe)
        if foe:is_elec_immune() then return end
        local nether = V.uget(you, "nether_attunement_power_scaling") or 1
        U.deal_flat_damage(foe, U.rng(3, 7) * nether, you)
        foe:add_effect(EffectTypeId.new("dazed"),
                       TimeDuration.from_turns(U.rng(1, 2)), nil, nil)
      end,
    },
    -- Red Elixir burn-back (effect_pyrokin_potion): the pyrokinesis potion's
    -- `enchant_pyrokin_potion` hit_me_effect (pyro_aura_attacked: 5-20 * nether
    -- heat + ignite) was likewise stripped.  Same shape as the Fire Aura proc
    -- above, but hit_me only (you don't burn things YOU hit with this one).
    {
      effect = "effect_pyrokin_potion",
      once_in = 1, hit_me = true, hit_you = false,
      proc = function(you, foe)
        local nether = V.uget(you, "nether_attunement_power_scaling") or 1
        U.deal_flat_damage(foe, U.rng(5, 20) * nether, you)
        foe:add_effect(EffectTypeId.new("onfire"),
                       TimeDuration.from_turns(U.rng(2, 4)), nil, nil)
      end,
    },
    -- Blue Elixir stutterstep (effect_teleport_potion): the teleportation
    -- potion's `enchant_teleport_potion` had a hit_you_effect (teleport_slow_
    -- monster -> effect_teleport_slow, "Stutterstepping") that warp-slows any
    -- enemy you strike.  BN stripped BOTH the enchant AND effect_teleport_slow's
    -- own SPEED penalty; port_effects.py now rebuilds the effect's speed_mod, so
    -- here we just apply it on each blow YOU land (hit_you, every hit).
    {
      effect = "effect_teleport_potion",
      once_in = 1, hit_me = false, hit_you = true,
      proc = function(you, foe)
        foe:add_effect(EffectTypeId.new("effect_teleport_slow"),
                       TimeDuration.from_turns(U.rng(20, 30)), nil, nil)
      end,
    },
  }
  -- Pre-resolve each aura's EffectTypeId once instead of on every landed
  -- blow (perf fix 2026-08-08).
  for _, aura in ipairs(mod.melee_auras) do aura.eid = EffectTypeId.new(aura.effect) end

  function mod.on_melee_attacked(params)
    if not params or not params.success then return end
    local ok, err = pcall(function()
      local you = gapi.get_avatar()
      if not you then return end
      local attacker, victim = params.char, params.target
      if not attacker or not victim then return end
      -- The avatar is the creature sharing the avatar's tile (exactly one does);
      -- U.is_avatar falls back to true on error, unsafe for monster operands.
      local yp = you:get_pos_ms()
      local function is_you(c)
        local p = c:get_pos_ms()
        return p.x == yp.x and p.y == yp.y and p.z == yp.z
      end
      local hit_me = is_you(victim)
      local hit_you = (not hit_me) and is_you(attacker)
      if not (hit_me or hit_you) then return end
      local foe = hit_me and attacker or victim
      for _, aura in ipairs(mod.melee_auras) do
        local dir_ok = (hit_me and aura.hit_me) or (hit_you and aura.hit_you)
        if dir_ok and you:has_effect(aura.eid)
           and (aura.once_in <= 1 or gapi.rng(1, aura.once_in) == 1) then
          aura.proc(you, foe, hit_me)
        end
      end
    end)
    if not ok then
      gdebug.log_error("MoM-BN: on_melee_attacked: " .. tostring(err))
    end
  end

  -- Warped Strikes (teleport_warped_strikes) --------------------------------
  -- DDA delivered this power's melee-reach extension through an effect
  -- enchantment on MELEE_RANGE_MODIFIER.  This BN build has NO such enchantment
  -- value: item::reach_range() (item.cpp) reads ONLY the wielded weapon's own
  -- REACH_ATTACK / REACH3 flags, so the ported effect applied but did nothing.
  -- Reimplement it by stamping those flags onto the wielded weapon while the
  -- buff is up, quantized to BN's two reach tiers (DDA's smooth per-level
  -- scaling can't be represented; 2->3 tiles is the whole range BN supports):
  --   spell level 0-4  -> REACH_ATTACK          (reach 2)
  --   spell level 5+   -> REACH_ATTACK + REACH3  (reach 3)
  -- Unarmed is not covered -- reach lives on the weapon item and fists are a
  -- transient pseudo-weapon -- so this is wielded-weapons-only, matching where
  -- BN keeps reach at all.
  --
  -- Lifecycle safety (the "never weld a flag onto a real weapon" requirement):
  -- we record EXACTLY the flags we add in an item var (mom_warped_flags) and
  -- only ever strip those, so a weapon that NATIVELY carries REACH_ATTACK (a
  -- spear, a naginata) is never harmed.  Every turn we re-reconcile: the wielded
  -- weapon is re-stamped to the current tier (so a spell-level change is picked
  -- up), and any OTHER item still carrying our var -- a weapon swapped away into
  -- the pack, or anything at all once the buff ends -- is stripped.  So the
  -- flags cannot outlive the effect on any item that stays with the character.
  -- Only teleporters ever run the reconcile (gated below); a persisted var lets
  -- everyone else skip it entirely.
  local WARPED_EFFECT = "effect_teleport_warped_strikes"
  local WARPED_EID = EffectTypeId.new(WARPED_EFFECT)
  local warped_flag_cache = {}
  local function warped_fid(name)
    local f = warped_flag_cache[name]
    if not f then f = JsonFlagId.new(name); warped_flag_cache[name] = f end
    return f
  end
  -- Remove only the flags WE added (per the item's own record); leave natives.
  local function warped_strip(it)
    local rec = it:get_var_str("mom_warped_flags", "")
    if rec == "" then return false end
    for name in rec:gmatch("[^,]+") do it:unset_flag(warped_fid(name)) end
    it:set_var_str("mom_warped_flags", "")
    return true
  end
  -- Add the wanted flags the item lacks; record just those (warped_strip having
  -- already cleared last tick's record) so a native reach flag is never logged
  -- as ours and thus never stripped later.
  local function warped_apply(it, want)
    local added = {}
    for _, name in ipairs(want) do
      if not it:has_flag(warped_fid(name)) then
        it:set_flag(warped_fid(name))
        added[#added + 1] = name
      end
    end
    it:set_var_str("mom_warped_flags", table.concat(added, ","))
    return #added > 0
  end

  function mod.warped_strikes_maintain(you)
    if not you then return end
    local active = you:has_effect(WARPED_EID)
    -- Fast path: skip the inventory scan unless the buff is up or
    -- mom_warped_managing says a previous tick left residue to clean up.
    -- mom_warped_managing is set to 1 on every tick that stamps or finds a
    -- managed item and 0 otherwise (see the end of this function), so it
    -- already fully answers "might a weapon still carry our flags" -- a
    -- second check against the TELEPORTER trait added nothing but forced
    -- EVERY teleporter to pay a full all_items() scan on EVERY turn forever,
    -- even one who has never cast this power (perf fix 2026-08-08; this was
    -- the single biggest per-tick cost for teleporters specifically).
    if not active and V.uget(you, "mom_warped_managing") ~= 1 then
      return
    end
    local want
    if active then
      local lvl = math.max(m.spell_level(you, "teleport_warped_strikes"), 0)
      want = (lvl >= 5) and { "REACH_ATTACK", "REACH3" } or { "REACH_ATTACK" }
    end
    local any = false
    for _, it in ipairs(you:all_items(false)) do
      if active and you:is_wielding(it) then
        warped_strip(it)                 -- clear last tick's flags, then...
        warped_apply(it, want)           -- ...re-stamp to the current tier
        any = true                       -- a weapon is under management
      else
        warped_strip(it)                 -- stowed swap / buff ended -> clean it
      end
    end
    -- Keep the managing flag up for the whole buff (even a turn with no weapon
    -- wielded) so the post-expiry cleanup sweep is guaranteed to run once.
    V.uset(you, "mom_warped_managing", (active or any) and 1 or 0)
  end

  -- Marker-bridge dispatch (Phase 2): an EOC-backed spell applies its
  -- generated mom_cast_<spell_id> marker; when that lands, run the translated
  -- EOC from mod.eoc.  The lookup happens at fire time so Phase 3 transpiler
  -- output can fill mod.eoc without touching this wiring.  EOC signature is
  -- (you, npc, ctx); the cast-map entry rides in ctx.
  -- EOC signature is (you, npc, ctx) with DDA semantics you = spell TARGET,
  -- npc = CASTER.  The hook can't recover the caster, so we pass the avatar:
  -- correct for every player cast (self-casts included, where you == npc);
  -- an NPC psion's marker would misattribute to the player (accepted — MoM
  -- NPC enemies attack via monster spells, not these EOCs).
  -- A mom_cast_* marker is a one-shot dispatch token: the spell applies it, its
  -- EFFECT_LUA_ON_ADDED fires the INITIATE, and that's its whole job.  But BN
  -- only fires on_added when an effect is *newly* added (character_turn.cpp
  -- process_one_effect gates the hook on is_new); re-adding a marker that is
  -- still live -- its ~1-turn spell duration hasn't elapsed -- just bumps the
  -- duration and silently no-ops.  So a SECOND cast within the same turn never
  -- re-runs the INITIATE and the power looks dead.  Phase exposed this: cancel
  -- its target picker (an invalid/aborted cast leaves you standing in place with
  -- moves to spare) and immediately recast, and the recast offered no targeting
  -- UI at all.  Consume the token right after dispatch so every cast lands as a
  -- fresh add and re-fires.  remove_effect only flags is_removed (creature.cpp),
  -- and these markers carry no ON_REMOVED hook, so this can't recurse or
  -- invalidate the effect mid-add.
  local function consume_marker(you, marker)
    if you and marker then
      pcall(function() you:remove_effect(EffectTypeId.new(marker)) end)
    end
  end

  -- Invoke an INITIATE/dispatch EOC, swallowing the U.cancel_cast signal so an
  -- aborted target pick (Esc) runs no downstream effects/messages and logs
  -- nothing.  Real errors are still surfaced (once) rather than propagating into
  -- the C++ effect hook as an uncaught Lua error.
  local function dispatch_eoc(fn, you, ctx)
    if not fn then return nil end
    local ok, res = pcall(fn, you, gapi.get_avatar(), ctx or {})
    if ok then return res end
    if mod.u.is_cancel(res) then return nil end
    gdebug.log_warn("MoM-BN: EOC dispatch error: " .. tostring(res))
    return nil
  end

  -- Event-EOC dispatch (DDA `eoc_type: EVENT` keyed by `required_event`).  All
  -- such EOCs are transpiled into mod.eoc; the transpiler groups their ids by
  -- event in mod.gen_events.  DDA semantics: u = the avatar, no beta talker,
  -- each EOC self-gates.  Defined here (ahead of the cast-map loop) so the cast
  -- handlers below can fire per-cast events; the game_start/game_begin callers
  -- further down capture this same local.
  local function fire_event_eocs(event, you, ctx)
    for _, id in ipairs((mod.gen_events or {})[event] or {}) do
      local fn = mod.eoc[id]
      if fn then
        local ok, err = pcall(fn, you, nil, ctx or {})
        if not ok then
          gdebug.log_error("MoM-BN: event " .. event .. " -> " .. id ..
                           ": " .. tostring(err))
        end
      end
    end
  end
  mod.fire_event_eocs = fire_event_eocs

  -- Synthesize DDA's per-cast events for one psi power.  BN has no spell-cast
  -- hook (catalua_hooks.cpp), so a top-level schooled psi cast is detected by a
  -- caster-side marker (a self buff's own INITIATE marker, or a generated
  -- finish-tag for offensive powers) and THIS fires the whole cost/attunement/
  -- metaphysics/consequence EOC class at once — opens_spellbook first (it sets
  -- the attunement power-scaling that spellcasting_finish's gain formula reads),
  -- then spellcasting_finish.  ctx mirrors event_spec<spellcasting_finish>:
  -- success = 1 (a psionic cast doesn't spell-fail; channeling failure is its
  -- own attunement/weather-gated roll), difficulty/school/spell from the cast
  -- map.  V.gget('false') is 0, so success = 1 makes the success paths fire and
  -- leaves the fail-only backfire paths quiet.
  local function fire_spell_cast_events(you, entry, spell_id)
    if not (you and entry and entry.finish and entry.school) then return end
    local ctx = { school = entry.school, difficulty = entry.difficulty or 0,
                  spell = spell_id, success = 1 }
    fire_event_eocs("opens_spellbook", you, ctx)
    fire_event_eocs("spellcasting_finish", you, ctx)
  end

  mod.cast_map = require("lua/gen_cast_map")

  -- ---- Nullification: empty the spellbook while a NO_PSIONICS effect is on ----
  --
  -- "You can't use your powers" is unenforceable in BN by any other route.
  -- spell::can_cast (magic/magic.cpp:781) checks ONLY spell components and
  -- energy -- no flag, no effect -- and BN has no spell-cast hook to intercept
  -- (see fire_spell_cast_events below, same problem).  Forcing a guaranteed
  -- miss is also out: spell_fail's effective_skill is
  -- `2*(spell_level - difficulty) + INT + metaphysics`, and ported powers reach
  -- max_level 40 against a median difficulty of 1, so the level term alone hits
  -- +78 before stats.  The only enchantable inputs BN offers are INTELLIGENCE
  -- and SKILL_LEVEL (all skills), so driving that below zero needs roughly -100
  -- and would nullify a novice while leaving a veteran untouched.
  --
  -- So: take the powers out of the spellbook.  Lossless, because
  -- spell::get_level() is derived purely from experience
  -- (`floor(log(experience + a)/b + c)`, magic.cpp) -- restore the xp and the
  -- level comes back with it.
  --
  -- Structured as an idempotent per-turn POLL rather than paired
  -- effect_added/effect_removed handlers, on purpose.  A paired design loses the
  -- powers permanently if the removal half ever fails to run -- mid-cast effect
  -- expiry, a save reloaded while nullified, a crash.  The poll makes recovery
  -- automatic instead: the stash lives in a character value (so it survives
  -- saving), and the very next turn after the effect is gone the restore branch
  -- fires no matter HOW it went away.  That is the same cold-boot-rearm
  -- reasoning as the maintained-power drain loops.
  mod.psi_powers = require("lua/gen_psi_powers")

  local NULLIFY_EFFECTS = {
    "effect_psi_null",         -- fd_nullifying_field / anti-psi zombies
    "effect_psi_null_unbound", -- same, minus the self-removal
    "effect_psi_neutralized",  -- 24h "something is interfering with your psionics"
  }
  -- The other NO_PSIONICS carriers are deliberately NOT here.  psi_stunned and
  -- effect_psi_too_much_pain_cant_channel already have their own gates,
  -- effect_clair_astral_projection is supposed to leave some powers usable,
  -- effect_psi_turn_off_powers lasts one second and only exists to drop
  -- maintained powers, and effect_monster_telekinetic_aegis is a monster effect.
  -- Emptying a spellbook for any of those would be a much larger behaviour
  -- change than the nullifier fields this was built for.
  -- Pre-resolve once: nullify_active runs from nullification_poll on EVERY
  -- turn for EVERY character (not just psions), so these three must not be
  -- reconstructed per call (perf fix 2026-08-08).
  local NULLIFY_EIDS = {}
  for _, id in ipairs(NULLIFY_EFFECTS) do NULLIFY_EIDS[#NULLIFY_EIDS + 1] = EffectTypeId.new(id) end
  local STASH_KEY = "mom_nullified_powers"
  local GRACE_KEY = "mom_nullified_grace"
  -- Turns of UNINTERRUPTED non-nullification required before handing the powers
  -- back.  A restore the instant the effect drops is wrong, because the effect
  -- is not continuous even while you stand in the field: effect_psi_null caps at
  -- max_duration 1 minute and the field re-applies it each turn, so any hitch
  -- that costs a tick of field processing -- reloading a save taken inside the
  -- field being the reproducible one -- leaves a gap the restore branch races
  -- into.  Playtest 2026-07-29 hit exactly that: reload inside the field handed
  -- the powers back, then the next field tick stripped them again.  Waiting a
  -- few turns costs nothing when you have genuinely walked out (the field decays
  -- in ~3 turns now) and absorbs every one-tick gap.
  local GRACE_TURNS = 5
  -- Activities that resolve a spell BY ID when they finish, so forgetting the
  -- spell out from under one makes BN debugmsg "Tried to get unknown spell" and
  -- fall back to a garbage spell (activity_handlers.cpp:4757 for the cast,
  -- :2195 for study).  Playtest hit this too.  Cancel them instead.
  local SPELL_ACTIVITIES = { ACT_SPELLCASTING = true, ACT_STUDY_SPELL = true }

  local function nullify_active(you)
    for _, eid in ipairs(NULLIFY_EIDS) do
      if you:has_effect(eid) then return true end
    end
    return false
  end

  -- Abort an in-flight cast/study before its spell disappears.
  local function cancel_spell_activity(you)
    if not you.get_activity then return end
    local act = you:get_activity()
    if act and act.id_str and SPELL_ACTIVITIES[act:id_str()] then
      you:cancel_activity()
      mod.u.msg(you, "Your concentration is severed.", MsgType.bad, nil)
    end
  end

  function mod.nullification_poll(you)
    if not you or not you.get_magic then return end
    local stash = you:get_value(STASH_KEY) or ""
    local active = nullify_active(you)
    -- Cheap gate first (perf fix 2026-08-09): get_magic() used to run for
    -- EVERY character on EVERY turn, even mundane ones who were never
    -- nullified and have nothing stashed.  Only fetch the spellbook once
    -- there's actually work to do.
    if not active and stash == "" then return end
    local km = you:get_magic()
    if not km then return end
    local powers = mod.psi_powers or {}

    if active then
      -- Sweep every turn, not just on the first: a power learned WHILE nullified
      -- would otherwise stay castable until the effect ended.  After the first
      -- sweep there is normally nothing left to find, so this costs one
      -- knows_spell per known power.
      local taken = {}
      for _, sid in ipairs(km:spells()) do
        local key = sid:str()
        if powers[key] then
          table.insert(taken, key .. "=" .. tostring(km:get_spell(sid):xp()))
        end
      end
      you:set_value(GRACE_KEY, "0")
      if #taken > 0 then
        cancel_spell_activity(you)
        for _, rec in ipairs(taken) do
          local key = rec:match("^([^=]+)=")
          km:forget_spell(SpellTypeId.new(key))
        end
        -- Append rather than overwrite: a mid-effect top-up must not discard the
        -- xp recorded by the first sweep.
        you:set_value(STASH_KEY,
          (stash ~= "" and (stash .. ";") or "") .. table.concat(taken, ";"))
        if stash == "" then
          mod.u.msg(you, "Your powers slip out of reach.", MsgType.bad, nil)
        end
      end
      return
    end

    -- Not nullified, but wait out the grace window before believing it.
    -- (stash is guaranteed non-empty here: the gate above already returned
    -- for the not-active-and-no-stash case.)
    local grace = tonumber(you:get_value(GRACE_KEY) or "0") or 0
    if grace < GRACE_TURNS then
      you:set_value(GRACE_KEY, tostring(grace + 1))
      return
    end
    you:set_value(GRACE_KEY, "0")
    -- Restore.  Clear the stash FIRST: if learn_spell were to throw partway
    -- through, a surviving stash would be re-restored next turn and re-apply xp
    -- to powers that already got it.  Losing the tail of one restore is
    -- recoverable; an unbounded retry loop against a live spellbook is not.
    you:set_value(STASH_KEY, "")
    local n = 0
    for key, xp in stash:gmatch("([^=;]+)=(%-?%d+)") do
      local sid = SpellTypeId.new(key)
      if not km:knows_spell(sid) then
        km:learn_spell(sid, you, true)  -- force: skips the class-trait gate
      end
      if km:knows_spell(sid) then
        -- math.floor at the binding boundary: set_exp binds void(int) and sol2
        -- rejects a number carrying decimals (same trap as gain_exp in mom_math).
        km:get_spell(sid):set_exp(math.floor(tonumber(xp) or 0))
        n = n + 1
      end
    end
    if n > 0 then
      mod.u.msg(you, "Your powers settle back into place.", MsgType.good, nil)
    end
  end
  -- INITIATE dispatch: a cast marker landing runs the power's translated EOC.
  -- Registered for every markered entry (eoc may be nil — a finish="initiate"
  -- self buff with no INITIATE still needs the event fired).  For self buffs
  -- the marker lands on the caster, so `you` here is the caster.
  for spell_id, entry in pairs(mod.cast_map) do
    if entry.marker then
      mod.effect_added_handlers[entry.marker] = function(you, _eff)
        local ok
        if entry.eoc then
          local fn = mod.eoc[entry.eoc]
          if fn then
            ok = dispatch_eoc(fn, you, { spell_id = spell_id, entry = entry })
          else
            gdebug.log_info("MoM-BN: " .. spell_id .. " -> " .. entry.eoc .. " (not yet ported)")
            gapi.add_msg("[MoM] " .. spell_id .. ": this power is not yet ported.")
          end
        end
        consume_marker(you, entry.marker)
        if entry.finish == "initiate" then
          fire_spell_cast_events(you, entry, spell_id)
        end
        return ok
      end
    end
  end

  -- Path B: offensive / non-self top-level psi powers can't tag the caster via
  -- their INITIATE marker (it lands on the target, or there is none), so the
  -- generator hangs a self-cast finish-tag off their extra_effects that lands
  -- marker momfin_<spell> on the caster.  Fire the per-cast events when it does.
  for spell_id, entry in pairs(mod.cast_map) do
    if entry.finish == "tag" then
      local marker = "momfin_" .. spell_id
      mod.effect_added_handlers[marker] = function(you, _eff)
        fire_spell_cast_events(you, entry, spell_id)
        consume_marker(you, marker)
        return true
      end
    end
  end

  -- No Go Zone (original fork power) isn't in the transpiled cast_map, so wire
  -- its cast marker to its INITIATE by hand -- same shape as the loop above.
  mod.effect_added_handlers["mom_cast_telekinetic_nogozone"] = function(you, _eff)
    local ok = dispatch_eoc(mod.eoc["EOC_TELEKIN_NOGOZONE_INITIATE"], you, {})
    consume_marker(you, "mom_cast_telekinetic_nogozone")
    return ok
  end

  -- Acquisition (original fork power): a Telekinetic who has developed some
  -- fine control -- Force Shove at level 3+ -- eventually intuits No Go Zone,
  -- granted once at a slow cadence.  Kept out of the transpiled RNG learning
  -- pool on purpose; pcall-guarded so a bad turn can never break on_every_x.
  mod.recurring["MOM_NOGOZONE_LEARN"] = {
    min_turns = 8000, max_turns = 18000,
    fn = function(you)
      pcall(function()
        if not you then return end
        local km = you:get_magic()
        if you:has_trait(MutationBranchId.new("TELEKINETIC"))
           and mod.math.spell_level(you, "telekinetic_push") >= 3
           and not km:knows_spell(SpellTypeId.new("telekinetic_nogozone")) then
          mod.u.set_spell_level(you, "telekinetic_nogozone", 1)
          mod.u.msg(you, "A new configuration of force resolves in your mind: "
            .. "you could hold a clear space around yourself at will.  "
            .. "(Learned No Go Zone.)", MsgType.good, nil)
        end
      end)
    end,
  }

  -- Circuit Sense (original fork power): cast marker -> INITIATE, by hand (not
  -- in the transpiled cast_map).
  mod.effect_added_handlers["mom_cast_electrokinetic_circuit_sense"] = function(you, _eff)
    local ok = dispatch_eoc(mod.eoc["EOC_ELECTROKIN_CIRCUIT_SENSE_INITIATE"], you, {})
    consume_marker(you, "mom_cast_electrokinetic_circuit_sense")
    return ok
  end

  -- Mass Hydrothermosis (original fork capstone; id pyrokinetic_aoe_blast, which
  -- REPLACES DDA "Hellfire").  Hand power in fork_powers.json, not in the
  -- transpiled cast_map, so wire its cast marker by hand: boil every monster in
  -- line of sight (U.mass_hydrothermosis), consume the marker, then fire the
  -- per-cast attunement/cost events -- it's a top-level offensive psi cast and
  -- should build nether pressure exactly like a generated finish="tag" power.
  -- The synthetic {school, difficulty, finish} entry is all fire_spell_cast_events
  -- reads.  Acquisition rides the auto-learn map (gen_learn_map keeps the
  -- inherited pyrokinetic_aoe_blast slot + prereqs), so no hand learner is needed.
  mod.effect_added_handlers["mom_cast_pyrokinetic_aoe_blast"] = function(you, _eff)
    local ok = pcall(mod.u.mass_hydrothermosis, you)
    consume_marker(you, "mom_cast_pyrokinetic_aoe_blast")
    fire_spell_cast_events(you,
      { school = "PYROKINETIC", difficulty = 9, finish = "tag" },
      "pyrokinetic_aoe_blast")
    return ok
  end

  -- Quell Fire (fork repair 2026-07-24).  ONE handler for every caster: the
  -- player power's hit_self sub-spell (pyrokinetic_quell_flames_self) and the
  -- flamebreaker triffid's relay (mom_quell_fire_monster_trigger) both land the
  -- same marker, and the character/monster hooks above share this table -- so
  -- `who` is a Character on the player path and a monster on the triffid path.
  -- U.quell_fire strips the caster's own `onfire` and then quenches every tile
  -- the parent spell painted with fd_mom_quench_marker.  No fire_spell_cast_
  -- events call here: the generated momfincast_pyrokinetic_quell_flames tag
  -- still rides the player power's extra_effects and fires them as before.
  mod.effect_added_handlers["mom_cast_mom_quell_fire"] = function(who, _eff)
    local put_out = mod.u.quell_fire(who, 24)
    consume_marker(who, "mom_cast_mom_quell_fire")
    if put_out and put_out > 0 then
      -- U.msg self-gates on U.is_avatar, so the triffid path stays silent.
      mod.u.msg(who, "The flames gutter and die.", MsgType.good, nil)
    end
    return true
  end

  -- Dialogue-effect bridge (Phase 5B).  BN dialogue can't run inline math or
  -- run_eocs, so the psi-attack responses in npcs/dialogue/*.json apply a 1-turn
  -- marker (effects/mom_dialogue_bridge_effects.json) to the target NPC instead;
  -- port_npcs.py substitutes the marker for the stripped payload.  Here `you` is
  -- the marker-bearer (the NPC victim); the avatar is the caster.  For the two
  -- run_eoc bridges, dispatch_eoc passes (alpha = you = victim, beta = avatar),
  -- matching the upstream `alpha_talker:npc, beta_talker:u`.
  -- Resolved lazily inside the handlers (which run at gameplay time): calling
  -- :int_id() at hook-init could precede bodypart-registry finalization.
  local function head_id() return BodyPartTypeId.new("head"):int_id() end

  -- Synaptic Overload (telepathic_blast), scaled variant: reduce the victim's
  -- head HP by a percentage = ((blast_lvl*3)+5) * scaling_factor(caster INT) *
  -- attunement (power_scale is exactly that product), and cost the caster pain.
  mod.effect_added_handlers["mom_dlg_synaptic_overload"] = function(you, _eff)
    pcall(function()
      local caster = gapi.get_avatar()
      local lvl = math.max(mod.math.spell_level(caster, "telepathic_blast"), 0)
      local pct = ((lvl * 3) + 5) * power_scale(caster)
      local bp = head_id()
      local cur = you:get_part_hp_cur(bp)
      you:set_part_hp_cur(bp, math.max(0, math.floor(cur * ((100 - pct) / 100))))
      pcall(function() caster:mod_pain(5) end)
    end)
    consume_marker(you, "mom_dlg_synaptic_overload")
    return true
  end

  -- Synaptic Overload, flat variant (used against the refugee-center traitor):
  -- upstream SETS head HP to 80 - 6*blast_lvl.  Guarded to only ever reduce
  -- (never heal a wounded target back up to 80).
  mod.effect_added_handlers["mom_dlg_synaptic_overload_flat"] = function(you, _eff)
    pcall(function()
      local caster = gapi.get_avatar()
      local lvl = math.max(mod.math.spell_level(caster, "telepathic_blast"), 0)
      local bp = head_id()
      local cur = you:get_part_hp_cur(bp)
      you:set_part_hp_cur(bp, math.max(0, math.min(cur, 80 - (6 * lvl))))
    end)
    consume_marker(you, "mom_dlg_synaptic_overload_flat")
    return true
  end

  -- Neural Spasms -> the transpiled electrokinetic paralysis EOC on the victim.
  mod.effect_added_handlers["mom_dlg_paralysis"] = function(you, _eff)
    local ok = dispatch_eoc(mod.eoc["EOC_ELECTROKIN_PARALYSIS"], you, {})
    consume_marker(you, "mom_dlg_paralysis")
    return ok
  end

  -- Teleporter: banish the traitor into the between-worlds (transpiled EOC).
  mod.effect_added_handlers["mom_dlg_traitor_banish"] = function(you, _eff)
    local ok = dispatch_eoc(mod.eoc["EOC_REMOVE_REFUGEE_CENTER_TRAITOR_BANISHED"], you, {})
    consume_marker(you, "mom_dlg_traitor_banish")
    return ok
  end

  -- Portal-storm teleport-out (upstream string effect `u_die`): the character
  -- leaves their dying world -- a run-ending exit.  Marker is on the avatar
  -- (u_add_effect), so `you` is the player; massive armour-agnostic damage ends
  -- the run.  Deferred to the effect-add hook rather than killing mid-dialogue.
  mod.effect_added_handlers["mom_dlg_u_die"] = function(you, _eff)
    pcall(function() mod.u.deal_flat_damage(you, 100000) end)
    consume_marker(you, "mom_dlg_u_die")
    return true
  end

  -- When the Circuit Sense buff ends by ANY means (re-cast toggle, concentration
  -- break, or the 7-day stand-in expiring), strip the hidden +3 carrier trait so
  -- the Electronics bonus can never outlive the power.  (Effect carries
  -- EFFECT_LUA_ON_REMOVED.)
  mod.effect_removed_handlers["effect_electrokinetic_circuit_sense"] = function(you, _eff)
    if you then mod.u.unset_mutation(you, "MOM_CIRCUIT_SENSE") end
  end

  -- Acquisition (original fork power): an Electrokinetic who has developed See
  -- Electric (level 3+) -- already feeling the shape of current -- eventually
  -- intuits Circuit Sense.  Slow cadence, pcall-guarded, kept out of the
  -- transpiled RNG learning pool on purpose.
  mod.recurring["MOM_CIRCUIT_SENSE_LEARN"] = {
    min_turns = 8000, max_turns = 18000,
    fn = function(you)
      pcall(function()
        if not you then return end
        local km = you:get_magic()
        if you:has_trait(MutationBranchId.new("ELECTROKINETIC"))
           and mod.math.spell_level(you, "electrokinetic_see_electric") >= 3
           and not km:knows_spell(SpellTypeId.new("electrokinetic_circuit_sense")) then
          mod.u.set_spell_level(you, "electrokinetic_circuit_sense", 1)
          mod.u.msg(you, "The current speaks to you more clearly now -- you find "
            .. "you can hold your senses open to the workings of any circuit at "
            .. "will.  (Learned Circuit Sense.)", MsgType.good, nil)
        end
      end)
    end,
  }

  -- See Mechanisms (original fork power, 2026-07-13; single-target redesign
  -- 2026-08-15): "seeing" the tumblers only tells you the answer -- it can't
  -- move a physical mechanism for you, so both branches below still require
  -- a hand on the lock.  Lockpicking needs a real LOCKPICK-quality item and
  -- takes real time (a genuine ACT_LOCKPICK-typed activity); safecracking
  -- needs only your hand on the dial, so it's instant.  One target per cast,
  -- picked with gapi.choose_adjacent_highlight (the same UI vanilla
  -- lockpicking itself uses to prompt for a direction) -- adjacent only, no
  -- exceptions, since neither branch has any business working at a distance.
  -- No roll ever: once the tool/adjacency gate is cleared, both branches
  -- always succeed and never trip an alarm.  Single-level power (max_level 1
  -- in fork_powers.json) -- there's nothing left for mastery to scale.
  --
  -- BN can't edit map terrain/furniture from spell JSON, and the ter_t/furn_t
  -- Lua binding does not expose `lockpick_result`, so the locked->open remap
  -- is a hardcoded table mirroring each object's own lockpick/crack result
  -- (furniture_and_terrain/*.json; safes use their pry/oxytorch result
  -- f_safe_o).  Electronic card readers and keypads are deliberately left to
  -- the Electrokinetic's MOM_HACK bridge -- clean path separation, and a
  -- circuit has no moving mechanism to "see".  Follows the
  -- circuit_sense/nogozone marker template.
  local seem_ids
  local function get_seem_ids()
    if seem_ids then return seem_ids end
    local function T(a, b) return { TerId.new(a):int_id(), TerId.new(b):int_id() } end
    local function F(a, b) return { FurnId.new(a):int_id(), FurnId.new(b):int_id() } end
    seem_ids = {
      ter = {
        T("t_door_locked",          "t_door_c"),
        T("t_door_locked_interior", "t_door_c"),
        T("t_door_locked_peep",     "t_door_c_peep"),
        T("t_door_locked_alarm",    "t_door_c"),
        T("t_door_metal_locked",    "t_door_metal_c"),
        T("t_door_bar_locked",      "t_door_bar_o"),
        T("t_chaingate_l",          "t_chaingate_c"),
      },
      furn = {
        F("f_safe_l",      "f_safe_o"),       -- dial safe: crack it wide open
        F("f_gunsafe_ml",  "f_gunsafe_o"),    -- mechanical (dial) gun safe
        F("f_displaycase", "f_displaycase_o"),
      },
    }
    return seem_ids
  end

  local function is_door_target(map, p)
    local t = map:get_ter_at(p)
    for _, pr in ipairs(get_seem_ids().ter) do
      if t == pr[1] then return pr end
    end
    return nil
  end

  local function is_safe_target(map, p)
    local f = map:get_furn_at(p)
    for _, pr in ipairs(get_seem_ids().furn) do
      if f == pr[1] then return pr end
    end
    return nil
  end

  -- Real BN items carrying LOCKPICK quality (tool_qualities.json items with
  -- "qualities":[["LOCKPICK",n]]).  Lua has no get_quality/get_use binding
  -- for items or Character at all (checked catalua_bindings_item.cpp -- both
  -- are absent), so this reimplements the check as an itype allow-list, the
  -- same workaround the Electrokinetic hacking bridge above uses for its own
  -- native-system gap.  Roster: bone_skewer, hairpin_picklock, crude_picklock,
  -- picklocks (locksmith kit), iceaxe, pseudo_bio_picklock (bionic).
  local lockpick_itypes
  local function get_lockpick_itypes()
    if lockpick_itypes then return lockpick_itypes end
    lockpick_itypes = {
      ItypeId.new("bone_skewer"),
      ItypeId.new("hairpin_picklock"),
      ItypeId.new("crude_picklock"),
      ItypeId.new("picklocks"),
      ItypeId.new("iceaxe"),
      ItypeId.new("pseudo_bio_picklock"),
    }
    return lockpick_itypes
  end

  local function has_lockpick(you)
    for _, it in ipairs(you:all_items(true)) do
      local t = it:get_type()
      for _, lp in ipairs(get_lockpick_itypes()) do
        if t == lp then return true end
      end
    end
    return false
  end

  local ACT_LOCKPICK = ActivityTypeId.new("ACT_LOCKPICK")

  local function crack_safe(you, map, p)
    local pr = is_safe_target(map, p)
    if not pr then return end -- changed underfoot between pick and resolve
    map:set_furn_at(p, pr[2])
    mod.u.msg(you,
      "You read the safe's dial like a book; the tumblers drop and it swings open.",
      MsgType.good, nil)
  end

  local function start_lockpick(you, map, p)
    if not has_lockpick(you) then
      mod.u.msg(you,
        "You see exactly how the pins would fall -- but seeing isn't turning.  "
        .. "You need something to actually work the lock with.", MsgType.info, nil)
      return
    end
    -- Reuses BN's real ACT_LOCKPICK activity_type (player_activities.json)
    -- purely for its verb/UI and its "rooted":true -- that field is what
    -- cancels the activity if you walk away, the same protection vanilla
    -- lockpicking gets against acting at a distance.  The finish callback
    -- below (not the native actor) is what actually resolves it, so there is
    -- no skill roll and no alarm path.
    you:assign_lua_activity({
      type = ACT_LOCKPICK,
      duration = TimeDuration.from_seconds(20),
      on_finish = "MOM_SEE_MECHANISMS_LOCKPICK_FINISH",
      pos = p,
      name = "clair_see_mechanisms",
    })
    mod.u.msg(you,
      "You set to work on the lock, guided by an inner eye that already knows "
      .. "exactly where every pin needs to fall.", MsgType.good, nil)
  end

  -- game.activity_functions trampoline target; registered in preload.lua.
  mod.see_mechanisms_lockpick_finish = function(params)
    local you = params.user
    local map = gapi.get_map()
    local p = params.pos and map:abs_to_bub(params.pos) or you:get_pos_ms()
    local pr = is_door_target(map, p)
    if not pr then return end -- door changed underfoot; say nothing
    map:set_ter_at(p, pr[2])
    mod.u.msg(you, "The lock's pins align in your mind's eye and the door falls open.",
      MsgType.good, nil)
  end

  local function see_mechanisms_pick(you)
    if not mod.u.is_avatar(you) then return end -- UI prompt: player-only
    local map = gapi.get_map()
    local target = gapi.choose_adjacent_highlight(
      "See which lock?",
      "There is no mechanical lock within your reach.",
      function(p) return is_door_target(map, p) ~= nil or is_safe_target(map, p) ~= nil end,
      false)
    if not target then return end
    if is_safe_target(map, target) then
      crack_safe(you, map, target)
    else
      start_lockpick(you, map, target)
    end
  end

  mod.effect_added_handlers["mom_cast_clair_see_mechanisms"] = function(you, _eff)
    local ok, err = pcall(see_mechanisms_pick, you)
    if not ok then gdebug.log_error("MoM-BN: see_mechanisms: " .. tostring(err)) end
    consume_marker(you, "mom_cast_clair_see_mechanisms")
    return true
  end

  -- Acquisition: a Clairsentient who has developed Heightened Senses (level 3+)
  -- -- already reading the world past its surface -- intuits how to turn that
  -- sight on locks.  Slow cadence, pcall-guarded, kept out of the transpiled RNG
  -- learning pool on purpose (same as No Go Zone / Circuit Sense).
  mod.recurring["MOM_SEE_MECHANISMS_LEARN"] = {
    min_turns = 8000, max_turns = 18000,
    fn = function(you)
      pcall(function()
        if not you then return end
        local km = you:get_magic()
        if you:has_trait(MutationBranchId.new("CLAIRSENTIENT"))
           and mod.math.spell_level(you, "clair_better_senses") >= 3
           and not km:knows_spell(SpellTypeId.new("clair_see_mechanisms")) then
          mod.u.set_spell_level(you, "clair_see_mechanisms", 1)
          mod.u.msg(you, "You turn your heightened senses inward on the world's "
            .. "locks and feel their hidden mechanisms lay themselves bare -- "
            .. "pins, wards, and tumblers, all plain to your inner eye.  "
            .. "(Learned See Mechanisms.)", MsgType.good, nil)
        end
      end)
    end,
  }

  -- Maintained-power manifest from the transpiler: every upstream EOC that
  -- runs EOC_POWER_MAINTENANCE_PLUS_ONE, mapped to the effect it sustains and
  -- how much concentration it costs.  Before this existed only the three
  -- hand-registered pilots counted, so mom_math.maintained_count read ~0 for
  -- a character holding a full stack of powers and every concentration
  -- consequence was skipped.  Registration is idempotent -- mom_eoc registers
  -- the pilots and the fork-original powers separately.
  for id, weight in pairs(mod.gen_maintenance or {}) do
    mod.math.register_maintenance(id, weight)
  end

  -- Recurring EOCs from the transpiler (upstream "recurrence"): randomized
  -- cadence handled by the on_every_x drainer above.
  --
  -- Cadence overrides (perf fix 2026-08-14) for upstream recurrence-1 EOCs
  -- whose effect is a status the player can't perceive at 1-second resolution.
  -- DDA runs these through its C++ EOC scheduler where a per-second no-op is
  -- cheap; here each firing is a Lua dispatch plus its full condition chain:
  --   * CONCENTRATION_LIMIT_INSTANT_UPDATER only toggles the
  --     effect_psi_intense_concentration warning marker (the real gameplay
  --     check, EOC_PSIONICS_CHANNEL_MAINTENANCE_CHECK, fires per cast, not
  --     here).  Its chain cost ~10 has_trait + three maintained_count walks +
  --     the ~35-term concentration_trait_bonuses formula EVERY turn for any
  --     psion maintaining a power.  A 5-turn cadence makes the warning appear
  --     or clear at most 5 seconds late — imperceptible.
  --   * GRANT_GROUNDING_MEDITATION is a one-shot recipe grant (metaphysics 4+
  --     psions), but once its condition held it called learn_recipe() every
  --     single turn forever.  Not deactivated outright (mod.recurring is
  --     per-VM: a new character in the same session must still be able to
  --     earn it) — a 10-minute cadence keeps the grant while removing the
  --     per-turn cost.
  local RECURRING_CADENCE = {
    EOC_CONCENTRATION_LIMIT_INSTANT_UPDATER = { min_turns = 5, max_turns = 5 },
    EOC_MOM_GRANT_GROUNDING_MEDITATION_TO_PSIONS = { min_turns = 500, max_turns = 700 },
  }
  for _, r in ipairs(mod.gen_recurring or {}) do
    if mod.eoc[r.id] then
      local o = RECURRING_CADENCE[r.id]
      mod.recurring[r.id] = {
        fn = function(you) return mod.eoc[r.id](you, nil, {}) end,
        min_turns = o and o.min_turns or r.min_turns,
        max_turns = o and o.max_turns or r.max_turns,
      }
    end
  end

  -- === Auto-learn: replace the DDA power-acquisition grind (2026-07-16) ======
  -- Upstream learns each power through three stacked timers (a 12h-7day "ready"
  -- counter, a per-power 12h-7day checker gated on a 1-in-20/40/80 roll OR the
  -- prerequisite spell levels) and then only hands you a `practice_<power>`
  -- RECIPE you still have to craft.  Design call: collapse it.  Auto-learn
  -- grants the spell DIRECTLY once you hold the school trait and have hit the
  -- prerequisite spell levels in the earlier powers, on a cadence scaled by
  -- Intelligence + Metaphysics.  No dice, no recipe stage, no crystal hunt --
  -- crystal AWAKENING (becoming a psion) is untouched.  Data (target, traits,
  -- prereqs, verbatim insight message) is harvested by tools/gen_learn_map.py;
  -- the three fork-original powers (No Go Zone / Circuit Sense / See Mechanisms)
  -- keep their own hand-authored learners above.

  -- Strip the old two-stage insight->practice-recipe machinery.  Matching
  -- "_LEARNING_" removes every per-school EOC_*_LEARNING_* checker AND
  -- EOC_PSI_LEARNING_VITAMIN_COUNTER; none of the recurring EOCs we keep (the
  -- attunement adjuster, portal/psyshield/telelixir ticks, ...) contain that
  -- token, and the fork learners above are "_LEARN" (no trailing "ING_").
  for id in pairs(mod.recurring) do
    if tostring(id):find("_LEARNING_", 1, true) then
      mod.recurring[id] = nil
    end
  end

  -- Dead recurring EOCs (perf fix 2026-08-09): upstream's crafting-proficiency
  -- auto-grant EOCs (min_turns=max_turns=1, so every tick for every character)
  -- had their body's actual write dropped during Phase 4 porting (BN has no
  -- proficiency system) but kept a real has_trait/has_any_trait/nested-EOC
  -- condition check upstream of that now-empty write.  They've been pure-cost
  -- no-ops ever since; strip the scheduler entries so the condition never runs.
  local DEAD_RECURRING = {
    EOC_MOM_GAME_ONGOING_GRANT_BIOKINETIC_CRAFTING_PROFICIENCY = true,
    EOC_MOM_GAME_ONGOING_GRANT_CRAFTING_PROFICIENICES = true,
    EOC_MOM_GAME_ONGOING_GRANT_PYROKINETIC_CRAFTING_PROFICIENCY = true,
    EOC_MOM_GAME_ONGOING_GRANT_TELEPORTATION_CRAFTING_PROFICIENCY = true,
    EOC_MOM_GAME_ONGOING_GRANT_VITAKINETIC_CRAFTING_PROFICIENCY = true,
    -- Portal-storm awakening pollers (perf fix 2026-08-14): BN has NO portal
    -- storms (see BN CONTENT GAPS in HANDOFF.md), so each condition's
    -- U.is_weather('[close_/distant_]portal_storm') can never be true — those
    -- weather ids never occur in BN, so mod.current_weather never matches.
    -- They were still paying a U.is_outside() map call every 1-10 minutes
    -- forever.  The rest of the dead awakening cluster (gen_jmath fns, the
    -- reducer/countup EOCs) stays in place per HANDOFF — nothing triggers it;
    -- these three were the only entries with a live scheduler registration.
    EOC_PORTAL_STORM_PSION_AWAKENING_CLOSE = true,
    EOC_PORTAL_STORM_PSION_AWAKENING_MEDIUM = true,
    EOC_PORTAL_STORM_PSION_AWAKENING_DISTANT = true,
  }
  for id in pairs(DEAD_RECURRING) do mod.recurring[id] = nil end

  local AUTOLEARN_POLL = 1000  -- nominal turns between polls (~17 game-minutes)

  -- Turns until the next power, once its prerequisites are met.  Linear in a
  -- "power score" P = (Int-8) + 1.5*Metaphysics: ~2 game-days at P=0 (Int 8,
  -- no Metaphysics) down to a 1-hour floor for a strong specialist (~2h around
  -- Int 12 / Metaphysics 8), matching the No Go Zone cadence.
  local function autolearn_interval(you)
    local P = math.max(mod.math.int(you) - 8, 0)
              + 1.5 * math.max(mod.math.skill(you, "metaphysics"), 0)
    local iv = 172800 - 10350 * P
    if iv < 3600 then iv = 3600 end
    if iv > 172800 then iv = 172800 end
    return iv
  end

  local function prereqs_met(you, e)
    if #e.prereqs == 0 then return true end          -- time-only power
    for _, set in ipairs(e.prereqs) do               -- OR of prerequisite sets
      local ok = true
      for _, p in ipairs(set) do                     -- AND within a set
        if mod.math.spell_level(you, p[1]) < p[2] then ok = false break end
      end
      if ok then return true end
    end
    return false
  end

  local function autolearn_eligible(you, e)
    local has = false
    for _, t in ipairs(e.traits) do
      if you:has_trait(MutationBranchId.new(t)) then has = true break end
    end
    if not has then return false end
    if you:get_magic():knows_spell(SpellTypeId.new(e.target)) then return false end
    return prereqs_met(you, e)
  end

  local function autolearn_grant(you, e)
    mod.u.set_spell_level(you, e.target, 1)
    if e.also then
      for _, s in ipairs(e.also) do mod.u.set_spell_level(you, s, 1) end
    end
    local nm = (mod.spell_names and mod.spell_names[e.target]) or e.target
    mod.u.msg(you, e.msg .. "  (Learned: " .. nm .. ".)", MsgType.good, nil)
  end

  mod.recurring["MOM_AUTOLEARN"] = {
    min_turns = 800, max_turns = 1200,
    fn = function(you)
      pcall(function()
        if not you then return end
        local map = mod.gen_learn_map
        if not map then return end
        local elig = {}
        for _, e in ipairs(map) do
          if autolearn_eligible(you, e) then elig[#elig + 1] = e end
        end
        if #elig == 0 then return end
        -- Memoryless timer: P(grant this poll) = poll / interval, so the mean
        -- wait once eligible is ~interval turns and responds to current stats.
        if gapi.rng(1, autolearn_interval(you)) <= AUTOLEARN_POLL then
          autolearn_grant(you, elig[gapi.rng(1, #elig)])
        end
      end)
    end,
  }

  -- === Nether Attunement: sustained pressure (2026-07-16) ===================
  -- Upstream only rolls the attunement consequences on spellcasting_finish, so
  -- a maxed-out psion who stops casting (idling while flying or invisible)
  -- feels nothing.  Run the same consequence dispatcher on a timer whenever
  -- attunement is high, so the downside bites the ENTIRE time you carry it.
  -- The dispatcher self-gates (>= 15) and picks one weighted consequence, each
  -- of which self-scales with attunement, so low-attunement psions are barely
  -- touched and the maxed ones pay for it continuously.
  mod.recurring["MOM_ATTUNEMENT_PRESSURE"] = {
    min_turns = 180, max_turns = 420,   -- ~5 game-minutes on average
    fn = function(you)
      pcall(function()
        if not you then return end
        if mod.math.attunement(you) < 15 then return end
        local fn = mod.eoc["EOC_PSIONICS_NETHER_ATTUNEMENT_CONSEQUENCES"]
        if fn then fn(you, nil, {}) end
      end)
    end,
  }

  -- Token recipes (Phase: recipes).  BN's recipe loader has no `result_eocs`
  -- (BN has no native EOC system), but it fires an on_craft_result Lua hook
  -- on completion.  gen_recipe_eoc carries three ident-keyed tables:
  --   eoc      -> the study/learning/unlock EOC that was the DDA result_eoc
  --               (already transpiled into mod.eoc); run with the crafter as
  --               both target and caster (self-study).
  --   practice -> DDA type:practice grinder grant: BN-native
  --               Character:practice(skill, amount, cap); cap = upstream
  --               skill_limit - 1 (practice() blocks at level > cap, so
  --               limit-1 trains TO the limit and no further — same as
  --               DDA recipe::get_skill_cap()).  Granted in 20 chunks:
  --               SkillLevel::train() zeroes exercise on level-up, so one
  --               lump would waste the overshoot (or, oversized, jump a
  --               whole level per cycle).  SET_FX drops C++ default args,
  --               so all four practice() args are mandatory.
  --   sweep    -> the weightless token item the recipe "crafts"; it only
  --               lands in inventory AFTER this hook returns, hence the
  --               next-turn queue rather than an inline remove.
  mod.recipe_eoc = require("lua/gen_recipe_eoc")

  local function sweep_token(you, token)
    if not you then return end
    local rm = {}
    -- all_items(false), NOT get_items(): get_items is a monster-only binding.
    for _, it in ipairs(you:all_items(false)) do
      if it:get_type():str() == token then rm[#rm + 1] = it end
    end
    for _, it in ipairs(rm) do you:remove_item(it) end
  end

  -- Concentration practice recipes -> proficiency-trait training. BN can't
  -- train proficiencies, so completing one of these feeds U.train_proficiency
  -- (grants the visible trait at 100%). pct-per-completion sets the crafting
  -- cost at 1 h/craft: basic 6 h -> 100/6, intermediate 8 h -> 100/8 (fork
  -- retune, down from upstream's steeper 16 h / 32 h). Intermediate gates on
  -- basic like the source recipe's prof requirement. Master has no practice
  -- recipe upstream -- power use only.
  local CONCENTRATION_RECIPES = {
    prac_concentration_basic = {
      trait = "PROF_CONCENTRATION_BASIC", pct = 100 / 6 },
    prac_concentration_intermediate = {
      trait = "PROF_CONCENTRATION_INTERMEDIATE", pct = 100 / 8,
      requires = "PROF_CONCENTRATION_BASIC" },
  }

  function mod.on_craft_result(params)
    local ok, err = pcall(function()
      -- BN never shows recipe.description in the crafting menu -- the info
      -- pane calls item::info() on the *result item*, which reads
      -- type->description (falling back from an item_vars_['description']
      -- override, checked first).  Every token recipe (practice/prac/psi)
      -- shares one result item id, so without this they'd all show the same
      -- generic token flavor text regardless of which power is selected.
      -- Runs on BOTH the preview dummy (menu browsing) and the real craft
      -- item -- unlike the XP/EOC/sweep logic below, decorating a preview is
      -- exactly the point here, so this runs BEFORE the params.craft guard.
      local rec = params and params.recipe
      local disp_item = params and params.item
      if rec and disp_item then
        local desc = mod.recipe_eoc.desc[rec:ident():str()]
        if desc then
          disp_item:set_var_str("description",
            mod.u.interp(params.crafter or gapi.get_avatar(), nil, desc))
        end
      end
      -- The crafting GUI ALSO fires this hook to decorate preview items
      -- (crafting_gui.cpp apply_craft_result_hooks: info pane + COMPARE).
      -- Only the real completion site (crafting.cpp complete_craft) passes
      -- the in-progress craft item — without this guard, merely browsing
      -- the menu grants XP / runs study EOCs / queues sweeps.
      if not (params and params.craft) then return end
      if not rec then return end
      local ident = rec:ident():str()
      local you = params.crafter or gapi.get_avatar()
      if not you then return end
      local eoc_id = mod.recipe_eoc.eoc[ident]
      if eoc_id then
        local fn = mod.eoc[eoc_id]
        if fn then
          fn(you, you, {})                   -- DDA you=target, npc=caster; self
        else
          gdebug.log_info("MoM-BN: recipe " .. eoc_id .. " not in mod.eoc")
        end
      end
      local prac = mod.recipe_eoc.practice[ident]
      if prac then
        local skill = SkillId.new(prac.skill)
        local chunk = math.max(1, math.floor(prac.amount / 20))
        for _ = 1, 20 do
          you:practice(skill, chunk, prac.cap, true)
        end
      end
      -- The ordering gate + progress/gate messaging now lives in
      -- train_proficiency (announce=true = deliberate practice craft, so it
      -- talks; the per-turn power-use trickle passes 3 args and stays silent).
      local ct = CONCENTRATION_RECIPES[ident]
      if ct then
        mod.u.train_proficiency(you, ct.trait, ct.pct, ct.requires, true)
      end
      local token = mod.recipe_eoc.sweep[ident]
      if token then
        util.queue_eoc(function(w) sweep_token(w, token) end, you, 1)
      end
    end)
    if not ok then
      gdebug.log_error("MoM-BN: on_craft_result: " .. tostring(err))
    end
  end

  -- EOC-activated items (2026-07-10, playtest round 2: matrix crystals were
  -- inert).  DDA use_action type effect_on_conditions -> BN Lua iuse actor
  -- "MOM_EOC_ITEM" (registered in preload.lua); per-item spec generated by
  -- port_items.py.  Contract (catalua_icallback_actor.cpp): params = {user,
  -- item, pos}, return = charges consumed.  We always return 0 and handle
  -- `consume` ourselves NEXT TURN: the C++ caller still holds the item
  -- reference when this returns (inline removal = use-after-free risk), and
  -- remove_item() rejects wielded items, so unwield first.  Consumption is
  -- by type id, first match only (don't eat spare crystals).
  mod.iuse_eoc = require("lua/gen_iuse_map")

  -- Remove ONE item of the given type: prefer a non-wielded copy (safe for
  -- remove_item); a wielded copy needs unwield() first, but unwield can be
  -- REFUSED (e.g. the post-awakening meditation activity) or can DROP the
  -- item to the ground (pack full) — so re-locate after unwielding, check
  -- the floor, and if the item is still stuck in hand retry next turn
  -- (bounded).  Round-2 playtest: blind unwield-then-remove hit
  -- "Tried to remove a item not in inventory" (inventory.cpp:669).
  local function consume_one(you, tid, tries)
    if not you then return end
    local wielded = nil
    for _, it in ipairs(you:all_items(false)) do
      if it:get_type():str() == tid then
        if you:is_wielding(it) then
          wielded = it
        else
          you:remove_item(it)
          return
        end
      end
    end
    if wielded then
      you:unwield()
      -- find where it ended up: inventory (stowed) or the floor (dropped)
      for _, it in ipairs(you:all_items(false)) do
        if it:get_type():str() == tid and not you:is_wielding(it) then
          you:remove_item(it)
          return
        end
      end
      local map = gapi.get_map()
      local pos = you:get_pos_ms()
      for _, it in ipairs(map:get_items_at(pos):items()) do
        if it:get_type():str() == tid then
          map:detach_item_at(pos, it)   -- Lua drops the ref -> item destroyed
          return
        end
      end
      -- unwield refused (busy) — try again next turn, give up after ~30
      tries = (tries or 0) + 1
      if tries < 30 then
        util.queue_eoc(function(w) consume_one(w, tid, tries) end, you, 1)
      else
        gdebug.log_info("MoM-BN: consume_one gave up on " .. tid)
      end
    end
  end

  function mod.iuse_eoc_item(params)
    local ok, err = pcall(function()
      local you = params and params.user
      local it = params and params.item
      if not (you and it) then return end
      local tid = it:get_type():str()
      local entry = mod.iuse_eoc[tid]
      if not entry then
        -- copy-from children can inherit the use_action without a map entry
        gdebug.log_info("MoM-BN: no iuse entry for " .. tid)
        return
      end
      if entry.need_wielding and not you:is_wielding(it) then
        gapi.add_msg("You need to be holding it to do that.")
        return
      end
      for _, id in ipairs(entry.eocs) do
        local fn = mod.eoc[id]
        if fn then
          fn(you, you, {})
        else
          gdebug.log_info("MoM-BN: iuse EOC " .. id .. " not in mod.eoc")
        end
      end
      if entry.consume then
        util.queue_eoc(function(w) consume_one(w, tid, 0) end, you, 1)
      end
    end)
    if not ok then
      gdebug.log_error("MoM-BN: iuse_eoc_item: " .. tostring(err))
    end
    return 0
  end

  -- Electrokinetic "hacking interface" (fork Lua bridge, 2026-07-13).  BN's
  -- native hacking is hardcoded to itype_electrohack + 25 battery charges
  -- (iexamine.cpp / hacking_activity_actor) and DDA's HACK tool_quality doesn't
  -- exist here, so a psionic construct can't trip any of it.  We reimplement the
  -- two useful outcomes — card readers (unlock nearby metal doors) and gun safes
  -- (spring the lock) — in Lua, rolled against the power's own mastery instead
  -- of Computer skill.  (Gas-pump fuel theft is deliberately not reproduced.)
  -- Activated off the worn interface item; registered as iuse "MOM_HACK" in
  -- preload.lua and wired onto the electrohack items by port_items.py.
  local mmath = require("lua/mom_math")
  local hack_ids
  local function get_hack_ids()
    if hack_ids then return hack_ids end
    hack_ids = {
      readers = {
        TerId.new("t_card_science"):int_id(),
        TerId.new("t_card_military"):int_id(),
        TerId.new("t_card_industrial"):int_id(),
      },
      reader_broken = TerId.new("t_card_reader_broken"):int_id(),
      door_locked   = TerId.new("t_door_metal_locked"):int_id(),
      door_closed   = TerId.new("t_door_metal_c"):int_id(),
      gunsafe       = FurnId.new("f_gun_safe_el"):int_id(),
      gunsafe_open  = FurnId.new("f_gunsafe_o"):int_id(),
    }
    return hack_ids
  end

  local function is_reader(ids, tid)
    for _, r in ipairs(ids.readers) do
      if tid == r then return true end
    end
    return false
  end

  -- Unlock every locked metal door within radius 3 of the reader, mirroring
  -- iexamine::cardreader / hacking_activity_actor's HACK_DOOR success.
  local function unlock_doors(map, center, ids)
    local n = 0
    for dx = -3, 3 do
      for dy = -3, 3 do
        local p = TripointBubMs.new(center.x + dx, center.y + dy, center.z)
        if map:get_ter_at(p) == ids.door_locked then
          map:set_ter_at(p, ids.door_closed)
          n = n + 1
        end
      end
    end
    return n
  end

  function mod.iuse_hack(params)
    local ok, err = pcall(function()
      local you = params and params.user
      if not you then return end
      local ids = get_hack_ids()
      local map = gapi.get_map()
      local origin = you:get_pos_ms()

      -- find an adjacent hackable: card reader (terrain) or gun safe (furniture)
      local target, kind
      for dx = -1, 1 do
        for dy = -1, 1 do
          if not target then
            local p = TripointBubMs.new(origin.x + dx, origin.y + dy, origin.z)
            if is_reader(ids, map:get_ter_at(p)) then
              target, kind = p, "door"
            elseif map:get_furn_at(p) == ids.gunsafe then
              target, kind = p, "safe"
            end
          end
        end
      end
      if not target then
        gapi.add_msg(MsgType.info,
          "There's nothing here your hacking interface can reach.")
        return
      end

      -- Roll vs the power's combined mastery (not Computer skill), keeping BN's
      -- INT contribution; two rng draws give a rough normal-ish spread.
      local mastery =
        math.max(mmath.spell_level(you, "electrokinetic_hacking_interface"), 0) +
        math.max(mmath.spell_level(you, "electrokinetic_hacking_interface_knack"), 0)
      local skill = mastery + math.floor((you:get_int() - 8) / 4)
      local roll = skill + gapi.rng(-3, 3) + gapi.rng(-3, 3)
      you:mod_moves(-100)   -- a focused moment (channeling time is the spell's own)

      if roll < 0 then
        gapi.add_msg(MsgType.bad,
          "Your surge misfires — a short circuit, and an alarm blares!")
        pcall(function() gapi.play_variant_sound("environment", "alarm", 100) end)
        return
      elseif roll < 6 then
        gapi.add_msg(MsgType.warning,
          "You probe the circuits but can't crack them — no alarm, at least.")
        return
      end

      if kind == "safe" then
        map:set_furn_at(target, ids.gunsafe_open)
        gapi.add_msg(MsgType.good,
          "The safe's lock yields to your will and swings open.")
      else
        map:set_ter_at(target, ids.reader_broken)
        local n = unlock_doors(map, target, ids)
        if n > 0 then
          gapi.add_msg(MsgType.good,
            "The panel sparks dead and the nearby doors unlock.")
        else
          gapi.add_msg(MsgType.good,
            "The panel sparks dead — but there are no locked doors nearby.")
        end
      end
    end)
    if not ok then
      gdebug.log_error("MoM-BN: iuse_hack: " .. tostring(err))
    end
    return 0
  end

  -- Event-EOC dispatch (2026-07-09).  Upstream `eoc_type: EVENT` EOCs (keyed
  -- by `required_event`) are all transpiled into mod.eoc; the transpiler
  -- collects their ids into mod.gen_events.  Wired: game_start + game_begin
  -- (below — this makes the SECRET contemplation recipes reachable, their
  -- per-path teachers being game_begin EOCs) and, per cast, spellcasting_finish
  -- + opens_spellbook (2026-07-14, the Nether Attunement / power-cost /
  -- metaphysics-XP event class — see fire_spell_cast_events and the cast-map
  -- loop above, which detect casts via caster-side markers since BN fires no
  -- spell event).  Remaining events (avatar_moves, …) stay dormant until their
  -- dispatch lands (spec §12).
  -- DDA event semantics here: u = the avatar, no beta talker.  Each EOC
  -- carries its own trait/spell-level conditions, so dispatch is
  -- unconditional and pcall-guarded per EOC.
  local MOD_ID = game.current_mod   -- only valid at load time; capture now
  -- (fire_event_eocs is defined earlier, ahead of the cast-map loop.)

  -- game_start EOCs are NOT idempotent (u_awakening_countup += 1, the
  -- power-learning timer globals), so they fire exactly once per character,
  -- guarded by a persisted character var.  Checking the guard on load too
  -- retro-initializes characters created before this dispatch existed.
  local function fire_game_start_once(you)
    if V.uget(you, "gamestart_events_fired") == 1 then return end
    V.uset(you, "gamestart_events_fired", 1)
    fire_event_eocs("game_start", you)
    -- Heart of Fire challenge scenario: BN's scenario loader has no "eoc"
    -- field at all (scenario.cpp's mandatory/optional list), so the
    -- upstream scenario-select payload (bonus knack levels, recipe unlock,
    -- awakening countup) is bridged here instead, gated on the scenario's
    -- own SCEN_HEART_OF_FIRE marker (forced_traits) -- reuses this same
    -- once-only guard, so u_awakening_countup += 50 can't double-apply on a
    -- later save/load.
    if you:has_trait(MutationBranchId.new("SCEN_HEART_OF_FIRE")) then
      local fn = mod.eoc["EOC_MOM_SCEN_HEART_OF_FIRE_INITIATE"]
      if fn then
        local ok, err = pcall(fn, you, nil, {})
        if not ok then
          gdebug.log_error("MoM-BN: scenario eoc EOC_MOM_SCEN_HEART_OF_FIRE_INITIATE: " ..
                           tostring(err))
        end
      end
    end
  end

  -- ==========================================================================
  -- Mind Sonar  (fork replacement for DDA "Sense Minds")
  -- --------------------------------------------------------------------------
  -- DDA's telepathic_mind_sense revealed minded creatures on the map (the "?"
  -- glyph) through an `enchantments: special_vision` block.  BN's engine has NO
  -- special_vision and NO data-driven creature-detection hook at all
  -- (Character::sees_with_specials is hardcoded to a fixed trait/bionic list),
  -- so a 1:1 port is impossible.  Fork adaptation (user decision 2026-07-20):
  -- reframe the power as a periodic "sonar" that sweeps for nearby SAPIENT
  -- minds and reports each by compass direction + distance band in the message
  -- log.  It can't paint them on the map, but it tells you they're there and
  -- roughly where -- and a level-scaled sweep RANGE (vs DDA's short continuous
  -- vision) makes it real recon.  Full census on every pulse, log only.
  --
  -- "A mind" in BN == an NPC (is_npc) or a monster flagged HUMAN.  BN has NO
  -- MF_HAS_MIND flag (DDA-only), so bestial/alien minds have nothing to key on;
  -- v1 senses sapient (human) minds only.  Telepathy-immune targets
  -- (eff_monster_immune_to_telepathy) are skipped.
  --
  -- Driven off effect_telepath_sense_minds (EFFECT_LUA_ON_ADDED/REMOVED, set by
  -- port_effects.apply_fork_overrides): add -> immediate census + install the
  -- recurring pulse; remove -> tear it down.  Cadence tightens as the power
  -- levels.  mod.recurring is runtime-only, so on_game_load reconciles the pulse
  -- after a reload (like re-casting would).
  local SONAR_EFF   = "effect_telepath_sense_minds"
  local SONAR_SPELL = "telepathic_mind_sense"
  local SONAR_KNACK = "telepathic_mind_sense_knack"
  local SONAR_HUMAN_FLAG = (MonsterFlag and MonsterFlag.HUMAN) or nil

  local function sonar_level(you)
    -- DDA summed the power's level and its knack level; clamp each to >= 0.
    local a = mod.math.spell_level(you, SONAR_SPELL)
    local b = mod.math.spell_level(you, SONAR_KNACK)
    return math.max(0, a) + math.max(0, b)
  end

  local function sonar_range(lvl)
    -- Generous, level-scaled sweep radius: ~11 tiles fresh, up to the reality
    -- bubble edge at mastery (vs DDA's stingy level*2 continuous vision).
    return math.max(8, math.min(60, U.round(8 + lvl * 3)))
  end

  local function sonar_period(lvl)
    -- Refresh cadence tightens with mastery: ~28 turns fresh -> ~8 at high level.
    return math.max(8, math.min(28, U.round(28 - lvl * 1.4)))
  end

  local function sonar_compass(dx, dy)
    if dx == 0 and dy == 0 then return "right here" end
    local ax, ay = math.abs(dx), math.abs(dy)
    local ns = (dy < 0) and "north" or "south"
    local ew = (dx > 0) and "east" or "west"
    if ax > ay * 2 then return ew end
    if ay > ax * 2 then return ns end
    return ns .. ew
  end

  -- band: 1 = adjacent, 2 = close, 3 = nearby, 4 = distant
  local SONAR_BANDWORD = { [2] = "close by", [3] = "nearby", [4] = "far off" }
  local function sonar_band(d)
    if d <= 1 then return 1 elseif d <= 5 then return 2
    elseif d <= 12 then return 3 else return 4 end
  end

  local function sonar_is_mind(cr, you)
    if not cr then return false end
    local ok, res = pcall(function()
      if cr:is_avatar() then return false end
      if cr:is_hallucination() then return false end
      if cr:is_dead() then return false end
      if cr:has_effect(EffectTypeId.new("eff_monster_immune_to_telepathy")) then
        return false
      end
      if cr:is_npc() then return true end
      if cr:is_monster() and SONAR_HUMAN_FLAG ~= nil then
        return cr:has_flag(SONAR_HUMAN_FLAG)
      end
      return false
    end)
    return ok and res == true
  end

  local function sonar_census(you)
    you = you or gapi.get_avatar()
    if not you then return end
    pcall(function()
      local origin = you:get_pos_ms()
      local lvl = sonar_level(you)
      local R = sonar_range(lvl)
      local groups, order = {}, {}
      for _, cr in ipairs(gapi.get_all_creatures()) do
        if sonar_is_mind(cr, you) then
          local p = cr:get_pos_ms()
          local d = U.dist(origin, p)
          if d <= R then
            local dir = sonar_compass(p.x - origin.x, p.y - origin.y)
            if p.z < origin.z then dir = dir .. " and below"
            elseif p.z > origin.z then dir = dir .. " and above" end
            local bnd = sonar_band(d)
            local key = dir .. "|" .. bnd
            local g = groups[key]
            if not g then
              g = { count = 0, hostile = 0, dir = dir, band = bnd,
                    name = nil, named = 0 }
              groups[key] = g
              order[#order + 1] = { key = key, d = d }
            end
            g.count = g.count + 1
            local hostile = false
            pcall(function()
              hostile = (cr:attitude_to(you) == Attitude.Hostile)
            end)
            if hostile then g.hostile = g.hostile + 1 end
            if lvl >= 4 then  -- progressive detail: name lone NPCs at mastery
              pcall(function()
                if cr:is_npc() then g.name = cr:get_name(); g.named = g.named + 1 end
              end)
            end
          end
        end
      end
      if #order == 0 then
        gapi.add_msg(MsgType.info,
          "You cast your mind outward, but sense no other minds nearby.")
        return
      end
      table.sort(order, function(a, b) return a.d < b.d end)
      for _, e in ipairs(order) do
        local g = groups[e.key]
        local who
        if g.count == 1 and g.name and g.named == 1 then
          who = g.name .. "'s mind"
        elseif g.count == 1 then
          who = "a mind"
        else
          who = tostring(g.count) .. " minds"
        end
        local where
        if g.dir == "right here" then
          where = " right beside you"
        elseif g.band == 1 then
          where = " right beside you, to the " .. g.dir
        else
          where = " to the " .. g.dir .. ", " .. (SONAR_BANDWORD[g.band] or "nearby")
        end
        local qualifier = ""
        if g.hostile > 0 then
          if g.count == 1 then qualifier = " (hostile)"
          elseif g.hostile == g.count then qualifier = " (all hostile)"
          else qualifier = " (" .. g.hostile .. " hostile)" end
        end
        gapi.add_msg(g.hostile > 0 and MsgType.warning or MsgType.info,
          "You sense " .. who .. where .. qualifier .. ".")
      end
    end)
  end

  local function sonar_start(you)
    you = you or gapi.get_avatar()
    if not you then return end
    sonar_census(you)  -- immediate census on activation / reload
    local p = sonar_period(sonar_level(you))
    mod.recurring["mind_sonar"] = {
      fn = function(y)
        sonar_census(y)
        local np = sonar_period(sonar_level(y))
        local r = mod.recurring["mind_sonar"]
        if r then r.min_turns = np; r.max_turns = np + 6 end
      end,
      min_turns = p,
      max_turns = p + 6,
      next_turn = nil,
      deactivate = function(y)
        local ok, has = pcall(function()
          return y:has_effect(EffectTypeId.new(SONAR_EFF))
        end)
        return not (ok and has)
      end,
    }
  end

  local function sonar_reconcile(you)
    -- After a reload, mod.recurring is empty but the PERMANENT effect persists;
    -- restart the pulse so the sonar keeps working without a re-cast.
    if mod.recurring["mind_sonar"] then return end
    if not you then return end
    local ok, has = pcall(function()
      return you:has_effect(EffectTypeId.new(SONAR_EFF))
    end)
    if ok and has then pcall(sonar_start, you) end
  end

  mod.effect_added_handlers[SONAR_EFF] = function(who)
    pcall(sonar_start, who or gapi.get_avatar())
  end
  mod.effect_removed_handlers[SONAR_EFF] = function(_who)
    mod.recurring["mind_sonar"] = nil
  end

  -- Restart re-arm for maintained-power XP loops.  A channeled power's spell XP
  -- comes from a DRAIN loop that self-requeues through util.queue -- an IN-MEMORY
  -- table (mom_util).  main.lua runs once per PROCESS, so a full game restart
  -- (quit-to-desktop + relaunch) boots a fresh Lua VM with an empty queue: the
  -- PERMANENT effect + carrier survive (saved), but the XP loop is gone and the
  -- power never levels again until re-cast.  (In-session save/reload keeps the
  -- VM, so the queue and its live loops persist -- re-arming THEN would DOUBLE
  -- them.)  So re-arm exactly once per process boot, on the first game-entry:
  -- `drains_armed` is a per-VM upvalue (this factory runs once per VM).  A fresh
  -- character (on_game_started) has no active powers yet -> no-op; a loaded save
  -- restarts every active power's loop.
  --   Generated loops: mod.eoc keys ending `_DRAIN`, gated by their side-effect-
  --   free condition in mod.eoc_conds (has_effect / has_item / ctx).  Three
  --   one-shot `_DRAIN`s are NOT self-requeue loops (return-true, real side
  --   effects) -> excluded.  Hand pilots register in mod.rearm_drains (mom_eoc).
  local REARM_EXCLUDE = {
    EOC_EATER_DRAIN = true,
    EOC_FOOD_PHOTOKIN_DRAIN = true,
    EOC_VITA_SUPER_HEAL_DRAIN = true,
  }
  local drains_armed = false
  local function cold_boot_rearm(you)
    if drains_armed then return end
    drains_armed = true
    if not you then return end
    local conds = mod.eoc_conds or {}
    for name, mfn in pairs(mod.eoc) do
      if name:sub(-6) == "_DRAIN" and not REARM_EXCLUDE[name] then
        local cfn = conds[name]
        local active = false
        if cfn then
          local ok, r = pcall(cfn, you, nil, {})
          active = ok and r and true or false
        end
        if active then
          -- Kick with a short randomized delay: the drain body re-queues itself,
          -- so one kick restores the whole loop; the spread avoids ticking every
          -- restored power on the same turn.  npc = the avatar (== you for a
          -- self-power), matching the normal dispatch path (dispatch_eoc passes
          -- gapi.get_avatar()).  pcall-guarded: the queue drainer in on_every_x
          -- runs entries raw, so a post-load hiccup must not break the tick.
          util.queue_eoc(function(y) pcall(mfn, y, y, {}) end, you, gapi.rng(30, 120))
        end
      end
    end
    for _, d in ipairs(mod.rearm_drains or {}) do
      local ok, active = pcall(d.active, you)
      if ok and active then pcall(d.arm, you) end
    end
  end

  function mod.on_game_started()
    local you = gapi.get_avatar()
    if not you then return end
    pcall(function() mod.math.enforce_skill_caps(you) end)  -- Metaphysics <= 15
    cold_boot_rearm(you)  -- claim the per-VM re-arm slot (no-op for a new char)
    fire_game_start_once(you)
    fire_event_eocs("game_begin", you)
  end

  function mod.on_game_load()
    -- Rebind global-var storage FIRST: loading a save deserializes nested
    -- mod_storage tables into fresh tables (catalua_serde.cpp:274), so the
    -- `globals` reference mom_vars captured at data-load time goes stale —
    -- reads would miss every loaded value and writes would vanish on the
    -- next save.
    mod.vars.bind_storage(game.mod_storage[MOD_ID])
    local you = gapi.get_avatar()
    if not you then return end
    pcall(function() mod.math.enforce_skill_caps(you) end)  -- Metaphysics <= 15
    cold_boot_rearm(you)  -- restart maintained-power XP loops after a full restart
    fire_game_start_once(you)
    fire_event_eocs("game_begin", you)
    sonar_reconcile(you)  -- restart the Mind Sonar pulse if its effect survived
  end

  function mod.on_game_save() end
end
