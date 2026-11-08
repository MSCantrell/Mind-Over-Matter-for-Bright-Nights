-- mom_pack: Pack Leader, the Beastmaster passive (original fork mechanic, 2026-11-07).
--
-- Design (user, 2026-11-07): once the avatar knows Beastmaster (the telepath power
-- telepathic_animal_mind_control OR its Psychic Knack twin), EVERY friendly pet
-- gets +25% melee damage -- the psion knows what it takes to bring down a zombie;
-- a wolf was only built for deer.  On top of that, pets fighting near the psion
-- (within PACK_RANGE tiles) gain a compounding +15% per packmate beyond the first,
-- counting at most PACK_CAP pets:
--     near pets:  mult = 1.25 * 1.15^(min(n, 8) - 1)    (n = near pets; 8 pets = x3.33)
--     other pets: mult = 1.25                            (still in the bubble)
-- Applies to every pet however it was won (Beastmaster, Beast Tamer, vanilla
-- taming, a temporary charm), i.e. any monster with friendly ~= 0.  Mindless
-- things (PSIPROOF: robots, zombies, ...) and telepathy-immune monsters are
-- left out -- there is no mind there to guide, matching the rest of the school.
--
-- Mechanism: BN has no damage-multiplier hook for monster melee.  It DOES read
-- effect bash_mod / cut_mod into Creature::bash_bonus / cut_bonus every turn
-- (monster::process_one_effect, monster.cpp:4013) and add them to each standard
-- melee hit (monster::melee_attack, monster.cpp:2493).  So the multiplier is
-- realized as a FLAT bonus = raw_damage * (mult - 1), split into bash and cut,
-- carried as the intensity of two hand effects (mom_engine_effects.json; bonus ==
-- intensity).  The same flat bonus also lands on JSON melee/bite special attacks
-- (melee_actor::call, mattack_actors.cpp:418), so it is sized to the pet's
-- STRONGEST attack (user call, 2026-11-07): the larger of
--   standard: avg of melee_dice d melee_sides + melee_damage (Lua-bound mtype), and
--   special:  raw max damage_max_instance of its best JSON melee/bite attack, from
--             lua/gen_pack_attacks.lua (tools/gen_pack_attacks.py; Lua can't read it).
-- The special uses raw MAX, not average, because BN multiplies (max + bonus) by
-- rng_float(min_mul, max_mul): bonus = max * (M - 1) makes that attack exactly x M.
-- Weaker attacks therefore get MORE than x M.  Monsters from other mods aren't in
-- the table and size off standard melee only.
-- LIMIT: hard-coded C++ attacks (LUNGE...), guns and spells never read the bonus.
--
-- Steadied nerves (user, 2026-11-07): pack pets within PACK_RANGE of the psion
-- don't flee while above STEADY_MIN_HP of max HP.  BN's monster::is_fleeing
-- (monster.cpp:1796) returns false outright once morale >= 100, and Lua can write
-- morale, so every turn we hold those pets at STEADY_MORALE (headroom for HURT's
-- 1 + dmg/3 morale loss per hit landing between our ticks).  The pet's own morale
-- is saved on it first (creature var MORALE_KEY, persists in the save) and put back
-- the moment it drops below the HP line, leaves range, stops being a pet, or the
-- psion no longer knows Beastmaster.  The `run` effect (HIT_AND_RUN monsters, some
-- fear effects) forces fleeing regardless of morale and is deliberately left alone.
--
-- Telepathic recall (user, 2026-11-08): BN pets only follow while they can SEE the
-- player (monster::plan, monmove.cpp:952), so a pet with short day/night vision --
-- the sewer gator's vision_day is 3 -- loses you constantly.  Every turn, any pack
-- pet anywhere in the bubble that is more than RECALL_DIST tiles away and isn't
-- fighting gets steered (set_move_target) to a free tile NEXT TO
-- you -- never your own tile, since ATTACKMON animals bite whatever they step into
-- (monmove.cpp:2491 -> attack_at:2369, user chose to keep that).  Skipped: pets
-- told to wait, tied, harnessed or ridden, and PET_WONT_FOLLOW types.  Temporary
-- Beastmaster charms are pack pets too, so they come along while the charm lasts.
--
-- Tether (user, 2026-11-08): fast, far-sighted pets (dire wolf: vision 50, speed
-- 150) chase prey right out of the reality bubble and get unloaded.  A pack pet
-- more than TETHER_OUT tiles away is made `docile` (monmove.cpp:626 skips target
-- selection), so it drops the chase and follows/recalls; once back within
-- TETHER_IN it's released.  BN's leash can't do this: it auto-drops past 8 tiles
-- (monmove.cpp:1850).  `docile` is permanent by type, so ours is tagged with the
-- creature var TETHER_KEY and always removed explicitly; a docile the player set
-- from the pet menu (no tag) is never touched.
return function(mod)
  local PACK_RANGE = 12
  local PACK_CAP = 8
  local BASE_MULT = 1.25
  local GROUP_MULT = 1.15
  local REFRESH_TURNS = 10
  local EFFECT_TURNS = 30   -- > REFRESH_TURNS, so the bonus fades if this stops running

  local BEASTMASTER = {
    SpellTypeId.new("telepathic_animal_mind_control"),
    SpellTypeId.new("telepathic_animal_mind_control_knack"),
  }
  local BASH_EID = EffectTypeId.new("mom_pack_tactics_bash")
  local CUT_EID = EffectTypeId.new("mom_pack_tactics_cut")
  local IMMUNE_EID = EffectTypeId.new("eff_monster_immune_to_telepathy")
  local PSIPROOF = (MonsterFlag and MonsterFlag.PSIPROOF) or nil
  local DUR = TimeDuration.from_turns(EFFECT_TURNS)
  local STEADY_MORALE = 200
  local STEADY_MIN_HP = 0.25
  local MORALE_KEY = "mom_pack_saved_morale"
  local RECALL_DIST = 3
  local TETHER_OUT = 30
  local TETHER_IN = 15
  local TETHER_KEY = "mom_pack_tethered"
  local DOCILE_EID = EffectTypeId.new("docile")
  local STAY_EIDS = {}
  for _, id in ipairs({ "ai_waiting", "tied", "harnessed", "ridden" }) do
    STAY_EIDS[#STAY_EIDS + 1] = EffectTypeId.new(id)
  end
  local WONT_FOLLOW = (MonsterFlag and MonsterFlag.PET_WONT_FOLLOW) or nil

  -- Exposed for the in-game Lua console / tests.
  mod.pack = mod.pack or {}
  local P = mod.pack
  P.avg_cache = {}
  local ok_tbl, tbl = pcall(require, "lua/gen_pack_attacks")
  P.special = (ok_tbl and type(tbl) == "table") and tbl or {}
  if not ok_tbl then gdebug.log_warn("MoM-BN: gen_pack_attacks missing: " .. tostring(tbl)) end

  function P.multiplier(n_near, near)
    if not near then return BASE_MULT end
    local n = math.min(math.max(n_near, 1), PACK_CAP)
    return BASE_MULT * GROUP_MULT ^ (n - 1)
  end

  -- {bash, cut} damage the bonus is sized from: the larger (by total) of the
  -- standard melee average and the strongest JSON special's raw max.  Cached per type.
  function P.avg_damage(mon)
    local tid = mon:get_type()
    local key = tid:str()
    local hit = P.avg_cache[key]
    if hit then return hit[1], hit[2] end
    local t = tid:obj()
    local bash, cut = 0, 0
    if t.melee_dice > 0 then
      bash = t.melee_dice * (t.melee_sides + 1) / 2
      local units = t.melee_damage.damage_units
      for _, du in pairs(units) do
        local amt = du.amount * (du.damage_multiplier or 1)
        if du.type == DamageType.DT_CUT then cut = cut + amt else bash = bash + amt end
      end
    end
    local sp = P.special[key]
    if sp and sp[1] + sp[2] > bash + cut then bash, cut = sp[1], sp[2] end
    P.avg_cache[key] = { bash, cut }
    return bash, cut
  end

  local function knows_beastmaster(you)
    local km = you:get_magic()
    for _, sid in ipairs(BEASTMASTER) do
      if km:knows_spell(sid) then return true end
    end
    return false
  end

  local function is_pack_pet(mon)
    if mon.friendly == 0 or mon:is_dead() or mon:is_hallucination() then return false end
    if PSIPROOF and mon:has_flag(PSIPROOF) then return false end
    if mon:has_effect(IMMUNE_EID) then return false end
    return true
  end

  local function set_bonus(mon, eid, amount)
    local v = math.floor(amount + 0.5)
    if v >= 1 then
      mon:add_effect(eid, DUR, nil, v)
    elseif mon:has_effect(eid) then
      mon:remove_effect(eid)
    end
  end

  local function clear(mon)
    if mon:has_effect(BASH_EID) then mon:remove_effect(BASH_EID) end
    if mon:has_effect(CUT_EID) then mon:remove_effect(CUT_EID) end
  end

  -- Put a steadied monster's own morale back.
  local function release(mon)
    local saved = mon:get_value(MORALE_KEY)
    if saved ~= nil and saved ~= "" then
      mon.morale = tonumber(saved) or mon.morale
      mon:remove_value(MORALE_KEY)
    end
  end

  local function tethered(mon)
    return mon:get_value(TETHER_KEY) == "1"
  end

  local function untether(mon)
    if tethered(mon) then
      if mon:has_effect(DOCILE_EID) then mon:remove_effect(DOCILE_EID) end
      mon:remove_value(TETHER_KEY)
    end
  end

  -- Hold a straying pet docile past TETHER_OUT; let go inside TETHER_IN.
  local function tether(mon, d)
    if tethered(mon) then
      if d <= TETHER_IN then untether(mon) end
    elseif d > TETHER_OUT and not mon:has_effect(DOCILE_EID) then
      mon:add_effect(DOCILE_EID, TimeDuration.from_turns(1))
      mon:set_value(TETHER_KEY, "1")
    end
  end

  -- Free, walkable tiles adjacent to the player (recall destinations).
  local function free_neighbors(here)
    local map = gapi.get_map()
    local out = {}
    for dx = -1, 1 do
      for dy = -1, 1 do
        if dx ~= 0 or dy ~= 0 then
          local p = TripointBubMs.new(here.x + dx, here.y + dy, here.z)
          local ok, yes = pcall(function()
            return map:get_ter_at(p):obj():get_movecost() > 0
              and map:get_furn_at(p):obj():get_movecost() >= 0
              and not gapi.get_creature_at(p)
          end)
          if ok and yes then out[#out + 1] = p end
        end
      end
    end
    return out
  end

  local function can_recall(mon, here)
    if WONT_FOLLOW and mon:has_flag(WONT_FOLLOW) then return false end
    for _, eid in ipairs(STAY_EIDS) do
      if mon:has_effect(eid) then return false end
    end
    -- No "can't see you" gate (dropped 2026-11-08): BN's own follow only fires when
    -- the pet has NO destination (monmove.cpp:955), so a pet still walking to a stale
    -- spot ignored a player in plain sight.  Recall now covers any idle straggler.
    return not mon:attack_target()
  end

  -- Every turn: hold eligible pack pets fearless, release the rest; recall
  -- stragglers that have lost sight of the psion.  Only pets
  -- (friendly ~= 0) are looked at here; anything that has since turned hostile is
  -- released by P.refresh within REFRESH_TURNS.
  function P.steady(you)
    you = you or gapi.get_avatar()
    if not you or not P.active then return end
    local here = you:get_pos_ms()
    local spots = nil   -- computed lazily, once per turn
    for _, mon in ipairs(gapi.get_all_monsters()) do
      if mon.friendly ~= 0 then
        local pack = is_pack_pet(mon)
        local d = mod.u.dist(here, mon:get_pos_ms())
        if pack then tether(mon, d) else untether(mon) end
        if pack and d > RECALL_DIST and can_recall(mon, here) then
          spots = spots or free_neighbors(here)
          local best, bd = nil, nil
          local mp = mon:get_pos_ms()
          for _, p in ipairs(spots) do
            local pd = mod.u.dist(p, mp)
            if not bd or pd < bd then best, bd = p, pd end
          end
          if best then mon:set_move_target(best) end
        end
        local hpmax = mon:get_hp_max()
        local ok = pack
          and d <= PACK_RANGE
          and hpmax > 0 and mon:get_hp() >= hpmax * STEADY_MIN_HP
        if ok then
          local saved = mon:get_value(MORALE_KEY)
          if saved == nil or saved == "" then
            mon:set_value(MORALE_KEY, tostring(mon.morale))
          end
          if mon.morale < STEADY_MORALE then mon.morale = STEADY_MORALE end
        else
          release(mon)
        end
      end
    end
  end

  function P.refresh(you)
    you = you or gapi.get_avatar()
    if not you then return end
    local active = knows_beastmaster(you)
    P.active = active
    local here = you:get_pos_ms()
    local pets, near = {}, {}
    local n_near = 0
    for _, mon in ipairs(gapi.get_all_monsters()) do
      if is_pack_pet(mon) then
        pets[#pets + 1] = mon
        if mod.u.dist(here, mon:get_pos_ms()) <= PACK_RANGE then
          near[#pets] = true
          n_near = n_near + 1
        end
      else
        if mon:has_effect(BASH_EID) or mon:has_effect(CUT_EID) then
          clear(mon)   -- turned hostile, died of mind, etc.
        end
        release(mon)   -- e.g. a Beastmaster charm that just expired
        untether(mon)
      end
    end
    P.last = { active = active, pets = #pets, near = n_near,
               mult_near = P.multiplier(n_near, true) }
    for i, mon in ipairs(pets) do
      if active then
        local extra = P.multiplier(n_near, near[i]) - 1
        local bash, cut = P.avg_damage(mon)
        set_bonus(mon, BASH_EID, bash * extra)
        set_bonus(mon, CUT_EID, cut * extra)
      else
        clear(mon)
        release(mon)
        untether(mon)
      end
    end
  end

  mod.recurring["MOM_PACK_TACTICS"] = {
    min_turns = REFRESH_TURNS, max_turns = REFRESH_TURNS,
    fn = function(you)
      local ok, err = pcall(P.refresh, you)
      if not ok and not P.warned then
        P.warned = true
        gdebug.log_warn("MoM-BN: pack tactics refresh failed: " .. tostring(err))
      end
    end,
  }

  mod.recurring["MOM_PACK_STEADY"] = {
    min_turns = 1, max_turns = 1,
    fn = function(you)
      local ok, err = pcall(P.steady, you)
      if not ok and not P.steady_warned then
        P.steady_warned = true
        gdebug.log_warn("MoM-BN: pack steady failed: " .. tostring(err))
      end
    end,
  }
end
