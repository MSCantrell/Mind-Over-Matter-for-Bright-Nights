-- mom_named_weapons: weapons that earn names (2026-11-08, "living world" idea #2).
-- HAND-AUTHORED.
--
-- Every kill made with a wielded weapon -- by you or by an allied NPC -- is
-- counted on the weapon itself (item vars, so the record travels with it):
--   10 kills    a Note line appears: the tally, first blood, the hardest foe
--   250 kills   the weapon earns a name, then every 250 more the name grows,
--               Dwarf Fortress style (user spec 2026-11-08):
--     250   Copperbelt
--     500   Copperbelt the Spider
--     750   Copperbelt the Grand Spider
--     1000  Copperbelt the Grand Spider of Goblets
--     1250  Golden Copperbelt the Grand Spider of Goblets
--     1500  Golden Copperbelt the Grand Spider of Merry Goblets   (final)
-- Shown as "<full name> (fire axe)".  Rarity, not volume: most gear never
-- gets there.
--
-- Attribution (BN gives no "killed with" on death; item::kill_count is not
-- bound to Lua):
--   * melee: on_creature_melee_attacked fires after the blow lands
--     (melee.cpp:1778); a target at <= 0 HP was killed by it, credit the
--     attacker's wielded item on the spot.
--   * guns: on_shoot (ranged.cpp:1579) stamps the shooter with the turn;
--     on_mon_death (monster.cpp:3823) with that shooter as killer within a
--     turn credits the wielded gun.
--   * NOT counted: thrown items, psionic powers, traps, fire, pets' kills.
--
-- Item vars: mom_nw_kills (num), mom_nw_first / mom_nw_best ("foe|date"),
-- mom_nw_best_diff (num), mom_nw_name, mom_nw_t_noun / _t_adj / _of_noun /
-- _pre_adj / _of_adj (the epithet parts), mom_nw_full (last name we wrote),
-- mom_nw_base, mom_nw_note
-- (our segment of item_note, kept after the player's own inscription the same
-- way mom_psychometry does).  The visible name is BN's `name` item var, which
-- replaces the type name in tname (item.cpp:11500).
return function(mod)
  local NW = {}
  mod.named_weapons = NW

  NW.NOTE_AT, NW.NAME_AT, NW.STEP = 10, 250, 250
  local SHOT_KEY, CREDITED_KEY = "mom_nw_shot", "mom_nw_credited"

  -- ---------------------------------------------------------------- word banks
  -- Base name: DF-style compound of two plain words (Copperbelt, Ashfang).
  local HEAD = {
    "Ash", "Bell", "Bitter", "Black", "Bone", "Brass", "Candle", "Carrion", "Cinder",
    "Cold", "Copper", "Dusk", "Ember", "Gall", "Grave", "Grief", "Hollow", "Hush",
    "Iron", "Kettle", "Lantern", "Marrow", "Mire", "Mourn", "Night", "Oak", "Red",
    "Rust", "Salt", "Shroud", "Skull", "Sorrow", "Stone", "Thorn", "Tin", "Vigil",
    "Widow", "Winter",
  }
  local TAIL = {
    "bane", "belt", "biter", "breaker", "call", "drinker", "fang", "gate", "hew",
    "kiss", "maker", "mark", "reaver", "rest", "shrift", "song", "spite", "thirst",
    "tooth", "wake", "ward", "wick", "word", "wright",
  }
  -- Epithet parts, added one per 250 kills in this order.
  local T_NOUN = {      -- "the Spider"
    "Spider", "Wolf", "Crow", "Hound", "Widow", "Shepherd", "Mason", "Lantern",
    "Thorn", "Tide", "Bell", "Harrow", "Ferryman", "Gardener", "Butcher", "Moth",
    "Viper", "Bishop", "Miller", "Storm",
  }
  local T_ADJ = {       -- "the Grand Spider"
    "Grand", "Bitter", "Silent", "Red", "Hollow", "Patient", "Pale", "Last",
    "Restless", "Old", "Weary", "Faithful", "Hungry", "Laughing", "Black",
  }
  local OF_NOUN = {     -- "of Goblets"
    "Goblets", "Ashes", "Bells", "Rivers", "Graves", "Teeth", "Winters", "Lanterns",
    "Crows", "Harvests", "Hymns", "Doors", "Roads", "Bones", "Embers", "Storms",
  }
  local PRE_ADJ = {     -- "Golden Copperbelt"
    "Golden", "Pale", "Weeping", "Iron", "Crimson", "Gentle", "Ashen", "Grim",
    "Blessed", "Wretched", "Silver", "Smiling",
  }
  local OF_ADJ = {      -- "of Merry Goblets"
    "Merry", "Broken", "Endless", "Drowned", "Burning", "Quiet", "Shattered",
    "Forgotten", "Thousand", "Bleeding", "Unmarked", "Hollow",
  }
  -- {var, bank} in the order they are earned (tiers 2..6).
  local PARTS = {
    { "mom_nw_t_noun", T_NOUN }, { "mom_nw_t_adj", T_ADJ }, { "mom_nw_of_noun", OF_NOUN },
    { "mom_nw_pre_adj", PRE_ADJ }, { "mom_nw_of_adj", OF_ADJ },
  }
  local MELEE_WEAR = {
    "The edge is chipped where it met %s.",
    "The grip is stained dark and worn to the shape of a hand.",
    "It is notched along its length, one notch for every life.",
    "Something of %s is still worked into the grain.",
    "It hangs heavier than it should.",
  }
  local GUN_WEAR = {
    "Tally marks are scratched into it, row on row.",
    "The finish is worn bright where a thumb rests between shots.",
    "It still smells of the day it stopped %s.",
    "It is warm to the touch, even cold.",
  }

  local function pick(t) return t[gapi.rng(1, #t)] end

  local function today()
    local s = tostring(gapi.current_turn())
    local season, day = s:match("(%a+), day (%d+)")
    return season and (season .. " " .. day) or s
  end

  local function turn_now()
    return gapi.current_turn():to_turn()
  end

  local function article(name)
    return (name:match("^[AEIOUaeiou]") and "an " or "a ") .. name
  end

  -- ---------------------------------------------------------------- note text
  local function write_note(it, ours)
    local cur = it:get_var_str("item_note", "")
    local last = it:get_var_str("mom_nw_note", "")
    local prev = cur
    if last ~= "" then
      local s, e = cur:find(last, 1, true)
      if s then prev = (cur:sub(1, s - 1) .. cur:sub(e + 1)):gsub("^%s+", ""):gsub("%s+$", "") end
    end
    it:set_var_str("item_note", (prev ~= "" and (prev .. "  ") or "") .. ours)
    it:set_var_str("mom_nw_note", ours)
  end

  local function split(rec)
    local foe, date = rec:match("^(.-)|(.*)$")
    return foe, date
  end

  local function display_name(it)
    local function v(k) return it:get_var_str(k, "") end
    local n = v("mom_nw_name")
    if v("mom_nw_pre_adj") ~= "" then n = v("mom_nw_pre_adj") .. " " .. n end
    if v("mom_nw_t_noun") ~= "" then
      local t = v("mom_nw_t_noun")
      if v("mom_nw_t_adj") ~= "" then t = v("mom_nw_t_adj") .. " " .. t end
      n = n .. " the " .. t
    end
    if v("mom_nw_of_noun") ~= "" then
      local o = v("mom_nw_of_noun")
      if v("mom_nw_of_adj") ~= "" then o = v("mom_nw_of_adj") .. " " .. o end
      n = n .. " of " .. o
    end
    return n
  end

  local function build_note(it)
    local kills = math.floor(it:get_var_num("mom_nw_kills", 0))
    local parts = {}
    local name = it:get_var_str("mom_nw_name", "")
    if name ~= "" then
      parts[#parts + 1] = string.format("%s has taken %d lives.", display_name(it), kills)
    else
      parts[#parts + 1] = string.format("%d kills.", kills)
    end
    local ffoe, fdate = split(it:get_var_str("mom_nw_first", ""))
    if ffoe then parts[#parts + 1] = string.format("First blood: %s, %s.", article(ffoe), fdate) end
    local bfoe, bdate = split(it:get_var_str("mom_nw_best", ""))
    if bfoe and bfoe ~= ffoe then
      parts[#parts + 1] = string.format("Hardest fight: %s, %s.", article(bfoe), bdate)
    end
    local wear = it:get_var_str("mom_nw_wear", "")
    if wear ~= "" then
      parts[#parts + 1] = (wear:gsub("%%s", "the " .. (bfoe or ffoe or "dead")))
    end
    return "[Kills] " .. table.concat(parts, "  ")
  end

  -- ---------------------------------------------------------------- crediting
  local function eligible(it)
    if not it or it:is_null() then return false end
    if it:is_stackable() or it:is_corpse() then return false end
    return true
  end

  local function wielded(ch)
    for _, it in ipairs(ch:all_items(false)) do
      if ch:is_wielding(it) then return it end
    end
    return nil
  end

  local function counts(ch)
    if ch:is_avatar() then return true end
    local guy = ch:as_npc()
    local you = gapi.get_avatar()
    return guy ~= nil and you ~= nil and guy:is_ally(you)
  end

  local function owner_phrase(ch, base)
    if ch:is_avatar() then return "Your " .. base end
    return ch:get_name() .. "'s " .. base
  end

  function NW.credit(ch, it, mon)
    if not eligible(it) or mon:is_hallucination() then return end
    local mt = mon:get_type():obj()
    NW.record(ch, it, mt:nname(1), mt.difficulty or 0)
  end

  function NW.record(ch, it, foe, diff)
    local date = today()

    local kills = math.floor(it:get_var_num("mom_nw_kills", 0)) + 1
    it:set_var_num("mom_nw_kills", kills)
    if it:get_var_str("mom_nw_first", "") == "" then
      it:set_var_str("mom_nw_first", foe .. "|" .. date)
    end
    if it:get_var_str("mom_nw_best", "") == "" or diff > it:get_var_num("mom_nw_best_diff", -1) then
      it:set_var_str("mom_nw_best", foe .. "|" .. date)
      it:set_var_num("mom_nw_best_diff", diff)
    end

    if kills >= NW.NAME_AT then
      local tier = math.min(1 + math.floor((kills - NW.NAME_AT) / NW.STEP), 1 + #PARTS)
      local before = it:get_var_str("mom_nw_name", "") ~= "" and display_name(it) or nil
      if not before then
        it:set_var_str("mom_nw_name", pick(HEAD) .. pick(TAIL))
        it:set_var_str("mom_nw_base", it:get_type():obj():get_name(1))
        it:set_var_str("mom_nw_wear", pick(it:is_gun() and GUN_WEAR or MELEE_WEAR))
      end
      for i = 1, tier - 1 do
        local key, bank = PARTS[i][1], PARTS[i][2]
        if it:get_var_str(key, "") == "" then it:set_var_str(key, pick(bank)) end
      end
      local full = display_name(it)
      if full ~= before then
        local base = it:get_var_str("mom_nw_base", "")
        -- Someone else's name (another mod, a unique item) wins; ours stays in the note.
        local cur = it:get_var_str("name", "")
        local ours = cur == "" or cur == it:get_var_str("mom_nw_full", "")
          -- items named by the first draft (2026.11.8-H) have no mom_nw_full yet
          or cur == it:get_var_str("mom_nw_name", "") .. " (" .. base .. ")"
          or cur:find(it:get_var_str("mom_nw_name", "") .. " the ", 1, true) == 1
        if ours then
          it:set_var_str("name", full .. " (" .. base .. ")")
          it:set_var_str("mom_nw_full", full .. " (" .. base .. ")")
        end
        if before then
          gapi.add_msg(MsgType.good, string.format("%s is now known as %s.", before, full))
        else
          gapi.add_msg(MsgType.good, string.format("%s has earned a name: %s.", owner_phrase(ch, base), full))
        end
      end
    end
    if kills >= NW.NOTE_AT then write_note(it, build_note(it)) end
  end

  -- ---------------------------------------------------------------- hooks
  local prev_melee = mod.on_melee_attacked
  function mod.on_melee_attacked(params)
    if prev_melee then prev_melee(params) end
    if not params or not params.success then return end
    local ok, err = pcall(function()
      local ch, victim = params.char, params.target
      if not ch or not victim or not victim:is_monster() then return end
      ch = ch:as_character()
      if not ch or not counts(ch) then return end
      if victim:get_hp() > 0 then return end
      local mon = victim:as_monster()
      if mon:get_value(CREDITED_KEY) == "1" then return end
      mon:set_value(CREDITED_KEY, "1")
      NW.credit(ch, wielded(ch), mon)
    end)
    if not ok then gdebug.log_error("MoM-BN named weapons (melee): " .. tostring(err)) end
  end

  function mod.on_shoot(params)
    pcall(function()
      local ch = params.shooter
      if ch and counts(ch) then ch:set_value(SHOT_KEY, tostring(turn_now())) end
    end)
  end

  local prev_death = mod.on_mon_death
  function mod.on_mon_death(params)
    if prev_death then prev_death(params) end
    local ok, err = pcall(function()
      local mon, killer = params.mon, params.killer
      if not mon or not killer or killer:is_monster() then return end
      if mon:get_value(CREDITED_KEY) == "1" then return end
      local ch = killer:as_character()
      if not ch or not counts(ch) then return end
      local shot = tonumber(ch:get_value(SHOT_KEY))
      if not shot or turn_now() - shot > 1 then return end
      local it = wielded(ch)
      if it and it:is_gun() then
        mon:set_value(CREDITED_KEY, "1")
        NW.credit(ch, it, mon)
      end
    end)
    if not ok then gdebug.log_error("MoM-BN named weapons (death): " .. tostring(err)) end
  end

  -- Console helpers: mod.named_weapons.show() prints the wielded item's record;
  -- mod.named_weapons.add(n) credits n fake kills (testing the tiers, e.g. add(1500)).
  function NW.show()
    local you = gapi.get_avatar()
    local it = you and wielded(you)
    if not it then return "nothing wielded" end
    return string.format("kills=%d name=%s note=%s", math.floor(it:get_var_num("mom_nw_kills", 0)),
      it:get_var_str("name", "-"), it:get_var_str("mom_nw_note", "-"))
  end

  function NW.add(n, foe)
    local you = gapi.get_avatar()
    local it = you and wielded(you)
    if not eligible(it) then return "nothing countable wielded" end
    for _ = 1, n or 1 do NW.record(you, it, foe or "zombie", 0) end
    return NW.show()
  end
end
