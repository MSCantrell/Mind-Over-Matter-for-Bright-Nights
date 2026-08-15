-- mom_u (U): runtime helpers for transpiler-generated EOC code.
-- Every uncertain binding call is pcall-guarded: a failure logs ONCE per key
-- and degrades (return 0/false/no-op) instead of crashing the dispatch.
-- Called from main.lua as require("lua/mom_u")(mod).
return function(mod)
  local m = mod.math
  local V = mod.vars
  local U = {}

  -- ---- logging (once per key; generated code can be very chatty)
  local seen = {}
  local function once(key, msg)
    if seen[key] then return end
    seen[key] = true
    gdebug.log_warn("MoM-BN: " .. msg)
  end

  function U.unported(eoc, what)
    once(eoc .. "|" .. what, "unported verb in " .. eoc .. ": " .. what)
  end

  function U.unported_num(eoc, what)
    once(eoc .. "|" .. what, "unported value in " .. eoc .. ": " .. what .. " -> 0")
    return 0
  end

  function U.badcond(eoc, key)
    once(eoc .. "|c|" .. key, "unported condition in " .. eoc .. ": " .. key .. " -> false")
    return false
  end

  function U.badstr(eoc)
    once(eoc .. "|s", "unported string operand in " .. eoc .. " -> ''")
    return ''
  end

  -- Cached string_id<T> constructors for the transpiler's generated condition/
  -- effect code (tools/eoc_transpile.py emits U.mid(...)/U.eid(...) in place
  -- of MutationBranchId.new(...)/EffectTypeId.new(...)).  Construction crosses
  -- the Lua/C++ boundary and isn't free; gen_eoc.lua references the same ids
  -- from many different EOC handlers, so memoizing here turns every
  -- occurrence after the first (whole-session, across all ~1794 handlers)
  -- into a table lookup. Perf fix 2026-08-08 -- same shape as mom_math.lua's
  -- spell_tid/effect_tid/skill_tid.
  local _mid_cache, _eid_cache = {}, {}
  function U.mid(id)
    local v = _mid_cache[id]
    if v == nil then v = MutationBranchId.new(id); _mid_cache[id] = v end
    return v
  end
  function U.eid(id)
    local v = _eid_cache[id]
    if v == nil then v = EffectTypeId.new(id); _eid_cache[id] = v end
    return v
  end

  -- Sentinel thrown when the player cancels an interactive target/tile pick
  -- (Esc).  It unwinds the whole cast so no downstream effects or "you did the
  -- thing" messages run -- an aborted Phase must not announce "you are somewhere
  -- else."  Every top-level EOC entry point (guarded here; dispatch_eoc in
  -- mom_hooks) recognizes it and returns quietly instead of logging an error.
  local CANCEL = {}
  function U.cancel_cast() error(CANCEL) end
  function U.is_cancel(e) return e == CANCEL end

  local function guarded(key, fn, fallback)
    local ok, res = pcall(fn)
    if ok then return res end
    if res == CANCEL then return fallback end  -- player aborted a pick; not an error
    once("g|" .. key, key .. " failed: " .. tostring(res))
    return fallback
  end

  -- ---- numeric / boolean glue (DDA math is numeric; Lua is typed)
  function U.truthy(x)
    if type(x) == "number" then return x ~= 0 end
    return x and true or false
  end

  function U.b2n(b)
    if type(b) == "number" then return b end
    return b and 1 or 0
  end

  function U.clamp(x, lo, hi)
    return math.max(lo, math.min(hi, x))
  end

  function U.round(x)
    return math.floor(x + 0.5)
  end

  function U.rng(a, b)
    a, b = math.floor(a), math.floor(b)
    if b < a then a, b = b, a end
    return gapi.rng(a, b)
  end

  function U.rng_dur(a, b)
    return TimeDuration.make_random(a, b)
  end

  function U.x_in_y(x, y)
    if y <= 0 then return true end
    return gapi.rng(1, 1000000) <= (x / y) * 1000000
  end

  -- DDA roll_contested (condition.cpp f_roll_contested):
  --   rng(1, die_size) + check > difficulty      (die_size default 10)
  -- Used by the research recipes you craft repeatedly to learn a power; each
  -- attempt is one roll of this against a fixed difficulty.
  function U.roll_contested(check, difficulty, die_size)
    die_size = die_size or 10
    if die_size < 1 then die_size = 1 end
    return (U.rng(1, die_size) + (check or 0)) > (difficulty or 0)
  end

  -- ---- messages (only when the actor is the avatar; strip DDA <tags>)
  function U.is_avatar(who)
    if not who then return false end
    return guarded("is_avatar", function() return who:is_avatar() end, true)
  end

  function U.msg(who, text, mtype, ctx)
    if not U.is_avatar(who) then return end
    text = U.interp(who, ctx, text)
    text = text:gsub("<[%w_:%s]->", "")  -- strip any tag interp left unresolved
    gapi.add_msg(mtype or MsgType.neutral, text)
  end

  U.msg_snippet = U.msg  -- snippets: plain text for now (Phase 4 polish)

  -- ---- effects
  -- add_effect(id, dur[, bp[, intensity]]) — catalua_bindings_creature.cpp:281.
  -- dur == 'PERMANENT' -> long duration + set_permanent on the live effect.
  -- Uses the U.eid memo (488 transpiled call sites re-add the same handful of
  -- ids) and bumps mom_math's maintained_count generation — adding an effect
  -- is one of the two Lua-side writes that can change the maintained-power
  -- count mid-turn (perf fix 2026-08-14).
  function U.add_effect(who, eff_id, dur, bp, intensity)
    if not who then return end
    local eid = U.eid(eff_id)
    local permanent = (dur == 'PERMANENT')
    if permanent then dur = TimeDuration.from_days(30) end
    local bpid = nil
    if bp then
      bpid = guarded("bodypart:" .. bp,
        function() return BodyPartTypeId.new(bp) end, nil)
    end
    who:add_effect(eid, dur, bpid, intensity)
    m.maintained_dirty()
    if permanent then
      guarded("set_permanent", function()
        who:get_effect(eid):set_permanent(true)
        return true
      end, nil)
    end
  end

  function U.set_effect_intensity(who, eff_id, v)
    v = U.round(v)
    local eid = U.eid(eff_id)
    m.maintained_dirty()
    if v <= 0 then
      who:remove_effect(eid)
      return
    end
    who:add_effect(eid, TimeDuration.from_hours(12), nil, v)
  end

  -- Apply an effect to every monster within `radius` tiles of `center`
  -- (a Tripoint).  Re-creates the spell_effect_blast delivery of the melee
  -- combat auras (blinding glare etc.), whose leaf attack spells were dropped
  -- from the port.  The avatar isn't a monster, so it's never caught here.
  function U.effect_around(center, radius, eff_id, dur)
    if not center then return end
    guarded("effect_around:" .. eff_id, function()
      radius = math.max(0, U.round(radius))
      local eid = EffectTypeId.new(eff_id)
      for _, mon in ipairs(gapi.get_all_monsters()) do
        if U.dist(center, mon:get_pos_ms()) <= radius then
          mon:add_effect(eid, dur, nil, nil)
        end
      end
      return true
    end, nil)
  end

  -- Flat HP damage to a single creature — the melee-aura "thorns" procs
  -- (electric/pyro) were range-1 single-target, so no AoE spread is needed.
  -- apply_damage is direct/armour-agnostic, matching the DOT path in mom_eoc;
  -- it only lowers HP (die() waits for the end-of-turn check_dead_state), so
  -- firing it inside the melee hook is safe.
  -- `source`, when given, is passed to apply_damage as the attacking Creature so
  -- a lethal hit sets the victim's killer (monster::apply_damage -> set_killer)
  -- and the kill CREDITS that source + fires the engine kill message.  Omit it
  -- (nil) for sourceless/self damage (backlash, debug kills) -- the prior
  -- behaviour.  This is what gives aura kills kill-log credit: BN fields and a
  -- nil-source apply_damage both attribute the kill to nobody (environment).
  function U.deal_flat_damage(target, amount, source)
    if not target then return end
    amount = U.round(amount)
    if amount < 1 then return end
    guarded("deal_flat_damage", function()
      local torso = BodyPartTypeId.new("torso"):int_id()
      if target:get_hp() > 0 then
        target:apply_damage(source, torso, amount, false)
      end
      return true
    end, nil)
  end

  -- Mass Hydrothermosis (fork capstone, id pyrokinetic_aoe_blast -- REPLACES
  -- DDA "Hellfire").  Boil the fluids inside every creature the caster can SEE,
  -- all at once: one flat heat hit per monster in line of sight, no environmental
  -- fire and no fixed radius.  LOS reach IS the capstone -- who:sees() is BN's
  -- gun/vision LOS (walls/floors block; clear air, incl. cross-z, passes), so
  -- range is bounded only by sight.  No "too dry" immunity: robot coolant/oil and
  -- insect ichor boil the same as blood.  Spared: the caster's own companions
  -- (friendly ~= 0, the CDDA convention used by the No Go Zone tick) and the
  -- nether-null PSI_NULL species (mirrors the source spell's ignored_monster_species
  -- -- the school simply can't touch it).  Damage is an rng band that grows with
  -- spell level (roughly 80..220 at reference stats), times the (currently 1.0)
  -- psionic power modifier; each hit is credited to the caster (deal_flat_damage
  -- source arg) so kills log and message normally.  Called from mom_hooks' cast
  -- handler; the STAMINA cost + attunement pressure ride on the marker spell/events.
  function U.mass_hydrothermosis(you)
    if not you then return end
    guarded("mass_hydrothermosis", function()
      local lvl = math.max(m.spell_level(you, "pyrokinetic_aoe_blast"), 0)
      local mod_p = m.power_modifiers(you)
      local dmin = (lvl * 4 + 80) * mod_p
      local dmax = (lvl * 5.3 + 140) * mod_p
      local psi_null = SpeciesTypeId.new("PSI_NULL")
      local hit = 0
      for _, mon in ipairs(gapi.get_all_monsters()) do
        if mon:get_hp() > 0 and mon.friendly == 0 then
          local p = mon:get_pos_ms()
          if you:sees(p) and not mon:in_species(psi_null) then
            U.deal_flat_damage(mon, U.rng(U.round(dmin), U.round(dmax)), you)
            hit = hit + 1
          end
        end
      end
      if hit == 0 then
        U.msg(you, "You reach out to boil the fluids around you -- but nothing "
          .. "in sight has any to boil.", MsgType.neutral, nil)
      end
      return true
    end, nil)
  end

  -- Nether Attunement meter (spec Rev 3, amended QA round 3): vitamin-scale
  -- char var + derived effect-intensity band; both live in mom_math so the
  -- pilot path (mom_util.channel_surge) can reach them without U.
  function U.attunement_set(who, v)
    guarded("attunement_set", function()
      m.attunement_set(who, v)
      return true
    end, nil)
  end

  -- ---- traits
  function U.set_mutation(who, trait)
    guarded("set_mutation:" .. trait, function()
      who:set_mutation(MutationBranchId.new(trait))
      return true
    end, nil)
  end

  function U.unset_mutation(who, trait)
    guarded("unset_mutation:" .. trait, function()
      local mid = MutationBranchId.new(trait)
      if who:has_trait(mid) then
        who:unset_mutation(mid)
      end
      return true
    end, nil)
  end

  -- ---- inventory removal
  -- DDA `u_remove_item_with`: destroy every carried item of this type. Used by
  -- the maintained powers that hand you a summoned tool (lifting jack, hacking
  -- interface, fire tool, radio, hammerhand, torch/weld, astral cord, rad
  -- sensor) to take it back when concentration ends -- so while this was a
  -- no-op stub those items piled up in inventory forever.
  --
  -- `all_items(false)` flattens worn garments, their contents, and the wielded
  -- weapon, so a force_equip'd tool is reachable -- but the three locations need
  -- three DIFFERENT removals, and getting that wrong is not a soft failure.
  --
  -- ⚠ Character:remove_item is INVENTORY-ONLY -- "The `Item` must be in the
  -- inventory, neither wielded nor worn" (catalua_bindings_creature.cpp:1071).
  -- It is not merely refused for worn/wielded items, it is memory-unsafe:
  -- location_inventory::remove_item (inventory.cpp:1380) calls
  -- it->remove_location() FIRST, unconditionally, and only then discovers the
  -- item is not in the inventory -- so a still-worn item is left with a dangling
  -- location -- and returns detached_ptr<item>( &inv.remove_item( it ) ), which
  -- on the miss path wraps null_item_reference() (inventory.cpp:669, the
  -- "Tried to remove a item not in inventory." debugmsg).  That is a STATIC
  -- singleton -- the game's global "no item" sentinel -- handed to Lua as an
  -- owning pointer, so the next GC frees it out from under the whole game.
  -- This hard-crashed a playtest (2026-07-25); the earlier version of this
  -- function fed it every worn Lifting Field tier.  Route by location instead,
  -- and NEVER fall back to remove_item when a targeted removal fails.
  --
  -- Worn: remove_worn -> Character::takeoff -> can_takeoff, which refuses
  -- NO_TAKEOFF (character.cpp:3566).  The bridge-managed auras therefore carry
  -- NO_TAKEOFF as an INSTANCE flag only (see port_items.py), and item::unset_flag
  -- clears item_tags, so the clear below works on those and is a harmless no-op
  -- on anything else.  A type-level NO_TAKEOFF would still refuse -- correctly,
  -- since destroying it is not something this function can safely do.
  --
  -- Wielded: unwield() first (it stows or drops), then the item is reachable as
  -- an ordinary inventory item on the next pass -- same dance as consume_one in
  -- mom_hooks.lua, which hit this same debugmsg during playtest round 2.
  --
  -- One removal per pass, re-reading all_items each time: every removal
  -- invalidates the pointers in the previous snapshot.
  local NO_TAKEOFF_FLAG = "NO_TAKEOFF"

  function U.remove_item_with(who, item_id)
    return guarded("remove_item_with:" .. item_id, function()
      local removed = false
      for _ = 1, 20 do
        local target, where
        for _, it in ipairs(who:all_items(false)) do
          local okt, t = pcall(function() return it:get_type():str() end)
          if okt and t == item_id then
            target = it
            local okw, worn = pcall(function() return who:is_worn(it) end)
            local okd, wielded = pcall(function() return who:is_wielding(it) end)
            -- a FAILED read must not be treated as "loose in inventory" --
            -- that is precisely the call that corrupts memory.  Bail instead.
            if not (okw and okd) then where = "unknown"
            elseif worn then where = "worn"
            elseif wielded then where = "wielded"
            else where = "inv" end
            break
          end
        end
        if not target then break end

        if where == "inv" then
          -- returned detached_ptr intentionally discarded: dropping ownership
          -- is what destroys the item
          local ok = pcall(function() who:remove_item(target) end)
          if not ok then
            once("rmi|" .. item_id, "remove_item failed for " .. item_id)
            break
          end
          removed = true
        elseif where == "worn" then
          local ok, gone = pcall(function()
            target:unset_flag(JsonFlagId.new(NO_TAKEOFF_FLAG))
            return who:remove_worn(target) ~= nil
          end)
          if not (ok and gone) then
            once("rmw|" .. item_id,
                 "could not remove worn " .. item_id ..
                 " (type-level NO_TAKEOFF?); leaving it on")
            break
          end
          removed = true
        elseif where == "wielded" then
          local ok, unwielded = pcall(function() return who:unwield() end)
          if not (ok and unwielded) then
            once("rmu|" .. item_id, "unwield refused for " .. item_id)
            break
          end
          -- do NOT count this as removed; the next pass finds it stowed (or it
          -- was dropped to the floor, in which case it is off the character)
        else
          once("rmq|" .. item_id,
               "could not locate " .. item_id .. " (is_worn/is_wielding failed)")
          break
        end
      end
      return removed
    end, false)
  end

  -- ---- integrated armor (trait -> worn item)
  -- BN has NO `integrated_armor` mutation field (zero hits in CBN/src), so a DDA
  -- trait that works by granting a worn item arrives completely inert -- the
  -- trait exists, the item exists, and nothing ever puts one on the other.
  -- port_traits.py reports the dropped key; each such trait needs an entry here.
  --
  -- Why a periodic sweep rather than an on-gain hook: these traits are handed out
  -- at chargen by professions (before any Lua hook the mod owns has a character to
  -- act on) and can also arrive mid-run from a crystal awakening. A cheap sweep
  -- covers both and self-heals if the item is somehow lost, which an event hook
  -- would not.
  local INTEGRATED_ARMOR = {
    -- Photon Regulation. Carries quality GLARE 2 (weld without goggles) and the
    -- SUN_GLASSES flag; the fork's night_vision_range override already lives on
    -- the trait itself, so only the glare half needs the item. PERSONAL layer, so
    -- it does not fight actual eyewear.
    { trait = "PHOTO_EYES", item = "integrated_photo_eyes" },
  }
  -- Lifting Field: 30 AURA-layer relic tiers, each carrying the CARRY_WEIGHT
  -- enchantment for its spell level (port_items.py builds the items and
  -- gen_lifting_field_enchantments.json). The power's own switcher grants
  -- exactly one TELEKINETIC_LIFTER_<n> marker trait, so the generic sweep below
  -- both wears the matching tier AND strips the others -- which is what makes
  -- levelling up mid-cast swap tiers cleanly, and what removes the aura when
  -- concentration ends and the trait goes away. BN's ONLY_ONE blocks duplicates
  -- of one id but NOT two different tiers (it compares typeId), so the
  -- trait-absent removal pass is what actually keeps a single tier worn.
  for n = 1, 30 do
    INTEGRATED_ARMOR[#INTEGRATED_ARMOR + 1] = {
      trait = "TELEKINETIC_LIFTER_" .. n,
      item = "telekinetic_container_" .. n,
      transient = true,   -- remove the item as soon as the trait is gone
    }
  end
  local IA_PERIOD = 60          -- turns between sweeps; the check is 1 has_trait
  local IA_MAX_FAILS = 3        -- stop retrying a wear that keeps refusing
  local ia_next_turn = 0
  local ia_fails = {}
  -- item id -> INTEGRATED_ARMOR entry, for items confirmed worn RIGHT NOW.
  -- Only `transient` entries land here; it is what lets teardown run every turn
  -- without paying for a full sweep (see integrated_armor_maintain).  Session
  -- state only -- a reload starts empty and the first periodic sweep repopulates
  -- it, so at worst a teardown across a save/load waits one period as before.
  local ia_worn = {}

  -- true / false / nil, where nil means "couldn't determine" -- never treat a
  -- failed read as "not worn", or we would spawn a duplicate every sweep.
  --
  -- `stamp` also pins NO_TAKEOFF onto the worn instance.  The `transient` aura
  -- tiers cannot carry it at the type level (a type flag is unclearable, so the
  -- bridge could never take the aura back off -- see port_items.py and
  -- U.remove_item_with), but the player still must not be able to peel a
  -- conjured field off by hand: without it, a manual takeoff would leave the
  -- item loose in the pack while the trait is still up, and the next sweep would
  -- see "not worn" and conjure a SECOND one.  Re-stamped every sweep, so it also
  -- self-heals on a save made before this fix.
  -- One-shot diagnostic for the aura items, logged the first time each one is
  -- confirmed worn.  These deliver their whole effect through
  -- relic_data.passive_effects, and that chain has four independent links that
  -- all fail SILENTLY -- no load error, no runtime error, just an item that does
  -- nothing (which is exactly how Lifting Field spent weeks inert before, and
  -- how it was reported again on 2026-07-25):
  --   relic?  -- item::get_enchantments() returns an empty static unless
  --             is_relic(), i.e. unless relic_data survived onto the INSTANCE.
  --             Note item::deserialize defaults relic_data to nullptr when the
  --             save has no entry (savegame_json.cpp:2797), so an instance
  --             carried over from a save made when the item was a TOOL is a
  --             non-relic forever.
  --   ench=N  -- 0 means passive_effects didn't resolve (a `{"id": ...}` entry is
  --             looked up eagerly at item-load time by relic::load, so the
  --             enchantment has to be loaded before the item that names it).
  --   cap     -- Character::weight_capacity() raw units, to compare against the
  --             same line with the aura off.
  -- Cheap: fires once per item id per session, and only for items the bridge
  -- actually manages.
  local function ia_probe(who, it, id)
    local ok, msg = pcall(function()
      local relic = it:is_relic()
      local n = 0
      local oke, enchs = pcall(function() return it:get_enchantments() end)
      if oke and enchs then for _ in ipairs(enchs) do n = n + 1 end end
      return string.format("%s worn: relic=%s ench=%d cap=%s",
                           id, tostring(relic), n,
                           tostring(who:get_weight_capacity()))
    end)
    once("iaprobe|" .. id, ok and msg or ("probe failed for " .. id))
  end

  local function wears_itype(who, id, stamp)
    local ok, worn = pcall(function() return who:get_worn_items() end)
    if not ok or not worn then return nil end
    for _, it in ipairs(worn) do
      local okt, t = pcall(function() return it:get_type():str() end)
      if okt and t == id then
        if stamp then
          pcall(function() it:set_flag(JsonFlagId.new("NO_TAKEOFF")) end)
          ia_probe(who, it, id)
        end
        return true
      end
    end
    return false
  end

  function U.integrated_armor_maintain(who)
    if not who then return end
    local turn = gapi.current_turn():to_turn()

    -- FAST TEARDOWN, every turn, before the IA_PERIOD gate.
    --
    -- The periodic sweep is coarse (IA_PERIOD) because it walks all 31 entries --
    -- fine for *acquiring* an item (chargen professions, a mid-run crystal
    -- awakening: nobody notices a minute's delay on something permanent), but
    -- wrong for teardown, where the player watches a conjured field linger for up
    -- to IA_PERIOD turns after they stop concentrating. Reported from playtest
    -- 2026-07-25: "it didn't disappear right away when I ended the power".
    --
    -- Teardown doesn't need the sweep: only entries we have already confirmed
    -- worn can need removing, and at most one lifter tier is ever worn. So
    -- ia_worn tracks those, and this checks just their traits -- 1 has_trait
    -- while a field is up, zero otherwise, against 31 for a full sweep.
    for item_id, e in pairs(ia_worn) do
      local okt, has = pcall(function()
        return who:has_trait(MutationBranchId.new(e.trait))
      end)
      -- a FAILED read must never destroy gear -- only act on a definite false
      if okt and not has then
        U.remove_item_with(who, item_id)
        ia_worn[item_id] = nil
        ia_fails[item_id] = nil
        -- Clearing a key mid-`pairs` is defined behavior in Lua (adding one is
        -- not); we only ever clear here.
        --
        -- A trait vanishing is EITHER the power ending or it levelling into a
        -- different tier, and this loop can't tell which. Opening the period gate
        -- makes the full sweep below run in THIS same call, so a tier swap wears
        -- its replacement without ever leaving the player aura-less (and short
        -- the carry bonus). On a genuine power-end the sweep just finds nothing
        -- and costs one cycle of trait reads.
        ia_next_turn = 0
      end
    end

    if turn < ia_next_turn then return end
    ia_next_turn = turn + IA_PERIOD
    for _, e in ipairs(INTEGRATED_ARMOR) do
      local okt, has = pcall(function()
        return who:has_trait(MutationBranchId.new(e.trait))
      end)
      -- `transient` entries belong to a maintained power: the trait going away
      -- means the power ended (or levelled into a different tier), so the item
      -- has to go with it or it lingers forever -- exactly the bug that left
      -- lifting jacks in inventory. Only remove when the trait read SUCCEEDED
      -- (okt) and came back false; a failed read must never destroy gear.
      if e.transient and okt and not has then
        if wears_itype(who, e.item) == true then
          U.remove_item_with(who, e.item)
          ia_fails[e.item] = nil
        end
        ia_worn[e.item] = nil
      elseif (ia_fails[e.item] or 0) < IA_MAX_FAILS then
        -- stamp=true: re-pins NO_TAKEOFF whenever the item is already worn
        local already = wears_itype(who, e.item, true)
        -- Register for fast teardown only once the item is CONFIRMED worn and
        -- only for transient entries. `already == nil` means the worn-list read
        -- failed, which must not be recorded either way.
        if e.transient and okt and has and already == true then
          ia_worn[e.item] = e
        end
        if okt and has and already == false then
          -- wear_detached takes ownership: on failure the detached item is
          -- destroyed with it, so a refused wear leaks nothing.
          local worn_ok = guarded("integrated_armor:" .. e.item, function()
            local det = gapi.create_item(ItypeId.new(e.item), 1)
            return who:wear_detached(det, false) and true or false
          end, false)
          if worn_ok then
            ia_fails[e.item] = nil
            -- pin NO_TAKEOFF on the new instance, and register the freshly worn
            -- transient item for fast teardown without waiting a whole period
            if wears_itype(who, e.item, true) == true and e.transient then
              ia_worn[e.item] = e
            end
          else
            ia_fails[e.item] = (ia_fails[e.item] or 0) + 1
            if ia_fails[e.item] >= IA_MAX_FAILS then
              once("ia|" .. e.item,
                   "integrated armor " .. e.item .. " could not be worn for " ..
                   e.trait .. "; giving up this session")
            end
          end
        end
      end
    end
  end

  -- ---- spells
  local function km_of(who) return who:get_magic() end

  function U.set_spell_level(who, spell_id, v)
    v = U.round(v)
    local sid = SpellTypeId.new(spell_id)
    -- Guard against spell ids the port cut: learn_spell/get_spell on an unknown
    -- id fires C++ debug popups ("Tried to learn invalid spell").  is_valid()
    -- only checks factory membership (no debugmsg); pcall so an older binding
    -- that lacks it degrades to the previous behavior instead of erroring.
    local ok_valid, valid = pcall(function() return sid:is_valid() end)
    if ok_valid and not valid then
      gdebug.log_info("MoM-BN: set_spell_level skipped unknown spell " .. spell_id)
      return
    end
    local km = km_of(who)
    guarded("set_spell_level:" .. spell_id, function()
      if v < 0 then
        if km:knows_spell(sid) then km:forget_spell(sid) end
        return true
      end
      if not km:knows_spell(sid) then km:learn_spell(sid, who, true) end
      km:get_spell(sid):set_level(v)
      return true
    end, nil)
  end

  function U.set_spell_exp(who, spell_id, v)
    local sid = SpellTypeId.new(spell_id)
    local km = km_of(who)
    if km:knows_spell(sid) then
      km:get_spell(sid):set_exp(U.round(v))
    end
  end

  function U.spell_difficulty(spell_id)
    return guarded("spell_difficulty", function()
      return SpellTypeId.new(spell_id):obj().difficulty
    end, 0)
  end

  -- u_roll_remainder / npc_roll_remainder (EFFECT_ON_CONDITION.md): grant one
  -- random entry from `ids` that `who` doesn't already have, matching DDA's
  -- f_roll_remainder (npctalk.cpp) -- spells are granted at level 1, traits
  -- via set_mutation. Only "mutation"/"spell" are used anywhere in the ported
  -- corpus (nether attunement's negative-trait roll; wild-talent random
  -- knacks; the Red Safari clair/vita research unlocks).
  function U.roll_remainder(who, ids, kind)
    return guarded("roll_remainder:" .. kind, function()
      local not_had = {}
      for _, id in ipairs(ids) do
        if kind == "mutation" then
          if not who:has_trait(MutationBranchId.new(id)) then
            not_had[#not_had + 1] = id
          end
        elseif kind == "spell" then
          if not km_of(who):knows_spell(SpellTypeId.new(id)) then
            not_had[#not_had + 1] = id
          end
        end
      end
      if #not_had == 0 then return false end
      local pick = not_had[gapi.rng(1, #not_had)]
      if kind == "mutation" then
        who:set_mutation(MutationBranchId.new(pick))
      elseif kind == "spell" then
        U.set_spell_level(who, pick, 1)
      end
      return true
    end, false)
  end

  -- <spell_name:X> message tag.  BN's spell_type binding has no .name
  -- accessor (unlike mutation_branch below), so gen_eoc's SPELL_NAMES table
  -- (built from the same JSON "name" field at transpile time) is the only
  -- source for this; unknown ids fall back to a prettified id.
  function U.spell_name(id)
    if not id or id == "" then return "" end
    local nm = mod.spell_names and mod.spell_names[id]
    if nm then return nm end
    return (id:gsub("_", " "))
  end

  -- <trait_name:X> / <trait_description:X> message tags.
  function U.trait_name(id)
    if not id or id == "" then return "" end
    return guarded("trait_name:" .. id, function()
      return MutationBranchId.new(id):obj():name()
    end, id)
  end

  function U.trait_description(id)
    if not id or id == "" then return "" end
    return guarded("trait_description:" .. id, function()
      return MutationBranchId.new(id):obj():desc()
    end, id)
  end

  -- Spell usertype ctor: Spell.new(SpellTypeId, level); cast(source, target)
  -- Spells that teleport the caster to a chosen tile (DDA's TARGET_TELEPORT
  -- flag, which BN lacks).  mom_eoc registers per-spell {msg, range=fn(you),
  -- scatter=fn(you)} entries; cast_spell routes them to U.teleport_to instead
  -- of Spell:cast.
  U.teleport_spells = {}

  -- Spells with DDA's "pickup" effect (telekinetic item retrieval), which BN
  -- lacks entirely — the ported defs carry effect:"none", BN's invalid-effect
  -- debugmsg handler, so these MUST be intercepted before Spell:cast.
  -- Upstream opens an area loot menu; our adaptation: pick a tile in range,
  -- everything on it is dragged to the caster's feet.  mom_eoc registers
  -- per-spell {msg, range=fn(you)} entries.
  U.pickup_spells = {}

  -- Pull every item off `from` onto the caster's tile.  item_stack:items()
  -- is the binding's frozen copy — mutating the live stack mid-iteration is
  -- undefined.  add_item returns the detached item back on failure (tile
  -- can't take it) -> put those back where they came from.
  function U.pull_items_to(who, from)
    return guarded("pull_items_to", function()
      local map = gapi.get_map()
      local dest = who:get_pos_ms()
      local frozen = map:get_items_at(from):items()
      local moved = 0
      for _, it in ipairs(frozen) do
        local d = map:detach_item_at(from, it)
        if d then
          local leftover = map:add_item(dest, d)
          if leftover then
            map:add_item(from, leftover)
          else
            moved = moved + 1
          end
        end
      end
      if moved > 0 then
        U.msg(who, "Your far hand drags everything over to you.", MsgType.good)
      else
        U.msg(who, "There is nothing there to pull.", MsgType.neutral)
      end
      return true
    end, nil)
  end

  -- Square (Chebyshev) distance, the games' rl_dist metric.
  function U.dist(a, b)
    return math.max(math.abs(a.x - b.x), math.abs(a.y - b.y),
                    math.abs(a.z - b.z))
  end

  -- u_knockback: push `target` `distance` tiles away from `source_pos` (a
  -- Tripoint), one tile at a time via the bound Creature:knock_back_to --
  -- there's no Lua binding for the single-step "move 1 tile away from a
  -- point" helper itself (Creature::knock_back_from, C++-only), so that
  -- math is reproduced here; knock_back_to itself already handles
  -- wall/creature bounces (its own hardcoded impact stun+damage, per
  -- monster.cpp/character.cpp) once it gets a destination tile. Stops early
  -- if a step doesn't move the target (bounced off something). `dam_mult`
  -- is accepted for call-site parity with the DDA EOC verb but unused: the
  -- only place that honors it (game::knockback) isn't bound to Lua, and
  -- knock_back_to's own built-in impact damage is close enough (degrade,
  -- don't crash, over exact fidelity).
  function U.knockback(target, source_pos, distance, stun, dam_mult)
    if not target or not source_pos then return end
    distance = U.round(distance)
    if distance > 0 then
      guarded("knockback", function()
        for _ = 1, distance do
          local from = target:get_pos_ms()
          local dx, dy = 0, 0
          if source_pos.x < from.x then dx = 1 elseif source_pos.x > from.x then dx = -1 end
          if source_pos.y < from.y then dy = 1 elseif source_pos.y > from.y then dy = -1 end
          if dx == 0 and dy == 0 then break end
          local to = target:get_pos_ms()
          to.x = to.x + dx
          to.y = to.y + dy
          target:knock_back_to(to)
          local now = target:get_pos_ms()
          if now.x == from.x and now.y == from.y then break end
        end
        return true
      end, nil)
    end
    if stun and stun > 0 then
      U.add_effect(target, "stunned", TimeDuration.from_turns(U.round(stun)))
    end
  end

  -- u_query_tile: interactive tile pick via the look-around UI.
  -- Returns a tripoint_bub_ms, or nil on cancel.  gapi.look_around() can't
  -- constrain the cursor, so the prompt states the range up front and an
  -- out-of-range pick RE-OPENS the picker instead of failing the cast
  -- (QA round 3: committing a pick and then erroring is hostile UX).
  function U.query_tile(who, opts)
    opts = opts or {}
    if not U.is_avatar(who) then return nil end
    return guarded("query_tile", function()
      local r = nil
      if opts.range then r = math.max(1, math.floor(opts.range + 0.5)) end
      local prompt = (opts.msg and opts.msg ~= "") and opts.msg or "Choose target."
      if r then prompt = prompt .. " (range " .. r .. " — Esc cancels)" end
      while true do
        gapi.add_msg(MsgType.info, prompt)
        local pos = gapi.look_around()
        if not pos then return nil end
        if not r or U.dist(who:get_pos_ms(), pos) <= r then return pos end
        gapi.add_msg(MsgType.bad,
          "That is out of range (max " .. r .. " tiles) — pick a closer tile or press Esc.")
      end
    end, nil)
  end

  -- run_eoc_selector: uilist-backed option menu.  Returns the 1-based index
  -- of the chosen entry, or nil on cancel.
  -- Substitute DDA's <u_val:X> / <global_val:X> / <context_val:X> variable
  -- interpolation tags with their stored values (used in menu labels and
  -- messages).  who = the u-talker (for u_val); ctx = the EOC context table.
  -- Unknown/empty vars collapse to "" rather than showing the raw tag.
  -- <spell_name:X>/<trait_name:X>/<trait_description:X> run as a SECOND pass
  -- so nested forms like <spell_name:<u_val:latest_studied_power_name>>
  -- resolve the inner var tag to a plain id first.
  function U.interp(who, ctx, text)
    if type(text) ~= "string" or text == "" then return text end
    text = text:gsub("<u_val:([%w_]+)>", function(k)
      return (who and V.ustr(who, k)) or "" end)
    text = text:gsub("<global_val:([%w_]+)>", function(k)
      return V.gstr(k) or "" end)
    text = text:gsub("<context_val:([%w_]+)>", function(k)
      local v = ctx and ctx[k]
      return v ~= nil and tostring(v) or "" end)
    text = text:gsub("<spell_name:([%w_]+)>", function(id)
      return U.spell_name(id) end)
    text = text:gsub("<trait_name:([%w_]+)>", function(id)
      return U.trait_name(id) end)
    text = text:gsub("<trait_description:([%w_]+)>", function(id)
      return U.trait_description(id) end)
    -- <u_spell_level:X>: recipe-description tag (DDA crafting-menu convention,
    -- carried over verbatim from MoM's source JSON).  -1 (mom_math's
    -- "unknown/not learned" convention) prints as-is; that's fine, it reads
    -- clearly enough in context ("Current Power Level: -1").
    text = text:gsub("<u_spell_level:([%w_]+)>", function(id)
      return tostring(guarded("spell_level:" .. id,
        function() return m.spell_level(who, id) end, -1)) end)
    return text
  end

  function U.select_menu(title, names, descs, who, ctx)
    return guarded("select_menu", function()
      local ui = UiList.new()
      if title and title ~= "" then ui:title(U.interp(who, ctx, title)) end
      if descs then ui:desc_enabled(true) end
      for i, nm in ipairs(names) do
        local label = U.interp(who, ctx, nm)
        if descs and descs[i] and descs[i] ~= "" then
          ui:add_w_desc(i, label, U.interp(who, ctx, descs[i]))
        else
          ui:add(i, label)
        end
      end
      local r = ui:query()
      if r and r >= 1 then return r end
      return nil
    end, nil)
  end

  -- string_input verb: prompt for free text (destination names etc.), returning
  -- the entry or `default` if cancelled/blank.  PopupInputStr = string_input_popup.
  function U.query_string(title, desc, default)
    return guarded("query_string", function()
      local p = PopupInputStr.new()
      if title and title ~= "" then p:title(title) end
      if desc and desc ~= "" then p:desc(desc) end
      local s = p:query_str()
      if not s or s == "" then return default or "" end
      return s
    end, default or "")
  end

  -- run_eoc_selector: show one entry per target EOC and return the chosen id
  -- (nil on cancel/empty).  hide=true drops entries whose target EOC condition
  -- C[id] is false (DDA hide_failing) — that's how Gateway hides locked/unset
  -- destination slots instead of showing dead options.
  function U.select_eoc_menu(title, ids, names, descs, who, npc, ctx, hide)
    return guarded("select_eoc_menu", function()
      local C = mod.eoc_conds or {}
      local fids, fnames, fdescs = {}, {}, {}
      for i = 1, #ids do
        local ok = true
        if hide and C[ids[i]] then
          local okc, res = pcall(C[ids[i]], who, npc, ctx)
          ok = okc and res and true or false
        end
        if ok then
          fids[#fids + 1] = ids[i]
          fnames[#fnames + 1] = names[i]
          if descs then fdescs[#fdescs + 1] = descs[i] end
        end
      end
      if #fids == 0 then return nil end
      local sel = U.select_menu(title, fnames, descs and fdescs or nil, who, ctx)
      if not sel then return nil end
      return fids[sel]
    end, nil)
  end

  -- Directed push/pull without a spell: step the target one tile at a time
  -- with Creature:knock_back_to (the engine handles collision damage and
  -- stopping).  dist > 0 pushes away from the caster, dist < 0 pulls toward
  -- — the same sign convention as BN's directed_push spell effect, whose
  -- damage field we can't drive from a runtime var.
  function U.shove(target, caster, dist)
    return guarded("shove", function()
      local steps = math.abs(U.round(dist))
      local toward = dist < 0
      for _ = 1, steps do
        local tp = target:get_pos_ms()
        local cp = caster:get_pos_ms()
        if toward and U.dist(tp, cp) <= 1 then break end
        local sx = (tp.x > cp.x and 1) or (tp.x < cp.x and -1) or 0
        local sy = (tp.y > cp.y and 1) or (tp.y < cp.y and -1) or 0
        if toward then sx, sy = -sx, -sy end
        if sx == 0 and sy == 0 then break end
        target:knock_back_to(TripointBubMs.new(tp.x + sx, tp.y + sy, tp.z))
        local np = target:get_pos_ms()
        if np.x == tp.x and np.y == tp.y and np.z == tp.z then break end
      end
      return true
    end, nil)
  end

  -- u_location_variable {"monster": ""}: the location of a random monster
  -- within [min_r, max_r] tiles of who, or nil (Galvanic Aura's zap picker).
  function U.find_monster_loc(who, min_r, max_r)
    return guarded("find_monster_loc", function()
      local origin = who:get_pos_ms()
      local lo = math.max(0, U.round(min_r or 0))
      local hi = math.max(lo, U.round(max_r or 0))
      local candidates = {}
      for _, mon in ipairs(gapi.get_all_monsters()) do
        local d = U.dist(origin, mon:get_pos_ms())
        if d >= lo and d <= hi then
          candidates[#candidates + 1] = mon:get_pos_ms()
        end
      end
      if #candidates == 0 then return nil end
      return candidates[gapi.rng(1, #candidates)]
    end, nil)
  end

  -- Like find_monster_loc, but only considers monsters `who` has clear
  -- line-of-sight to via Creature:sees() -- BN's gun/vision LOS: it passes
  -- through open air (INCLUDING to another z-level, e.g. down a stair-hole or
  -- up from under a tree/roof) but is blocked by walls, floors and ceilings.
  -- Returns the chosen Monster itself (caller needs its z to decide delivery),
  -- or nil.  This is the "spells strike like guns, not like spears" primitive:
  -- wall/floor blocking and cross-z clear-air reach both fall out of sees().
  function U.find_visible_monster(who, min_r, max_r)
    return guarded("find_visible_monster", function()
      local origin = who:get_pos_ms()
      local lo = math.max(0, U.round(min_r or 0))
      local hi = math.max(lo, U.round(max_r or 0))
      local candidates = {}
      for _, mon in ipairs(gapi.get_all_monsters()) do
        if mon:get_hp() > 0 then
          local p = mon:get_pos_ms()
          local d = U.dist(origin, p)
          if d >= lo and d <= hi and who:sees(p) then
            candidates[#candidates + 1] = mon
          end
        end
      end
      if #candidates == 0 then return nil end
      return candidates[gapi.rng(1, #candidates)]
    end, nil)
  end

  -- Faithful port of MonsterGroupManager::GetResultFromGroup's weighted draw
  -- (mongroup.cpp): roll rng(1, freq_total) and walk entries subtracting each
  -- .frequency until one is >= the roll.  Note freq_total defaults to 1000 even
  -- when the entry weights sum higher, so tail entries past the 1000 mark are
  -- unreachable -- same as vanilla.  Time/condition-gated entries are not
  -- modelled (the psionic breach groups have none).  Returns an mtype_id.
  local function weighted_group_pick(grp)
    local entries = grp.monsters
    local total = grp.freq_total
    if total == nil or total < 1 then total = 1000 end
    local roll = gapi.rng(1, total)
    for i = 1, #entries do
      local e = entries[i]
      if e.frequency >= roll then return e.name end
      roll = roll - e.frequency
    end
    return grp.defaultMonster
  end

  -- u_spawn_monster: place `count` monsters within `radius` of the summoner.
  -- DDA's min_radius/max_radius annulus is approximated by place_monster_around
  -- (a 0..radius disc; the inner-radius exclusion is dropped, cosmetic).  BN
  -- exposes no summon-lifespan setter, so summoned mobs persist until the
  -- power's disappear EOC (or their DISAPPEAR death_function) removes them.
  -- alpha (summoner_is_alpha) -> make_friendly (player faction).
  -- group=true means mon_id is a monstergroup id; each spawn draws a fresh
  -- weighted member (mixing the summoned pack, exactly like a native group).
  function U.spawn_monster(who, mon_id, count, radius, alpha, group)
    who = who or gapi.get_avatar()
    count = math.floor((tonumber(count) or 0) + 0.5)
    if count < 1 then return end
    radius = math.max(1, U.round(radius or 1))
    guarded("spawn_monster:" .. tostring(mon_id), function()
      local center = who:get_pos_ms()
      local mid, grp
      if group then
        grp = monster_groups.get_group(MonsterGroupId.new(mon_id))
      else
        mid = MonsterTypeId.new(mon_id)
      end
      for _ = 1, count do
        local this_mid = group and weighted_group_pick(grp) or mid
        if this_mid ~= nil then
          local mon = gapi.place_monster_around(this_mid, center, radius)
          if mon ~= nil and alpha then mon:make_friendly() end
        end
      end
      return true
    end, nil)
  end

  function U.has_field(pos, field_id)
    if not pos then return false end
    return guarded("has_field:" .. field_id, function()
      return gapi.get_map():has_field_at(pos, FieldTypeId.new(field_id))
    end, false)
  end

  -- u_set_field: BN map:add_field_at is additive on an existing field of the
  -- same type (matching DDA u_set_field, which is how Intensify Flames grows
  -- an existing fire with intensity 1).
  function U.set_field(pos, field_id, intensity, radius)
    if not pos then return end
    guarded("set_field:" .. field_id, function()
      local map = gapi.get_map()
      local fid = FieldTypeId.new(field_id)
      local r = math.max(0, U.round(radius or 0))
      local inten = math.max(1, U.round(intensity or 1))
      for dx = -r, r do
        for dy = -r, r do
          map:add_field_at(TripointBubMs.new(pos.x + dx, pos.y + dy, pos.z),
                           fid, inten, TimeDuration.from_turns(0))
        end
      end
      return true
    end, nil)
  end

  -- Quell Fire (fork repair, 2026-07-24).  BN can do neither half of this from
  -- data: no spell effect removes a field (spell::create_field only ever ADDS),
  -- and ter_furn_transform has no `field` support at all -- which is why the
  -- ported ter_pyrokin_quell_fire transform silently did nothing.  Lua CAN
  -- remove fields, but NO BN Lua hook carries a spell's target tile, so the
  -- spell paints the invisible relay field fd_mom_quench_marker over its aimed
  -- AoE and we sweep for the paint here.  See strip_spell_math's
  -- _rewrite_quell_fire block for the full mechanism.
  --
  -- `who` is the caster and may be a Character OR a monster -- mom_hooks' two
  -- effect-added hooks share one handler table, so the flamebreaker triffid
  -- lands in here too.  Order matters: strip the caster's own `onfire` first
  -- (that half used to be `effect: "none"`, i.e. a bare debugmsg every cast),
  -- then quench the painted tiles.  Returns the number of tiles put out.
  --
  -- RADIUS bounds the scan, it does not bound the power: the paint only exists
  -- where the spell actually landed, so a generous box just guarantees we find
  -- all of it (player reach is max_range 15 + max_aoe 8 = 23).  Clamped to the
  -- reality bubble so a cast right after a long teleport can't walk off the map.
  function U.quell_fire(who, radius)
    if not who then return 0 end
    guarded("quell_fire_self", function()
      who:remove_effect(EffectTypeId.new("onfire"))
      return true
    end, nil)
    return guarded("quell_fire_sweep", function()
      local map = gapi.get_map()
      local mark = FieldTypeId.new("fd_mom_quench_marker")
      local fire = FieldTypeId.new("fd_fire")
      local pos = who:get_pos_ms()
      local r = math.max(0, U.round(radius or 24))
      local lim = map:get_map_size() - 1
      local x0, x1 = math.max(0, pos.x - r), math.min(lim, pos.x + r)
      local y0, y1 = math.max(0, pos.y - r), math.min(lim, pos.y + r)
      local n = 0
      for x = x0, x1 do
        for y = y0, y1 do
          local p = TripointBubMs.new(x, y, pos.z)
          if map:get_field_int_at(p, mark) > 0 then
            if map:get_field_int_at(p, fire) > 0 then
              map:remove_field_at(p, fire)
              n = n + 1
            end
            map:remove_field_at(p, mark)
          end
        end
      end
      return n
    end, 0)
  end

  -- Teleport who to pos: the exact tile when scatter is 0, else a random
  -- passable, unoccupied tile within scatter of it.
  function U.teleport_to(who, pos, scatter)
    scatter = math.max(0, U.round(scatter or 0))
    return guarded("teleport_to", function()
      local map = gapi.get_map()
      local candidates = {}
      for dx = -scatter, scatter do
        for dy = -scatter, scatter do
          local p = TripointBubMs.new(pos.x + dx, pos.y + dy, pos.z)
          if map:get_ter_at(p):obj():get_movecost() > 0
              and not gapi.get_creature_at(p) then
            candidates[#candidates + 1] = p
          end
        end
      end
      if #candidates == 0 then
        U.msg(who, "The destination is blocked.", MsgType.bad)
        return false
      end
      local dest = candidates[gapi.rng(1, #candidates)]
      if U.is_avatar(who) then
        -- setpos on the avatar is ignored by the game loop; g->place_player
        -- (gapi.place_player_local_at) handles map shift & visibility.
        gapi.place_player_local_at(dest)
      else
        who:set_pos_ms(dest)
      end
      return true
    end, false)
  end

  -- ---- saved-location teleport (Loci, Gateway, Relocation) ----------------
  -- DDA's u_location_variable saves a spot, then u_teleport/npc_teleport recalls
  -- to it — possibly after wandering off the map, so the spot is persisted in
  -- ABSOLUTE ms coords (survives reality-bubble shifts), not the ephemeral ctx
  -- bub_ms the transpiler uses for intra-EOC handoff.  Stored as "x,y,z" in the
  -- char var store (or globals) so a later cast can read it back.
  -- store_who nil => save to the global var store (global_val locations).
  function U.save_location(store_who, name, pos)
    if not pos then return end
    guarded("save_location:" .. name, function()
      local abs = gapi.bub_to_abs(pos)
      local s = abs.x .. "," .. abs.y .. "," .. abs.z
      if store_who then V.usets(store_who, name, s) else V.gset(name, s) end
      return true
    end, nil)
  end

  -- store_who nil => read from the global var store (global_val locations).
  local function read_saved_abs(store_who, name)
    return guarded("read_location:" .. name, function()
      local s = store_who and V.ustr(store_who, name) or V.gstr(name)
      if not s or s == "" then return nil end
      local x, y, z = tostring(s):match("(-?%d+),(-?%d+),(-?%d+)")
      if not x then return nil end
      return coords.tripoint_abs_ms(tonumber(x), tonumber(y), tonumber(z))
    end, nil)
  end

  -- Move a creature to an absolute-ms coord.  The avatar uses the overmap+local
  -- placement pair (any distance; loads the target map); others use set_pos_ms
  -- (bubble-local — fine for the adjacent NPCs the gateway powers move).
  local function place_at_abs(target, abs)
    if U.is_avatar(target) then
      gapi.place_player_overmap_at(coords.project_to_omt(abs))
      gapi.place_player_local_at(gapi.abs_to_bub(abs))
    else
      target:set_pos_ms(gapi.abs_to_bub(abs))
    end
  end

  -- Recall `target` to a saved location variable (store_who holds the var; nil
  -- => global).  Returns true on success so the caller can pick the message.
  function U.teleport_to_saved(target, store_who, name)
    if not target then return false end
    local abs = read_saved_abs(store_who, name)
    if not abs then return false end
    return guarded("teleport_to_saved:" .. name, function()
      place_at_abs(target, abs)
      return true
    end, false)
  end

  -- context_val teleport: pos is a ctx-carried bub_ms from a u_location_variable
  -- earlier in the same EOC (mishap scatter, item apport) — always in-bubble.
  function U.teleport_to_pos(target, pos)
    if not target or not pos then return false end
    return guarded("teleport_to_pos", function()
      if U.is_avatar(target) then
        gapi.place_player_local_at(pos)
      else
        target:set_pos_ms(pos)
      end
      return true
    end, false)
  end

  function U.cast_spell(who, spell_id, level, loc)
    -- Self-target effect_on_condition sub-spells are a pure "run this EOC on
    -- me" dispatch.  Cast here they'd rely on a second marker's on_added hook
    -- firing re-entrantly inside the outer EOC's Lua hook, which BN does not
    -- reliably execute — the report/effect silently never happens (that was
    -- Radiation Sense's self/surroundings menu going quiet).  Skip the marker
    -- round-trip and call the EOC directly; for a self spell the dispatch
    -- target and caster are both `who` (DDA you=target, npc=caster).
    local ce = (mod.cast_map or {})[spell_id]
    if ce and ce.self and ce.eoc then
      local fn = (mod.eoc or {})[ce.eoc]
      if fn then
        guarded("cast_spell_self_eoc:" .. spell_id, function()
          fn(who, who, { spell_id = spell_id, entry = ce })
          return true
        end, nil)
        return
      end
    end
    local tp = U.teleport_spells[spell_id]
    if tp then
      local pos = loc
      if not pos then
        pos = U.query_tile(who, {
          range = tp.range and tp.range(who) or nil,
          msg = tp.msg,
        })
        if not pos then return U.cancel_cast() end
      end
      U.teleport_to(who, pos, tp.scatter and tp.scatter(who) or 0)
      return
    end
    local pk = U.pickup_spells[spell_id]
    if pk then
      local pos = loc
      if not pos then
        pos = U.query_tile(who, {
          range = pk.range and pk.range(who) or nil,
          msg = pk.msg,
        })
        if not pos then return U.cancel_cast() end
      end
      U.pull_items_to(who, pos)
      return
    end
    guarded("cast_spell:" .. spell_id, function()
      local lvl = level
      if lvl == nil then
        lvl = math.max(m.spell_level(who, spell_id), 0)
      end
      local sp = Spell.new(SpellTypeId.new(spell_id), U.round(lvl))
      sp:cast(who, loc or who:get_pos_ms())
      return true
    end, nil)
  end

  -- DDA u_cast_spell { … } + "targeted": true — open the tile picker, then
  -- cast at the chosen tile.  The Spell binding exposes no range accessor,
  -- so the transpiler passes the target spell's upstream range math as a
  -- number.  NPC casters fall back to an untargeted cast at their own tile.
  function U.cast_spell_targeted(who, spell_id, level, range, msg)
    if not U.is_avatar(who) then
      return U.cast_spell(who, spell_id, level, nil)
    end
    local pos = U.query_tile(who, { range = range, msg = msg })
    if not pos then return U.cancel_cast() end
    U.cast_spell(who, spell_id, level, pos)
  end

  -- school tables are generated (mod.school_spells: class trait -> spell ids)
  function U.spell_level_sum(who, school)
    local ids = (mod.school_spells or {})[school]
    if not ids then
      return U.unported_num("spell_level_sum", tostring(school))
    end
    local sum = 0
    for _, sid in ipairs(ids) do
      sum = sum + math.max(m.spell_level(who, sid), 0)
    end
    return sum
  end

  U.school_level = U.spell_level_sum

  -- u_level_spell_class: raise every already-known spell of a class by n
  -- levels (DDA leaves un-known spells of that class untouched). The Wild
  -- Talent roll uses this to bump its freshly-rolled level-1 knacks to 5.
  function U.level_spell_class(who, school, n)
    local ids = (mod.school_spells or {})[school]
    if not ids then
      U.unported("level_spell_class", tostring(school))
      return
    end
    local km = km_of(who)
    for _, sid in ipairs(ids) do
      local sp = SpellTypeId.new(sid)
      if km:knows_spell(sp) then
        guarded("level_spell_class:" .. sid, function()
          local cur = math.max(m.spell_level(who, sid), 0)
          km:get_spell(sp):set_level(cur + n)
          return true
        end, nil)
      end
    end
  end

  -- Concentration proficiencies are modeled as visible traits (BN has no
  -- proficiency system). DDA trains them in percent-of-completion units, both
  -- through power use (u_proficiency('prof_concentration_X','percent') += ...,
  -- mapped here by eoc_transpile) and the concentration practice recipes
  -- (mom_hooks on_craft_result). Both feed this one accumulator; the trait is
  -- granted the instant the counter reaches 100 and is idempotent thereafter.
  local PROFICIENCY_TRAIT_NAMES = {
    PROF_CONCENTRATION_BASIC = "Concentration (Beginner)",
    PROF_CONCENTRATION_INTERMEDIATE = "Concentration (Expert)",
    PROF_CONCENTRATION_MASTER = "Concentration (Master)",
  }
  -- amount   : percent-of-completion to add this call.
  -- requires : prerequisite trait id (recipe path only) -- the upstream Expert
  --            practice recipe REQUIRED the Beginner proficiency. BN can't gate
  --            recipe availability on a (nonexistent) proficiency, so the craft
  --            is offered but must do nothing until the prerequisite is held.
  -- announce : emit progress / gate feedback (recipe path only). The power-use
  --            trickle (gen_eoc, 3-arg call, announce=nil) stays SILENT so it
  --            doesn't spam a message every turn a power is maintained.
  function U.train_proficiency(who, trait, amount, requires, announce)
    guarded("train_proficiency:" .. trait, function()
      local tid = MutationBranchId.new(trait)
      local disp = PROFICIENCY_TRAIT_NAMES[trait] or trait
      if who:has_trait(tid) then return true end
      if requires and not who:has_trait(MutationBranchId.new(requires)) then
        if announce then
          U.msg(who, "You go through the motions, but without " ..
                (PROFICIENCY_TRAIT_NAMES[requires] or requires) ..
                " the exercise doesn't take.  Master that first.",
                MsgType.bad, nil)
        end
        return true
      end
      local key = trait .. "_train"
      local cur = (V.uget(who, key) or 0) + (amount or 0)
      if cur >= 100 then
        who:set_mutation(tid)
        V.uset(who, key, 100)
        U.msg(who, "Your practice pays off -- you've internalized " ..
              disp .. ".", MsgType.good, nil)
      else
        V.uset(who, key, cur)
        if announce then
          U.msg(who, "You practice your focus.  " .. disp .. ": " ..
                math.floor(cur + 0.5) .. "%.", MsgType.info, nil)
        end
      end
      return true
    end, nil)
  end

  function U.spell_count(who, school)
    local km = km_of(who)
    if school == nil then
      return guarded("spell_count", function() return #km:get_spells() end, 0)
    end
    local ids = (mod.school_spells or {})[school] or {}
    local n = 0
    for _, sid in ipairs(ids) do
      if km:knows_spell(SpellTypeId.new(sid)) then n = n + 1 end
    end
    return n
  end

  -- ---- activities (u_assign_activity): Lua-backed activity, no on_finish —
  -- MoM uses these as busy-time; follow-up EOCs are queued separately.
  function U.assign_activity(who, act_id, seconds)
    guarded("assign_activity:" .. act_id, function()
      who:assign_lua_activity({
        type = ActivityTypeId.new(act_id),
        duration = TimeDuration.from_turns(U.round(seconds)),
        name = "channeling",
        interruptable = true,
      })
      return true
    end, nil)
  end

  -- ---- overmap: is an overmap terrain within `range` OMT tiles?
  -- Perf fix 2026-08-08: this is the dominant per-cast psi cost. Several
  -- generated conditions (EOC_CONDITION_NEAR_NETHER_RELATED_LOCATION alone
  -- chains ~69 of these with `or`, none of which short-circuit near a normal
  -- spawn) run on EVERY cast via the opens_spellbook/spellcasting_finish
  -- event fan-out. Each call is a native overmapbuffer.find_closest scan;
  -- the result depends only on (loc, range, the querying OMT) -- not on who
  -- is asking, not on anything that changes turn to turn -- and a
  -- character's OMT position changes far less often than they cast. Cache
  -- by that key instead of rescanning the overmap on every single spell.
  -- The first-ever query of a given loc/range/area still pays the real
  -- overmapbuffer cost (measured: this is where a fresh character's
  -- multi-second first-cast stall lives, since ~69 fresh native scans run
  -- back to back); every repeat query from the same spot is now a table
  -- lookup. Session-only, unbounded but tiny (a handful of bytes per
  -- distinct key ever queried) -- not worth pruning for a single session.
  local near_om_cache = {}
  function U.near_om_location(who, loc, range)
    local abs = gapi.bub_to_abs(who:get_pos_ms())
    local omt = coords.project_to_omt(abs)
    local key = loc .. "|" .. range .. "|" .. omt.x .. "," .. omt.y .. "," .. omt.z
    local cached = near_om_cache[key]
    if cached ~= nil then return cached end
    local result = guarded("near_om_location:" .. loc, function()
      local params = OmtFindParams.new()
      -- NB: BN registers enum keys from io::enum_to_string, so the member is
      -- OtMatchType.TYPE, not .type (overmap.cpp:7413).  Lowercase reads nil
      -- and every near_om_location silently returned false.
      params:add_type(loc, OtMatchType.TYPE)
      params:set_search_range(0, math.floor(range))
      params.max_results = 1
      local found = overmapbuffer.find_closest(omt, params)
      return found ~= nil
    end, false)
    near_om_cache[key] = result
    return result
  end

  -- Batched sibling of near_om_location: tools/eoc_transpile.py collapses a
  -- run of `u_near_om_location` OR-children sharing one literal range into a
  -- single call here instead of N sequential near_om_location calls -- one
  -- native overmapbuffer.find_closest scan (OmtFindParams.add_type appends,
  -- so one query can match ANY of several types) instead of N.
  -- Shares near_om_cache's per-(loc,range,omt) keys with near_om_location
  -- above, so a location already resolved via either path is a hit for both.
  -- A combined query can't attribute a single `true` result back to which
  -- one of several uncached ids actually matched, so only a combined `false`
  -- gets cached per-id (still correct -- and it's the case that matters:
  -- nothing nearby, over and over, every cast).
  function U.near_any_om_location(who, ids, range)
    local abs = gapi.bub_to_abs(who:get_pos_ms())
    local omt = coords.project_to_omt(abs)
    local function key_for(loc) return loc .. "|" .. range .. "|" .. omt.x .. "," .. omt.y .. "," .. omt.z end
    local uncached = {}
    for _, loc in ipairs(ids) do
      local cached = near_om_cache[key_for(loc)]
      if cached == true then return true end
      if cached == nil then uncached[#uncached + 1] = loc end
    end
    if #uncached == 0 then return false end
    local found = guarded("near_any_om_location", function()
      local params = OmtFindParams.new()
      for _, loc in ipairs(uncached) do params:add_type(loc, OtMatchType.TYPE) end
      params:set_search_range(0, math.floor(range))
      params.max_results = 1
      return overmapbuffer.find_closest(omt, params) ~= nil
    end, false)
    if not found then
      for _, loc in ipairs(uncached) do near_om_cache[key_for(loc)] = false end
    end
    return found
  end

  -- ---- misc body/state accessors
  function U.hp(who, bp)
    return guarded("hp", function()
      if bp then return who:get_hp(BodyPartTypeId.new(bp)) end
      return who:get_hp()
    end, 0)
  end

  function U.hp_max(who, bp)
    return guarded("hp_max", function()
      if bp then return who:get_hp_max(BodyPartTypeId.new(bp)) end
      return who:get_hp_max()
    end, 0)
  end

  function U.health(who)
    return guarded("health", function() return who:get_healthy() end, 0)
  end

  function U.size(who)
    return guarded("size", function() return who:get_size() end, 3)
  end

  -- Body volume of a CREATURE, in ml.  BN exposes no creature body-volume
  -- binding (monster::get_volume() is C++-only; the mtype Lua usertype carries
  -- no volume), so approximate it from weight.  CBN authors a LIVING creature's
  -- volume(ml) == its weight(g) EXACTLY (squirrel 624/624, dog 30000/30000,
  -- wolf/deer/cow/moose/bear all 1:1); undead run ~1.3x heavier than their
  -- volume (zombie 62500 ml / 81500 g; zombie dog 30000 ml / 40750 g).  So
  -- weight_g * 0.8 lands undead -- the usual Displacement target -- within a few
  -- percent of true volume (zombie dog -> ~32600, true 30000) and living animals
  -- ~20% under.  Caveat: a few dense specials whose authored volume >> weight
  -- (e.g. zombie hulk, 875 L but 200 kg) read much lighter here, so they're
  -- easier to displace than in DDA.  This was a 0-returning stub, which made the
  -- Displacement size gate ("volume > 0" clause) fail for EVERY target -> a
  -- perpetual "too big to teleport."  Only live caller is that gate; carried-gear
  -- tallies use U.item_volume and item apport has its own qualifier.
  function U.volume(who)
    return guarded("volume", function()
      return who:get_weight():to_gram() * 0.8
    end, 0)
  end

  function U.weight(who)
    return guarded("weight", function()
      return who:get_weight():to_gram()
    end, 0)
  end

  function U.monsters_nearby(who, ...)
    return U.unported_num("u_monsters_nearby", "monsters_nearby")
  end

  -- BN's Lua API has no binding to read a configured game option at all
  -- (confirmed absent from every catalua_bindings_*.cpp — not a narrow gap
  -- like spell_type.name, just nothing registered) — the old
  -- gapi.get_option(name) call always pcall-failed and fell back to 0,
  -- which silently zeroed every formula that multiplies by
  -- game_option('SKILL_TRAINING_SPEED') (contemplation's Metaphysics gain,
  -- channeling's Metaphysics gain) no matter the caster's actual skill gap.
  -- Return each option's BN default (options.cpp) instead: doesn't reflect
  -- a player's own options.json override, but 1.0 is far closer to correct
  -- than an unconditional, permanent 0.
  local GAME_OPTION_DEFAULTS = { SKILL_TRAINING_SPEED = 1.0,
                                 PROFICIENCY_TRAINING_SPEED = 1.0 }
  function U.game_option(name)
    return GAME_OPTION_DEFAULTS[name] or 1.0
  end

  -- ---- time: DDA time('now') counts seconds since turn 0
  function U.time(what)
    if what == 'now' then
      return gapi.current_turn():to_turn()
    end
    if what == 'cataclysm' then
      return 0  -- approximation: epoch
    end
    return U.unported_num("time", tostring(what))
  end

  function U.time_since(what)
    return U.time('now') - U.time(what)
  end

  -- ---- conditions
  function U.test_eoc(C, id, you, npc, ctx)
    local fn = C[id]
    if fn then return fn(you, npc, ctx) end
    once("test|" .. id, "test_eoc of unknown EOC " .. id .. " -> false")
    return false
  end

  function U.is_outside(who)
    return guarded("is_outside", function()
      return gapi.get_map():is_outside(who:get_pos_ms())
    end, false)
  end

  function U.has_creature_flag(who, flag)
    return U.badcond("has_creature_flag", flag)
  end

  -- current weather is tracked by preload.lua's on_weather_changed hook;
  -- unknown until the first change after load ('' compares false to any id)
  function U.is_weather(weather_id)
    return (mod.current_weather or '') == weather_id
  end

  -- closest BN check for worn/wielded-with-flag: carried-with-flag
  function U.has_item_flag(who, flag)
    return guarded("has_item_flag:" .. flag, function()
      return who:has_item_with_flag(JsonFlagId.new(flag), false)
    end, false)
  end

  -- `has_amount` is a Character method in DDA but is NOT bound in BN's Lua API
  -- (catalua_bindings_creature.cpp binds has_item_with_id / all_items /
  -- all_items_with_flag, no has_amount / use_amount).  Calling it raised
  -- "attempt to call a nil value (method 'has_amount')" inside guarded(), so
  -- BOTH of these silently answered false for every item, every time -- any
  -- generated condition gated on carrying a psi tool was dead.  Found in the
  -- 2026-07-25 playtest log next to the remove_item_with crash.
  function U.has_item(who, item_id)
    return guarded("has_item:" .. item_id, function()
      return who:has_item_with_id(ItypeId.new(item_id), false)
    end, false)
  end

  -- No bound counting call either, so count by walking all_items(false) --
  -- same traversal remove_item_with uses (inventory + worn + wielded).  Stops
  -- at `count`, so the common count == 1 case is cheap.
  function U.has_items(who, item_id, count)
    return guarded("has_items:" .. item_id, function()
      local want = U.round(count)
      if want <= 1 then
        return who:has_item_with_id(ItypeId.new(item_id), false)
      end
      local n = 0
      for _, it in ipairs(who:all_items(false)) do
        local okt, t = pcall(function() return it:get_type():str() end)
        if okt and t == item_id then
          n = n + 1
          if n >= want then return true end
        end
      end
      return false
    end, false)
  end

  -- ---- morale / recipes / death
  function U.add_morale(who, morale_id, bonus, max_bonus, dur, decay)
    guarded("add_morale:" .. morale_id, function()
      who:add_morale(MoraleTypeDataId.new(morale_id), bonus, max_bonus, dur, decay)
      return true
    end, nil)
  end

  function U.forget_recipe(who, recipe_id)
    guarded("forget_recipe:" .. recipe_id, function()
      who:forget_recipe(RecipeId.new(recipe_id))
      return true
    end, nil)
  end

  function U.die(who)
    guarded("die", function()
      who:die(nil)
      return true
    end, nil)
  end

  function U.cancel_activity(who)
    guarded("cancel_activity", function()
      who:cancel_activity()
      return true
    end, nil)
  end

  -- ==========================================================================
  -- Inventory-EOC family (DDA u_run_inv_eocs): iterate the actor's items,
  -- filter by search_data, and run inner EOCs with the matched ITEM as the
  -- beta (n) talker.  The transpiler compiles inner true_eocs inline in
  -- "item-beta" mode, so their n_val('power')/n_volume() etc. route to the
  -- U.item_* helpers below (called on the item, not a creature).
  --
  -- DDA item-talker val semantics (talker_item.cpp): n_val('power') =
  -- ammo_remaining() (battery charges), n_val('power_max') = ammo_capacity(),
  -- writing power = ammo_set(battery, clamp(value,0,cap)).  CBN's spell engine
  -- exposes no item::is_chargeable / uses_energy binding, so `chargeable` is
  -- approximated (battery-powered tool with room) — a prebuilt-exe limitation.
  -- ==========================================================================
  local BATTERY_ITYPE = nil  -- lazily ItypeId.new("battery")

  function U.item_power(it)
    return guarded("item_power", function() return it:ammo_remaining() end, 0)
  end
  function U.item_power_max(it)
    return guarded("item_power_max", function() return it:ammo_capacity(false) end, 0)
  end
  function U.item_volume(it)
    return guarded("item_volume", function() return it:volume():to_milliliter() end, 0)
  end
  function U.item_weight(it)
    return guarded("item_weight", function() return it:weight():to_gram() end, 0)
  end

  local function set_item_power(it, value)
    BATTERY_ITYPE = BATTERY_ITYPE or ItypeId.new("battery")
    local cap = it:ammo_capacity(false)
    it:ammo_set(BATTERY_ITYPE, U.clamp(U.round(value), 0, cap))
  end
  function U.item_add_power(it, delta)
    guarded("item_add_power", function()
      set_item_power(it, it:ammo_remaining() + delta); return true
    end, nil)
  end
  function U.item_set_power(it, value)
    guarded("item_set_power", function() set_item_power(it, value); return true end, nil)
  end

  -- u_activate on an item talker: invoke the item's use-action (e.g. bandages'
  -- "heal", the robot-interface's ROBOTCONTROL) as the actor, at their tile.
  function U.activate_item(who, it)
    guarded("activate_item", function()
      it:invoke_at(who:get_pos_ms()); return true
    end, nil)
  end

  -- is_chargeable approximation.  DDA's item::is_chargeable() is
  -- uses_energy() && (battery_charges < battery_capacity); and uses_energy()
  -- (item_gun_tool_ammo.cpp:1544) is TRUE for a bare MAGAZINE that holds
  -- battery ammo -- so a loose battery cell in your pack IS chargeable, not
  -- just tools.  The old gate here required it:is_tool(), which every battery
  -- cell (type MAGAZINE, e.g. medium_battery_cell) fails, so Electron Overflow
  -- silently skipped the loose batteries people actually carry.  Match the
  -- cells directly instead: all_items(false) surfaces each cell individually
  -- (loose AND nested inside a tool), and the cell is the object that stores
  -- the charge, so matching it (not its host tool) also avoids charging the
  -- same magazine twice in one tick.
  -- Battery-magazine identity.  DDA's is_chargeable() charges ANY battery
  -- magazine that isn't full (uses_energy() is true for a magazine holding
  -- battery ammo) -- NOT only the RECHARGE-flagged ones.  An earlier fix
  -- over-narrowed this to has_flag(RECHARGE), which silently skipped MoM's own
  -- *_electronoetic psionic cells (type MAGAZINE, ammo_type battery, but flagged
  -- BATTERY_LIGHT/MEDIUM/HEAVY, no RECHARGE) -- i.e. the very cells an
  -- electrokinetic carries, so Electron Overflow still charged nothing.  BN's
  -- ammo_types() (a magazine's declared ammotype) isn't bound to Lua, and
  -- ammo_current() is NULL on a fully-drained cell, so identify a battery cell
  -- by: (a) loaded ammo == "battery" (covers any partly-charged cell), else
  -- (b) an identifying cell flag -- standard cells carry RECHARGE, MoM
  -- electronoetic cells carry BATTERY_LIGHT/MEDIUM/HEAVY (stubbed json_flags in
  -- flags_psionic.json).  Atomic/disposable cells match none and are left alone.
  local BATTERY_MAG_FLAGS = {"RECHARGE", "BATTERY_LIGHT", "BATTERY_MEDIUM", "BATTERY_HEAVY"}
  local _batt_fids = nil
  local function is_battery_mag(it)
    local ok, cur = pcall(function() return it:ammo_current() end)
    if ok and cur and cur:str() == "battery" then return true end
    if not _batt_fids then
      _batt_fids = {}
      for _, f in ipairs(BATTERY_MAG_FLAGS) do
        local fid = JsonFlagId.new(f)
        if fid:is_valid() then _batt_fids[#_batt_fids + 1] = fid end
      end
    end
    for _, fid in ipairs(_batt_fids) do
      if it:has_flag(fid) then return true end
    end
    return false
  end
  local function chargeable_approx(it)
    local ok, r = pcall(function()
      local function not_full(x)
        local cap = x:ammo_capacity(false)
        return cap > 0 and x:ammo_remaining() < cap
      end
      -- (1) a battery cell (loose or nested).  all_items(false) surfaces each
      --     cell individually, and the cell is the object that stores the
      --     charge, so matching it (not its host tool) also avoids charging the
      --     same magazine twice in one tick.
      if it:is_magazine() then
        return is_battery_mag(it) and not_full(it)
      end
      -- (2) a legacy integral-battery tool with no discrete magazine item
      --     (BN mostly uses cells, but a few tools still carry internal
      --     charges).  Skip tools that DO have a magazine loaded -- their cell
      --     is already matched by (1), so charging the tool too would
      --     double-spend the power budget on the same battery.  MUST also
      --     require battery ammo: without it, ANY internal-charge tool matched
      --     (a lighter, etc.) and set_item_power's ammo_set(battery,...) then
      --     hit item.cpp:712 "Tried to set invalid ammo battery for <tool>",
      --     failing the charge AND spamming a Lua backtrace every cycle.  For a
      --     tool, is_battery_mag falls to the ammo_current=="battery" test (no
      --     RECHARGE/BATTERY_* flags), so a fully-drained integral-battery tool
      --     is skipped -- acceptable; those are rare and cells cover the case.
      if it:is_tool() and not it:current_magazine() then
        return is_battery_mag(it) and not_full(it)
      end
      return false
    end)
    return ok and r
  end

  -- tname's bound signature has no default args (SET_FX drops them), so the
  -- no-arg call fails and must pass (quantity, with_prefix, truncate).
  function U.item_name(it)
    local ok, r = pcall(function() return it:tname(1, false, 0) end)
    if ok and r and r ~= "" then return r end
    ok, r = pcall(function() return it:get_type():str() end)
    return (ok and r) or "item"
  end
  local item_name = U.item_name

  -- Guarded flag test: JsonFlagId.new(<unregistered flag>):obj() hard-errors
  -- (debugmsg), so pcall it — an unknown flag simply reads false.
  function U.item_has_flag(it, flag)
    local ok, r = pcall(function()
      return it:has_flag(JsonFlagId.new(flag))
    end)
    return ok and r or false
  end

  function U.item_is_artifact(it)
    local ok, r = pcall(function() return it:is_artifact() end)
    return ok and r or false
  end

  -- Any-key text popup (base game's lib.ui.popup, inlined so we don't depend
  -- on the base package path).  QueryPopup:message is "%s"-formatted, so the
  -- text can't inject format specifiers.
  function U.popup(text)
    guarded("popup", function()
      local p = QueryPopup.new()
      p:message(text)
      p:allow_any_key(true)
      p:query()
      return true
    end, nil)
  end

  -- Psychometric read of a relic: mirrors CBN's artifact-analyzer-console
  -- (lua/iuse/artifact_analyzer.lua) — charge type/requirement + the
  -- activated/wielded/worn/carried effect descriptions off islot_artifact.
  -- Returns the report string, or nil if the item carries no artifact data.
  function U.artifact_report(it)
    return guarded("artifact_report", function()
      local itype = it:get_type():obj()
      if not itype then return nil end
      local slot = itype:slot_artifact()
      if not slot then return nil end
      local L = {}
      local function push(s) L[#L + 1] = s end
      local function section(label, entries)
        if not entries or #entries == 0 then
          push(label .. ": Nothing"); return
        end
        push(label .. ":")
        for _, e in ipairs(entries) do push("  - " .. e) end
      end
      push("You press your senses into " .. U.item_name(it) .. "...")
      push("")
      push("Charge: " .. slot:charge_type_description())
      push("Charge requirement: " .. slot:charge_req_description())
      push("")
      section("When activated", slot:effects_activated_descriptions())
      section("When wielded", slot:effects_wielded_descriptions())
      section("When worn", slot:effects_worn_descriptions())
      section("When carried", slot:effects_carried_descriptions())
      return table.concat(L, "\n")
    end, nil)
  end

  local function item_matches(it, filt)
    if filt.ids then
      local hit = false
      for _, id in ipairs(filt.ids) do
        if it:get_type():str() == id then hit = true; break end
      end
      if not hit then return false end
    end
    -- A flag id BN doesn't define can't be held by any item, so skip it rather
    -- than resolve it: has_flag() on an unknown id fires a generic_factory
    -- debugmsg + full backtrace (e.g. the DDA-only PSEUDO / INTEGRATED flags in
    -- the teleport carried-volume checker's excluded_flags -- spammed the log on
    -- every jump).  is_valid() only checks factory membership, no debugmsg.
    if filt.flags then
      for _, f in ipairs(filt.flags) do
        local fid = JsonFlagId.new(f)
        if fid:is_valid() and not it:has_flag(fid) then return false end
      end
    end
    if filt.excluded_flags then
      for _, f in ipairs(filt.excluded_flags) do
        local fid = JsonFlagId.new(f)
        if fid:is_valid() and it:has_flag(fid) then return false end
      end
    end
    if filt.chargeable and not chargeable_approx(it) then return false end
    if filt.cond and not filt.cond(it) then return false end
    return true
  end

  local function collect_items(who, filt)
    if filt.worn_only then
      local ok, r = pcall(function() return who:get_worn_items() end)
      return (ok and r) or {}
    end
    if filt.wielded_only then
      -- No wielded-item getter is bound, but is_wielding() is.  all_items()
      -- flattens EVERY carried item (worn garments + all their nested contents
      -- + the weapon), so returning it wholesale for a "wielded only" pass sums
      -- your entire inventory's volume -- which, stacked on the worn pass, was
      -- reporting a ~57 qt "carried volume" for an 8 qt loadout and choking the
      -- teleport carry gates.  Filter down to just the item(s) actually wielded.
      local ok, all = pcall(function() return who:all_items(false) end)
      if not ok or not all then return {} end
      local held = {}
      for _, it in ipairs(all) do
        local okw, w = pcall(function() return who:is_wielding(it) end)
        if okw and w then held[#held + 1] = it end
      end
      return held
    end
    -- default: full carried set
    return who:all_items(false)
  end

  -- mode: "all" runs every match; "random" one random match; "manual"/
  -- "manual_mult" prompt a menu (single pick — mult picking is simplified).
  function U.run_inv_eocs(who, ctx, mode, filt, inner_fn)
    return guarded("run_inv_eocs", function()
      local items = collect_items(who, filt)
      local matches = {}
      for _, it in ipairs(items) do
        local ok, m = pcall(item_matches, it, filt)
        if ok and m then matches[#matches + 1] = it end
      end
      if #matches == 0 then return false end
      if mode == "random" then
        inner_fn(matches[gapi.rng(1, #matches)])
      elseif mode == "manual" or mode == "manual_mult" then
        local names = {}
        for i, it in ipairs(matches) do names[i] = item_name(it) end
        local pick = U.select_menu("Choose an item", names, nil, who, ctx)
        if pick and matches[pick] then inner_fn(matches[pick]) end
      else  -- "all"
        for _, it in ipairs(matches) do inner_fn(it) end
      end
      return true
    end, false)
  end

  return U
end
