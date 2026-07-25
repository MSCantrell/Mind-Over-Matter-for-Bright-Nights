-- mom_util: run/queue/weighted EOC helpers (spec §8).
local M = {}

-- queue_eocs: {fire_turn, fn, you} entries drained by mom_hooks.on_every_x.
-- fire_turn is an integer turn number (gapi.current_turn():to_turn()) — the
-- TimePoint binding has __lt/__eq but no __le, so >= on TimePoints is unsafe;
-- plain ints sidestep that (TODO 4 resolved, catalua_bindings.cpp:971).
M.queue = {}

-- delay is in turns (1 turn = 1 second in BN).
function M.queue_eoc(fn, you, delay)
  table.insert(M.queue, {
    fire_turn = gapi.current_turn():to_turn() + math.floor(delay),
    fn = fn,
    you = you,
  })
end

-- Scaled duration for a cast-map entry's duration_moves at a spell level.
-- Cast-map values are DDA *moves* (100 moves = 1 turn).  TODO(phase2): confirm
-- the scale at first in-game cast with a visible-duration effect.
function M.duration_from_moves(dm, level)
  if not dm then return nil end
  local moves = dm.min_duration + dm.duration_increment * math.max(level, 0)
  if moves > dm.max_duration then moves = dm.max_duration end
  return TimeDuration.from_turns(math.floor(moves / 100))
end

-- Nether Attunement bump (spec Rev 3, amended QA round 3): the meter is
-- vitamin-scale (0..250, see mom_math).  `weight` ~ power difficulty; odds
-- also scale with how many powers are being maintained.  Kept for the
-- hand-ported pilot path; the transpiled RAISE_ATTUNEMENT chains write the
-- meter directly via attunement_set.
function M.channel_surge(you, weight, math_shim)
  local odds = weight + 10 * math_shim.maintained_count(you)  -- TODO: tune (percent)
  if gapi.rng(1, 100) <= odds then
    math_shim.attunement_set(you, math_shim.attunement(you) + gapi.rng(0, weight))
  end
end

-- weighted_list_eocs: pairs of {fn, weight}; picks one and calls it.
function M.weighted_call(entries, you, npc, ctx)
  local total = 0
  for _, e in ipairs(entries) do total = total + e[2] end
  local roll = gapi.rng(1, total)
  for _, e in ipairs(entries) do
    roll = roll - e[2]
    if roll <= 0 then return e[1](you, npc, ctx) end
  end
end

return M
