-- mom_locate: Clairsentient item finding (2026-11-10).  HAND-AUTHORED.
--
-- Two original fork powers (fork_powers.json):
--   Locate Item (clair_locate_item)
--     Name an item; scan the live reality bubble around you and report the
--     direction and distance of the nearest matches.  Radius 6 + 2/level, +-1
--     floor from level 5, +-2 from level 10; 1 + level/4 results.
--   Locate Items Thoroughly (clair_locate_items_thoroughly)
--     Search the passive item MEMORY below, out to 20 + 10/level overmap tiles.
--     Results nearest first in a uilist; picking one writes an overmap note.
--
-- Why a memory: Lua's `map` is only the reality bubble (~5 OMT across).  A real
-- world scan needs the C++ mapbuffer, which isn't bound, so unloaded towns
-- can't be read.  Instead every CLAIRSENTIENT avatar passively records what
-- lies in the 3x3 OMTs around them (current z) as they move, and Thoroughly
-- queries that record.  It's stale by design: what you sensed, not what's
-- there now (the age is shown).
--
-- Matching: case-insensitive substring of the item's name, like the V-menu
-- filter.  Live scans use tname; the memory stores itype ids and matches the
-- type name (get_name(1)).  Only top-level items on map tiles count: item
-- contents aren't enumerable from Lua, and vehicle cargo isn't map i_at.
--
-- Storage (game.mod_storage[MOD_ID].locate, persisted with the save):
--   ids  = itype ids interned in first-seen order, joined with "\n"
--   omt  = { ["x,y,z"] = "<turn>;<i>,<i>,..." }  (1-based indexes into ids)
--   n    = number of omt entries
-- Strings, not nested tables: catalua_serde wraps every value in a typed JSON
-- object, so a table of ints would cost ~30 bytes per item instead of ~4.
-- Loading a save replaces mod_storage's nested tables (catalua_serde.cpp:274),
-- so never hold a reference across turns -- always go through store().
return function(mod)
  local L = {}
  mod.locate = L
  local U = mod.u
  local MOD_ID = game.current_mod   -- only valid at load time; capture now

  local OMT = 24
  L.PASSIVE_EVERY = 10     -- turns between passive checks
  L.RESCAN_AFTER = 3600    -- turns: an OMT sensed longer ago than this is re-read
  L.CAP = 3000             -- max remembered OMTs; trimmed to 90% when exceeded
  L.MAX_RESULTS = 200      -- Thoroughly list cap

  local CLAIR = MutationBranchId.new("CLAIRSENTIENT")

  -- ---------------------------------------------------------------- storage
  local function store()
    local root = game.mod_storage[MOD_ID]
    local s = root.locate
    if type(s) ~= "table" then
      s = { ids = "", omt = {}, n = 0 }
      root.locate = s
    end
    s.omt = s.omt or {}
    s.ids = s.ids or ""
    s.n = tonumber(s.n) or 0
    return s
  end

  -- Runtime intern cache, rebuilt whenever store() hands back a different
  -- table (i.e. after a load).
  local cache = { src = nil, list = {}, index = {} }
  local function interned()
    local s = store()
    if cache.src ~= s then
      local list, index = {}, {}
      for id in s.ids:gmatch("[^\n]+") do
        list[#list + 1] = id
        index[id] = #list
      end
      cache.src, cache.list, cache.index = s, list, index
    end
    return s, cache
  end

  local function intern(s, c, id)
    local i = c.index[id]
    if i then return i end
    c.list[#c.list + 1] = id
    i = #c.list
    c.index[id] = i
    s.ids = (s.ids == "") and id or (s.ids .. "\n" .. id)
    return i
  end

  local function omt_key(p) return p.x .. "," .. p.y .. "," .. p.z end

  local function entry_turn(v)
    return tonumber(v:match("^(%-?%d+);")) or 0
  end

  local function evict(s)
    if s.n <= L.CAP then return end
    local all = {}
    for k, v in pairs(s.omt) do all[#all + 1] = { k = k, t = entry_turn(v) } end
    table.sort(all, function(a, b) return a.t < b.t end)
    local drop = #all - math.floor(L.CAP * 0.9)   -- trim to 90% of the cap
    for i = 1, drop do s.omt[all[i].k] = nil end
    s.n = #all - drop
  end

  -- ------------------------------------------------------------------ helpers
  local function now() return gapi.current_turn():to_turn() end

  local function compass(dx, dy)
    local ns = (dy < -math.abs(dx) / 2) and "north" or ((dy > math.abs(dx) / 2) and "south" or "")
    local ew = (dx > math.abs(dy) / 2) and "east" or ((dx < -math.abs(dy) / 2) and "west" or "")
    return ns .. ew
  end

  local FLOOR_WORDS = { "one", "two", "three", "four", "five" }
  local function floors(dz)
    if dz == 0 then return "" end
    local n = math.abs(dz)
    local word = FLOOR_WORDS[n] or tostring(n)
    return ", " .. word .. (n == 1 and " floor " or " floors ") .. (dz > 0 and "up" or "down")
  end

  local function where(dx, dy, dz, d, unit)
    local dir = compass(dx, dy)
    local s
    if d == 0 then
      s = (unit == "tile") and "right here" or "in this area"
    else
      s = d .. " " .. unit .. (d == 1 and "" or "s") .. (dir ~= "" and (" " .. dir) or "")
    end
    return s .. floors(dz)
  end

  local function age(turns)
    if turns < 120 then return "just now" end
    local m = math.floor(turns / 60)
    if m < 120 then return m .. " minutes ago" end
    local h = math.floor(m / 60)
    if h < 48 then return h .. " hours ago" end
    return math.floor(h / 24) .. " days ago"
  end

  local function level(you, id)
    return math.max(mod.math.spell_level(you, id), 0)
  end

  local function ask_query(title)
    local q = U.query_string(title, "Part of a name is enough: \"rope\", \"9mm\", \"aspirin\".", "")
    q = (q or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if q == "" then return nil end
    return q:lower()
  end

  local function in_bubble(map, size, x, y, z)
    return x >= 0 and y >= 0 and x < size and y < size and z >= -10 and z <= 10
  end

  -- ---------------------------------------------------------- memory scanning
  -- Read one OMT from the live map into memory.  Skips OMTs not wholly inside
  -- the bubble, so a partial read never overwrites a full one.  Returns true
  -- if the OMT was read.
  local function scan_omt(map, size, omt, t)
    local o = map:abs_to_bub(coords.project_to_ms(omt))
    if not (in_bubble(map, size, o.x, o.y, o.z)
            and in_bubble(map, size, o.x + OMT - 1, o.y + OMT - 1, o.z)) then
      return false
    end
    local s, c = interned()
    local seen, list = {}, {}
    for dx = 0, OMT - 1 do
      for dy = 0, OMT - 1 do
        local p = TripointBubMs.new(o.x + dx, o.y + dy, o.z)
        if map:has_items_at(p) then
          for _, it in ipairs(map:get_items_at(p):items()) do
            local ok, id = pcall(function() return it:get_type():str() end)
            if ok and id and id ~= "" then
              local i = intern(s, c, id)
              if not seen[i] then
                seen[i] = true
                list[#list + 1] = i
              end
            end
          end
        end
      end
    end
    local key = omt_key(omt)
    if s.omt[key] == nil then s.n = s.n + 1 end
    s.omt[key] = t .. ";" .. table.concat(list, ",")
    return true
  end

  -- Read every OMT within `r` of `center` (same z +- dz) that is missing or
  -- older than `stale` turns.
  local function sense_around(center, r, dz, stale)
    local map = gapi.get_map()
    local size = map:get_map_size()
    local t = now()
    local s = store()
    local read = 0
    for z = center.z - dz, center.z + dz do
      for x = center.x - r, center.x + r do
        for y = center.y - r, center.y + r do
          local omt = TripointAbsOmt.new(x, y, z)
          local v = s.omt[omt_key(omt)]
          if not v or (t - entry_turn(v)) >= stale then
            if scan_omt(map, size, omt, t) then read = read + 1 end
          end
        end
      end
    end
    if read > 0 then evict(store()) end
    return read
  end

  -- Passive gathering for every Clairsentient avatar: cheap check every
  -- PASSIVE_EVERY turns, real work only on entering a new OMT or when the
  -- current neighbourhood has gone stale.
  local last = { key = nil, turn = -1e9 }
  mod.recurring = mod.recurring or {}
  mod.recurring["MOM_LOCATE_PASSIVE"] = {
    min_turns = L.PASSIVE_EVERY, max_turns = L.PASSIVE_EVERY,
    fn = function(you)
      local ok, err = pcall(function()
        if not you or not you:has_trait(CLAIR) then return end
        local here = coords.project_to_omt(you:abs_pos())
        local key, t = omt_key(here), now()
        if key == last.key and (t - last.turn) < L.RESCAN_AFTER then return end
        last.key, last.turn = key, t
        sense_around(here, 1, 0, L.RESCAN_AFTER)
      end)
      if not ok then gdebug.log_error("MoM-BN: locate passive: " .. tostring(err)) end
    end,
  }

  -- ------------------------------------------------------------- Locate Item
  local function locate_item(you)
    local lvl = level(you, "clair_locate_item")
    local q = ask_query("What are you looking for?")
    if not q then
      U.msg(you, "You let the half-formed image slip away.", MsgType.info, nil)
      return
    end
    local radius = math.min(6 + 2 * lvl, 36)
    local dz = (lvl >= 10) and 2 or ((lvl >= 5) and 1 or 0)
    local want = 1 + math.floor(lvl / 4)

    local map = gapi.get_map()
    local size = map:get_map_size()
    local c = you:get_pos_ms()
    local hits = {}
    for z = c.z - dz, c.z + dz do
      for x = c.x - radius, c.x + radius do
        for y = c.y - radius, c.y + radius do
          if in_bubble(map, size, x, y, z) then
            local p = TripointBubMs.new(x, y, z)
            if map:has_items_at(p) then
              for _, it in ipairs(map:get_items_at(p):items()) do
                local name = U.item_name(it)
                if name:lower():find(q, 1, true) then
                  hits[#hits + 1] = { x = x, y = y, z = z, name = name,
                    d = math.max(math.abs(x - c.x), math.abs(y - c.y)) }
                end
              end
            end
          end
        end
      end
    end

    if #hits == 0 then
      U.msg(you, "You reach out for \"" .. q .. "\" and feel nothing like it within "
        .. radius .. " tiles.", MsgType.info, nil)
      return
    end
    table.sort(hits, function(a, b)
      if a.d ~= b.d then return a.d < b.d end
      return math.abs(a.z - c.z) < math.abs(b.z - c.z)
    end)
    local lines = {}
    for i = 1, math.min(want, #hits) do
      local h = hits[i]
      lines[#lines + 1] = h.name .. ", " .. where(h.x - c.x, h.y - c.y, h.z - c.z, h.d, "tile")
    end
    local extra = #hits - #lines
    U.msg(you, "Your senses snag on " .. table.concat(lines, "; ") .. "."
      .. (extra > 0 and ("  (" .. extra .. " more within " .. radius .. " tiles.)") or ""),
      MsgType.good, nil)
  end

  -- --------------------------------------------------- Locate Items Thoroughly
  local function type_name(id)
    local ok, n = pcall(function() return ItypeId.new(id):obj():get_name(1) end)
    return (ok and n and n ~= "") and n or id
  end

  local function add_note(p, text)
    local ok = pcall(function()
      local old = overmapbuffer.get_note(p)
      if old and old ~= "" then
        if not old:find(text, 1, true) then overmapbuffer.set_note(p, old .. " | " .. text) end
      else
        overmapbuffer.set_note(p, text)
      end
    end)
    return ok
  end

  local function locate_thoroughly(you)
    local lvl = level(you, "clair_locate_items_thoroughly")
    local q = ask_query("What are you trying to remember?")
    if not q then
      U.msg(you, "You let the memories settle again, unsearched.", MsgType.info, nil)
      return
    end
    local here = coords.project_to_omt(you:abs_pos())
    -- Refresh everything the bubble can show (OMTs read within the last few
    -- minutes are kept), so nearby results are current.
    sense_around(here, 3, 1, 300)
    last.key, last.turn = omt_key(here), now()

    local s, c = interned()
    local match, names = {}, {}
    for i, id in ipairs(c.list) do
      local n = type_name(id)
      if n:lower():find(q, 1, true) then
        match[i] = true
        names[i] = n
      end
    end

    local reach = 20 + 10 * lvl
    local t = now()
    local found = {}
    for key, v in pairs(s.omt) do
      local x, y, z = key:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
      x, y, z = tonumber(x), tonumber(y), tonumber(z)
      if x then
        local d = math.max(math.abs(x - here.x), math.abs(y - here.y))
        if d <= reach then
          local got
          for si in v:gmatch("[;,](%d+)") do
            local i = tonumber(si)
            if match[i] then
              got = got or {}
              got[#got + 1] = names[i]
            end
          end
          if got then
            table.sort(got)
            found[#found + 1] = { x = x, y = y, z = z, d = d, names = got,
                                  age = t - entry_turn(v) }
          end
        end
      end
    end

    if #found == 0 then
      U.msg(you, "You search " .. s.n .. " remembered places for \"" .. q
        .. "\" and find no trace of it within " .. reach .. " map tiles.", MsgType.info, nil)
      return
    end
    table.sort(found, function(a, b)
      if a.d ~= b.d then return a.d < b.d end
      return math.abs(a.z - here.z) < math.abs(b.z - here.z)
    end)
    local total = #found
    while #found > L.MAX_RESULTS do table.remove(found) end

    local labels = {}
    local function label(f)
      local what = f.names[1]
      if #f.names == 2 then
        what = what .. " and " .. f.names[2]
      elseif #f.names > 2 then
        what = what .. ", " .. f.names[2] .. " and " .. (#f.names - 2) .. " more"
      end
      return (f.marked and "[marked] " or "") .. what .. "  -- "
        .. where(f.x - here.x, f.y - here.y, f.z - here.z, f.d, "map tile")
        .. ", sensed " .. age(f.age)
    end
    for i, f in ipairs(found) do labels[i] = label(f) end

    local title = "You recall \"" .. q .. "\" in " .. total .. (total == 1 and " place" or " places")
      .. (total > #found and (" (nearest " .. #found .. " shown)") or "")
      .. ".  Choose one to mark it on your map.  (Type / to filter.)"
    U.msg(you, "Your memory of " .. s.n .. " places gives up \"" .. q .. "\" in "
      .. total .. (total == 1 and " of them." or " of them."), MsgType.good, nil)
    local marked = 0
    while true do
      local pick = U.select_menu(title, labels, nil, nil, nil)
      if not pick then break end
      local f = found[pick]
      if not f.marked then
        local text = "Sensed: " .. f.names[1] .. (#f.names > 1 and (" +" .. (#f.names - 1)) or "")
        if add_note(TripointAbsOmt.new(f.x, f.y, f.z), text) then
          f.marked = true
          marked = marked + 1
          labels[pick] = label(f)
        end
      end
    end
    if marked > 0 then
      U.msg(you, "You fix " .. marked .. (marked == 1 and " place" or " places")
        .. " on your map.", MsgType.info, nil)
    end
  end

  -- -------------------------------------------------------------- wiring
  local function wire(spell_id, fn, difficulty)
    local marker = "mom_cast_" .. spell_id
    mod.effect_added_handlers = mod.effect_added_handlers or {}
    mod.effect_added_handlers[marker] = function(you, _eff)
      if U.is_avatar(you) then
        local ok, err = pcall(fn, you)
        if not ok then gdebug.log_error("MoM-BN: " .. spell_id .. ": " .. tostring(err)) end
      end
      pcall(function() you:remove_effect(EffectTypeId.new(marker)) end)
      if mod.fire_spell_cast_events then
        mod.fire_spell_cast_events(you,
          { school = "CLAIRSENTIENT", difficulty = difficulty, finish = "tag" }, spell_id)
      end
      return true
    end
  end
  wire("clair_locate_item", locate_item, 3)
  wire("clair_locate_items_thoroughly", locate_thoroughly, 6)

  -- Console helpers: mod.locate.stats() / mod.locate.forget()
  function L.stats()
    local s, c = interned()
    local bytes = #s.ids
    for k, v in pairs(s.omt) do bytes = bytes + #k + #v end
    print(string.format("locate memory: %d places, %d item types, ~%d KB",
      s.n, #c.list, math.floor(bytes / 1024)))
  end
  function L.forget()
    game.mod_storage[MOD_ID].locate = nil
    cache.src = nil
    last.key = nil
  end

  return L
end
