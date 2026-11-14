-- Psionic Alliance enclave (fork-original, 2026-10-30): the biokinetic tally board
-- in the quarry mess hall.  Furniture f_mom_tally_board carries
-- `examine_action: "lua:mom_psi_tally_board"`; BN strips the "lua:" prefix and calls
-- game.examine_functions[<id>] with { user, pos } (iexamine::lua_examine).
--
-- The board lists the biokinetics actually in camp right now: loaded NPCs in the
-- psi_alliance faction with the BIOKINETIC trait -- Ray and Theo, plus any biokinetic
-- the player has brought home on a Green Pin -- and the player too, if they're one.
-- Counts are derived, not stored: each person's meals per day are a hash of
-- (name, week, day), summed over the days elapsed this week, so the board grows
-- through the week, resets every seven days, and never needs save data.
return function(mod)
  local DAY = 24 * 60 * 60        -- BN turns are seconds
  local WEEK = 7 * DAY
  local REACH = 60                -- tiles from the board that still count as "in camp"
  local BIO = MutationBranchId.new("BIOKINETIC")

  -- Ray eats one more than his hash says on about half the days.  He would insist it's
  -- every day.  Enough of an edge that he usually leads, not so much that Theo never
  -- forces a RECOUNT.
  local BONUS = { ["Ray Haskins"] = 1 }
  local NOTES = { "", "(under protest)", "(disputed)", "(says soup doesn't count)",
                  "(still finding the pantry)" }

  local function hash(s)
    local h = 5381
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
    return h
  end

  local function meals(name, week, day, bonus)
    local n = 0
    for d = 0, day do
      local h = hash(name .. ":" .. week .. ":" .. d)
      n = n + 2 + h % 5 + ((h // 7) % 2 == 0 and bonus or 0)
    end
    return math.max(n, 0)
  end

  local function first_name(full)
    return full:match("^(%S+)") or full
  end

  local function board_text(pos)
    local t = gapi.current_turn():to_turn() - gapi.turn_zero():to_turn()
    local week = math.floor(t / WEEK)
    local day = math.floor((t % WEEK) / DAY)

    local rows = {}
    for _, guy in ipairs(gapi.get_all_npcs()) do
      local p = guy:get_pos_ms()
      if guy:get_faction_id():str() == "psi_alliance" and guy:has_trait(BIO)
          and math.abs(p.x - pos.x) <= REACH and math.abs(p.y - pos.y) <= REACH then
        local full = guy.name
        rows[#rows + 1] = { who = first_name(full), n = meals(full, week, day, BONUS[full] or 0) }
      end
    end
    local you = gapi.get_avatar()
    if you:has_trait(BIO) then
      rows[#rows + 1] = { who = "You", n = meals("avatar", week, day, -1), guest = true }
    end

    local head = string.format("EATS OF THE WEEK -- week %d, day %d of 7\n"
      .. "(Biokinetics only.  Everyone else: stop asking.)\n\n", week + 1, day + 1)
    if #rows == 0 then
      return head .. "The columns are still ruled in marker, but nobody has added a "
        .. "number in a while.  Someone has drawn a small, sad face in the corner."
    end

    table.sort(rows, function(a, b)
      if a.n ~= b.n then return a.n > b.n end
      return a.who < b.who
    end)
    local lines = {}
    for i, r in ipairs(rows) do
      local note = r.guest and "(guest)" or (NOTES[i] or "")
      lines[#lines + 1] = string.format("%d. %s -- %d meals", i, r.who, r.n)
        .. (note ~= "" and (" " .. note) or "")
    end
    local foot = ""
    if rows[1].who ~= "Ray" then
      for _, r in ipairs(rows) do
        if r.who == "Ray" then
          foot = "\n\nWritten underneath, in different handwriting: RECOUNT."
        end
      end
    end
    return head .. table.concat(lines, "\n") .. foot
  end

  game.examine_functions["mom_psi_tally_board"] = function(params)
    local ok, text = pcall(board_text, params.pos)
    if not ok then
      gdebug.log_warn("MoM-BN: tally board failed: " .. tostring(text))
      text = "The tally board is smudged past reading."
    end
    mod.u.popup(text)
  end

  ---------------------------------------------------------------------------
  -- The green pin map (2026-11-03): furniture f_mom_green_pin_map in the office
  -- map room.  Every green pin is somebody Wren felt awaken, and each has an index
  -- card.  Ten cards are history written before the player arrived: eight of the
  -- people in camp (Wren holds the pins, so she has none) and two who died, which
  -- is what the DAYS WITHOUT A DEATH sign keeps resetting for.  Every Green Pin
  -- recruit the player settles gets a new card (mod.psi_record_green_pin, called
  -- from the mom_psi_alliance_settle marker in mom_hooks.lua), and anyone with a
  -- card who dies has their pin painted black (mod.on_character_death, registered
  -- in preload.lua).
  --
  -- Storage: one string on the avatar (set_value persists with the save), one
  -- record per line, tab-separated:   P <name> <school> <date>  |  D <name> <date>
  ---------------------------------------------------------------------------
  local PINS_KEY = "mom_psi_green_pins"

  -- trait id, card label, Wren's note on who in camp took them in
  local SCHOOLS = {
    { "BIOKINETIC", "biokinetic", "Theo checked them over and says they'll mend.  Ray is already jealous." },
    { "CLAIRSENTIENT", "clairsentient", "Knew you were coming before you did.  I liked that." },
    { "ELECTROKINETIC", "electrokinetic", "Eli has built them a cage of their own.  He pretends it was no trouble." },
    { "PHOTOKINETIC", "photokinetic", "Priya is teaching them how to dim." },
    { "PYROKINETIC", "pyrokinetic", "Dana has given them the forge shift nobody wants." },
    { "TELEKINETIC", "telekinetic", "Marcus has them stacking blocks.  Small ones first." },
    { "TELEPATH", "telepath", "Constance sat up with them the whole first night." },
    { "TELEPORTER", "teleporter", "Jules drew them a circle of their own." },
  }
  local SCHOOL_NOTE = {}
  for _, s in ipairs(SCHOOLS) do SCHOOL_NOTE[s[2]] = s[3] end
  -- The resident each note names, and what Wren writes instead once they're gone
  -- (2026-11-04: residents die, and a recruit's card kept saying "Marcus has them
  -- stacking blocks" after Marcus's pin went black).  Clairsentient names nobody.
  local SCHOOL_RESIDENT = {
    biokinetic = { "Theo Lindqvist", "They found Theo's notes on the clinic desk and have been reading them every night." },
    electrokinetic = { "Eli Navarro", "They sat by Eli's battery bank the whole first night.  Nobody had the heart to tell them it's dead." },
    photokinetic = { "Priya Raman", "They found Priya's lamps in the basement and turned every one of them on." },
    pyrokinetic = { "Dana Okafor", "They keep the forge lit now.  Nobody asked them to." },
    telekinetic = { "Marcus Bell", "They stack Marcus's blocks every morning.  Small ones first, the way he did." },
    telepath = { "Constance Hale", "I sat up with them the first night.  Constance always did that.  I see why now." },
    teleporter = { "Jules Ferreira", "They redraw Jules's circles every morning.  Somebody has to." },
  }

  -- In pin order.  `dead` cards were already black when the game started.
  local HISTORY = {
    { name = "Constance Hale", school = "telepath",
      text = "Library basement, Concord.  Walked.  She was waiting at the door when I got "
          .. "there.  \"You took your time.\"" },
    { name = "Jules Ferreira", school = "teleporter",
      text = "On the roof of a bus station, with no ladder up to it.  He didn't know how he "
          .. "got there either.  Walked.  The last one I ever had to walk to." },
    { name = "Theo Lindqvist", school = "biokinetic",
      text = "Tax office, Manchester.  He had set his own leg and gone back to somebody's "
          .. "return." },
    { name = "Eli Navarro", school = "electrokinetic",
      text = "I followed the dead streetlights to him.  He was sitting in the dark on "
          .. "purpose, so he couldn't hurt anyone." },
    { name = "Audrey Sinclair", school = "pyrokinetic", dead = true,
      text = "Dairy farm off Route 9.  Jules got there an hour late.  The barn was still "
          .. "burning." },
    { name = "Dana Okafor", school = "pyrokinetic",
      text = "Fire station, of all places.  Sitting in the engine bay, very calm.  "
          .. "Everything around her was not.  We left sooner this time." },
    { name = "Marcus Bell", school = "telekinetic",
      text = "Holding up a fallen parking-deck ceiling so three strangers could crawl out.  "
          .. "They didn't stay to thank him." },
    { name = "Ray Haskins", school = "biokinetic",
      text = "Barricaded in a grocery store, eating his way through the deli.  He wouldn't "
          .. "leave until Jules mentioned the mess hall." },
    { name = "Priya Raman", school = "photokinetic",
      text = "Glowing in a garden center, at night.  You could see her from two miles off.  "
          .. "So could everything else." },
    { name = "Tomasz Wilk", school = "teleporter", dead = true,
      text = "Made it home.  Jumped in his sleep on his third night, and we never found "
          .. "where he landed.  Jules redraws the circles every morning now." },
  }
  local HISTORY_NAMES = {}
  for _, h in ipairs(HISTORY) do HISTORY_NAMES[h.name] = true end

  local function today()
    local s = tostring(gapi.current_turn())
    return s:match("^(.-day %d+)") or s     -- "Year 1, Spring, day 14" (drop the clock)
  end

  local function load_pins()
    local you = gapi.get_avatar()
    local raw = (you and you:get_value(PINS_KEY)) or ""
    local pins, dead = {}, {}
    for line in raw:gmatch("[^\n]+") do
      local f = {}
      for field in line:gmatch("[^\t]+") do f[#f + 1] = field end
      if f[1] == "P" and f[2] then
        pins[#pins + 1] = { name = f[2], school = f[3] or "psion", date = f[4] or "", where = f[5] }
      elseif f[1] == "D" and f[2] then
        dead[f[2]] = f[3] or ""
      end
    end
    return pins, dead
  end

  local function append_record(fields)
    local you = gapi.get_avatar()
    if not you then return end
    local raw = you:get_value(PINS_KEY) or ""
    you:set_value(PINS_KEY, raw .. table.concat(fields, "\t") .. "\n")
  end

  local function clean(name)    -- records are tab/newline delimited
    return (tostring(name or ""):gsub("[\t\n]", " "))
  end

  local function has_card(name, pins)
    if HISTORY_NAMES[name] then return true end
    for _, p in ipairs(pins) do if p.name == name then return true end end
    return false
  end

  -- A Green Pin recruit settling into camp gets a card (once).
  function mod.psi_record_green_pin(guy)
    local name = clean(guy.name)
    local pins = load_pins()
    if name == "" or has_card(name, pins) then return end
    local school = "psion"
    for _, s in ipairs(SCHOOLS) do
      if guy:has_trait(MutationBranchId.new(s[1])) then school = s[2]; break end
    end
    local where = ""
    pcall(function() where = clean(guy:get_value("mom_pin_hideout") or "") end)
    local rec = { "P", name, school, today() }
    if where ~= "" then rec[5] = where end   -- older records have 4 fields
    append_record(rec)
    -- Bringing home a psion of a school unlocks that school's services
    -- (lua/mom_psi_services.lua).
    if mod.psi_service_unlock then mod.psi_service_unlock(school, name) end
  end

  -- Schools you've brought home at least one psion of (set of school labels).
  function mod.psi_green_pin_schools()
    local set = {}
    for _, p in ipairs((load_pins())) do set[p.school] = true end
    return set
  end

  -- Anyone with a card who dies gets a black pin.  NPCs only: the avatar's death
  -- ends the run, and the avatar is where the cards live.
  local prev_death = mod.on_character_death
  function mod.on_character_death(params)
    pcall(function()
      local ch = params.char
      local guy = ch and ch:as_npc()
      if not guy then return end
      local name = clean(guy.name)
      local pins, dead = load_pins()
      if dead[name] or not has_card(name, pins) then return end
      append_record({ "D", name, today() })
    end)
    if prev_death then return prev_death(params) end
  end

  -- The open Green Pin, if the player is on one, and roughly where it is.
  -- Matched by NAME, not id: BN's reg_mission_type re-registers MissionTypeId
  -- as a bare usertype with no methods (catalua_bindings_mission.cpp:199), so
  -- m:mission_id():str() throws "attempt to index a sol.string_id<mission_type>"
  -- and mission_type exposes no id field either.  "Green Pin" is unique.
  local GREEN_PIN_NAME = "Green Pin"
  local function is_green_pin(m)
    local ok, nm = pcall(function() return m:name() end)
    return ok and nm == GREEN_PIN_NAME
  end

  ---------------------------------------------------------------------------
  -- Hiding places (2026-11-13, user: "they're almost all out in fields").  The
  -- Green Pin missions now cycle through hiding-place variants (houses, river,
  -- library, bank, cave... see the MISSION_PSI_ALLIANCE_GREEN_PIN* followup chain
  -- in npcs/psi_alliance.json).  update_mapgen can only drop the recruit at a
  -- fixed tile (12,12), which in a building may be a wall or the middle of a
  -- room, so when you get within a couple of OMTs and they're out of your sight
  -- this moves them somewhere a frightened person would actually be: a closet or
  -- alcove indoors, the bank of the river, a thicket, the back of the cave.  The
  -- place is stamped on the recruit (creature var mom_pin_hideout) and the board
  -- card says where you found them.
  ---------------------------------------------------------------------------
  local HIDE_KEY = "mom_pin_hideout"
  local KINDS = {   -- first match wins; order matters only for overlapping prefixes
    { "house", "PREFIX", "house" }, { "s_library", "PREFIX", "library" },
    { "bank", "PREFIX", "bank" }, { "cabin", "PREFIX", "cabin" },
    { "church", "PREFIX", "church" }, { "s_pharm", "PREFIX", "pharmacy" },
    { "motel", "PREFIX", "motel" }, { "cave", "TYPE", "cave" },
    { "river", "TYPE", "river" }, { "forest_thick", "TYPE", "forest" },
  }
  local INDOOR_KIND = { house = 45, library = 30, bank = 30, cabin = 35, church = 30,
                        pharmacy = 30, motel = 40 }   -- % chance of a closet, if one exists
  local OMT = 24

  local function kind_of(omt)
    for _, k in ipairs(KINDS) do
      if overmapbuffer.check_ot(k[1], OtMatchType[k[2]], omt) then return k[3] end
    end
    return "field"
  end

  local function blocked(map, p)
    local t = map:get_ter_at(p)
    if not t or t:obj():get_movecost() <= 0 then return true end
    local f = map:get_furn_at(p)
    return f and f:obj():get_movecost() < 0
  end

  local function free(map, p)
    return not blocked(map, p) and not gapi.get_creature_at(p)
  end

  local ORTH = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
  local ALL8 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
  local function count(map, p, dirs, test)
    local n = 0
    for _, d in ipairs(dirs) do
      if test(map, TripointBubMs.new(p.x + d[1], p.y + d[2], p.z)) then n = n + 1 end
    end
    return n
  end
  local function wet(map, p) return map:has_ter_flag_at("LIQUID", p) end

  -- Returns bub point, spot label ("closet" / "" ) or nil.
  function mod.psi_pin_pick_spot(map, o, kind)
    local best, closets, cands = {}, {}, {}
    for dx = 1, OMT - 2 do
      for dy = 1, OMT - 2 do
        local p = TripointBubMs.new(o.x + dx, o.y + dy, o.z)
        if free(map, p) then
          if INDOOR_KIND[kind] then
            if map:has_ter_flag_at("INDOORS", p) then
              local walls = count(map, p, ORTH, blocked)
              cands[#cands + 1] = p
              if walls >= 3 then closets[#closets + 1] = p
              elseif walls >= 2 then best[#best + 1] = p end
            end
          elseif kind == "river" then
            if not wet(map, p) and count(map, p, ALL8, wet) > 0 then best[#best + 1] = p end
          else   -- forest / cave: the most enclosed open tile
            local n = count(map, p, ALL8, blocked)
            if n >= (kind == "cave" and 5 or 3) then best[#best + 1] = p end
            if n >= 2 then cands[#cands + 1] = p end
          end
        end
      end
    end
    local function any(t) return t[gapi.rng(1, #t)] end
    if #closets > 0 and gapi.rng(1, 100) <= (INDOOR_KIND[kind] or 0) then return any(closets), "closet" end
    if #best > 0 then return any(best), "" end
    if #closets > 0 then return any(closets), "closet" end
    if #cands > 0 then return any(cands), "" end
    return nil
  end

  local function same_omt(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end

  function mod.psi_pin_hide_tick(you, m)
    local there = m:get_target_point()
    local here = coords.project_to_omt(you:abs_pos())
    if math.max(math.abs(there.x - here.x), math.abs(there.y - here.y)) > 2 or there.z ~= here.z then return end
    local map = gapi.get_map()
    local o = map:abs_to_bub(coords.project_to_ms(there))
    local size = map:get_map_size()
    if o.x < 0 or o.y < 0 or o.x + OMT > size or o.y + OMT > size then return end
    for _, guy in ipairs(gapi.get_all_npcs()) do
      if (guy:get_value(HIDE_KEY) or "") == "" and not guy:is_following()
          and same_omt(coords.project_to_omt(guy:abs_pos()), there) then
        local school = false
        for _, s in ipairs(SCHOOLS) do
          if guy:has_trait(MutationBranchId.new(s[1])) then school = true; break end
        end
        if school then
          local kind = kind_of(there)
          local key = kind
          local pos = guy:get_pos_ms()
          if kind ~= "field" and (not you:sees(pos) or blocked(map, pos)) then
            local p, spot = mod.psi_pin_pick_spot(map, o, kind)
            if p then
              guy:set_pos_ms(p)
              if spot == "closet" then key = kind .. "_closet" end
            end
          end
          guy:set_value(HIDE_KEY, key)
          gdebug.log_info("MoM-BN: green pin recruit " .. tostring(guy.name) .. " hidden: " .. key)
        end
      end
    end
  end

  mod.recurring = mod.recurring or {}
  mod.recurring["MOM_GREEN_PIN_HIDE"] = {
    min_turns = 5, max_turns = 5,
    fn = function(you)
      local ok, err = pcall(function()
        if not you then return end
        for _, m in ipairs(you:get_active_missions()) do
          if is_green_pin(m) then mod.psi_pin_hide_tick(you, m) end
        end
      end)
      if not ok and not mod._pin_hide_warned then
        mod._pin_hide_warned = true
        gdebug.log_warn("MoM-BN: green pin hiding failed (further errors suppressed): " .. tostring(err))
      end
    end,
  }

  local function open_pin_line()
    local you = gapi.get_avatar()
    for _, m in ipairs(you:get_active_missions()) do
      if is_green_pin(m) then
        local where = ""
        pcall(function()
          local here = coords.project_to_omt(you:abs_pos())
          local there = m:get_target_point()
          local dx, dy = there.x - here.x, there.y - here.y
          local ns = (dy < -math.abs(dx) / 2) and "north" or ((dy > math.abs(dx) / 2) and "south" or "")
          local ew = (dx > math.abs(dy) / 2) and "east" or ((dx < -math.abs(dy) / 2) and "west" or "")
          local far = math.max(math.abs(dx), math.abs(dy))
          local how = far < 15 and "not far" or (far < 30 and "a fair walk" or "a long way")
          if ns .. ew ~= "" then where = "  It's " .. how .. " " .. ns .. ew .. " of here." end
        end)
        return "The newest green pin has no card yet, only a sticky note in careful block "
          .. "capitals: AWAKENED?  MOVING.  SEND SOMEONE." .. where
      end
    end
    return "There's no new pin up.  Wren checks the map anyway, every time she passes it."
  end

  -- The board as data: header, one entry per card, and the closing lines.  Shared by
  -- the scrollable catalog (examine) and the flat-text fallback.
  local INTRO = "Every green pin has an index card tacked beside it, in Wren's small, "
    .. "slanted hand.  The black pins kept their cards."
  local WREN_CARD = "At the edge of the map is one more card, with no pin: \"I'm the one "
    .. "holding them.  -W\""

  -- Where you found them (2026-11-13), keyed by the hideout stamp (kind, or
  -- kind_closet).  One line per card, chosen by a hash of the name so it never
  -- changes between looks.  Records from before this have no stamp: no line.
  local FOUND = {
    house_closet = {
      "In a hall closet, behind the winter coats.  They'd been in there two days.",
      "Wedged into a bedroom closet, holding the door shut from inside.",
      "In a linen closet, sitting on the towels, making themselves very small.",
    },
    house = {
      "In somebody's house, under the kitchen table, with every light off.",
      "In a stranger's house, in the corner furthest from every window.",
      "In a house that wasn't theirs.  They'd laid the table for a family that wasn't coming back.",
    },
    library_closet = { "In a library supply closet, between the mop bucket and the returns cart." },
    library = {
      "In a library, between the stacks, reading.  Looking up what they were, they said.  Nothing on the shelves was any help.",
      "In the children's section of a library, because nobody would look for them there.",
    },
    bank_closet = { "Shut in a bank's back office no bigger than a closet, with the deadbolt thrown." },
    bank = {
      "In a bank, behind the teller counter.  Of all the safe places to pick.",
      "In a bank, sitting with their back against the vault door.  It was the thickest wall they could find.",
    },
    cabin_closet = { "In a cabin's storage cupboard, under a pile of quilts." },
    cabin = {
      "In a cabin a long way from anywhere, which was the whole point.",
      "In a hunting cabin with the shutters nailed closed.  From the inside.",
    },
    church_closet = { "In a church vestry, among the robes, with the door pulled to." },
    church = {
      "In a church, in the last pew, praying to nobody in particular.",
      "In a church.  Sanctuary, they said.  It had seemed worth a try.",
    },
    pharmacy_closet = { "In a pharmacy stockroom, reading every label for something that would make it stop." },
    pharmacy = {
      "Behind a pharmacy counter, reading every label for something that would make it stop.",
      "In a pharmacy, with three kinds of sleeping pill lined up and none of them opened.  Good.",
    },
    motel_closet = { "In a motel bathroom, in the tub, with the door locked." },
    motel = {
      "In a motel room with the bed pushed up against the door.",
      "In a motel room with the TV on and no signal, just for the noise.",
    },
    river = {
      "Down at the river, in the reeds, half in the water.",
      "On the riverbank, watching the water as if it might explain things.",
    },
    forest = {
      "Deep in the woods, curled up in a thicket.",
      "In the trees, where nobody could see them and they couldn't see anybody.",
    },
    cave = {
      "In the mouth of a cave, as far back as the light reached.",
      "In a cave.  The only place quiet enough, they said.",
    },
    field = {
      "Out in an open field.  Nowhere to hide, so they'd stopped trying.",
      "Standing in the middle of a field, in plain sight of everything.",
    },
  }
  local function found_line(name, where)
    if not where or where == "" then return nil end
    local list = FOUND[where] or FOUND[where:gsub("_closet$", "")]
    if not list then return nil end
    local h = 5381
    for i = 1, #name do h = (h * 33 + name:byte(i)) % 2147483647 end
    return list[h % #list + 1]
  end

  local function pin_map_cards()
    local pins, dead = load_pins()
    local cards = {}
    local blacks = 0
    local function card(name, school, body, is_dead, died)
      if is_dead then blacks = blacks + 1 end
      local text = body
      if died then text = text .. "  Died " .. died .. "." end
      cards[#cards + 1] = { name = name:upper(), school = school, text = text, dead = is_dead }
    end
    for _, h in ipairs(HISTORY) do
      card(h.name, h.school, h.text, h.dead or dead[h.name] ~= nil, dead[h.name])
    end
    for _, p in ipairs(pins) do
      local died = dead[p.name]
      local body = "Brought home by you, " .. p.date .. "."
      local found = found_line(p.name, p.where)
      if found then body = found .. "  " .. body end
      if not died and SCHOOL_NOTE[p.school] then
        local res = SCHOOL_RESIDENT[p.school]
        local gone = res and (dead[res[1]] ~= nil)
        body = body .. "  " .. (gone and res[2] or SCHOOL_NOTE[p.school])
      end
      card(p.name, p.school, body, died ~= nil, died)
    end
    local ok, newest = pcall(open_pin_line)
    if not ok then
      gdebug.log_warn("MoM-BN: green pin open-pin line failed: " .. tostring(newest))
      newest = ""
    end
    local summary = string.format("%d pins, %d of them black.", #cards, blacks)
    return cards, summary, newest
  end

  local function pin_map_text()
    local cards, summary, newest = pin_map_cards()
    local lines = {}
    for i, c in ipairs(cards) do
      lines[#lines + 1] = string.format("%d. [%s pin]  %s -- %s.  %s", i,
        c.dead and "black" or "green", c.name, c.school, c.text)
    end
    return "THE GREEN PINS\n\n" .. INTRO .. "\n\n" .. table.concat(lines, "\n\n")
      .. "\n\n" .. summary .. "  " .. WREN_CARD .. "\n\n" .. newest
  end

  -- Scrollable catalog (2026-11-04: the flat popup ran off the bottom of the screen
  -- once the player had brought a few people home).  One entry per card, colored by
  -- pin; the highlighted card's full text shows in the lower box (BN sizes it to the
  -- longest card).  Enter or Esc closes.
  local function color(name)
    local ok, c = pcall(function() return Color[name] end)
    return ok and c or nil
  end

  local function show_catalog()
    local cards, summary, newest = pin_map_cards()
    local green, gray = color("c_light_green"), color("c_dark_gray")
    local ui = UiList.new()
    ui:title("THE GREEN PINS")
    ui:text(INTRO .. "  " .. summary)
    ui:desc_enabled(true)
    for i, c in ipairs(cards) do
      ui:add_w_desc(i, string.format("%2d. %s -- %s%s", i, c.name, c.school,
        c.dead and "  (black pin)" or ""), c.text)
      local col = c.dead and gray or green
      if col then pcall(function() ui.entries[#ui.entries]:txt_color(col) end) end
    end
    local n = #cards
    ui:add_w_desc(n + 1, "The card with no pin", WREN_CARD)
    if newest ~= "" then ui:add_w_desc(n + 2, "The newest pin", newest) end
    ui:query()   -- browse with the arrow keys; Enter or Esc puts the board down
  end

  game.examine_functions["mom_psi_green_pin_map"] = function(_params)
    local ok, err = pcall(show_catalog)
    if ok then return end
    gdebug.log_warn("MoM-BN: green pin catalog failed: " .. tostring(err))
    local ok2, text = pcall(pin_map_text)
    if not ok2 then
      gdebug.log_warn("MoM-BN: green pin map failed: " .. tostring(text))
      text = "The cards are too faded to read."
    end
    mod.u.popup(text)
  end
end
