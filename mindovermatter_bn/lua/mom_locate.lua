-- mom_locate: Clairsentient item finding (2026-11-10).  HAND-AUTHORED.
--
-- One original fork power (fork_powers.json):
--   Locate Items (clair_locate_items_thoroughly; the id is from when it was
--   "Locate Items Thoroughly")
--     Search the passive item MEMORY below, out to 20 + 10/level overmap tiles.
--     Results nearest first in a uilist; picking one writes an overmap note.
--   Until 2026-11-18 there was also a tier-1 Locate Item (clair_locate_item), a
--   live scan 6 + 2/level tiles around you.  Cut (user: only the big one is
--   worth training); the bubble refresh at cast time covers what it did.
--
-- Why a memory: Lua's `map` is only the reality bubble (~5 OMT across).  A real
-- world scan needs the C++ mapbuffer, which isn't bound, so unloaded towns
-- can't be read.  Instead every CLAIRSENTIENT avatar passively records what
-- lies in the 7x7 OMTs around them (every floor but sky and solid rock) as they move, and Locate Items
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
  L.PASSIVE_EVERY = 1      -- turns between passive checks (cheap unless work is due)
  L.PASSIVE_RADIUS = 3     -- OMTs around you read passively (7x7: the loaded map
                           -- is ~180 tiles with its border; scan_omt skips any
                           -- OMT not wholly inside it)
  L.PASSIVE_BUDGET = 8     -- max OMT-floors actually read per passive tick
  L.RESCAN_AFTER = 3600    -- turns: an OMT sensed longer ago than this is re-read
  L.CAP = 6000             -- max remembered OMT-floors; trimmed to 90% when exceeded
  -- Every floor of the bubble is read (Clairvoyance shows them all), except
  -- OMTs that can't hold items: sky and unbroken rock.  User bench 2026-11-19
  -- at a mansion: all 21 floors of the 180x180 map = 680,400 squares in 2.06 s
  -- (~3 us/square; only 727 had items), so the cost is visiting squares, and
  -- skipping empty floors removes most of it.  One OMT-floor ~= 1.7 ms, so the
  -- budget keeps a tick near 14 ms; a backlog drains over the next turns,
  -- nearest places first.
  local EMPTY_OTERS = { "open_air", "empty_rock" }
  local Z_MIN, Z_MAX = -10, 10
  L.MAX_RESULTS = 200      -- Thoroughly list cap

  local CLAIR = MutationBranchId.new("CLAIRSENTIENT")

  -- ---------------------------------------------------------------- storage
  local function store()
    local root = game.mod_storage[MOD_ID]
    local s = root.locate
    if type(s) ~= "table" then
      s = { ids = "", omt = {}, n = 0, cats = "" }
      root.locate = s
    end
    s.omt = s.omt or {}
    s.ids = s.ids or ""
    s.cats = s.cats or ""
    s.n = tonumber(s.n) or 0
    return s
  end

  -- Runtime intern cache, rebuilt whenever store() hands back a different
  -- table (i.e. after a load).
  local cache = { src = nil, list = {}, index = {}, cat = {} }
  local function interned()
    local s = store()
    if cache.src ~= s then
      local list, index, cat = {}, {}, {}
      for id in s.ids:gmatch("[^\n]+") do
        list[#list + 1] = id
        index[id] = #list
      end
      for id, ct in s.cats:gmatch("([^\n=]+)=([^\n]*)") do cat[id] = ct end
      cache.src, cache.list, cache.index, cache.cat = s, list, index, cat
    end
    return s, cache
  end

  -- Item category per type, for the c: prefix.  Lua can read a category only
  -- from an item instance (item:get_category_id), not from its itype, so it is
  -- learned as items are sensed and kept in s.cats ("id=cat" lines).
  local function learn_cat(s, c, id, it)
    if c.cat[id] ~= nil then return end
    local ok, ct = pcall(function() return it:get_category_id() end)
    if ok and type(ct) == "string" and ct ~= "" then
      c.cat[id] = ct
      local line = id .. "=" .. ct
      s.cats = (s.cats == "") and line or (s.cats .. "\n" .. line)
    end
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
    local q = U.query_string(title,
      "Part of a name is enough: \"rope\", \"9mm\", \"aspirin\".  Like the game's own search:  "
      .. "c:category  m:material  q:tool quality  k:skill a book teaches  "
      .. "b:first;second (both)  a,b (either)  -x (not x)", "")
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
              learn_cat(s, c, id, it)
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

  -- Sky / solid rock OMTs, remembered for this session only (key -> turn
  -- checked) so a backlog doesn't re-ask the overmap every tick.
  local empty_seen = {}
  local function is_empty_omt(omt, key, t)
    local seen = empty_seen[key]
    if seen and (t - seen) < L.RESCAN_AFTER then return true end
    for _, id in ipairs(EMPTY_OTERS) do
      local ok, yes = pcall(function()
        return overmapbuffer.check_ot(id, OtMatchType.TYPE, omt)
      end)
      if ok and yes then
        empty_seen[key] = t
        return true
      end
    end
    return false
  end

  -- Read the OMTs within `r` of `center` on every floor (all = true) or
  -- center.z +- 0 that are missing or older than `stale` turns, nearest
  -- first, at most `budget` of them (nil = no limit).  Returns the number
  -- read and whether work is still left.
  local function sense_around(center, r, stale, budget)
    local map = gapi.get_map()
    local size = map:get_map_size()
    local t = now()
    local s = store()
    local due = {}
    for z = Z_MIN, Z_MAX do
      for x = center.x - r, center.x + r do
        for y = center.y - r, center.y + r do
          local key = x .. "," .. y .. "," .. z
          local v = s.omt[key]
          if not v or (t - entry_turn(v)) >= stale then
            due[#due + 1] = { x = x, y = y, z = z, key = key,
              d = math.max(math.abs(x - center.x), math.abs(y - center.y))
                  + math.abs(z - center.z) }
          end
        end
      end
    end
    table.sort(due, function(a, b) return a.d < b.d end)
    local read, left = 0, false
    for _, e in ipairs(due) do
      if budget and read >= budget then left = true; break end
      local omt = TripointAbsOmt.new(e.x, e.y, e.z)
      if not is_empty_omt(omt, e.key, t) then
        if scan_omt(map, size, omt, t) then read = read + 1 end
      end
    end
    if read > 0 then evict(store()) end
    return read, left
  end

  -- Passive gathering for every Clairsentient avatar: cheap check every
  -- PASSIVE_EVERY turns, real work only on entering a new OMT, when the
  -- current neighbourhood has gone stale, or while a backlog is left.
  local last = { key = nil, turn = -1e9, backlog = false }
  mod.recurring = mod.recurring or {}
  mod.recurring["MOM_LOCATE_PASSIVE"] = {
    min_turns = L.PASSIVE_EVERY, max_turns = L.PASSIVE_EVERY,
    fn = function(you)
      local ok, err = pcall(function()
        if not you or not you:has_trait(CLAIR) then return end
        local here = coords.project_to_omt(you:abs_pos())
        local key, t = omt_key(here), now()
        if key == last.key and not last.backlog and (t - last.turn) < L.RESCAN_AFTER then
          return
        end
        if key ~= last.key or not last.backlog then last.turn = t end
        last.key = key
        local _, left = sense_around(here, L.PASSIVE_RADIUS, L.RESCAN_AFTER, L.PASSIVE_BUDGET)
        last.backlog = left
      end)
      if not ok then gdebug.log_error("MoM-BN: locate passive: " .. tostring(err)) end
    end,
  }

  -- ------------------------------------------------------------ Locate Items
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

  -- ------------------------------------------------- search-prefix matching
  -- Lua port of BN's item_filter_from_string (item_search.cpp/.h, not bound to
  -- Lua), run against item TYPES because that is all the memory keeps.  Plain
  -- terms match the name; c: m: q: k: b: as in the game; "a,b" = any of them,
  -- "-x" = exclude.  n: (item notes) and d: (disassembly) need an item instance
  -- or recipe data Lua can't reach, so they are refused.  Matching is a
  -- case-insensitive substring of the display name, or of the raw id (so
  -- categories/qualities/skills from other mods, absent from
  -- gen_search_names, still match).
  local names_ok, NAMES = pcall(require, "lua/gen_search_names")
  if not names_ok or type(NAMES) ~= "table" then
    gdebug.log_warn("MoM-BN: gen_search_names missing: " .. tostring(NAMES))
    NAMES = { categories = {}, qualities = {}, skills = {} }
  end
  local UNSUPPORTED = { n = "item notes", d = "disassembly parts" }

  local function lcm(text, f)
    return type(text) == "string" and text:lower():find(f, 1, true) ~= nil
  end
  local function named(tbl, id, f)
    return lcm(id, f) or lcm(tbl[id], f)
  end
  local function itype_obj(id)
    local ok, o = pcall(function() return ItypeId.new(id):obj() end)
    return ok and o or nil
  end

  local compile
  local function basic(f, c)
    local flag
    local colon = f:find(":", 1, true)
    if colon and colon >= 2 then
      flag = f:sub(colon - 1, colon - 1)
      f = f:sub(colon + 1)
    end
    if flag and UNSUPPORTED[flag] then
      error({ msg = flag .. ": (" .. UNSUPPORTED[flag] .. ") can't be searched from memory." })
    end
    if flag == "c" then
      return function(id) return named(NAMES.categories, c.cat[id], f) end
    elseif flag == "m" then
      return function(id)
        local o = itype_obj(id)
        if not o then return false end
        local hit = false
        pcall(function()
          for _, mat in pairs(o.materials) do
            local ok, nm = pcall(function() return mat:obj():name() end)
            if lcm(mat:str(), f) or (ok and lcm(nm, f)) then hit = true; return end
          end
        end)
        return hit
      end
    elseif flag == "q" then
      return function(id)
        local o = itype_obj(id)
        if not o then return false end
        local hit = false
        pcall(function()
          for qid, _ in pairs(o.qualities) do
            if named(NAMES.qualities, qid:str(), f) then hit = true; return end
          end
        end)
        return hit
      end
    elseif flag == "k" then
      return function(id)
        local o = itype_obj(id)
        if not o then return false end
        local ok, sk = pcall(function()
          local b = o:slot_book()
          return b and b.skill and b.skill:str() or nil
        end)
        return ok and sk ~= nil and sk ~= "" and sk ~= "none" and named(NAMES.skills, sk, f)
      end
    elseif flag == "b" then
      local semi = f:find(";", 1, true)
      local a = compile(semi and f:sub(1, semi - 1) or f, c)
      local b2 = compile(semi and f:sub(semi + 1) or "", c)
      return function(id) return a(id) and b2(id) end
    end
    return function(id) return lcm(type_name(id), f) end
  end

  local function trim(x) return (x:gsub("^%s+", ""):gsub("%s+$", "")) end

  compile = function(f, c)
    f = f:gsub("[{}]", "")
    if f == "" then return function() return true end end
    if f:find(",", 1, true) then
      local any, all = {}, {}
      for raw in (f .. ","):gmatch("([^,]*),") do
        local part = trim(raw)
        if part ~= "" then
          local fn = compile(part, c)
          if part:sub(1, 1) == "-" then all[#all + 1] = fn else any[#any + 1] = fn end
        end
      end
      return function(id)
        local p = false
        for _, fn in ipairs(any) do if fn(id) then p = true; break end end
        local n = true
        for _, fn in ipairs(all) do if not fn(id) then n = false; break end end
        if #any > 0 and #all == 0 then return p end
        if #any == 0 and #all > 0 then return n end
        return p and n
      end
    end
    if f:sub(1, 1) == "-" then
      local inner = compile(f:sub(2), c)
      return function(id) return not inner(id) end
    end
    return basic(f, c)
  end
  L._compile_query = compile   -- test hook

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
    sense_around(here, L.PASSIVE_RADIUS, 300, nil)
    last.key, last.turn, last.backlog = omt_key(here), now(), false

    local s, c = interned()
    local okc, pred = pcall(compile, q, c)
    if not okc then
      local why = type(pred) == "table" and pred.msg or tostring(pred)
      U.msg(you, "Your memory can't sort by that: " .. why, MsgType.info, nil)
      return
    end
    local match, names = {}, {}
    for i, id in ipairs(c.list) do
      local okm, yes = pcall(pred, id)
      if okm and yes then
        match[i] = true
        names[i] = type_name(id)
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
  wire("clair_locate_items_thoroughly", locate_thoroughly, 4)

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
    cache.cat = {}
    last.key = nil
    empty_seen = {}
  end

  L._passive_state = function() return last end   -- for mom_prof
  return L
end
