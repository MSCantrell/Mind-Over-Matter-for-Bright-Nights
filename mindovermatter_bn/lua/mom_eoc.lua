-- mom_eoc: translated effect_on_condition functions.
-- Populated by tools/eoc_transpile.py output + hand-finished cases.
-- Naming: M.EOC_<UPSTREAM_ID>(you, npc, ctx) — same signature as the
-- generated EOCs in gen_eoc.lua (these hand versions override them); keep
-- upstream IDs literal so
-- run_eocs chains read the same as the JSON they came from.  mom_hooks
-- dispatches into this table when a cast-marker effect lands (looked up at
-- fire time, so transpiler output can extend it later).
-- Called from main.lua as require("lua/mom_eoc")(mod) so all modules share
-- one mod.math / mod.util instance.
return function(mod)
  local m = mod.math
  local util = mod.util
  local U = mod.u
  local M = {}

  -- ==========================================================================
  -- Phase 2 pilot: Physical Enhancement (maintained concentration power).
  -- Upstream chain (powers/biokinesis_concentration_eocs.json):
  --   INITIATE: toggle on -> message, effect PERMANENT, maintenance +1,
  --             schedule DRAIN; toggle off -> REMOVE.
  --   DRAIN:    attunement roll + spell XP + concentration check, reschedule.
  --   REMOVE:   lose effect, maintenance -1.
  -- Maintenance count is derived (mom_math.maintained_count), not stored.
  -- ==========================================================================

  local PHYS_EFFECT = "effect_biokin_physical"
  local PHYS_SPELL = "biokin_physical_enhance"

  m.register_maintenance(PHYS_EFFECT)

  -- Upstream drain cadence: rng(level*15+90, level*90+450) seconds.
  local function phys_drain_delay(lvl)
    lvl = math.max(lvl, 0)
    return gapi.rng(lvl * 15 + 90, lvl * 90 + 450)
  end

  local function phys_drain(you)
    local eid = EffectTypeId.new(PHYS_EFFECT)
    if not you:has_effect(eid) then return end  -- power ended; stop rescheduling
    util.channel_surge(you, 4, m)  -- fork: raised 2 -> 4, this super-buff costs more to hold
    -- TODO(phase3): psionic_power_experience_formula(); flat stand-in for now.
    m.gain_spell_exp(you, PHYS_SPELL, 50)
    -- TODO(phase4): calorie cost + concentration check
    -- (EOC_PSI_MAINTENANCE_CALORIE_COST_CALCULATOR, EOC_POWER_MAINTENANCE_CONCENTRATION_CHECK).
    util.queue_eoc(phys_drain, you, phys_drain_delay(m.spell_level(you, PHYS_SPELL)))
  end

  M.EOC_BIOKIN_PHYSICAL_ENHANCE_INITIATE = function(you, npc, ctx)
    local eid = EffectTypeId.new(PHYS_EFFECT)
    if you:has_effect(eid) then
      return M.EOC_BIOKIN_REMOVE_PHYSICAL_ENHANCE(you, npc, ctx)
    end
    gapi.add_msg(MsgType.good, "You suffuse your body with focused psionic energy.")
    local lvl = math.max(m.spell_level(you, PHYS_SPELL), 0)
    -- FORK 'Personal Enhancement': boost all four stats (STR/DEX/INT/PER) by an
    -- amount scaling with BOTH power level and Intelligence.  Target design
    -- anchors: +1 each at (level 1, INT 8) and +10 each at (level 15, INT 12) =>
    --   bonus = round((level + INT - 7) / 2), clamped to [1, 10].
    -- The effect JSON adds +1 to every stat per intensity step, so bonus ==
    -- intensity.  7-day duration stands in for PERMANENT until concentration
    -- checks land.
    local bonus = math.floor((lvl + m.int(you) - 7) / 2 + 0.5)
    local intensity = math.max(1, math.min(bonus, 10))
    you:add_effect(eid, TimeDuration.from_days(7), nil, intensity)
    util.queue_eoc(phys_drain, you, phys_drain_delay(lvl))
  end

  M.EOC_BIOKIN_REMOVE_PHYSICAL_ENHANCE = function(you, npc, ctx)
    local eid = EffectTypeId.new(PHYS_EFFECT)
    if you:has_effect(eid) then
      you:remove_effect(eid)  -- remove_message comes from the effect JSON
    end
  end

  -- ==========================================================================
  -- No Go Zone (C) -- ORIGINAL Bright Nights fork power (NOT in upstream MoM).
  -- A maintained telekinetic exclusion field.  Every turn, any non-allied
  -- monster standing in one of the 8 tiles adjacent to the caster is shoved
  -- one tile outward (range 1 -> range 2).  Enemies may loiter at range 2 and
  -- use reach/ranged attacks, but cannot hold a melee tile.  Contrast with the
  -- teleporter's Reactive Displacement, which only yanks an attacker away
  -- AFTER it lands a hit: this refuses adjacency outright and continuously.
  -- Structure mirrors the Physical Enhancement maintained-power pilot above
  -- (INITIATE toggles; a slow DRAIN accrues XP + reschedules; REMOVE ends it).
  -- The per-turn enforcement is EOC_TELEKIN_NOGOZONE_TICK, dispatched from
  -- mom_hooks' on_every_x (like the contemplation grind's per-turn tick).
  -- ==========================================================================
  local NOGO_EFFECT = "effect_telekinetic_nogozone"
  local NOGO_SPELL = "telekinetic_nogozone"
  m.register_maintenance(NOGO_EFFECT)

  -- Slow upkeep cadence (seconds), same shape as Reactive Displacement's drain.
  local function nogo_drain_delay(lvl)
    lvl = math.max(lvl, 0)
    return gapi.rng(lvl * 4 + 20, lvl * 4 + 200)
  end

  local function nogo_drain(you)
    if not you:has_effect(EffectTypeId.new(NOGO_EFFECT)) then return end  -- ended
    util.channel_surge(you, 3, m)          -- channeled-power difficulty = 3
    m.gain_spell_exp(you, NOGO_SPELL, 50)  -- maintaining it trains the power
    util.queue_eoc(nogo_drain, you, nogo_drain_delay(m.spell_level(you, NOGO_SPELL)))
  end

  -- Per-turn field enforcement: shove every adjacent non-ally out to range 2.
  -- friendly ~= 0 marks the player's own pets/allies (CDDA convention) -- never
  -- shove those.  U.shove is obstacle-aware: a monster backed against a wall
  -- simply isn't moved that turn (rare corner case, acceptable).
  M.EOC_TELEKIN_NOGOZONE_TICK = function(you, npc, ctx)
    if not you:has_effect(EffectTypeId.new(NOGO_EFFECT)) then return false end
    local origin = you:get_pos_ms()
    for _, mon in ipairs(gapi.get_all_monsters()) do
      if mon:get_hp() > 0 and mon.friendly == 0
         and U.dist(origin, mon:get_pos_ms()) == 1 then
        U.shove(mon, you, 1)               -- one step away: range 1 -> range 2
      end
    end
    return true
  end

  M.EOC_TELEKIN_NOGOZONE_INITIATE = function(you, npc, ctx)
    local eid = EffectTypeId.new(NOGO_EFFECT)
    if you:has_effect(eid) then            -- re-cast toggles the power off
      return M.EOC_TELEKIN_REMOVE_NOGOZONE(you, npc, ctx)
    end
    U.msg(you, "You raise a telekinetic cordon; nothing will crowd you now.",
          MsgType.good, ctx)
    you:add_effect(eid, TimeDuration.from_days(7), nil, 1)  -- PERMANENT stand-in
    util.queue_eoc(nogo_drain, you, nogo_drain_delay(m.spell_level(you, NOGO_SPELL)))
    M.EOC_TELEKIN_NOGOZONE_TICK(you, npc, ctx)  -- clear your space immediately
    return true
  end

  M.EOC_TELEKIN_REMOVE_NOGOZONE = function(you, npc, ctx)
    local eid = EffectTypeId.new(NOGO_EFFECT)
    if you:has_effect(eid) then
      you:remove_effect(eid)  -- remove_message comes from the effect JSON
    end
    return true
  end

  -- ==========================================================================
  -- [Ψ]Circuit Sense (C): ORIGINAL fork power (NOT upstream MoM).  A maintained
  -- Electrokinetic buff that raises effective Electronics skill by +3 while up
  -- (crafting, repair, any Electronics check) -- Electronics-only, no speed
  -- component (BN crafting speed is global-only; user chose the pure version
  -- 2026-07-13).  The +3 is carried by the hidden trait MOM_CIRCUIT_SENSE
  -- (mut_enchantments SKILL_LEVEL_ELECTRONICS); INITIATE grants it, and
  -- mom_hooks' effect-removed handler strips it whenever the buff ends by ANY
  -- means (re-cast toggle, concentration break, or expiry) so the +3 can never
  -- outlive the power.  No per-turn tick -- the enchantment is passive while the
  -- trait is held.
  -- ==========================================================================
  local CIRCUIT_EFFECT = "effect_electrokinetic_circuit_sense"
  local CIRCUIT_SPELL = "electrokinetic_circuit_sense"
  local CIRCUIT_TRAIT = "MOM_CIRCUIT_SENSE"
  m.register_maintenance(CIRCUIT_EFFECT)

  local function circuit_drain_delay(lvl)
    lvl = math.max(lvl, 0)
    return gapi.rng(lvl * 4 + 20, lvl * 4 + 200)
  end

  local function circuit_drain(you)
    if not you:has_effect(EffectTypeId.new(CIRCUIT_EFFECT)) then return end  -- ended
    util.channel_surge(you, 2, m)          -- channeled-power difficulty = 2
    m.gain_spell_exp(you, CIRCUIT_SPELL, 50)
    util.queue_eoc(circuit_drain, you, circuit_drain_delay(m.spell_level(you, CIRCUIT_SPELL)))
  end

  M.EOC_ELECTROKIN_CIRCUIT_SENSE_INITIATE = function(you, npc, ctx)
    local eid = EffectTypeId.new(CIRCUIT_EFFECT)
    if you:has_effect(eid) then            -- re-cast toggles the power off
      return M.EOC_ELECTROKIN_REMOVE_CIRCUIT_SENSE(you, npc, ctx)
    end
    U.msg(you, "You open your senses to the flow of current; the workings of "
          .. "every circuit feel obvious.", MsgType.good, ctx)
    you:add_effect(eid, TimeDuration.from_days(7), nil, 1)  -- PERMANENT stand-in
    U.set_mutation(you, CIRCUIT_TRAIT)     -- carries +3 SKILL_LEVEL_ELECTRONICS
    util.queue_eoc(circuit_drain, you, circuit_drain_delay(m.spell_level(you, CIRCUIT_SPELL)))
    return true
  end

  M.EOC_ELECTROKIN_REMOVE_CIRCUIT_SENSE = function(you, npc, ctx)
    local eid = EffectTypeId.new(CIRCUIT_EFFECT)
    if you:has_effect(eid) then
      you:remove_effect(eid)  -- fires the effect-removed handler -> strips trait
    end
    U.unset_mutation(you, CIRCUIT_TRAIT)  -- belt-and-suspenders (idempotent)
    return true
  end

  -- Restart re-arm registration.  These three hand pilots drive their XP DRAIN
  -- through LOCAL closures queued in util.queue (in-memory), not through a
  -- generated `EOC_*_DRAIN` in mod.eoc -- so mom_hooks' generated-drain scan
  -- can't see them.  Register each as { active, arm } in the shared
  -- mod.rearm_drains list; mom_hooks.cold_boot_rearm re-queues the active ones
  -- once per process boot (see the reload/restart note there).
  mod.rearm_drains = mod.rearm_drains or {}
  local function reg_hand_drain(effect_id, drain_fn, delay_fn, spell)
    mod.rearm_drains[#mod.rearm_drains + 1] = {
      active = function(you) return you:has_effect(EffectTypeId.new(effect_id)) end,
      arm = function(you) util.queue_eoc(drain_fn, you, delay_fn(m.spell_level(you, spell))) end,
    }
  end
  reg_hand_drain(PHYS_EFFECT, phys_drain, phys_drain_delay, PHYS_SPELL)
  reg_hand_drain(NOGO_EFFECT, nogo_drain, nogo_drain_delay, NOGO_SPELL)
  reg_hand_drain(CIRCUIT_EFFECT, circuit_drain, circuit_drain_delay, CIRCUIT_SPELL)

  -- ==========================================================================
  -- [Ψ]Clairvoyance (C): reworked from upstream's remote fd_clairvoyant field
  -- (no BN equivalent) to a SELF see-through-walls buff (user decision, QA
  -- round 4).  Toggle: cast to open the inner eye, cast again to close it.
  -- The self-effect effect_clair_voyance carries BN's CLAIRVOYANCE (radius)
  -- via the MOM_CLAIRVOYANCE carrier trait (TRAIT_BRIDGE above).
  -- strip_spell_math rewrites clair_voyance to the effect_on_condition marker
  -- bridge that dispatches here.
  -- ==========================================================================
  local CLAIR_EFFECT = "effect_clair_voyance"
  M.EOC_MOM_CLAIRVOYANCE_TOGGLE = function(you, npc, ctx)
    local eid = EffectTypeId.new(CLAIR_EFFECT)
    if you:has_effect(eid) then
      you:remove_effect(eid)  -- remove_message from the effect JSON
      return
    end
    you:add_effect(eid, TimeDuration.from_minutes(30))
  end

  -- ==========================================================================
  -- Teleport-to-target spells.  Upstream these carry DDA's TARGET_TELEPORT
  -- spell flag (short_range_teleport to the aimed tile); BN has no such flag,
  -- so U.cast_spell intercepts these ids and teleports via Lua.  Range/scatter
  -- expressions mirror the upstream spell JSON math.
  -- ==========================================================================
  local U = mod.u
  local J = mod.jmath
  local function ppm(you)
    if J and J.psionic_power_modifiers then
      return J.psionic_power_modifiers(you)
    end
    return 1.0
  end

  -- teleport_phase: exact tile, range clamp((lvl*0.1 + 2) * ppm, 2, 4)
  U.teleport_spells["teleport_phase_real"] = {
    msg = "Phase to where?",
    range = function(you)
      return U.clamp((math.max(m.spell_level(you, "teleport_phase"), 0) * 0.1
                      + 2) * ppm(you), 2, 4)
    end,
  }

  -- teleport_farstep: range min((lvl*2 + 1) * ppm, 80), scatter ~1
  -- (upstream RANDOM_AOE rng(1, min(4 - 0.2*lvl, 1)) is effectively 1)
  U.teleport_spells["teleport_farstep_real"] = {
    msg = "Farstep to where?",
    range = function(you)
      return math.min((math.max(m.spell_level(you, "teleport_farstep"), 0) * 2
                       + 1) * ppm(you), 80)
    end,
    scatter = function(you) return 1 end,
  }

  -- warped strikes reactive warp: range 4, scatter ~2 (upstream aoe ternary
  -- always evaluates to 1 + 2 once the maintenance effect is up)
  U.teleport_spells["teleport_warper_combat_warp_chance_attacker"] = {
    msg = "Warp to where?",
    range = function(you) return 4 end,
    scatter = function(you) return 2 end,
  }

  -- Far Hand item pull: DDA effect "pickup" (area loot menu) has no BN
  -- equivalent — the ported spell carries effect:"none" (= BN's
  -- invalid-effect debugmsg).  Adapted to tile pick + drag-to-feet
  -- (U.pull_items_to).  Range = upstream min_range math:
  -- min(((pull_lvl + pull_knack_lvl) * 0.9 + 2) * ppm, 40).
  U.pickup_spells["telekinetic_item_pull_real"] = {
    msg = "Pull items from where?",
    range = function(you)
      local lvl = math.max(m.spell_level(you, "telekinetic_pull"), 0)
                  + math.max(m.spell_level(you, "telekinetic_pull_knack"), 0)
      return math.min((lvl * 0.9 + 2) * ppm(you), 40)
    end,
  }

  -- ==========================================================================
  -- [Ψ]Apportation (teleport_item_apport).  Upstream teleports the WIELDED ITEM
  -- to an aimed tile: inside a u_run_inv_eocs search the item is the beta ("n")
  -- talker, and npc_teleport moves that talker.  BN's Lua has no item-as-talker
  -- teleport, so the transpiler rendered npc_teleport as U.teleport_to_pos(npc,
  -- ...) -- which moved the CASTER ("it's teleporting me, not my object").  The
  -- "inside a solid object" guard also fell to a dead U.badcond (map_terrain_
  -- with_flag on a loc context_val was unportable).
  --
  -- BINDING WALL (user decision 2026-07-16): BN exposes NO non-interactive way to
  -- pull the WIELDED item out of your hand -- unwield() always pops the drop/stash
  -- dispose menu, and remove_primary_weapon() isn't bound to Lua.  remove_item()
  -- only silently detaches INVENTORY items.  So the fork apports a carried item
  -- you pick from a menu (real object moved intact, no dupe, no prompts) rather
  -- than the item in your hand -- stow a held item first to send it.  Overrides
  -- the transpiled EOC via main.lua's merge.  you = caster, npc unused.
  -- ==========================================================================
  M.EOC_TELEPORT_ITEM_APPORT = function(you, npc, ctx)
    ctx = ctx or {}
    you = you or gapi.get_avatar()
    if not you then return false end

    local lvl = math.max(m.spell_level(you, "teleport_item_apport"), 0)
    local cap = ((lvl * 2500) + 2000) * ppm(you)   -- volume cap, mL (upstream)

    -- Apportable = carried items remove_item can silently detach: your pack,
    -- including things inside worn containers.  The WIELDED item and WORN armor
    -- are excluded (the wielded one can't be freed without the dispose prompt;
    -- worn armor isn't loot to send).  volume > 0 only.
    local candidates, names = {}, {}
    for _, it in ipairs(you:all_items(false)) do
      if not you:is_wielding(it) and not you:is_worn(it)
         and U.item_volume(it) > 0 then
        candidates[#candidates + 1] = it
        names[#names + 1] = U.item_name(it)
      end
    end
    if #candidates == 0 then
      U.msg(you, "You have nothing you can apport.  (An item held in your hand "
            .. "can't be apported -- stow it in a pocket or pack first.)",
            MsgType.neutral, ctx)
      return true
    end

    -- Pick which item (auto-select when there's only one).
    local pick = 1
    if #candidates > 1 then
      pick = U.select_menu("Apport which item?", names, nil, you, ctx)
      if not pick then return false end            -- cancelled the menu
    end
    local chosen = candidates[pick]
    local nm = U.item_name(chosen)                 -- capture before detach

    -- Size gate: item volume <= (lvl*2500 + 2000) mL * power modifiers.
    if U.item_volume(chosen) > cap then
      U.msg(you, "The air around " .. nm .. " wavers, but nothing happens.  "
            .. "It is too large to apport.", MsgType.neutral, ctx)
      return true
    end

    -- Aim the destination (line-of-sight, ranged): min((lvl*1.25 + 2)*ppm, 80).
    local range = math.min(((lvl * 1.25) + 2) * ppm(you), 80)
    local dest = U.query_tile(you, { range = range, msg = "Apport it to where?" })
    if not dest then
      U.msg(you, "Canceled", MsgType.neutral, ctx)
      return true
    end

    local map = gapi.get_map()
    if map:has_flag_at("WALL", dest) or map:has_flag_at("DOOR", dest) then
      U.msg(you, "You cannot apport an item inside a solid object.", MsgType.bad, ctx)
      return true
    end

    -- Detach the picked item and hand it to the map.  BINDING LIMIT: the only
    -- Lua detach we have, you:remove_item, is inv_remove_item -- it pulls loose
    -- items out of your inventory but NOT an item installed inside another item
    -- (a battery/magazine in a tool or gun, liquid sealed in a container).
    -- all_items() lists those internals, so the menu can offer one, but on a
    -- miss remove_item doesn't error cleanly: it strips the item's location
    -- first, then hands back a null-item stub -- which, passed to add_item,
    -- spams "null item to map" and drops nothing.  So validate the detached
    -- item (a real one has volume > 0; the null stub is 0 / unreadable) before
    -- placing it, and fail gracefully when it's a locked-in component.
    local ok, detached = pcall(function() return you:remove_item(chosen) end)
    local got_it = false
    if ok and detached then
      local vok, v = pcall(function() return U.item_volume(detached) end)
      got_it = vok and type(v) == "number" and v > 0
    end
    if not got_it then
      U.msg(you, nm .. " won't come loose -- it's installed inside another item "
            .. "(like a battery in a tool or ammo in a gun).  Take it out first, "
            .. "then apport it as a loose item.", MsgType.bad, ctx)
      return true
    end
    local leftover = map:add_item(dest, detached)
    if leftover then
      map:add_item(you:get_pos_ms(), leftover)
      U.msg(you, nm .. " resists the pull and reappears at your feet.",
            MsgType.bad, ctx)
      return true
    end
    U.msg(you, nm .. " grows freezing cold for a moment before vanishing.",
          MsgType.neutral, ctx)
    return true
  end

  -- ==========================================================================
  -- Nether Attunement decay (QA round 3 meter redesign): the meter is a
  -- vitamin-scale char var (mom_math); upstream's vitamin decayed 1 per
  -- 5 minutes ("rate": "5 m").  The old int_decay path no longer applies —
  -- attunement_set resyncs the display effect on every write.
  -- ==========================================================================
  local V = mod.vars
  mod.recurring = mod.recurring or {}
  mod.recurring["mom_attunement_decay"] = {
    min_turns = 300, max_turns = 300,
    fn = function(you)
      local v = m.attunement(you)
      if v > 0 then U.attunement_set(you, v - 1) end
    end,
  }

  -- Crystalline elixir "nether boost" cost (fork restore).  DDA's potions carried
  -- a hidden vitamin (effect_matrix_potion_nether_boost) that raised psionic drain
  -- 1-2 every 5 minutes for the elixir's whole 30h — the corruption price of the
  -- drug.  Vitamins are designed out here, so the boost effect ported inert; re-add
  -- the cost as an attunement tick while ANY elixir is active.  At +1..2 vs the
  -- decay's -1 per 5 min, the meter climbs the entire time you're dosed, so leaning
  -- on elixirs pushes you toward Nether Attunement backlash — the intended tradeoff.
  local NETHER_BOOST_EID = EffectTypeId.new("effect_matrix_potion_nether_boost")
  mod.recurring["mom_potion_nether_boost"] = {
    min_turns = 300, max_turns = 300,
    fn = function(you)
      if you:has_effect(NETHER_BOOST_EID) then
        U.attunement_set(you, m.attunement(you) + U.rng(1, 2))
      end
    end,
  }

  -- ==========================================================================
  -- Effect-flag -> trait bridge.  BN implements some capabilities MoM grants
  -- via effect flags as TRAITS only (drowning checks trait_GILLS literally,
  -- character.cpp:8745).  port_effects.py stamps the Lua hook flags on these
  -- effects; here the real trait is granted while the effect is active.
  -- ==========================================================================
  mod.effect_added_handlers = mod.effect_added_handlers or {}
  mod.effect_removed_handlers = mod.effect_removed_handlers or {}
  -- Only the capabilities the generated carrier system does NOT cover stay
  -- here: GILLS is a trait-FLAG capability (not an enchantment), and
  -- Clairvoyance was hand-reworked (SPELL_REWRITE, no upstream enchantment).
  -- Perfected Motion / Marksman's Eye are now generated per-level carriers
  -- (see the generalized bridge below), so their hand entries are retired.
  local TRAIT_BRIDGE = {
    effect_biokin_breathe_skin = { "GILLS" },  -- [Ψ]Oxygen Absorption
    -- [Ψ]Clairvoyance: self see-through-walls (CLAIRVOYANCE=radius enchantment).
    effect_clair_voyance = { "MOM_CLAIRVOYANCE" },
    -- [Ψ]Levitation: BN's can_fly() reads MUTATION_FLIGHT off traits only, so
    -- the effect's DDA LEVITATION/CLIMB_FLYING flags do nothing — grant a
    -- hidden MUTATION_FLIGHT carrier for real (limited) flight, like Bird Wings.
    effect_telekinetic_levitation = { "MOM_LEVITATION_FLIGHT" },
  }
  for eff_id, traits in pairs(TRAIT_BRIDGE) do
    mod.effect_added_handlers[eff_id] = function(who)
      for _, t in ipairs(traits) do U.set_mutation(who, t) end
    end
    mod.effect_removed_handlers[eff_id] = function(who)
      for _, t in ipairs(traits) do U.unset_mutation(who, t) end
    end
  end

  -- ==========================================================================
  -- Generalized carrier-trait bridge (Phase 4, SCALED-CARRIER-TRAITS-SPEC.md).
  -- gen_carrier_map: effect id -> { spell, max_level, prefix }.  port_carriers
  -- generated one hidden trait per spell level (MOM_CAR_<effect>_L<n>) holding
  -- that level's fitted enchantments / native members; port_effects stamps
  -- EFFECT_LUA_ON_ADDED/REMOVED on the source effect.  When the effect lands we
  -- grant the tier matching the caster's current spell level, stash it for an
  -- exact later removal, and a periodic sweep swaps the tier if a maintained
  -- power levels up while active.
  -- ==========================================================================
  local carriers = require("lua/gen_carrier_map")
  mod.carriers = carriers

  -- Pre-resolve each carrier's EffectTypeId once at load instead of on every
  -- retier-sweep tick (105 entries x fresh EffectTypeId.new() every 30 turns,
  -- for EVERY character regardless of school -- perf fix 2026-08-08).
  local carrier_eid = {}
  for eff in pairs(carriers) do carrier_eid[eff] = EffectTypeId.new(eff) end

  local function carrier_level(who, ent)
    if not ent.spell then return 0 end  -- constant effect: single L0 tier
    local lvl = 0
    -- spell_level needs a Character with magic; monster markers (rare) skip.
    pcall(function() lvl = math.max(m.spell_level(who, ent.spell), 0) end)
    return U.clamp(U.round(lvl), 0, ent.max_level)
  end

  local function grant_carrier(who, eff, ent)
    local lvl = carrier_level(who, ent)
    U.set_mutation(who, ent.prefix .. lvl)
    V.uset(who, "_car_" .. eff, lvl)
  end

  local function remove_carrier(who, eff, ent)
    local lvl = V.uget(who, "_car_" .. eff)
    if lvl == nil then lvl = carrier_level(who, ent) end
    U.unset_mutation(who, ent.prefix .. U.round(lvl))
    V.uset(who, "_car_" .. eff, nil)
  end

  -- Track which carriers are live on the avatar right now, so the re-tier
  -- sweep below doesn't have to brute-force all 105 entries every cadence
  -- (perf fix 2026-08-09).  mod.recurring only ever drives `you` = the
  -- avatar (mom_hooks.on_every_x), so a single flat set keyed by effect id
  -- is enough -- no per-character indexing needed.
  local avatar_carriers = {}
  for eff, ent in pairs(carriers) do
    mod.effect_added_handlers[eff] = function(who)
      grant_carrier(who, eff, ent)
      if ent.spell and U.is_avatar(who) then avatar_carriers[eff] = true end
    end
    mod.effect_removed_handlers[eff] = function(who)
      remove_carrier(who, eff, ent)
      if U.is_avatar(who) then avatar_carriers[eff] = nil end
    end
  end

  -- Re-tier sweep: a maintained power can gain levels while active.  Runs on
  -- mod.recurring (drained by mom_hooks.on_every_x); ~30 s cadence.  mom_hooks
  -- does `mod.recurring = mod.recurring or {}` after us, so this entry survives.
  mod.recurring = mod.recurring or {}
  mod.recurring["_mom_carrier_retier"] = {
    min_turns = 30, max_turns = 30,
    fn = function(you)
      for eff in pairs(avatar_carriers) do
        local ent = carriers[eff]
        -- has_effect stays as a defensive check against tracking/effect
        -- desync (e.g. an effect cleared through a path that skips our
        -- removed-handler); cheap now that this only walks active entries
        -- instead of all 105.
        if you:has_effect(carrier_eid[eff]) then
          local cur = carrier_level(you, ent)
          local old = V.uget(you, "_car_" .. eff)
          if old == nil or U.round(old) ~= cur then
            if old ~= nil then U.unset_mutation(you, ent.prefix .. U.round(old)) end
            U.set_mutation(you, ent.prefix .. cur)
            V.uset(you, "_car_" .. eff, cur)
          end
        else
          avatar_carriers[eff] = nil
        end
      end
    end,
  }

  -- Pain Suppression (electrokinetic_reduce_pain) -- perceived-pain reduction.
  -- BN has no PAIN enchantment value (port_carriers ENCH_VALUE_DROP), so the
  -- generated carrier trait only carries the weak PAIN_REMOVE -> pain_recovery
  -- bump; upstream's *main* effect -- a PAIN multiply that scales *perceived*
  -- pain down 15%..50% by level -- was dropped, leaving the power near-inert.
  -- Reproduce it in Lua: BN's get_perceived_pain() = max(pain - painkiller, 0)
  -- (character.cpp:1126), so holding painkiller at pain*factor while the effect
  -- is up yields perceived = pain - pain*factor = pain*(1-factor), exactly the
  -- upstream multiply.  Only ever RAISE pkill to that floor (never lower) so a
  -- drug's painkiller is preserved and we merely top it up.  On power-end we
  -- touch nothing: painkiller decays ~1/turn (character.cpp:5754), so the pain
  -- "surges back", matching the effect's remove_message.  Capped at 200, well
  -- under the 240 overdose threshold (character.cpp:5862).  Runs every turn --
  -- painkiller decays each turn, so a coarser sweep would let the mask flicker.
  local REDUCE_PAIN_EID = EffectTypeId.new("effect_electrokin_reduce_pain")
  mod.recurring["_mom_reduce_pain_mask"] = {
    min_turns = 1, max_turns = 1,
    fn = function(you)
      pcall(function()
        if not you:has_effect(REDUCE_PAIN_EID) then return end
        local pain = you:get_pain()
        if pain <= 0 then return end
        -- upstream: min((level*0.02 + 0.15) * psionic_power_modifiers, 0.5)
        local lvl = math.max(m.spell_level(you, "electrokinetic_reduce_pain"), 0)
        local factor = math.min((lvl * 0.02 + 0.15)
                                * J.psionic_power_modifiers(you, nil, {}), 0.5)
        local floor = math.min(U.round(pain * factor), 200)
        if you:get_painkiller() < floor then you:set_painkiller(floor) end
      end)
    end,
  }

  -- ==========================================================================
  -- Hand ports for monster-target EOC spells whose numbers can't be fitted
  -- into spell JSON (they read runtime caster vars).  Signature reminder:
  -- you = spell TARGET, npc = CASTER (the marker bridge passes the avatar).
  -- ==========================================================================

  -- [Ψ]Oubliette: banish, don't damage.  Upstream compares a damage roll to
  -- the target's total HP; a win is u_die { remove_corpse } — in BN,
  -- death_drops = false makes monster::die() bail before drops, corpse and
  -- kill credit (monster.cpp:3263), which is exactly a clean banish.
  -- Upstream's TELESTOP/TELEPORT_IMMUNE/DIMENSIONAL_ANCHOR gates stay
  -- unported (Phase 4, needs monster-flag bindings).
  M.EOC_TELEPORTER_OUBLIETTE_HANDLING = function(you, npc, ctx)
    npc = npc or gapi.get_avatar()
    local sf = (m.int(npc) + 10) / 20
    local scale = V.uget(npc, "nether_attunement_power_scaling")
    local lvl = math.max(m.spell_level(npc, "teleport_banish"), 0)
    local dmg = U.rng((15 + lvl * 15) * sf * scale, (350 + lvl * 35) * sf * scale)
    local mon = you.as_monster and you:as_monster() or nil
    if not mon then
      -- character targets use limb-average HP upstream; rare, Phase 4
      U.msg(npc, "Your target wavers for a moment, but nothing happens.", MsgType.neutral)
      return true
    end
    if dmg > you:get_hp() then
      U.msg(npc, "With a tremendous mental exertion, you hurl your target…elsewhere.", MsgType.good)
      mon.death_drops = false
      mon:set_hp(0)
    end
    -- upstream is silent when the target resists — too strong to hurl
    return true
  end

  -- [Ψ]Force Shove / Kinetic Hand / Megakinesis push-pull: the real push
  -- spell (telekinetic_force_shove_real, effect directed_push) reads its
  -- distance from a runtime var, which fits to 0 — so the push happens in
  -- Lua via U.shove (knock_back_to steps) instead.  Weight-ratio math is
  -- upstream EOC_TELEKINETIC_THROW_WEIGHT_HANDLER verbatim.  Upstream's
  -- free-direction hurl picker for pushes is simplified to directly-away-
  -- from-caster (BN directed_push behavior; Phase-4 nicety).
  M.EOC_TELEKINETIC_THROW_WEIGHT_HANDLER = function(you, npc, ctx)
    ctx = ctx or {}
    npc = npc or gapi.get_avatar()
    V.uset(you, "telekinesis_intelligence", ((m.int(npc) + 10) / 20))
    V.uset(you, "nether_attunement_telekinesis_scaling",
           V.uget(npc, "nether_attunement_power_scaling"))
    local ratio = ((((V.uget(you, "telekinesis_power_level")
                      * V.uget(you, "telekinesis_weight_ratio"))
                     * V.uget(you, "telekinesis_intelligence"))
                    * V.uget(you, "nether_attunement_telekinesis_scaling"))
                   + (V.uget(you, "telekinesis_weight_ratio") / 2))
                  / (U.weight(you) / 1000000)
    V.uset(you, "weight_ratio", ratio)
    local lvl = U.clamp((ratio - 1) * 2, 0, 30)
    V.uset(you, "telekinesis_shove_spell_level", lvl)
    local down = mod.eoc and mod.eoc["EOC_TELEKINETIC_PUSH_DOWN_CHECKER"]
    if lvl < 1 then
      if down then down(you, npc, ctx) end
      return true
    end
    local pull = V.uget(you, "telekinesis_push_pull_selector") == -1
    if not pull and U.is_avatar(npc) then
      U.msg(npc, "You hurl your target.", MsgType.good)
    end
    U.shove(you, npc, pull and -lvl or lvl)
    if down then down(you, npc, ctx) end
    return true
  end

  -- ==========================================================================
  -- directed_push corrupts the creature tracker (2026-08-01, player report).
  --
  -- BN's directed_push moves a monster with `mon->setpos( push_dest )`
  -- (magic_spell_effect.cpp:776) after checking ONLY map::impassable along the
  -- path -- it never asks critter_at() whether the destination is occupied.
  -- monster::setpos (monster.cpp:475) then calls update_zombie_pos and assigns
  -- pos_abs REGARDLESS of the false return, so the engine's own refusal is
  -- cosmetic: the monster relocates while Creature_tracker still indexes it at
  -- its old tile, and the next setpos erases the OTHER monster's entry
  -- (creature_tracker.cpp:171).  That monster stays alive but drops out of
  -- every critter_at lookup -- unattackable, walk-through-able, still able to
  -- attack -- and the state is saved.  Reported as:
  --   "wanted to move the deer to 305,1833,0, but new location already has the
  --    feral PKer"
  --
  -- strip_spell_math now reroutes the two creature-moving directed_push spells
  -- here (SPELL_REWRITE -> _rewrite_monster_pull / _rewrite_telelixir_push).
  -- U.shove steps with Creature::knock_back_to, which DOES check critter_at at
  -- every tile and bounces off an occupant, so a blocked push stops short.
  --
  -- Fix the engine and this whole block goes away; see
  -- docs/upstream-bn-directed-push.md.
  -- ==========================================================================

  -- mtypes carrying telekinetic_pull_monster.  BN's effect hooks pass only
  -- (mon, effect) -- no caster (monster.cpp:3792) -- and mom_hooks' marker
  -- dispatch fills `npc` with the avatar, which is wrong for a monster cast.
  -- So the puller is inferred.  Keep in sync with monsters/feral_psychics.json,
  -- monsters/bosses.json, monsters/monster_overrides.json; check_refs would
  -- catch a renamed id, not a newly added caster, so an unlisted puller simply
  -- fizzles rather than misbehaving.
  local TK_PULLERS = {
    mon_feral_human_telekin = true,
    mon_feral_human_telekin2 = true,
    mon_feral_human_telekin3 = true,
    mon_transcendant_alpha_psion = true,
    mon_zombie_nemesis = true,
  }

  -- The nearest TK_PULLERS monster that can see `target` and is within the
  -- spell's own max_range (20).  nil when nothing plausible is in reach.
  local function find_tk_puller(target)
    local tp = target:get_pos_ms()
    local best, best_d = nil, nil
    for _, mon in ipairs(gapi.get_all_monsters()) do
      local mp = mon:get_pos_ms()
      -- Position equality doubles as "not the target itself": two creatures
      -- never legitimately share a tile, and if they do we are already in the
      -- corrupted state this function exists to avoid creating.
      if not (mp.x == tp.x and mp.y == tp.y and mp.z == tp.z) then
        -- `:str()`, NOT tostring().  luna registers to_string on every
        -- string_id as "%s[%s]" % (usertype name, id)
        -- (catalua_bindings_ids_common.h:55), so tostring() yields
        -- "MtypeId[mon_feral_human_telekin]" and never matches a bare id key --
        -- find_tk_puller returned nil on every call, and since a nil puller
        -- fizzles silently the pull did nothing with no error to show for it.
        -- `str` is bound to string_id::c_str on the same usertype (:53).
        local ok, id = pcall(function() return mon:get_type():str() end)
        if ok and TK_PULLERS[id] and mon:get_hp() > 0 then
          local d = U.dist(mp, tp)
          if d <= 20 and (not best_d or d < best_d) and mon:sees(tp) then
            best, best_d = mon, d
          end
        end
      end
    end
    return best
  end

  -- telekinetic_pull_monster.  Upstream is DDA `pull_target`, which the
  -- pull_target branch of transpile_spell encoded as directed_push with damage
  -- -(max_range); directed_push clamps a negative distance to exactly
  -- rl_dist(caster, target), so every cast inside 20 tiles dropped the target
  -- on the caster's own tile.  U.shove's `toward` loop breaks at range 1, so
  -- the pull now correctly ends ADJACENT to the puller.
  M.EOC_MOM_MONSTER_TK_PULL = function(you, npc, ctx)
    local caster = find_tk_puller(you)
    -- No identifiable puller: fizzle.  A silent no-op is strictly better than
    -- guessing a direction, and far better than the tracker corruption.
    if not caster then return true end
    U.shove(you, caster, -20)
    return true
  end

  -- telelixir_push: the telekinesis elixir surge (EOC_TELELIXIR_CAST fires it
  -- every 2-5 turns while TELELIXIRDOWN_active).  Player-cast, so mom_hooks'
  -- avatar `npc` is the correct caster here.  3-8 tiles is upstream's
  -- min_damage/max_damage, which the marker bridge strips off the spell.
  M.EOC_MOM_TELELIXIR_PUSH = function(you, npc, ctx)
    npc = npc or gapi.get_avatar()
    U.shove(you, npc, U.rng(3, 8))
    return true
  end

  -- Font of vitality (mon_feral_human_vita3) death revival.  Upstream, in
  -- CDDA/data/mods/MindOverMatter/monsters/death_effects.json:
  --   npc_location_variable -> spawn_place
  --   npc_spawn_monster mon_feral_human_vita3_revived, real_count 1, radius 0..0
  --   run_eocs EOC_VITAKIN3_DEATH_EFFECT_2 with alpha_loc = spawn_place
  --     -> u_hp('ALL') = 25, u_add_effect effect_feral_regeneration 15-30 s
  --
  -- The transpiler has no `npc_spawn_monster` verb (only `u_spawn_monster`, as
  -- U.spawn_monster), so gen_eoc's version called U.unported() and the font
  -- announced its revival without ever rising.  _2 was wrong twice over: it
  -- cannot write hp at all, and `alpha_loc` means its `u` is the NEWLY SPAWNED
  -- monster -- the generated version would have put the regen on the corpse.
  --
  -- U.spawn_monster is unusable here: it floors radius at 1 (`math.max(1, ...)`)
  -- and discards the monster it placed, and we need both the exact tile and a
  -- handle to set hp on.  gapi.place_monster_at is place_critter_around(.., 0),
  -- which gates the tile on can_place_monster and returns nil rather than
  -- stacking -- the safe primitive, unlike setpos (see EOC_MOM_MONSTER_TK_PULL).
  --
  -- The radius-1 fallback is not belt-and-braces: `on_mon_death` fires at the end
  -- of monster::die (monster.cpp:3565) but the corpse is not unregistered until
  -- the game loop's later cleanup_dead, so its own tile is usually still occupied
  -- and the exact-tile attempt is expected to fail more often than not.
  local function vita3_spawn(where)
    local id = MonsterTypeId.new('mon_feral_human_vita3_revived')
    local mon = gapi.place_monster_at(id, where)
    if mon == nil then mon = gapi.place_monster_around(id, where, 1) end
    return mon
  end

  M.EOC_VITAKIN3_DEATH_EFFECT = function(you, npc, ctx)
    ctx = ctx or {}
    -- on_mon_death dispatches as fn(mon, mon, {}), so either arg is the corpse.
    local who = npc or you
    if not who then return true end
    local ok, where = pcall(function() return who:get_pos_ms() end)
    if not ok or not where then return true end
    ctx['spawn_place'] = where
    local sok, mon = pcall(vita3_spawn, where)
    -- Nowhere free to rise: stay dead.  Better a missed revival than a debugmsg.
    if not sok or not mon then return true end
    M.EOC_VITAKIN3_DEATH_EFFECT_2(mon, npc, ctx)
    return true
  end

  M.EOC_VITAKIN3_DEATH_EFFECT_2 = function(you, npc, ctx)
    ctx = ctx or {}
    if not you then return true end
    -- monster:set_hp is bound (catalua_bindings_creature.cpp:569); Character has
    -- no such setter, but `you` here is always the spawned monster.
    pcall(function() you:set_hp(25) end)
    U.add_effect(you, 'effect_feral_regeneration',
                 U.rng_dur(TimeDuration.from_seconds(15),
                           TimeDuration.from_seconds(30)), nil, nil)
    return true
  end

  -- [Ψ]Degenerating Touch: damage-over-time driven entirely by caster math
  -- (the fitted vita_degenerating_touch_self_* spells read runtime vars and
  -- fit to 0).  Total damage spread over the duration, 1 tick per second
  -- via util.queue; the visible effect is applied for the same duration.
  M.EOC_VITAKIN_DEGENERATING_TOUCH = function(you, npc, ctx)
    npc = npc or gapi.get_avatar()
    local sf = (m.int(npc) + 10) / 20
    local scale = V.uget(npc, "nether_attunement_power_scaling")
    local lvl = math.max(m.spell_level(npc, "vita_degenerating_touch"), 0)
    local total = U.rng((lvl * 17 + 25) * sf * scale, (lvl * 32 + 55) * sf * scale)
    local dur = U.round(U.rng(math.max(30 - lvl * sf * scale, 15),
                              math.max(75 - lvl * 2 * sf * scale, 15)))
    U.msg(npc, "Your target's flesh begins decaying before your eyes!", MsgType.good)
    U.add_effect(you, "effect_vita_degenerating_touch",
                 TimeDuration.from_turns(dur), nil, nil)
    local per_tick = total / dur
    local torso = BodyPartTypeId.new("torso"):int_id()
    local carry = 0
    for t = 1, dur do
      util.queue_eoc(function(target)
        -- pcall: ticks run raw in the on_every_x drainer, and the target
        -- reference can go stale mid-DOT (death, despawn)
        pcall(function()
          carry = carry + per_tick
          local hit = math.floor(carry)
          carry = carry - hit
          if hit > 0 and target and target:get_hp() > 0 then
            target:apply_damage(nil, torso, hit, false)
          end
        end)
      end, you, t)
    end
    return true
  end

  -- ==========================================================================
  -- [Ψ]Anabolic Rejuvenation (vita_super_heal): "heal a hundredfold."  The heal
  -- tick (EOC_VITAKIN_SUPER_HEAL_EFFECTS) was DEAD in the transpile — BN's Lua
  -- can't express u_hp()/u_vitamin() reads+writes, so all 13 branches came out
  -- as U.unported stubs (0 real heals).  The rest of the chain is fine: INITIATE
  -- applies effect_vita_super_heal + schedules the RUN_HEALING loop, RUN_HEALING
  -- reschedules and pays the (working) kcal cost, and it calls this EOC through
  -- the shared mod.eoc table — so overriding it here (main.lua merges over
  -- gen_eoc) is all that's needed.  Reproduce upstream's per-limb regen: every
  -- damaged part gains max(1 * psionic_power_modifiers, 1) HP per tick (scales up
  -- with nether attunement; upstream also accelerates the tick with power level,
  -- which the surviving RUN_HEALING reschedule already does).  DROPPED (user,
  -- 2026-07-17): the blood/redcells vitamin replenishment and the bleed-intensity
  -- scrub — BN has no anemia and treats bleeding as flat HP loss, which this
  -- regen already offsets, so neither needs separate handling.
  -- ==========================================================================
  local SUPER_HEAL_PARTS
  M.EOC_VITAKIN_SUPER_HEAL_EFFECTS = function(you, npc, ctx)
    you = you or gapi.get_avatar()
    if not you then return true end
    if not SUPER_HEAL_PARTS then
      SUPER_HEAL_PARTS = {}
      for _, p in ipairs({ "arm_l", "arm_r", "leg_l", "leg_r", "torso", "head" }) do
        SUPER_HEAL_PARTS[#SUPER_HEAL_PARTS + 1] = BodyPartTypeId.new(p):int_id()
      end
    end
    local heal = math.max(U.round(ppm(you)), 1)   -- upstream max(1 * ppm, 1)
    for _, bp in ipairs(SUPER_HEAL_PARTS) do
      local cur, mx = you:get_part_hp_cur(bp), you:get_part_hp_max(bp)
      if cur < mx then
        you:set_part_hp_cur(bp, math.min(cur + heal, mx))
      end
    end
    return true
  end

  -- ==========================================================================
  -- Short Circuit (electrokinetic_kill_robot).  Upstream is PERCENTAGE_DAMAGE
  -- 150 (removes 150% of max HP -> always kills) restricted to
  -- targeted_monster_species [CYBORG, ROBOT, ROBOT_FLYING].  CBN honors neither
  -- percentage damage nor monster-species targeting, so the flat-150 port hit
  -- everything.  strip_spell_math now reroutes the spell through the marker
  -- bridge (SPELL_REWRITE); here we gate on species and deliver the real
  -- effect only to robots.  CBN tags cyborgs as species ROBOT, so ROBOT +
  -- ROBOT_FLYING covers the upstream CYBORG/ROBOT/ROBOT_FLYING set.
  -- you = target creature, npc = caster (avatar).
  -- ==========================================================================
  M.EOC_MOM_SHORT_CIRCUIT = function(you, npc, ctx)
    local caster = npc or gapi.get_avatar()
    local is_robot = false
    pcall(function()
      is_robot = you:in_species(SpeciesTypeId.new("ROBOT"))
                 or you:in_species(SpeciesTypeId.new("ROBOT_FLYING"))
    end)
    if not is_robot then
      U.msg(caster, "Your power surge crackles over " .. you:get_name() ..
            " to no effect; there's no circuitry to overload.", MsgType.warning)
      return false
    end
    -- Flavor: the LOUD spark burst (fd_electricity field + "zzzzaaaaaapp!").
    U.cast_spell(caster, "electrokinetic_kill_robot_sparks",
                 math.max(m.spell_level(caster, "electrokinetic_kill_robot"), 0),
                 you:get_pos_ms())
    -- The disabling surge: upstream 150% of max HP, a guaranteed disable.
    U.msg(caster, "You channel a massive power surge into " .. you:get_name() ..
          " -- its systems overload and fail!", MsgType.good)
    U.deal_flat_damage(you, U.round(U.hp_max(you) * 1.5))
    return true
  end

  -- ==========================================================================
  -- Abjuration Stone (mom_abjuration_stone_effects).  Upstream banishes Nether
  -- creatures in a 15-25 tile radius: valid_targets [hostile, ally] narrowed by
  -- targeted_monster_species [NETHER, NETHER_EMANATION, NETHER_BURROWING], and
  -- its EOC is a bare `u_die` on whatever survives that filter.  BN's spell
  -- engine has no species filter (the same gap as Short Circuit above), so the
  -- ported spell runs through the marker bridge and the filter lives HERE.
  -- Without it the stone would instantly kill every hostile and every ally
  -- within 25 tiles -- not a port, a nuke.  NETHER_BURROWING is not in the port
  -- (nothing in BN core or this mod carries it), so NETHER + NETHER_EMANATION is
  -- the whole reachable set.
  -- Deliberately silent, like upstream: the creatures visibly dying is the
  -- feedback, and a nether breach would otherwise spam a line per corpse.  The
  -- one upstream detail BN can't honor is `remove_corpse` -- `die()` leaves
  -- whatever corpse the monster type would normally leave, which for most nether
  -- creatures is none anyway (they carry NO_CORPSE / "melts away").
  -- you = target creature, npc = caster (avatar).
  -- ==========================================================================
  M.EOC_MOM_ABJURATION_STONE_SPELL_EFFECTS = function(you, npc, ctx)
    local nether = false
    pcall(function()
      nether = you:in_species(SpeciesTypeId.new("NETHER"))
               or you:in_species(SpeciesTypeId.new("NETHER_EMANATION"))
    end)
    if not nether then return false end
    U.die(you)
    return true
  end

  -- ==========================================================================
  -- Beastmaster (telepathic_animal_mind_control [+_knack]) / Beast Tamer
  -- (telepathic_beast_taming), user backlog 2026-08-06.  Upstream is BN-
  -- native charm_monster gated by targeted_monster_species [MAMMAL, BIRD,
  -- AMPHIBIAN, REPTILE, FISH] / ignored_monster_species [ZOMBIE, ROBOT,
  -- ROBOT_FLYING, NETHER, NETHER_EMANATION, LEECH_PLANT, WORM, FUNGUS, SLIME,
  -- PSI_NULL].  BN's spell engine has no species filter at all (same gap as
  -- Short Circuit / Abjuration Stone above), so as ported BOTH spells already
  -- had zero species gate -- they'd already charm a zombie today.  Separately,
  -- BN's native charm_monster (magic_spell_effect.cpp:1071) never reads
  -- spell_flag::RECHARM/CHARM_PET at all -- unlike DDA's real version
  -- (CDDA/src/magic_spell_effect.cpp:1604), it hard-requires friendly==0, so
  -- Beast Tamer's whole premise ("must already be friendly, this extends it")
  -- could never fire, for animals either, before today.
  -- Rerouted through the marker bridge (strip_spell_math.SPELL_REWRITE) to
  -- fix both: gate on MF_PSIPROOF (this mod's existing, already-verified
  -- stand-in for the upstream exclusion set -- TEEP_IMMUNE->PSIPROOF, see
  -- port_monsters -- landing on ZOMBIE/ROBOT/NETHER/plant/slime, the same set
  -- upstream cared about, and correctly still resisting the handful of
  -- high-tier feral Telepaths that carry PSIPROOF as their own psi ward) and
  -- a hand port of DDA's real charm_monster logic, RECHARM/CHARM_PET
  -- included.  The upstream animal-only species WHITELIST is not rebuilt: BN
  -- has no mechanism to enforce one, and PSIPROOF already keeps out
  -- everything upstream excluded for a reason, so nothing that used to be
  -- blocked on purpose becomes targetable just because ferals now are.
  -- you = target creature, npc = caster (avatar).
  -- ==========================================================================
  local MOM_CHARM_PSIPROOF_FLAG = (MonsterFlag and MonsterFlag.PSIPROOF) or nil
  local function mom_charm_is_mindless(you)
    if MOM_CHARM_PSIPROOF_FLAG == nil then return false end
    local ok, res = pcall(function() return you:has_flag(MOM_CHARM_PSIPROOF_FLAG) end)
    return ok and res == true
  end
  -- Shared charm-attempt logic (DDA magic_spell_effect.cpp:1604, hand port).
  -- recharm: allow success when already friendly (spell_flag::RECHARM).
  -- charm_pet: on success, override to permanent friendly=-1 + effect_pet
  -- (spell_flag::CHARM_PET) -- this is what actually makes Beast Tamer
  -- permanent; the duration roll below is otherwise moot once it fires.
  local function mom_charm_attempt(you, caster, min_dmg, max_dmg,
                                    min_dur, max_dur, recharm, charm_pet)
    if mom_charm_is_mindless(you) then
      U.msg(caster, "You reach for " .. you:get_name() ..
            "'s mind and find nothing there to seize.", MsgType.warning)
      return false
    end
    local friendly = you.friendly or 0
    if not (friendly == 0 or (friendly ~= 0 and recharm)) then
      U.msg(caster, "Something about " .. you:get_name() ..
            " resists your reach.", MsgType.warning)
      return false
    end
    local threshold = U.rng(min_dmg, max_dmg)
    if you:get_hp() > threshold then
      U.msg(caster, "The " .. you:get_name() ..
            " resists your charm attempt.", MsgType.bad)
      return false
    end
    local dur_turns = U.round(U.rng(min_dur, max_dur) / 100)
    you.friendly = you.friendly + dur_turns
    if charm_pet and you.friendly ~= -1 then
      you.friendly = -1
      U.add_effect(you, 'pet', TimeDuration.from_turns(1), nil, nil)
    end
    U.msg(caster, "You charm the " .. you:get_name() .. "!", MsgType.good)
    return true
  end

  M.EOC_MOM_BEASTMASTER_CHARM = function(you, npc, ctx)
    local caster = npc or gapi.get_avatar()
    local lvl = math.max(m.spell_level(caster, 'telepathic_animal_mind_control'), 0)
              + math.max(m.spell_level(caster, 'telepathic_animal_mind_control_knack'), 0)
    local p = ppm(caster)
    return mom_charm_attempt(you, caster,
      (lvl * 8 + 40) * p, (lvl * 15 + 200) * p,
      (lvl * 1125 + 18000) * p, (lvl * 2800 + 47000) * p,
      false, false)
  end

  M.EOC_MOM_BEAST_TAMER_CHARM = function(you, npc, ctx)
    local caster = npc or gapi.get_avatar()
    local lvl = math.max(m.spell_level(caster, 'telepathic_beast_taming'), 0)
    local p = ppm(caster)
    return mom_charm_attempt(you, caster,
      (lvl * 15 + 200) * p, (lvl * 35 + 500) * p,
      (lvl * 8640000 + 241920000) * p, (lvl * 25920000 + 483840000) * p,
      true, true)
  end

  -- ==========================================================================
  -- Psychometry (clair_examine_item).  Upstream reads artifact_resonance + the
  -- FIFTH_SUN_TECHNOLOGY flag off the chosen item; BN has neither (resonance is
  -- a DDA-only enchant value; MoM's Fifth-Sun items/flag aren't ported, and the
  -- unregistered-flag lookup was crashing).  Reworked to the BN-native relic
  -- readout: pick a carried item; if it's an artifact, show the same analysis
  -- CBN's artifact-analyzer console gives (U.artifact_report); else report
  -- nothing unusual.  (User request, 2026-07-09.)  Overrides the generated EOC.
  -- ==========================================================================
  M.EOC_CLAIR_EXAMINE_ITEM_INITIATE = function(you, npc, ctx)
    local items = you:all_items(false)
    if not items or #items == 0 then
      U.msg(you, "You have nothing on you to read.", MsgType.neutral)
      return true
    end
    local names = {}
    for i, it in ipairs(items) do names[i] = U.item_name(it) end
    local pick = U.select_menu("Read the impressions from which object?",
                               names, nil, you, ctx)
    if not pick then return false end
    local it = items[pick]
    local report = U.item_is_artifact(it) and U.artifact_report(it) or nil
    if report then
      U.popup(report)
    else
      U.msg(you, "You focus on " .. U.item_name(it) ..
            ", but sense nothing unusual about it.", MsgType.neutral)
    end
    return true
  end

  -- ==========================================================================
  -- Galvanic Aura -- 3D line-of-sight strike.  *** UPGRADE vs upstream DDA. ***
  -- Overrides the transpiled gen_eoc version (main.lua merges this table over
  -- gen_eoc's, and every internal call -- INITIATE and the 5s self-reschedule
  -- -- routes through the shared mod.eoc table, so this wins the whole loop).
  --
  -- Upstream (and the literal transpile) picked ANY monster in a flat 3D
  -- radius with NO line-of-sight test, then cast a 2D `line`/attack spell at
  -- it.  Two consequences: it zapped through solid walls on your own floor,
  -- and any target on another z-level silently fizzled (BN spell projection
  -- is 2D -- the upstream JSON even flags the attack "not fully functional").
  --
  -- Now target selection is gated on Creature:sees() -- BN's gun/vision LOS:
  -- clear through open air (incl. up a tree or down a stair-hole to another
  -- z-level), blocked by walls, floors and ceilings.  A same-z target still
  -- takes the real attack spell (full armour/field/effect pipeline, byte-for-
  -- byte upstream).  A target reached across z through open air takes a direct
  -- flat electric hit rolled from the SAME damage formula the spell uses
  -- (BN exposes no resistance-aware damage binding to Lua, so cross-z damage
  -- is armour-agnostic -- identical to the mod's existing electric/pyro
  -- aura-thorn procs).  Net: Galvanic Aura strikes like a gun, not a spear.
  -- ==========================================================================
  local AURA_EFFECT = "effect_electrokinetic_lightning_aura"
  M["EOC_ELECTROKIN_LIGHTNING_AURA_EFFECTS"] = function(you, npc, ctx)
    ctx = ctx or {}
    if not you:has_effect(EffectTypeId.new(AURA_EFFECT)) then
      return false
    end
    local lvl = m.spell_level(you, "electrokinetic_lightning_aura")
    local radius = math.min(((lvl * 0.33) + 2) *
                            J.psionic_power_modifiers(you, npc, ctx), 10)
    local target = U.find_visible_monster(you, 0, radius)
    if target then
      if target:get_pos_ms().z == you:get_pos_ms().z then
        -- same floor: real spell, unchanged (armour, effects, field, arc)
        U.cast_spell(you, "electrokinetic_lightning_aura_attack_placeholder",
                     nil, target:get_pos_ms())
      else
        -- clear-air cross-z: 2D spell would fizzle, so deliver it directly
        local bolt = m.spell_level(you, "electrokinetic_lightning_bolt")
        local sf = J.scaling_factor(you, npc, ctx, m.int(you))
        local lo = U.round(((lvl * 1) + 5) * sf)
        local hi = U.round(((bolt * 1.5) + 20) * sf)
        if hi < lo then hi = lo end
        -- pass `you` as the source so a cross-z kill CREDITS the caster + fires
        -- the kill message (a nil source is sourceless like field damage -> the
        -- long-standing "aura kills give no credit up a tree" bug).
        U.deal_flat_damage(target, gapi.rng(lo, hi), you)
      end
    end
    U.cast_spell(you, "electrokinetic_lightning_aura_spark", nil, nil)
    util.queue_eoc(function(y)
      mod.eoc["EOC_ELECTROKIN_LIGHTNING_AURA_EFFECTS"](y, npc, ctx)
    end, you, 5)
    return true
  end

  -- ==========================================================================
  -- Fork addition (2026-07-17): serious hunger/thirst breaks ongoing channeling.
  -- Upstream never guards its per-tick calorie drain, so a player maintaining a
  -- power (e.g. Anabolic Rejuvenation) could quietly starve to death mid-heal —
  -- killed by their own healing power.  Both channeling loops self-reschedule and
  -- pass through one universal hook apiece, so we wrap those hooks:
  --   * maintained/concentration powers -> EOC_POWER_MAINTENANCE_CONCENTRATION_CHECK
  --   * contemplation / power study      -> EOC_PSI_STUDYING_POWER_NETHER_ATTUNEMENT
  -- Thresholds mirror BN's own alarm bands: thirst >= 480 (thirst_levels::
  -- dehydrated, the band just before damage-dealing "Parched" at 600) and stored
  -- kcal <= 14% of max (roughly the "Starving" description, ~1 day of food left).
  -- This is a forced physical cutout, NOT a psychic concentration failure, so we
  -- deliberately skip the nether-attunement backlash and failure-XP that a real
  -- concentration break carries — your body gave out, the Nether didn't bite.
  local NEED_THIRST_BREAK = 480      -- thirst_levels::dehydrated (character.h)
  local NEED_KCAL_PCT_BREAK = 0.14   -- ~"Starving": one day of calories left
  local function channeling_need_break(you)
    if not you or you.get_thirst == nil then return nil end  -- monster/ no body
    if you:get_thirst() >= NEED_THIRST_BREAK then return "thirst" end
    if you:get_kcal_percent() <= NEED_KCAL_PCT_BREAK then return "hunger" end
    return nil
  end

  -- Capture the generated originals BEFORE main.lua merges these overrides back
  -- over mod.eoc (gen_eoc's own M table), so we can delegate the normal case.
  local gen_conc_check = mod.eoc and mod.eoc["EOC_POWER_MAINTENANCE_CONCENTRATION_CHECK"]
  local gen_study_drain = mod.eoc and mod.eoc["EOC_PSI_STUDYING_POWER_NETHER_ATTUNEMENT"]

  M["EOC_POWER_MAINTENANCE_CONCENTRATION_CHECK"] = function(you, npc, ctx)
    ctx = ctx or {}
    if you and m.maintained_count(you) >= 1 then
      local why = channeling_need_break(you)
      if why then
        U.msg(you, (why == "thirst")
          and "You're too parched to keep channeling — your concentration collapses."
          or  "You're too starved to keep channeling — your concentration collapses.",
          MsgType.bad, ctx)
        mod.eoc["EOC_END_PSI_POWERS_MAINTAINED"](you, npc, ctx)
        mod.eoc["EOC_CONCENTRATION_FAILURE_REDUCE_FOCUS"](you, npc, ctx)
        U.cancel_activity(you)
        return true
      end
    end
    return gen_conc_check(you, npc, ctx)
  end

  M["EOC_PSI_STUDYING_POWER_NETHER_ATTUNEMENT"] = function(you, npc, ctx)
    ctx = ctx or {}
    if you and you:has_effect(EffectTypeId.new("effect_psi_studying_power")) then
      local why = channeling_need_break(you)
      if why then
        U.msg(you, (why == "thirst")
          and "Thirst shatters your contemplation; you can channel no further."
          or  "Hunger shatters your contemplation; you can channel no further.",
          MsgType.bad, ctx)
        you:remove_effect(EffectTypeId.new("effect_psi_studying_power"))
        you:remove_effect(EffectTypeId.new("effect_psi_learning_new_power"))
        U.cancel_activity(you)
        return true   -- do not reschedule: the drain loop halts
      end
    end
    return gen_study_drain(you, npc, ctx)
  end

  return M
end
