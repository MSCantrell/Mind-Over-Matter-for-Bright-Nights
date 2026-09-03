-- mom_math: the u_val / math-function shim (spec §5, Rev 2 scope).
-- Every function takes the acting Character as its first argument.
local M = {}

-- string_id<T> construction (SpellTypeId.new / EffectTypeId.new / SkillId.new)
-- crosses the Lua/C++ boundary (marshal the string, run the factory lookup,
-- wrap the result in userdata) on every call -- it is not a free table index.
-- These three accessors are the ones the generated EOC/jmath code calls
-- CONSTANTLY (every condition check, every formula term, often several times
-- per cast and per tick for a psion with active powers), so memoize by
-- string once per session rather than re-resolving the same id over and
-- over.  Perf fix 2026-08-08: this was previously a fresh construction on
-- every call, one of the bigger contributors to psi-specific slowdown.
local _spell_ids, _effect_ids, _skill_ids = {}, {}, {}
local function spell_tid(s)
  local v = _spell_ids[s]
  if v == nil then v = SpellTypeId.new(s); _spell_ids[s] = v end
  return v
end
local function effect_tid(s)
  local v = _effect_ids[s]
  if v == nil then v = EffectTypeId.new(s); _effect_ids[s] = v end
  return v
end
local function skill_tid(s)
  local v = _skill_ids[s]
  if v == nil then v = SkillId.new(s); _skill_ids[s] = v end
  return v
end

-- u_val('intelligence') — effective stat = base + bonus in BN.
-- BN binds the stat accessors on Character ONLY.  Since QA round 3 an EOC can
-- run with a monster as `you` (a marker landing on a spell's monster target,
-- e.g. Mesmerize) — monsters have no get_*_base, which crashed the hook.  The
-- psi stat formulas describe the caster, so fall back to the avatar rather
-- than error (same "degrade, don't throw" philosophy as magic_of below;
-- NPC-psion misattribution accepted, per HANDOFF).
local function stat_src(you)
  if you ~= nil and you.get_int_base ~= nil then return you end
  return gapi.get_avatar()
end
function M.int(you) local c = stat_src(you) return c:get_int_base() + c:get_int_bonus() end
function M.str(you) local c = stat_src(you) return c:get_str_base() + c:get_str_bonus() end
function M.dex(you) local c = stat_src(you) return c:get_dex_base() + c:get_dex_bonus() end
function M.per(you) local c = stat_src(you) return c:get_per_base() + c:get_per_bonus() end

-- Spells live on the spellbook (known_magic), not on Character directly —
-- Character's only spell binding is get_magic() (catalua_bindings_creature.cpp:615).
-- Monsters have no get_magic binding, and since QA round 3 EOCs can run with
-- a monster as `you` (marker landing on a spell target) — treat "no
-- spellbook" as "spell unknown" rather than erroring inside a hook.
local function magic_of(you)
  if you.get_magic == nil then return nil end
  return you:get_magic()
end

-- u_spell_level('id') -> -1 if unknown (MoM convention).
function M.spell_level(you, spell_id)
  local km = magic_of(you)
  if not km then return -1 end
  local sid = spell_tid(spell_id)
  if not km:knows_spell(sid) then return -1 end
  return km:get_spell(sid):get_level()
end

-- u_spell_exp('id')
function M.spell_exp(you, spell_id)
  local km = magic_of(you)
  if not km then return -1 end
  local sid = spell_tid(spell_id)
  if not km:knows_spell(sid) then return -1 end
  return km:get_spell(sid):xp()
end

-- u_spell_exp('id') += n
-- gain_exp binds void(int); sol2 rejects numbers with decimals, and the
-- upstream drain math is fractional — round here, at the binding boundary.
function M.gain_spell_exp(you, spell_id, amount)
  local km = magic_of(you)
  if not km then return end
  local sid = spell_tid(spell_id)
  if km:knows_spell(sid) then
    km:get_spell(sid):gain_exp(math.floor(amount + 0.5))
  end
end

-- u_effect_intensity('id') -> -1 if absent (MoM convention).
function M.effect_intensity(you, effect_id, bp)
  local eid = effect_tid(effect_id)
  if not you:has_effect(eid, bp) then return -1 end
  return you:get_effect_int(eid, bp)
end

function M.focus(you) return you.focus_pool end
function M.pain(you) return you:get_pain() end
function M.stamina(you) return you:get_stamina() end
function M.sleep_deprivation(you) return you:get_sleep_deprivation() end
function M.skill(you, skill_id) return you:get_skill_level(skill_tid(skill_id)) end
function M.morale(you) return you:get_morale_level() end

-- Fork skill ceilings.  Base BN caps skills at 10 ("thorough mastery"); the
-- MoM grants train via SkillLevel:train() with skip_scaling, which bypasses that
-- cap, so Metaphysics was climbing unbounded (playtest reached 29).  Cap it at
-- 15 (the intended psionic ceiling): gain_skill_exp refuses to push a capped
-- skill past its ceiling, and enforce_skill_caps clamps any existing overage
-- (called from the load hooks so a live over-cap character is corrected on load).
M.SKILL_CAPS = { metaphysics = 15 }

-- u_skill_exp('id', 'format': 'raw') += n
-- SkillLevel:train(amount, skip_scaling) — DDA's 'raw' format bypasses any
-- internal scaling (the EOC math already multiplies by
-- game_option('SKILL_TRAINING_SPEED') itself), so skip_scaling=true here
-- mirrors that: it adds straight to _exercise (skill.cpp:237).
function M.gain_skill_exp(you, skill_id, amount)
  local sid = skill_tid(skill_id)
  local cap = M.SKILL_CAPS[skill_id]
  if cap and you:get_skill_level(sid) >= cap then return end   -- already at ceiling
  you:get_skill_level_object(sid):train(math.floor(amount + 0.5), true)
  -- A single large grant can vault multiple levels at once; clamp any overshoot
  -- so the ceiling is exact, not "the last level before a big grant".
  if cap and you:get_skill_level(sid) > cap then
    you:set_skill_level(sid, cap)
  end
end

-- Clamp any capped skill sitting above its ceiling down to the ceiling.  Run
-- from the game load / start hooks so a character who banked levels before the
-- cap existed (or under an older build) is corrected the next time they load.
function M.enforce_skill_caps(you)
  if not you then return end
  for skill_id, cap in pairs(M.SKILL_CAPS) do
    local sid = skill_tid(skill_id)
    if you:get_skill_level(sid) > cap then
      you:set_skill_level(sid, cap)
    end
  end
end

-- === Nether Attunement (spec Rev 3, amended QA round 3) ====================

-- The attunement meter is stored on the character in the UPSTREAM VITAMIN
-- SCALE (0..250) via a character var; the drain effect's intensity (0..12)
-- is a derived display band.  Every transpiled comparison and increment
-- (thresholds 15/35/../245, "+= rand(3)", "/ 25", "* 2" durations) is
-- vitamin-scale, and intensity alone cannot accumulate sub-band increments,
-- so both accessors below must speak vitamin-scale.  Band mapping is
-- upstream vitamins.json disease_excess: intensity i covers 20i-5..20i+14.
M.ATTUNEMENT_EFFECT = "effect_disease_psionic_drain"
M.ATTUNEMENT_VAR = "mom_nether_attunement_meter"  -- raw set_value key
M.ATTUNEMENT_MAX = 250

function M.attunement(you)
  local v = tonumber(you:get_value(M.ATTUNEMENT_VAR))
  if v then return v end
  -- Migration: derive from a pre-existing effect intensity (band start).
  local eid = effect_tid(M.ATTUNEMENT_EFFECT)
  if not you:has_effect(eid) then return 0 end
  local i = you:get_effect_int(eid)
  return i <= 0 and 0 or (20 * i - 5)
end

-- Write the meter and sync the display effect's intensity to the band.
function M.attunement_set(you, v)
  v = math.max(0, math.min(math.floor(v + 0.5), M.ATTUNEMENT_MAX))
  you:set_value(M.ATTUNEMENT_VAR, tostring(v))
  local band = math.max(0, math.min(math.floor((v + 5) / 20), 12))
  local eid = effect_tid(M.ATTUNEMENT_EFFECT)
  if band <= 0 then
    you:remove_effect(eid)
  else
    -- Long duration: the 5-minute Lua decay tick (mom_eoc) is the meter's
    -- real clock, mirroring the upstream vitamin rate of 1 per 5 minutes.
    you:add_effect(eid, TimeDuration.from_hours(12), nil, band)
  end
end

-- Concentration powers currently sustained — derived, never stored.
-- Replaces u_vitamin('vitamin_maintained_powers').  Two populators:
--   * mom_hooks bulk-registers the transpiler's manifest (mod.gen_maintenance,
--     one entry per upstream EOC that runs EOC_POWER_MAINTENANCE_PLUS_ONE);
--   * mom_eoc registers the hand-written pilots and the fork-original powers,
--     which have no upstream EOC for the transpiler to have seen.
-- Registration is idempotent because those two sets overlap.
--
-- Weight, not a flag: upstream expresses "this power costs 2 concentration"
-- by naming EOC_POWER_MAINTENANCE_PLUS_ONE twice in the same run_eocs list.
M.maintenance_effects = {}
M.maintenance_weight = {}
M.maintenance_eid = {}   -- id -> pre-resolved EffectTypeId, filled at register time

function M.register_maintenance(id, weight)
  if M.maintenance_weight[id] == nil then
    table.insert(M.maintenance_effects, id)
    M.maintenance_eid[id] = effect_tid(id)
    M.maintenance_weight[id] = weight or 1
  else
    -- Both populators saw it; keep the costlier reading rather than the last.
    M.maintenance_weight[id] = math.max(M.maintenance_weight[id], weight or 1)
  end
end

-- Called from several per-cast/per-tick formulas (concentration-break odds,
-- per-turn drain, attunement gain, the concentration-practice gates,
-- EOC_..._VS_LIMIT) -- walks all ~68 registered maintenance effects every
-- call, so the id lookup MUST be pre-resolved (M.maintenance_eid), not
-- reconstructed here; that used to be a fresh EffectTypeId.new() per entry
-- per call and was the single largest per-cast cost for a psion.
--
-- Turn-scoped avatar cache (perf fix 2026-08-14): even pre-resolved, the walk
-- is ~68 has_effect boundary calls, and the concentration updater chain alone
-- calls this three times per tick (its own gate + the VS_LIMIT condition's two
-- reads), with ~33 more call sites across the per-cast spellcasting_finish /
-- opens_spellbook EOCs.  The count only changes when an effect is added or
-- removed, so cache it for the current turn and let every write path bump a
-- generation counter: U.add_effect / U.set_effect_intensity (the transpiled
-- add/removal verbs) and the four effect add/remove hooks in mom_hooks (which
-- also catch natural expiry of any flagged effect).  A maintained effect that
-- expires through a path none of those see goes stale for AT MOST the rest of
-- the current turn -- the turn key refreshes it on the next tick.
local _mc_turn, _mc_gen_seen, _mc_val = -1, -1, 0
local _mc_gen = 0
function M.maintained_dirty() _mc_gen = _mc_gen + 1 end
-- Same, but only when the effect that changed is one of the ~68 the count
-- actually walks.  The blanket version fired on EVERY effect add and remove --
-- `winded` from a sprint, a fresh `bleed`, any of the dozens of ambient effects
-- a turn can bring -- and each one threw away a cache whose value could not
-- have changed, forcing the next reader to re-walk all 68 has_effect calls.
-- Callers that know the id (the four effect hooks, U.add_effect,
-- U.set_effect_intensity) should use this; maintained_dirty() stays for the
-- callers that don't.
function M.maintained_dirty_id(id)
  if id ~= nil and M.maintenance_weight[id] == nil then return end
  _mc_gen = _mc_gen + 1
end
-- Read the generation counter.  Other turn-scoped caches (the concentration
-- formulas in mom_hooks) hang off the same "an effect was added or removed"
-- signal, so they read this rather than each keeping their own hook.
function M.maintained_gen() return _mc_gen end
function M.maintained_count(you)
  local avatar = you.is_avatar ~= nil and you:is_avatar()
  local turn
  if avatar then
    turn = gapi.current_turn():to_turn()
    if _mc_turn == turn and _mc_gen_seen == _mc_gen then return _mc_val end
  end
  local n = 0
  for _, id in ipairs(M.maintenance_effects) do
    if you:has_effect(M.maintenance_eid[id]) then
      n = n + (M.maintenance_weight[id] or 1)
    end
  end
  if avatar then
    _mc_turn, _mc_gen_seen, _mc_val = turn, _mc_gen, n
  end
  return n
end

-- psionic_power_modifiers() jmath: attunement / weariness product.
-- TODO(phase3): transpile the real jmath function; 1.0 is the reference value
-- the spell fits were computed at.
function M.power_modifiers(you)
  return 1.0
end

-- u_vitamin() calls that survive transpilation are a porting bug:
-- psionic_drain -> M.attunement, maintained_powers -> M.maintained_count,
-- psi_learning_counter -> deleted (native spell XP), base-game vitamins ->
-- per-power Phase 4 redesign.  Fail loudly.
function M.vitamin(you, vitamin_id)
  error("mom_math.vitamin('" .. tostring(vitamin_id)
    .. "'): vitamins are designed out (spec Rev 3); route this call to its replacement")
end

return M
