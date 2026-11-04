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
  local GREEN_PIN_MISSION = "MISSION_PSI_ALLIANCE_GREEN_PIN"

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
  local function open_pin_line()
    local you = gapi.get_avatar()
    for _, m in ipairs(you:get_active_missions()) do
      if m:mission_id():str() == GREEN_PIN_MISSION then
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

  local function pin_map_text()
    local pins, dead = load_pins()
    local lines = {}
    local n, blacks = 0, 0
    local function card(name, school, body, is_dead, died)
      n = n + 1
      if is_dead then blacks = blacks + 1 end
      local text = body
      if died then text = text .. "  Died " .. died .. "." end
      lines[#lines + 1] = string.format("%d. [%s pin]  %s -- %s.  %s", n,
        is_dead and "black" or "green", name:upper(), school, text)
    end
    for _, h in ipairs(HISTORY) do
      card(h.name, h.school, h.text, h.dead or dead[h.name] ~= nil, dead[h.name])
    end
    for _, p in ipairs(pins) do
      local died = dead[p.name]
      local body = "Brought home by you, " .. p.date .. "."
      if not died and SCHOOL_NOTE[p.school] then body = body .. "  " .. SCHOOL_NOTE[p.school] end
      card(p.name, p.school, body, died ~= nil, died)
    end
    return "THE GREEN PINS\n\n"
      .. "Every green pin has an index card tacked beside it, in Wren's small, slanted "
      .. "hand.  The black pins kept their cards.\n\n"
      .. table.concat(lines, "\n\n")
      .. string.format("\n\n%d pins, %d of them black.", n, blacks)
      .. "  At the edge of the map is one more card, with no pin: \"I'm the one holding "
      .. "them.  -W\"\n\n" .. open_pin_line()
  end

  game.examine_functions["mom_psi_green_pin_map"] = function(_params)
    local ok, text = pcall(pin_map_text)
    if not ok then
      gdebug.log_warn("MoM-BN: green pin map failed: " .. tostring(text))
      text = "The cards are too faded to read."
    end
    mod.u.popup(text)
  end
end
