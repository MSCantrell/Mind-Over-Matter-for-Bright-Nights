-- mom_util: run/queue/weighted EOC helpers (spec §8).
local M = {}

-- queue_eocs: {fire_turn, fn, you} entries drained by mom_hooks.on_every_x.
-- fire_turn is an integer turn number (gapi.current_turn():to_turn()) — the
-- TimePoint binding has __lt/__eq but no __le, so >= on TimePoints is unsafe;
-- plain ints sidestep that (TODO 4 resolved, catalua_bindings.cpp:971).
M.queue = {}

-- Activity binding (2026-11-04, Gateway double-attune bug).  DDA's channeled powers
-- (Gateway attune, healing trances, sterilization...) do: assign an activity, then
-- queue the "finished" EOC for when it should end.  Nothing ties the queued EOC to that
-- particular activity, so a cast cancelled and then re-cast left the first cast's
-- callback live, and it fired inside the second one.  U.assign_activity now bumps a
-- per-activity generation and arms `pending_bind`; the next queue_eoc in the same turn
-- (the starter's own) takes the binding, and the drainer (mom_hooks.on_every_x) drops
-- an entry whose activity has since been started again.  Cancel-without-restart is
-- handled by the restored character_finished_activity event (same drainer), which
-- strips the channeling effect the queued EOC's own condition checks.
M.act_gen = {}
M.pending_bind = nil

function M.bind_next_queue(act_id)
  M.act_gen[act_id] = (M.act_gen[act_id] or 0) + 1
  M.pending_bind = { act = act_id, gen = M.act_gen[act_id],
                     turn = gapi.current_turn():to_turn() }
end

function M.entry_is_stale(entry)
  local b = entry.bind
  return b ~= nil and M.act_gen[b.act] ~= b.gen
end

-- delay is in turns (1 turn = 1 second in BN).
function M.queue_eoc(fn, you, delay)
  local now = gapi.current_turn():to_turn()
  local bind = M.pending_bind
  if bind then
    M.pending_bind = nil
    if bind.turn ~= now then bind = nil end
  end
  table.insert(M.queue, {
    fire_turn = now + math.floor(delay),
    fn = fn,
    you = you,
    bind = bind,
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
