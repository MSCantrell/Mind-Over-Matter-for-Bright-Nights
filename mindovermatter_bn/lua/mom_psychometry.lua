-- mom_psychometry: item history for [Ψ]Psychometry (2026-11-04, "living world" idea #1).
-- HAND-AUTHORED.
--
-- Touch an item and read the person who carried it before you.  The reading grows with
-- the power's level:
--   L0-4   a feeling and one sensory fragment ("Panic.  The smell of wet pennies.")
--   L5-9   + who they were (name, what they did before) and one moment with this item
--   L10+   + what they were afraid of, and how it ended for them
--
-- Consistency, not volume: the first touch stores a random seed on the item
-- (item var mom_psy_seed), and every later reading rebuilds the same story from it, so
-- the same knife always belonged to the same person.  The deepest reading reached is
-- written into the item's Note line (item var item_note, which BN shows under the
-- description, item.cpp:1812), after any inscription the player carved themselves.
--
-- Items with no stranger's past:
--   * crafted items -- stamped mom_psy_maker by mod.psy_stamp_crafted (on_craft_result)
--   * starting gear -- stamped mom_psy_maker by mod.psy_stamp_start (on_game_started)
--   Reading those gives the maker's impression instead.  (Item ownership can't be used
--   to tell: BN zone-sorting sets the sorter as owner, activity_item_handling.cpp:2596.)
return function(mod)
  local U = mod.u

  -- ---------------------------------------------------------------- word banks
  local FIRST = {
    "Abby", "Alan", "Amara", "Ben", "Bev", "Carla", "Cole", "Dale", "Darius", "Dot",
    "Elena", "Emmett", "Faith", "Frank", "Gloria", "Grant", "Hank", "Helen", "Ivy", "Jamal",
    "Janet", "Jesse", "June", "Keisha", "Kurt", "Lena", "Lou", "Maggie", "Marco", "Mei",
    "Nate", "Nora", "Omar", "Pam", "Paul", "Quinn", "Rosa", "Russ", "Sal", "Sandra",
    "Tariq", "Tess", "Todd", "Uma", "Vic", "Wade", "Wanda", "Yusuf", "Zoe", "Hector",
  }
  local LAST = {
    "Abbott", "Barnes", "Castillo", "Dunn", "Ellison", "Fischer", "Garza", "Hale", "Ibarra",
    "Jensen", "Kowalski", "Lambert", "Mercer", "Nakamura", "Okafor", "Price", "Quinlan",
    "Reyes", "Sorensen", "Tate", "Underwood", "Vance", "Walsh", "Yates", "Zielinski",
    "Boyd", "Chen", "Delgado", "Foster", "Grady", "Hollis", "Kerr", "Lindgren", "Moss",
    "Novak", "Ortiz", "Pruitt", "Russo", "Strand", "Whitaker",
  }
  local JOBS = {
    "a school bus driver", "a night-shift nurse", "a dental hygienist", "a line cook",
    "a high school chemistry teacher", "a long-haul trucker", "a substitute teacher",
    "a retired machinist", "a hardware store clerk", "a church organist", "a paramedic",
    "a bank teller", "a dog groomer", "a county surveyor", "a college sophomore",
    "a roofer", "a real estate agent", "a librarian", "a mail carrier", "a farmhand",
    "a security guard", "a hospice worker", "a mechanic", "an insurance adjuster",
    "a hairdresser", "a sheriff's deputy", "a pharmacist", "a cashier at a gas station",
    "a stay-at-home parent", "a pastor", "a carpenter", "a tattoo artist",
  }
  local FEELINGS = {
    "Panic", "Grief", "Stubborn hope", "Exhaustion, bone-deep", "Rage", "Guilt",
    "A strange calm", "Shame", "Dread", "Love, and worry", "Relief", "Loneliness",
  }
  local SENSES = {
    "the smell of wet pennies", "a car alarm that would not stop", "rain on a tin roof",
    "a baby crying two rooms away", "the taste of cheap coffee", "smoke, everywhere",
    "a radio playing static", "cold hands", "the drone of a helicopter that never landed",
    "a dog barking, then not", "the smell of bleach", "a hymn, hummed under the breath",
    "sirens, far off and getting farther", "the weight of a sleeping child",
    "breath held behind a door", "a flashlight beam shaking", "mud to the ankles",
    "the hum of a refrigerator in an empty house", "fever-heat", "the click of a lock",
  }
  local FEARS = {
    "the dark", "being alone when it happened", "turning, and not knowing it",
    "dogs, ever since they were small", "deep water", "hospitals", "their own reflection",
    "the quiet after the screaming stopped", "being eaten", "hurting someone they loved",
    "fire", "running out of insulin", "the basement", "never finding their sister",
    "the voices they had started to hear", "dying hungry", "losing their mind first",
    "being the last one", "the thing in the cornfield", "sleep",
  }
  -- How it ended.  Some lived; not every story is a death.
  local FATES = {
    "They were bitten in the first week, and hid it for two days.",
    "They starved, slowly, waiting for a rescue that had already been called off.",
    "Other survivors shot them over a can of beans.",
    "They turned in their sleep.  Nobody was awake to see it.",
    "A fever took them.  It was only an infected cut.",
    "They fell from a roof, running.",
    "They burned with the house, on purpose.",
    "They walked into the woods one morning and did not come back.",
    "They were dragged out of a car window on the interstate.",
    "They died warm, in a bed, with someone holding their hand.  It was luck, of a kind.",
    "They put it down to carry someone else, and kept walking.  They may still be alive.",
    "They traded it away at a refugee camp, for antibiotics.  They lived.",
    "The cold got them, the first night the power failed.",
    "Something too fast to see took them in an alley.  It took a long time.",
    "They drowned crossing a river.  They could not swim.",
    "They are still out there.  You can feel them, faintly, walking.",
  }
  -- Rare: the owner was awakening, and never knew.
  local PSION_FATE = "There is something else in it too, faint and familiar: they were "
    .. "waking up, the way you did.  They never found out what they were."

  -- One moment with this kind of item.  `%s` = the owner's first name.
  local MOMENTS = {
    weapon = {
      "%s swung it until their arms shook, and then swung it again.",
      "%s never used it.  They kept it by the door, and checked it every night.",
      "%s cleaned it after the first time, and threw up, and cleaned it again.",
      "%s took it off a body, and said sorry to the body.",
      "%s practiced with it in a garage, against a mattress, the week before.",
    },
    gun = {
      "%s counted the rounds left, out loud, every hour.",
      "%s fired it once, at something that had been their neighbor.",
      "%s bought it years ago and was always a little afraid of it.",
      "%s kept the last bullet separate.  They knew what it was for.",
    },
    armor = {
      "%s wore it the day the sirens started, and every day after.",
      "%s mended it by lamplight, badly, with dental floss.",
      "%s's blood soaked into it once.  Not all of it washed out.",
      "%s took it from a store with the door kicked in, and left money on the counter.",
    },
    food = {
      "%s was saving it for a birthday.",
      "%s found it in a stranger's pantry and ate a little, crying, standing up.",
      "%s promised it to a child, who did not live to eat it.",
    },
    book = {
      "%s read it aloud to keep somebody calm.",
      "%s read the same page over and over and never took it in.",
      "%s wrote a name inside the cover, and then crossed it out.",
    },
    container = {
      "%s packed it in a hurry and forgot the one thing they needed.",
      "%s carried everything they owned in it, and it was never enough.",
      "%s kept letters in it.  The letters are gone now.",
    },
    other = {
      "%s carried it a long way for no reason they could explain.",
      "%s turned it over in their hands to keep from thinking.",
      "%s took it because it reminded them of home.",
      "%s almost threw it away, twice.",
      "%s was holding it when they heard the news.",
    },
  }

  -- ---------------------------------------------------------------- deterministic rng
  -- LCG seeded per item, so a reading is reproducible from the stored seed.
  local function rng_from(seed)
    local s = seed % 2147483647
    if s <= 0 then s = s + 2147483646 end
    return function(n)
      s = (s * 48271) % 2147483647
      return (s % n) + 1
    end
  end
  local function pick(r, list) return list[r(#list)] end

  local function kind_of(it)
    local function try(fn)
      local ok, yes = pcall(fn)
      return ok and yes
    end
    if try(function() return it:is_gun() end) then return "gun" end
    if try(function() return it:is_melee() end) then return "weapon" end
    if try(function() return it:is_armor() end) then return "armor" end
    if try(function() return it:is_comestible() end) then return "food" end
    if try(function() return it:is_book() end) then return "book" end
    if try(function() return it:is_container() end) then return "container" end
    return "other"
  end

  -- The full story for a seed; `level` decides how much of it is legible.
  local function story(seed, kind, level)
    local r = rng_from(seed)
    -- Draw every field in a FIXED order, whatever the level, so the same seed always
    -- yields the same person (a higher level only reveals more of it).
    local s = {
      feeling = pick(r, FEELINGS), sense = pick(r, SENSES),
      first = pick(r, FIRST), last = pick(r, LAST), job = pick(r, JOBS),
      moment = pick(r, MOMENTS[kind] or MOMENTS.other),
      fear = pick(r, FEARS), fate = pick(r, FATES), psion = (r(20) == 1),
    }
    s.moment = s.moment:format(s.first)
    local long, note = {}, {}
    long[#long + 1] = s.feeling .. ".  " .. s.sense:gsub("^%l", string.upper) .. "."
    note[#note + 1] = s.feeling .. "; " .. s.sense .. "."
    if level >= 5 then
      long[#long + 1] = "It belonged to " .. s.first .. " " .. s.last .. ", " .. s.job
        .. ".  " .. s.moment
      note[#note + 1] = s.first .. " " .. s.last .. ", " .. s.job .. "."
    end
    if level >= 10 then
      long[#long + 1] = s.first .. " was afraid of " .. s.fear .. ".  " .. s.fate
      if s.psion then long[#long + 1] = PSION_FATE end
      note[#note + 1] = "Afraid of " .. s.fear .. ".  " .. s.fate
    end
    local tier = (level >= 10) and 3 or ((level >= 5) and 2 or 1)
    return long, "[Psychometry] " .. table.concat(note, "  "), tier
  end

  -- Write our reading into item_note, after the player's own inscription if any.
  local function write_note(it, ours)
    local cur = it:get_var_str("item_note", "")
    local last = it:get_var_str("mom_psy_note", "")
    local prev
    if last ~= "" and cur:sub(-#last) == last then
      prev = cur:sub(1, #cur - #last):gsub("%s+$", "")    -- strip our old reading
    else
      prev = cur                                          -- player's (possibly new) text
    end
    it:set_var_str("item_note", (prev ~= "" and (prev .. "  ") or "") .. ours)
    it:set_var_str("mom_psy_note", ours)
  end

  local function level_of(you)
    local lvl = 0
    for _, id in ipairs({ "clair_examine_item", "clair_examine_item_knack" }) do
      pcall(function() lvl = math.max(lvl, mod.math.spell_level(you, id)) end)
    end
    return math.max(lvl, 0)
  end

  -- Returns the popup text.  Called from EOC_CLAIR_EXAMINE_ITEM_INITIATE (mom_eoc.lua)
  -- for non-artifact items.
  function mod.psychometry_read(you, it)
    local name = U.item_name(it)
    local maker = it:get_var_str("mom_psy_maker", "")
    if maker == "start" then
      return "You close your hand around the " .. name .. ".  All it holds is you: the "
        .. "life you had before, and every day since.  It has never belonged to anyone else."
    elseif maker ~= "" then
      local whose = (maker == "you") and "your own" or (maker .. "'s")
      return "You close your hand around the " .. name .. ".  There is nothing in it but "
        .. whose .. " work: the hours spent making it, and the small pride of finishing.  "
        .. "No one else has carried it yet."
    end
    local seed = tonumber(it:get_var_str("mom_psy_seed", ""))
    if not seed then
      seed = gapi.rng(1, 2147483646)
      it:set_var_str("mom_psy_seed", tostring(seed))
    end
    local level = level_of(you)
    local long, note, tier = story(seed, kind_of(it), level)
    -- The note keeps the deepest reading ever reached (a power can't un-learn).
    local best = tonumber(it:get_var_str("mom_psy_tier", "")) or 0
    if tier >= best then
      write_note(it, note)
      it:set_var_str("mom_psy_tier", tostring(tier))
    end
    local text = "You close your hand around the " .. name .. " and let it tell you.\n\n"
      .. table.concat(long, "\n\n")
    if level < 5 then
      text = text .. "\n\n(The impression is too faint to make out more.  With practice, "
        .. "you could read who carried it.)"
    elseif level < 10 then
      text = text .. "\n\n(There's more underneath, out of reach for now.)"
    end
    return text .. "\n\n(Written into the item's note.)"
  end

  -- ---------------------------------------------------------------- maker stamps
  function mod.psy_stamp_crafted(it, crafter)
    pcall(function()
      if it:get_var_str("mom_psy_maker", "") ~= "" then return end
      local who = "you"
      if crafter and not U.is_avatar(crafter) then who = tostring(crafter.name) end
      it:set_var_str("mom_psy_maker", who)
    end)
  end

  local prev_started = mod.on_game_started
  function mod.on_game_started(...)
    local r
    if prev_started then r = prev_started(...) end
    pcall(function()
      local you = gapi.get_avatar()
      if not you then return end
      for _, it in ipairs(you:all_items(false)) do
        if it:get_var_str("mom_psy_maker", "") == "" then
          it:set_var_str("mom_psy_maker", "start")
        end
      end
    end)
    return r
  end

  mod.psychometry_story = story    -- exposed for tests
end
