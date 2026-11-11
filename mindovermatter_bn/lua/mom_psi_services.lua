-- mom_psi_services: the Green Pin payoff (2026-11-04, user design).  HAND-AUTHORED.
--
-- Bringing home a psion of school X unlocks that school's service.  From then on ANY
-- living Psionic Alliance psion of school X will do it -- the named residents, or
-- recruits you brought in -- so if Theo dies, the next biokinetic you rescue heals you
-- instead.  Each psion has their OWN cooldown, so more psions of a school = more help.
--
--   biokinetic      heal wounds, clear radiation (+ BN's native bionic install/remove, in JSON)
--   electrokinetic  charge every battery you carry, and your bionic power
--   telekinetic     repair all damaged gear you carry
--   pyrokinetic     warm you through: clear cold/frostbite, 12 h of body heat
--   photokinetic    fresh vegetables from the basement garden
--   clairsentient   reveal the map around the nearest unseen place of a type
--   teleporter      send you (one way) to one of your map notes, landing within 3 OMT
--   telepath        calm your mind: remove bad morale, +30 morale for 24 h
--
-- Wiring:
--   * Unlock = dialogue var npctalk_var_dialogue_psi_alliance_svc_<school> = "yes" on the
--     avatar, so the JSON can hide the "use your gift" line until it's earned.  Set by
--     mod.psi_service_unlock (called when a recruit's green-pin card is written) and
--     backfilled from the cards on every load.
--   * npcs/psi_alliance.json: TALK_PSI_SERVICE responses put a 2-second marker effect
--     mom_psi_svc_<kind> on the NPC.  The effect-added hook fires on that NPC's next turn
--     (after the dialogue closes); the handler queues the real work onto util.queue so it
--     runs from on_every_x, not from inside NPC turn processing -- the teleport unloads
--     every NPC, which must never happen mid-iteration.
--   * Cooldowns: avatar value mom_psi_svc_cd_<npc character id>_<kind> = turn of last use.
--     Not an NPC effect: NPC effects stop ticking while the camp is unloaded, so the
--     cooldown would freeze whenever you were away.
return function(mod)
  local U = mod.u
  local util = mod.util

  local HOUR = 60 * 60

  local SCHOOL_TRAITS = {
    biokinetic = "BIOKINETIC", clairsentient = "CLAIRSENTIENT",
    electrokinetic = "ELECTROKINETIC", photokinetic = "PHOTOKINETIC",
    pyrokinetic = "PYROKINETIC", telekinetic = "TELEKINETIC",
    telepath = "TELEPATH", teleporter = "TELEPORTER",
  }

  -- What the thank-you popup promises, per school.
  local PITCH = {
    biokinetic = "If you get hurt out there, come and find me.  I can knit bone, close "
      .. "wounds, draw out radiation, and I can put in or take out bionics, if you've got them.",
    electrokinetic = "Bring me your dead batteries.  All of them.  It's the least I can do.",
    telekinetic = "Anything you carry that's bent, cracked or falling apart, I can put back "
      .. "the way it was.  Just ask.",
    pyrokinetic = "When the cold gets into you, come and sit by me.  I'll warm you right "
      .. "through, and it'll last.",
    photokinetic = "The basement garden's doing well.  Come by and I'll send you off with "
      .. "something fresh.",
    clairsentient = "If you need to know what's out there, tell me what you're looking for.  "
      .. "I'll look for you.",
    teleporter = "If you need to be somewhere, mark it on your map and show me.  I can't "
      .. "bring you back, and I can't land you on a pin, but I'll get you close.",
    telepath = "When your head gets too loud, come and see me.  I can quiet it.",
  }

  local SERVICE_LABEL = {
    biokinetic = "healing and bionic surgery", electrokinetic = "charging",
    telekinetic = "gear repair", pyrokinetic = "warmth", photokinetic = "fresh produce",
    clairsentient = "scouting", teleporter = "teleport", telepath = "calming your mind",
  }

  -- kind -> { cooldown in seconds, verb used in "not ready" lines }
  local KINDS = {
    heal    = { cd = 24 * HOUR, tired = "is still worn out from patching you up" },
    charge  = { cd = 24 * HOUR, tired = "hasn't built the charge back up yet" },
    repair  = { cd = 24 * HOUR, tired = "is still rubbing their temples from the last repair job" },
    warm    = { cd = 24 * HOUR, tired = "is still running cold from the last time" },
    produce = { cd = 72 * HOUR, tired = "says nothing new has ripened yet" },
    scout   = { cd = 24 * HOUR, tired = "is still seeing double from the last search" },
    send    = { cd = 24 * HOUR, tired = "can't manage another jump yet" },
    calm    = { cd = 72 * HOUR, tired = "says your mind needs time to settle on its own first" },
  }

  local function svc_var(school)
    return "npctalk_var_dialogue_psi_alliance_svc_" .. school
  end

  local function first_name(full)
    full = tostring(full or "")
    return full:match("^(%S+)") or full
  end

  local function now() return gapi.current_turn():to_turn() end

  local function npc_key(npc)
    local ok, id = pcall(function() return npc:getID():get_value() end)
    if ok and id then return tostring(id) end
    return tostring(npc.name)
  end

  local function cd_key(npc, kind) return "mom_psi_svc_cd_" .. npc_key(npc) .. "_" .. kind end



  local function hours_text(sec)
    local h = math.ceil(sec / HOUR)
    if h <= 1 then return "about an hour" end
    if h < 48 then return "about " .. h .. " hours" end
    return "about " .. math.floor(h / 24 + 0.5) .. " days"
  end

  local function log_fail(what, err)
    gdebug.log_warn("MoM-BN: psi service " .. what .. " failed: " .. tostring(err))
  end

  -- ------------------------------------------------------------ unlock + thanks
  local function school_of(guy)
    for school, trait in pairs(SCHOOL_TRAITS) do
      if guy:has_trait(MutationBranchId.new(trait)) then return school end
    end
    return nil
  end

  -- Someone in camp of `school` to say thank you, preferring anyone but the recruit.
  local function thanker(school, recruit_name)
    local trait = MutationBranchId.new(SCHOOL_TRAITS[school])
    local fallback
    for _, guy in ipairs(gapi.get_all_npcs()) do
      local ok, match = pcall(function()
        return guy:get_faction_id():str() == "psi_alliance" and guy:has_trait(trait)
          and not guy:is_dead()
      end)
      if ok and match then
        if guy.name ~= recruit_name then return guy.name end
        fallback = guy.name
      end
    end
    return fallback
  end

  function mod.psi_service_unlock(school, recruit_name)
    if not SCHOOL_TRAITS[school] then return end
    local you = gapi.get_avatar()
    if not you then return end
    if you:get_value(svc_var(school)) == "yes" then return end
    you:set_value(svc_var(school), "yes")
    local who = thanker(school, recruit_name) or recruit_name or "Someone"
    local other = (who ~= recruit_name) and recruit_name
    local text = first_name(who) .. " finds you while "
      .. (other and (first_name(other) .. " is") or "you are") .. " still getting settled.\n\n"
      .. "\"You brought home a " .. school .. ".  One of mine.  I won't forget that.\"\n\n"
      .. "\"" .. PITCH[school] .. "\"\n\n"
      .. "(Any " .. school .. " living at the quarry will now help you with "
      .. SERVICE_LABEL[school] .. ".  Ask them what their gift can do for you.)"
    -- Deferred: this runs from the settle marker, inside NPC turn processing.
    util.queue_eoc(function() pcall(U.popup, text) end, you, 1)
  end

  -- Backfill from the green-pin cards (saves from before this module existed).
  local function backfill(you)
    if not mod.psi_green_pin_schools then return end
    for school in pairs(mod.psi_green_pin_schools()) do
      if SCHOOL_TRAITS[school] then you:set_value(svc_var(school), "yes") end
    end
  end

  local prev_load = mod.on_game_load
  function mod.on_game_load(...)
    local r
    if prev_load then r = prev_load(...) end
    local ok, err = pcall(function()
      local you = gapi.get_avatar()
      if you then backfill(you) end
    end)
    if not ok then log_fail("unlock backfill", err) end
    return r
  end

  -- ------------------------------------------------------------ the services
  local function eff(id) return EffectTypeId.new(id) end

  local S = {}

  function S.heal(you, npc)
    local n = 0
    for _, bp in ipairs(you:get_all_body_parts(false)) do
      local cur, mx = you:get_part_hp_cur(bp), you:get_part_hp_max(bp)
      if cur < mx then you:set_part_hp_cur(bp, mx); n = n + 1 end
    end
    for _, id in ipairs({ "bleed", "bite", "infected", "disabled" }) do
      pcall(function()
        if you:has_effect(eff(id)) then you:remove_effect(eff(id)); n = n + 1 end
      end)
    end
    pcall(function() if you:get_pain() > 0 then you:set_pain(0); n = n + 1 end end)
    local rad = false
    pcall(function() if you:get_rad() > 0 then you:set_rad(0); n = n + 1; rad = true end end)
    if n == 0 then
      return false, first_name(npc.name) .. " looks you over twice.  \"There's nothing wrong "
        .. "with you.  Go away.\"  It sounds almost fond."
    end
    return true, first_name(npc.name) .. " lays both hands on you.  Heat runs under your skin; "
      .. "torn things knit, bruises fade, and broken bone grinds back together.  When "
      .. first_name(npc.name) .. " lets go, nothing hurts."
      .. (rad and "  \"And you were glowing a little.  Not anymore.  Stay out of wherever "
          .. "that was.\"" or "")
  end

  local function is_battery_powered(it)
    local ok, yes = pcall(function()
      local cur = it:ammo_current()
      if cur and cur:str() == "battery" then return true end
      -- slot_magazine is a bound FUNCTION (VALUE_PTR_MEMB_N, catalua_bindings_item.cpp:655),
      -- not a field: `.slot_magazine` returned the function itself, `.default_ammo` on it
      -- threw, and every fully drained cell (ammo_current() == null) was skipped. 2026-11-08.
      local mag = it:get_type():obj():slot_magazine()
      return mag ~= nil and mag.default_ammo:str() == "battery"
    end)
    return ok and yes
  end

  function S.charge(you, npc)
    local n = 0
    for _, it in ipairs(you:all_items(false)) do
      if is_battery_powered(it) then
        local cap = U.item_power_max(it)
        if cap > 0 and U.item_power(it) < cap then
          U.item_set_power(it, cap); n = n + 1
        end
      end
    end
    local bio = false
    pcall(function()
      local mx = you:get_max_power_level()
      if you:get_power_level() < mx then you:set_power_level(mx); bio = true end
    end)
    if n == 0 and not bio then
      return false, first_name(npc.name) .. " holds out a hand, frowns, and lowers it.  "
        .. "\"Everything you've got is already full.\""
    end
    local parts = {}
    if n > 0 then parts[#parts + 1] = n .. (n == 1 and " device" or " devices") end
    if bio then parts[#parts + 1] = "your bionics" end
    return true, first_name(npc.name) .. " takes your wrist.  Every hair on your arm stands up, "
      .. "and the air smells like a storm.  " .. table.concat(parts, " and ")
      .. (#parts > 1 and " are" or (n == 1 and not bio and " is" or " are")) .. " fully charged."
  end

  function S.repair(you, npc)
    local n = 0
    for _, it in ipairs(you:all_items(false)) do
      pcall(function()
        if it:get_damage() > 0 then it:set_damage(0); n = n + 1 end
      end)
    end
    if n == 0 then
      return false, first_name(npc.name) .. " turns your gear over in the air, one piece at a "
        .. "time, and sets it all back down.  \"Nothing to fix.\""
    end
    return true, "Your gear lifts off you and hangs in the air around " .. first_name(npc.name)
      .. ".  Dents push out, cracks close, frayed straps pull tight.  " .. n
      .. (n == 1 and " item settles" or " items settle") .. " back into your hands like new."
  end

  function S.warm(you, npc)
    for _, id in ipairs({ "frostbite", "cold" }) do
      pcall(function() you:remove_effect(eff(id)) end)
    end
    you:add_effect(eff("mom_psi_warmed"), TimeDuration.from_hours(12))
    return true, first_name(npc.name) .. " cups your hands between theirs and breathes on "
      .. "them.  The heat goes in and keeps going, down your arms and into your chest, "
      .. "until even your feet are warm.  It feels like it will last a while."
  end

  local PRODUCE = { "tomato", "cucumber", "lettuce", "carrot", "potato", "onion",
                    "cabbage", "zucchini", "broccoli" }
  local PRODUCE_NAME = {   -- { one, many }
    tomato = { "tomato", "tomatoes" }, cucumber = { "cucumber", "cucumbers" },
    lettuce = { "head of lettuce", "heads of lettuce" }, carrot = { "carrot", "carrots" },
    potato = { "potato", "potatoes" }, onion = { "onion", "onions" },
    cabbage = { "cabbage", "cabbages" }, zucchini = { "zucchini", "zucchini" },
    broccoli = { "head of broccoli", "heads of broccoli" },
  }

  function S.produce(you, npc)
    local got = {}
    for _ = 1, gapi.rng(4, 7) do
      local id = PRODUCE[gapi.rng(1, #PRODUCE)]
      local ok = pcall(function() you:create_item(ItypeId.new(id), 1) end)
      if ok then got[id] = (got[id] or 0) + 1 end
    end
    local names = {}
    for id, c in pairs(got) do
      names[#names + 1] = c .. " " .. PRODUCE_NAME[id][c == 1 and 1 or 2]
    end
    table.sort(names)
    if #names == 0 then
      return false, "The basement shelves are bare today."
    end
    return true, first_name(npc.name) .. " comes back up from the basement, glowing faintly "
      .. "and squinting, with an armful of vegetables still warm from the light: "
      .. table.concat(names, ", ") .. "."
  end

  -- Places a clairsentient can look for and a teleporter can send you to.  Prefixes as in
  -- mom_graffiti.lua.  `lab = true` entries are scouting-only (no dropping you on a lab).
  local PLACES = {
    { what = "town", p = { "house" } },
    { what = "pharmacy", p = { "s_pharm" } },
    { what = "gun store", p = { "s_gun" } },
    { what = "grocery store", p = { "s_grocery" } },
    { what = "hospital", p = { "hospital" } },
    { what = "hardware store", p = { "s_hardware" } },
    { what = "sporting goods store", p = { "s_sports" } },
    { what = "gas station", p = { "s_gas" } },
    { what = "police station", p = { "police" } },
    { what = "evac shelter", p = { "evac_center", "shelter" } },
    { what = "farm", p = { "farm" } },
    { what = "lab", p = { "lab", "central_lab" }, lab = true },
    { what = "military site", p = { "mil_", "bunker" }, lab = true },
  }
  local SEARCH = 150   -- overmap tiles

  local function nearest(origin, prefixes, min_d, unseen_only)
    local best, bd
    for _, pre in ipairs(prefixes) do
      local fp = OmtFindParams.new()
      fp:add_type(pre, OtMatchType.PREFIX)
      fp:set_search_range(min_d, SEARCH)
      fp:set_search_layers(origin.z, origin.z)
      fp.existing_only = true
      if unseen_only then fp.seen = false end
      local hit = overmapbuffer.find_closest(origin, fp)
      if hit then
        local d = math.max(math.abs(hit.x - origin.x), math.abs(hit.y - origin.y))
        if not bd or d < bd then best, bd = hit, d end
      end
    end
    return best, bd
  end

  local function compass(dx, dy)
    local ns = (dy < -math.abs(dx) / 2) and "north" or ((dy > math.abs(dx) / 2) and "south" or "")
    local ew = (dx > math.abs(dy) / 2) and "east" or ((dx < -math.abs(dy) / 2) and "west" or "")
    return ns .. ew
  end

  local function pick_place(title, allow_labs)
    local opts, names = {}, {}
    for _, pl in ipairs(PLACES) do
      if allow_labs or not pl.lab then
        opts[#opts + 1] = pl
        names[#names + 1] = "The nearest " .. pl.what
      end
    end
    local r = U.select_menu(title, names, nil, nil, nil)
    return r and opts[r] or nil
  end

  function S.scout(you, npc)
    local pl = pick_place(first_name(npc.name) .. " closes their eyes.  \"What am I looking for?\"",
                          true)
    if not pl then return nil end
    local here = coords.project_to_omt(you:abs_pos())
    local hit, d = nearest(here, pl.p, 1, true)
    local fresh = true
    if not hit then hit, d = nearest(here, pl.p, 1, false); fresh = false end
    if not hit then
      return false, first_name(npc.name) .. " searches for a long time, then opens their eyes.  "
        .. "\"Nothing.  Not for a long way in any direction.\""
    end
    overmapbuffer.reveal(hit, 4)
    pcall(function()
      if not overmapbuffer.get_note(hit) then
        overmapbuffer.set_note(hit, first_name(npc.name) .. ": " .. pl.what)
      end
    end)
    local dir = compass(hit.x - here.x, hit.y - here.y)
    return true, first_name(npc.name) .. "'s eyes move under their lids as though reading.  "
      .. "\"There.  A " .. pl.what .. ", " .. d .. " tiles " .. (dir ~= "" and dir or "from here")
      .. (fresh and ".  You've never been near it." or ".  You've seen this one already; it's "
          .. "the closest there is.") .. "  I've drawn you the streets around it.\"\n\n"
      .. "(The area is revealed on your map" .. (fresh and ", with a note." or ".") .. ")"
  end

  -- Is this tile somewhere you could stand outdoors?
  local function good_landing(map, p)
    local ok, yes = pcall(function()
      return map:get_ter_at(p):obj():get_movecost() > 0
        and map:get_furn_at(p):obj():get_movecost() >= 0
        and map:is_outside(p)
        and not gapi.get_creature_at(p)
    end)
    return ok and yes
  end

  -- Teleport targets are the player's own map notes (2026-11-04, user design): BN's Lua
  -- has no overmap point picker, but it can read notes.  overmapbuffer.get_note only
  -- reads overmaps that already exist, so the scan never generates terrain.
  local SEND_RANGE = 150   -- overmap tiles, each way
  local SCATTER = 3        -- landing lands within this many overmap tiles of the mark

  -- "X:R;Gun store" -> "Gun store": drop BN's symbol / color / SPRITE prefixes.
  local function note_label(s)
    s = s:gsub("^%s*SPRITE:[^%s:;]*[%s:;]?", "")
    s = s:gsub("^%s*[^%s:;]:", "", 1)
    s = s:gsub("^%s*[%a_]+;", "", 1)
    s = s:gsub("^%s+", "")
    if s == "" then s = "(unlabelled mark)" end
    if #s > 50 then s = s:sub(1, 47) .. "..." end
    return s
  end

  local function map_notes(origin)
    local found = {}
    for dx = -SEND_RANGE, SEND_RANGE do
      for dy = -SEND_RANGE, SEND_RANGE do
        local p = TripointAbsOmt.new(origin.x + dx, origin.y + dy, origin.z)
        local note = overmapbuffer.get_note(p)
        if note and (dx ~= 0 or dy ~= 0) then
          found[#found + 1] = { p = p, label = note_label(note), d = math.max(math.abs(dx), math.abs(dy)),
                                dir = compass(dx, dy) }
        end
      end
    end
    table.sort(found, function(a, b) return a.d < b.d end)
    return found
  end

  -- Overmap tiles that are mostly or partly open water.  OtMatchType.TYPE ignores the
  -- rotation suffix.  (forest_water is swamp: shallow, survivable, not listed.)
  local WATER = { "lake_surface", "lake_shore", "river", "river_center", "river_shore" }
  local function is_water(p)
    for _, id in ipairs(WATER) do
      local ok, yes = pcall(overmapbuffer.check_ot, id, OtMatchType.TYPE, p)
      if ok and yes then return true end
    end
    return false
  end

  local function scatter_tiles(mark)
    local tiles, wet = {}, 0
    for dx = -SCATTER, SCATTER do
      for dy = -SCATTER, SCATTER do
        if dx * dx + dy * dy <= SCATTER * SCATTER + 1 then
          local p = TripointAbsOmt.new(mark.x + dx, mark.y + dy, mark.z)
          tiles[#tiles + 1] = p
          if is_water(p) then wet = wet + 1 end
        end
      end
    end
    return tiles, wet
  end

  function S.send(you, npc)
    local name = first_name(npc.name)
    local here = coords.project_to_omt(you:abs_pos())
    local notes = map_notes(here)
    if #notes == 0 then
      return false, name .. " looks at your map and hands it back.  \"There's nothing on it.  "
        .. "Put a note where you want to go, then come and find me.\"\n\n"
        .. "(Open your map and add a note to the spot you want to reach.)"
    end
    local labels = {}
    -- No cap (was 40, nearest-first: a dense map never showed anything past ~35 OMT,
    -- player report 2026-11-09).  uilist scrolls, and '/' filters by text.
    for i, n in ipairs(notes) do
      labels[i] = n.label .. "  (" .. n.d .. " tiles" .. (n.dir ~= "" and " " .. n.dir or "") .. ")"
    end
    local mark, tiles
    while not mark do
      local pick = U.select_menu(name .. " chalks a circle around your feet.  \"Show me where.  "
        .. "Just the one way, mind.\"\n(Type / to search your notes.)", labels, nil, nil, nil)
      if not pick then return nil end
      local wet
      tiles, wet = scatter_tiles(notes[pick].p)
      if wet == 0 then
        mark = notes[pick]
      else
        local share = wet * 3 >= #tiles and "a lot of water" or "water"
        local go = U.select_menu(name .. " frowns at the map.  \"There's " .. share .. " inside "
          .. SCATTER .. " tiles of that mark, and I can't promise you won't come down in it.  "
          .. "With everything you're carrying, you'd sink.  Aim further inland if you can.\"",
          { "Pick somewhere else.", "Send me anyway." }, nil, nil, nil)
        if go == 2 then mark = notes[pick] elseif not go then return nil end
      end
    end
    local land = tiles[gapi.rng(1, #tiles)]
    local off = math.max(math.abs(land.x - mark.p.x), math.abs(land.y - mark.p.y))
    -- Say it now: place_player_overmap unloads every NPC, `npc` included.
    U.popup(name .. " puts a hand flat on your chest and pushes.\n\nThe quarry folds away.  "
      .. "For a moment you are nowhere at all.\n\nThen there is ground under your feet again"
      .. (off == 0 and ", right where you marked." or (", about " .. off .. " tile"
          .. (off == 1 and "" or "s") .. " " .. compass(land.x - mark.p.x, land.y - mark.p.y)
          .. " of your mark.")))
    local corner = coords.project_to_ms(land)
    local abs = TripointAbsMs.new(corner.x + gapi.rng(0, 23), corner.y + gapi.rng(0, 23), corner.z)
    gapi.place_player_overmap_at(land)
    gapi.place_player_local_at(gapi.abs_to_bub(abs))
    -- Step to the nearest open outdoor tile.
    local map = gapi.get_map()
    local c = you:get_pos_ms()
    if not good_landing(map, c) then
      for r = 1, 12 do
        local found
        for dx = -r, r do
          for dy = -r, r do
            if math.max(math.abs(dx), math.abs(dy)) == r then
              local p = TripointBubMs.new(c.x + dx, c.y + dy, c.z)
              if not found and good_landing(map, p) then found = p end
            end
          end
        end
        if found then gapi.place_player_local_at(found); break end
      end
    end
    return true, nil
  end

  -- Every morale type BN defines (data/json/morale_types.json, ce8a10d) plus the mod's
  -- own.  No Lua enumeration exists (MoraleTypeDataId has no get_all), so: a list.
  local MORALE_IDS = {
    "morale_food_good", "morale_food_hot", "morale_food_cold", "morale_food_very_cold",
    "morale_chat", "morale_ate_with_table", "morale_ate_without_table", "morale_music",
    "morale_honey", "morale_game", "morale_marloss", "morale_mutagen", "morale_feeling_good",
    "morale_shower", "morale_bath", "morale_cleansed_self", "morale_support", "morale_photos",
    "morale_craving_nicotine", "morale_craving_caffeine", "morale_craving_alcohol",
    "morale_craving_opiate", "morale_craving_speed", "morale_craving_cocaine",
    "morale_craving_crack", "morale_craving_mutagen", "morale_craving_diazepam",
    "morale_craving_marloss", "morale_food_bad", "morale_cannibal", "morale_vegetarian",
    "morale_meatarian", "morale_antifruit", "morale_lactose", "morale_antijunk",
    "morale_antiwheat", "morale_sweettooth", "morale_no_digest", "morale_wet",
    "morale_dried_off", "morale_cold", "morale_hot", "morale_feeling_bad",
    "morale_killed_innocent", "morale_killed_friend", "morale_killed_monster",
    "morale_mutilate_corpse", "morale_mutagen_elf", "morale_mutagen_chimera",
    "morale_mutagen_mutation", "morale_moodswing", "morale_book", "morale_comfy",
    "morale_scream", "morale_perm_masochist", "morale_perm_noface", "morale_perm_fpmode_on",
    "morale_perm_hoarder", "morale_perm_fancy", "morale_perm_optimist",
    "morale_perm_badtemper", "morale_perm_constrained", "morale_perm_nomad",
    "morale_game_found_kitten", "morale_haircut", "morale_shave", "morale_vomited",
    "morale_play_with_pet", "morale_pyromania_startfire", "morale_pyromania_nearfire",
    "morale_pyromania_nofire", "morale_killer_has_killed", "morale_killer_need_to_kill",
    "morale_butcher", "morale_gravedigger", "morale_funeral", "morale_tree_communion",
    "morale_accomplishment", "morale_failure", "morale_high", "morale_drunk", "morale_xanax",
    "morale_valium", "morale_nicotine", "morale_indoor_misery", "morale_outdoor_misery",
    "morale_clutter_intolerant",
    "morale_telepathy", "morale_silent_one_drain",
  }
  local CALM = "morale_mom_psi_calm"

  function S.calm(you, npc)
    local removed = 0
    for _, id in ipairs(MORALE_IDS) do
      pcall(function()
        local t = MoraleTypeDataId.new(id)
        if you:get_morale(t) < 0 then you:rem_morale(t); removed = removed + 1 end
      end)
    end
    you:add_morale(MoraleTypeDataId.new(CALM), 30, 30, TimeDuration.from_hours(24),
                   TimeDuration.from_hours(20), true)
    return true, first_name(npc.name) .. " takes your face in both hands and looks at you, "
      .. "and keeps looking.  Something unknots behind your eyes.  "
      .. (removed > 0 and "The things that were weighing on you are still true, but they "
          .. "don't weigh anything now." or "You hadn't noticed how loud it was in there "
          .. "until it went quiet.")
  end

  -- ------------------------------------------------------------ dispatch
  local function run(kind, npc)
    local you = gapi.get_avatar()
    if not you or not npc then return end
    -- Capture everything about the NPC up front: S.send unloads every NPC, after which
    -- `npc` is a dangling reference.
    local key, name = cd_key(npc, kind), first_name(tostring(npc.name))
    local last = tonumber(you:get_value(key) or "")
    local left = last and math.max(0, last + KINDS[kind].cd - now()) or 0
    if left > 0 then
      U.popup(name .. " " .. KINDS[kind].tired .. ".  Come back in " .. hours_text(left) .. ".")
      return
    end
    local ok, did, text = pcall(S[kind], you, npc)
    if not ok then
      log_fail(kind, did)
      U.popup(name .. " tries, and something goes wrong.  \"Sorry.  It isn't working today.\"")
      return
    end
    if did == nil then return end                 -- menu cancelled: no cooldown
    if did then you:set_value(key, tostring(now())) end
    if text then U.popup(text) end
  end

  for kind in pairs(KINDS) do
    local marker = "mom_psi_svc_" .. kind
    mod.effect_added_handlers[marker] = function(npc, _eff)
      local guy = npc and npc:as_npc()
      if guy then util.queue_eoc(function() run(kind, guy) end, nil, 0) end
      return true
    end
  end

  -- Pyrokinetic warmth: the visible effect carries the hidden body-heat trait.
  local WARM_EFF, WARM_TRAIT = "mom_psi_warmed", "MOM_PSI_WARMED"
  mod.effect_added_handlers[WARM_EFF] = function(who, _eff)
    if who then U.set_mutation(who, WARM_TRAIT) end
    return true
  end
  mod.effect_removed_handlers[WARM_EFF] = function(who, _eff)
    if who then U.unset_mutation(who, WARM_TRAIT) end
    return true
  end
  -- A trait that outlived its effect (e.g. a crash between the two) is stripped on load.
  local prev_load2 = mod.on_game_load
  function mod.on_game_load(...)
    local r
    if prev_load2 then r = prev_load2(...) end
    pcall(function()
      local you = gapi.get_avatar()
      if you and you:has_trait(MutationBranchId.new(WARM_TRAIT))
          and not you:has_effect(EffectTypeId.new(WARM_EFF)) then
        U.unset_mutation(you, WARM_TRAIT)
      end
    end)
    return r
  end

  mod.psi_service_school_of = school_of
end
