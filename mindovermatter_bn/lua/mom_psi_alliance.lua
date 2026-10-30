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
end
