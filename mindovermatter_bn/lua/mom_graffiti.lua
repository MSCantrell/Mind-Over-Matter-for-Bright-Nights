-- Survivor graffiti (fork-original, 2026-11-03).  User design: messages left by earlier
-- survivors that refer to REAL places nearby -- "MEDS -> PHARMACY 3 BLOCKS NE.  LOOTED?" --
-- found on town streets, inside buildings, on countryside roads and (densely) in evac
-- shelters.  Text only: reading one does NOT mark the map (user call).  Locations are true
-- when written; claims like LOOTED or SAFE are the writer's guess.
--
-- How: on_mapgen_postprocess (registered in preload.lua) hands us each freshly generated
-- overmap tile.  A few get a furniture f_mom_graffiti whose message is stored in furniture
-- vars (persisted with the map: savegame_json.cpp "furniture_vars").  BN's own
-- set_graffiti/set_signage exist in C++ (mapgen_constructor.h) but aren't bound to Lua,
-- hence the furniture.  Nearby places come from overmapbuffer.find_closest over EXISTING
-- overmaps only, so a message never forces new overmap generation.
--
-- The hook runs during map generation, so EVERYTHING is pcall-guarded: an error escaping
-- it would surface as a debugmsg popup ("Failed to run hook on_mapgen_postprocess").
return function(mod)
  local G = {}
  mod.graffiti = G

  local FURN = "f_mom_graffiti"
  local VAR_MEDIUM, VAR_TEXT = "mom_graffiti_medium", "mom_graffiti_text"

  -- Percent chance per overmap tile, and max messages per tile.  Tripled 2026-11-12 (user:
  -- "haven't seen a single one"); was street 6 / building 3 / country 2 / shelter 50 max 3.
  -- Shelters are where people waited, so they're dense.
  G.RATE = { street = 18, building = 9, country = 6, shelter = 100 }
  G.MAX_PER_TILE = { street = 1, building = 1, country = 1, shelter = 5 }

  -- BN's PREFIX match (overmap.cpp is_ot_prefix) needs the id to equal the prefix or continue
  -- with '_', so a prefix must NOT end in '_' ("s_" only matched "s__...": never).  Shop ids
  -- are s_<kind>[_n]; the list below is every BN s_ kind except lots/fields/airport/parking.
  local SHOP_PREFIXES = { "s_antique", "s_arcade", "s_bike", "s_bookstore", "s_butcher",
    "s_clothes", "s_daycare", "s_dive", "s_electronics", "s_games", "s_garage", "s_gardening",
    "s_gas", "s_grocery", "s_gun", "s_hardware", "s_hunting", "s_jewelry", "s_laundromat",
    "s_library", "s_lightindustry", "s_liquor", "s_music", "s_petstore", "s_pharm", "s_pizza",
    "s_restaurant", "s_reststop", "s_shoppingplaza", "s_sports", "s_teashop", "s_thrift", "s_vfw" }
  local function concat(a, b)
    local t = {}
    for _, v in ipairs(a) do t[#t + 1] = v end
    for _, v in ipairs(b) do t[#t + 1] = v end
    return t
  end
  local SHELTER_PREFIXES = { "evac_center", "shelter", "fema" }
  local BUILDING_PREFIXES = concat({ "house", "office", "church", "school", "bar", "police",
    "fire_station", "motel", "hotel", "apartments", "bank", "pawn", "cabin", "farm", "gym",
    "mall", "garage", "warehouse", "museum", "bakery" }, SHOP_PREFIXES)
  -- a road with one of these within 2 tiles is a town street
  local TOWN_PREFIXES = concat({ "house" }, SHOP_PREFIXES)
  G.SHOP_PREFIXES, G.BUILDING_PREFIXES, G.TOWN_PREFIXES = SHOP_PREFIXES, BUILDING_PREFIXES, TOWN_PREFIXES

  -- ------------------------------------------------------------------ content tables
  -- Status lines are per place and match how BN GENERATES it (checked against CBN mapgen
  -- 2026-11-03): everything spawns fully stocked, nothing is pre-looted, and the high-value
  -- shops spawn locked.  Gun stores: barred, alarmed windows and metal/alarmed locked doors.
  -- Pharmacies: alarmed locked front door.  Police: bars and metal locked doors.  Hospitals
  -- and evac centers: locked metal doors.  Groceries, hardware and sports stores: mostly
  -- ordinary unlocked doors and glass.  So no "LOOTED"/"EMPTY"/"DOOR'S OPEN" on the locked
  -- ones -- they'd be wrong every time.  "" = no status.
  local SUPPLIES = {
    { p = { "s_pharm" }, what = "PHARMACY", hook = { "MEDS", "PILLS", "MEDICINE" },
      status = { "STILL STOCKED.", "LOCKED. ALARM ON THE DOOR.", "BRING A CROWBAR.", "" } },
    { p = { "s_gun" }, what = "GUN STORE", hook = { "GUNS", "AMMO" },
      status = { "BARS ON THE WINDOWS. ALARMS.", "LOCKED UP TIGHT.", "STILL FULL. CAN'T GET IN.",
                 "BRING A TORCH.", "" } },
    { p = { "s_grocery" }, what = "GROCERY", hook = { "FOOD", "CANNED FOOD" },
      status = { "STILL STOCKED.", "DOORS AREN'T EVEN LOCKED.", "CANS IN THE BACK.", "" } },
    { p = { "hospital" }, what = "HOSPITAL", hook = { "DOCTORS?", "MEDS" },
      status = { "LOCKED.", "SUPPLIES STILL INSIDE.", "DON'T GO IN AT NIGHT.", "" } },
    { p = { "s_hardware" }, what = "HARDWARE STORE", hook = { "TOOLS" },
      status = { "STILL STOCKED.", "DOORS AREN'T LOCKED.", "" } },
    { p = { "s_sports" }, what = "SPORTS STORE", hook = { "CAMPING GEAR", "BOWS" },
      status = { "STILL STOCKED.", "DOORS AREN'T LOCKED.", "" } },
    { p = { "s_gas" }, what = "GAS STATION", hook = { "GAS", "FUEL" },
      status = { "STORE'S LOCKED. PUMPS ARE OUTSIDE.", "" } },
    { p = { "police" }, what = "POLICE STATION", hook = { "COP GUNS", "ARMOR" },
      status = { "LOCKED UP TIGHT. BARS.", "ARMORY'S IN THE BACK.", "" } },
    { p = { "evac_center", "shelter" }, what = "EVAC SHELTER", hook = { "SHELTER", "SAFE?" },
      status = { "LOCKED. NOBODY ANSWERED.", "" } },
  }
  local SUPPLY_LINES = {
    "{HOOK} -> {WHAT} {WHERE}. {STATUS}",
    "{WHAT} {WHERE}. {STATUS}",
    "NEED {HOOK}? {WHAT}, {WHERE}. {STATUS}",
    "{HOOK} @ {WHAT} {WHERE}",
  }

  local DANGERS = {
    { p = { "lab", "central_lab" }, lines = {
      "DON'T GO {DIR}. THERE'S A LAB.",
      "LAB {WHERE}. SEALED. KEEP IT THAT WAY.",
      "{DIR} = LAB = NO." } },
    { p = { "mil_base", "mil_airfield", "mil_blacksite", "outpost", "bunker" }, lines = {
      "SOLDIERS {WHERE}. THEY SHOOT FIRST.",
      "THE BASE {DIR} WENT QUIET ON DAY 2.",
      "DON'T TRUST THE ARMY {DIR}. NOBODY CAME BACK." } },
    { p = { "fungal" }, lines = {
      "MUSHROOM PEOPLE {DIR}. DON'T BREATHE IT IN.",
      "THE GROUND IS FUZZY {WHERE}. TURN BACK." } },
    { p = { "triffid" }, lines = {
      "PLANTS THAT WALK. {WHERE}. NOT A JOKE.",
      "DON'T GO IN THE GROVE {DIR}." } },
    { p = { "anthill", "acid_anthill" }, lines = {
      "ANTS THE SIZE OF DOGS. {WHERE}.",
      "HOLE IN THE GROUND {DIR}. SOMETHING CLICKS DOWN THERE." } },
  }

  local PSI_NEAR = {
    "PSYCHICS @ OLD QUARRY {DIR}. THEY TAKE STRAYS.",
    "IF YOU HEAR THE HUM, GO {DIR}. QUARRY. ASK FOR WREN.",
    "FIRE HANDS? LIGHTNING SKIN? QUARRY, {WHERE}. YOU'RE NOT CRAZY.",
    "THE QUARRY PEOPLE {DIR} ARE OK. THEY DIDN'T ASK QUESTIONS.",
  }
  local PSI_FAR = {
    "THEY SAY THERE'S A QUARRY FULL OF PEOPLE LIKE US.",
    "THE LADY WITH THE PINS IS REAL.",
    "IF THINGS MOVE WHEN YOU'RE ANGRY, YOU'RE NOT ALONE.",
    "SOMEBODY SENT A STRANGER TO FIND ME. I SHOULD HAVE GONE.",
  }

  local NAMES = { "J", "DANNY", "MARISOL", "KEV", "ABBY", "TOMAS", "LIZ", "DEV", "NANA",
    "RUTHIE", "CAL", "PRIYA", "BEN", "MO", "SAM", "TEDDY", "JO", "OMAR", "KAT", "LUIS" }
  local PETS = { "BISCUIT", "DUKE", "PEPPER", "MOOSE", "GHOST" }
  local PERSONAL = {
    "MOM - WENT TO GRANDMA'S. - {N1}",
    "{N1} IF YOU SEE THIS I'M OK. GONE {DIR}.",
    "WE WAITED 3 DAYS FOR {N1}.",
    "{N1} + {N2} WERE HERE",
    "SORRY {N1}.",
    "DON'T DRINK THE TAP WATER.",
    "COUNTED 41 OF THEM GOING {DIR}.",
    "NO ONE IS COMING.",
    "BITTEN = LEAVE. WE MEAN IT.",
    "HONK IF YOU'RE ALIVE",
    "THE DOG IS NAMED {PET}. PLEASE FEED HIM.",
    "{N1} - I TOOK THE CAR. I'M SORRY.",
    "GOD ISN'T ANSWERING. TRY AGAIN LATER.",
    "IT'S NOT THE END OF THE WORLD. JUST THE END OF THIS ONE.",
  }
  local EERIE = {
    "THE HUM ISN'T IN YOUR HEAD.",
    "I KNEW YOU WOULD READ THIS.",
    "STOP LISTENING TO THEM.",
    "THEY CAN HEAR YOU THINK. THINK QUIETLY.",
    "I SAW THIS WALL BEFORE I GOT HERE.",
    "THE CRYSTALS ARE WARM. DON'T TOUCH THE WARM ONES.",
    "MY HANDS GLOWED LAST NIGHT. I DIDN'T TELL ANYONE.",
    "IF YOU CAN READ THIS WITH YOUR EYES CLOSED, RUN.",
  }
  local SHELTER = {
    "DAY {D}. STILL NO BUS.",
    "THE BUS NEVER CAME.",
    "DAY 1 2 3 4 5 6 7 8 9 ... WE STOPPED COUNTING.",
    "IF FOUND, WE WENT {DIR}. - {N1}, {N2}, {N3}",
    "FULL. GO AWAY.",
    "THEY SAID HELP WAS COMING.",
    "{D} OF US LEFT.",
    "{N1} DIED HERE. WE WILL REMEMBER.",
  }

  local MEDIUM = {
    street = { "Spray-painted across the pavement:", "Spray-painted in dripping letters:" },
    country = { "Spray-painted on the road in huge letters:",
                "Painted on a sheet of plywood propped beside the road:" },
    building = { "Written on the wall in marker:", "Scrawled on the wall in lipstick:",
                 "Scratched into the wall:" },
    shelter = { "Scrawled on the wall in marker:", "Written on the wall, gone over again and again:",
                "Written on the wall in something that is not paint:" },
  }

  -- Kind weights per place.  Supplies/danger/psi fall back to personal when nothing real
  -- is in range.
  G.WEIGHTS = {
    street   = { supplies = 40, danger = 20, psi = 10, personal = 20, eerie = 10 },
    building = { supplies = 20, danger = 10, psi = 15, personal = 40, eerie = 15 },
    country  = { supplies = 20, danger = 25, psi = 20, personal = 25, eerie = 10 },
    shelter  = { shelter = 40, personal = 30, danger = 10, psi = 10, eerie = 10 },
  }
  local RANGE = { supplies = 12, danger = 15, psi = 40 }

  -- ------------------------------------------------------------------ pure helpers
  local function pick(t) return t[gapi.rng(1, #t)] end

  local function shuffled(t)
    local s = {}
    for i, v in ipairs(t) do s[i] = v end
    for i = #s, 2, -1 do
      local j = gapi.rng(1, i)
      s[i], s[j] = s[j], s[i]
    end
    return s
  end

  local function weighted(w)
    local total = 0
    for _, v in pairs(w) do total = total + v end
    local r = gapi.rng(1, total)
    local keys = {}
    for k in pairs(w) do keys[#keys + 1] = k end
    table.sort(keys)                      -- deterministic order for a given rng stream
    for _, k in ipairs(keys) do
      r = r - w[k]
      if r <= 0 then return k end
    end
    return keys[#keys]
  end

  -- 8-way compass from (dx, dy), overmap y growing south.
  function G.compass(dx, dy)
    if dx == 0 and dy == 0 then return "HERE" end
    local a = math.deg(math.atan(-dy, dx)) % 360
    local names = { "E", "NE", "N", "NW", "W", "SW", "S", "SE" }
    return names[(math.floor((a + 22.5) / 45) % 8) + 1]
  end

  -- "3 BLOCKS NE" in town; "NE, NOT FAR" out in the country.
  function G.where(dx, dy, place)
    local dir = G.compass(dx, dy)
    local n = math.max(math.abs(dx), math.abs(dy))
    if place == "country" then
      return dir .. (n <= 6 and ", NOT FAR" or ", LONG WALK")
    end
    if n <= 1 then return "NEXT BLOCK " .. dir end
    if n <= 12 then return n .. " BLOCKS " .. dir end
    return "WAY " .. dir
  end

  local function fill(tpl, t)
    local s = tpl:gsub("{(%u+%d?)}", function(k) return t[k] or "" end)
    s = s:gsub("%s+$", ""):gsub("%s%s+", " ")
    return s
  end

  -- ------------------------------------------------------------------ world queries
  -- Closest existing overmap tile whose id starts with one of `prefixes`, within `range`
  -- tiles on the same z-level.  Returns dx, dy or nil.  One scan with every prefix as a type
  -- (was one scan per prefix; the shop list made that ~35 scans per road tile).
  function G.find_near(origin, prefixes, range)
    local fp = OmtFindParams.new()
    for _, pre in ipairs(prefixes) do fp:add_type(pre, OtMatchType.PREFIX) end
    fp:set_search_range(1, range)
    fp:set_search_layers(origin.z, origin.z)
    fp.existing_only = true
    local hit = overmapbuffer.find_closest(origin, fp)
    if hit then return hit.x - origin.x, hit.y - origin.y end
    return nil
  end

  local function any_prefix(prefixes, omt)
    for _, pre in ipairs(prefixes) do
      if overmapbuffer.check_ot(pre, OtMatchType.PREFIX, omt) then return true end
    end
    return false
  end

  -- Which kind of place is this overmap tile?  nil = never gets graffiti.
  function G.classify(omt)
    if omt.z ~= 0 then return nil end
    if any_prefix(SHELTER_PREFIXES, omt) then return "shelter" end
    if overmapbuffer.check_ot("road", OtMatchType.PREFIX, omt) then
      return G.find_near(omt, TOWN_PREFIXES, 2) and "street" or "country"
    end
    if any_prefix(BUILDING_PREFIXES, omt) then return "building" end
    return nil
  end

  -- ------------------------------------------------------------------ message
  -- Returns medium, text.  `near(prefixes, range)` -> dx, dy | nil (injected for tests).
  function G.compose(place, near)
    local kind = weighted(G.WEIGHTS[place])
    local base = { N1 = pick(NAMES), N2 = pick(NAMES), N3 = pick(NAMES), PET = pick(PETS),
                   D = tostring(gapi.rng(3, 19)), DIR = G.compass(gapi.rng(-3, 3), gapi.rng(-3, 3)) }
    if base.DIR == "HERE" then base.DIR = "NORTH" end
    local text
    -- Supplies/danger try EVERY kind in random order until one is in range (was 3 random
    -- picks / 1 pick, so a town missing a few kinds mostly fell back to personal notes).
    -- Only runs for the few tiles that won the RATE roll, so the extra scans are cheap.
    if kind == "supplies" then
      for _, s in ipairs(shuffled(SUPPLIES)) do
        local dx, dy = near(s.p, RANGE.supplies)
        if dx then
          text = fill(pick(SUPPLY_LINES), { HOOK = pick(s.hook), WHAT = s.what,
            WHERE = G.where(dx, dy, place), STATUS = pick(s.status) })
          break
        end
      end
    elseif kind == "danger" then
      for _, d in ipairs(shuffled(DANGERS)) do
        local dx, dy = near(d.p, RANGE.danger)
        if dx then
          text = fill(pick(d.lines), { DIR = G.compass(dx, dy), WHERE = G.where(dx, dy, place) })
          break
        end
      end
    elseif kind == "psi" then
      local dx, dy = near({ "mom_psi_enclave" }, RANGE.psi)
      if dx then
        text = fill(pick(PSI_NEAR), { DIR = G.compass(dx, dy), WHERE = G.where(dx, dy, place) })
      else
        text = pick(PSI_FAR)
      end
    elseif kind == "eerie" then
      text = pick(EERIE)
    elseif kind == "shelter" then
      text = fill(pick(SHELTER), base)
    end
    if not text then text = fill(pick(PERSONAL), base) end   -- personal, or a fallback
    return pick(MEDIUM[place]), text
  end

  -- ------------------------------------------------------------------ placement
  local function is_null_furn(map, p)
    local f = map:get_furn_at(p)
    return (not f) or f:str_id():str() == "f_null"
  end

  local function passable(map, p)
    local t = map:get_ter_at(p)
    return t and t:obj():get_movecost() > 0 and not map:has_ter_flag_at("LIQUID", p)
  end

  -- Indoors: a floor tile beside a wall.  Outdoors: open ground.  nil if none found.
  function G.find_spot(map, indoor)
    local size = map:get_map_size()
    for _ = 1, 60 do
      local x, y = gapi.rng(1, size - 2), gapi.rng(1, size - 2)
      local p = PointOmtMs.new(x, y)
      if passable(map, p) and is_null_furn(map, p)
          and map:has_ter_flag_at("INDOORS", p) == indoor then
        if not indoor then return p end
        for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
          if map:has_ter_flag_at("WALL", PointOmtMs.new(x + d[1], y + d[2])) then return p end
        end
      end
    end
    return nil
  end

  local FURN_INT
  function G.postprocess(params)
    local omt, map = params.omt, params.map
    if not (omt and map) then return end
    local place = G.classify(omt)
    if not place or gapi.rng(1, 100) > G.RATE[place] then return end
    FURN_INT = FURN_INT or FurnId.new(FURN):int_id()
    local near = function(prefixes, range) return G.find_near(omt, prefixes, range) end
    local indoor = (place == "building" or place == "shelter")
    for _ = 1, gapi.rng(1, G.MAX_PER_TILE[place]) do
      local p = G.find_spot(map, indoor)
      if not p then return end
      local medium, text = G.compose(place, near)
      map:set_furn_at(p, FURN_INT)
      map:set_furn_var_at(p, VAR_MEDIUM, medium)
      map:set_furn_var_at(p, VAR_TEXT, text)
      -- One INFO line per message so a playtest can confirm placement from debug.log
      -- (grep "MoM-BN: graffiti"); never seen in play as of 2026-11-12.
      G.placed = (G.placed or 0) + 1
      gdebug.log_info(string.format("MoM-BN: graffiti #%d (%s) at omt %d,%d: %s",
        G.placed, place, omt.x, omt.y, text))
    end
  end

  local warned = false
  local prev = mod.on_mapgen_postprocess
  function mod.on_mapgen_postprocess(params)
    local ok, err = pcall(G.postprocess, params)
    if not ok and not warned then
      warned = true
      gdebug.log_warn("MoM-BN: graffiti mapgen failed (further errors suppressed): " .. tostring(err))
    end
    if prev then return prev(params) end
  end

  game.examine_functions["mom_graffiti"] = function(params)
    local ok, text = pcall(function()
      local m = gapi.get_map()
      local medium = m:get_furn_var_at(params.pos, VAR_MEDIUM, "Scrawled here:")
      local words = m:get_furn_var_at(params.pos, VAR_TEXT, "")
      if words == "" then return "Whatever was written here has been scrubbed away." end
      return medium .. "\n\n\"" .. words .. "\""
    end)
    if not ok then
      gdebug.log_warn("MoM-BN: graffiti examine failed: " .. tostring(text))
      text = "The writing is too smeared to read."
    end
    mod.u.popup(text)
  end
end
