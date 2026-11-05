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
        pins[#pins + 1] = { name = f[2], school = f[3] or "psion", date = f[4] or "" }
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
    append_record({ "P", name, school, today() })
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
