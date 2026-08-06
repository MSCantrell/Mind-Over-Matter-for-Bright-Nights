# Matrix Crystals and the Odds of Awakening

⚠️ **Spoilers.** The game deliberately tells you none of this. If you'd rather
find out by playing, close the tab.

Strange crystals are the only way to awaken a psionic path mid-game. There are
**two kinds**, and they work on completely different rules:

- **Nine colored crystals**, one per school. These roll against a hidden,
  exponentially-decaying chance. Most of this document is about them.
- **One coruscating crystal**, which ignores that math entirely and is far more
  reliable. [See below](#the-coruscating-crystal).

---

## The colored crystals

| Color | School | Item id |
|---|---|---|
| Pink | Biokinesis | `matrix_crystal_biokinesis` |
| Gray | Clairsentience | `matrix_crystal_clairsentience` |
| Cyan | Electrokinesis | `matrix_crystal_electrokinesis` |
| Golden | Photokinesis | `matrix_crystal_photokinesis` |
| Red | Pyrokinesis | `matrix_crystal_pyrokinesis` |
| Yellow | Telekinesis | `matrix_crystal_telekinesis` |
| White | Telepathy | `matrix_crystal_telepathy` |
| Blue | Teleportation | `matrix_crystal_teleportation` |
| Green | Vitakinesis | `matrix_crystal_vitakinesis` |

**You must be wielding it** to activate one. Each use destroys the crystal,
win or lose.

### The formula

Every character carries a hidden counter, `awakening_countup` (**`N`** below).
Your chance, as a percentage:

```
chance = 100 × e ^ ( -(N - B) / 1.7 )

  N = awakening_countup
  B = 0.75 if you have Noetic Flexibility, else 0
```

Two constants fall out of that `1.7`:

- **Every point of `N` multiplies your odds by 0.5553** — a 44.5% cut, at every
  level. Odds halve every 1.18 points, and a path costs 1 point, so **each path
  you own roughly halves your chance at the next one.**
- **Noetic Flexibility multiplies your odds by 1.5545** — a flat +55.5%
  *relative* improvement at every value of `N`. It doesn't flatten the curve; it
  shifts you three-quarters of a path back down it.

### The table

| `N` | Chance | Crystals to expect | With Noetic Flexibility | Crystals |
|---:|---:|---:|---:|---:|
| 0 | 100% | 1 | 100%¹ | 1 |
| 1 | 55.5% | 1.8 | 86.3% | 1.2 |
| 2 | 30.8% | 3.2 | 47.9% | 2.1 |
| 3 | 17.1% | 5.8 | 26.6% | 3.8 |
| 4 | 9.51% | 10.5 | 14.8% | 6.8 |
| 5 | 5.28% | 18.9 | 8.21% | 12.2 |
| 6 | 2.93% | 34.1 | 4.56% | 21.9 |
| 7 | 1.63% | 61.4 | 2.53% | 39.5 |
| 8 | 0.904% | 110.6 | 1.41% | 71.2 |
| 9 | 0.502% | 199.2 | 0.780% | 128.1 |
| 10 | 0.279% | 358.7 | 0.433% | 230.7 |

¹ *the raw value is 155%, capped at certainty*

**"Crystals to expect" is just `1 / chance`.** A failed attempt does **not**
raise `N` and does **not** improve your next try — every attempt is an
independent roll at the same odds. There is no pity timer and no accumulating
progress. If the odds say 199 crystals, that is the honest expected cost, and
half of all characters will need more than 138.

### Where `N` comes from

| Source | Amount | When |
|---|---|---|
| Each psionic path you already have | **+1** | at game start, and again on every awakening |
| Baseline | **+1** | once, 60 turns into the game |
| Psychic Knack trait | **+ ½ per spell known** | at game start |
| Heart of Fire scenario | **+50** | at scenario start |

**Fork change (2026-08-06): the hidden luck roll is gone.** Upstream MoM rolled
a uniform 1–9 here, invisible to the player, that alone spread a fresh
character's real first-crystal odds across a **110× range** (55.5% down to
0.502%) — decided at character creation and never shown or explained. This
fork replaces that roll with a flat **+1**, landing every non-psionic
character's first attempt at the same **55.5%**, no matter what. Everything
else about the formula — the curve, the per-path +1, Noetic Flexibility's
bonus — is unchanged.

Two traits change this:

- **`ALWAYS_GAIN_PSIONICS`** skips the roll entirely, leaving `N` at 0 — your
  first crystal is a guaranteed awakening. The trait is stripped the moment it
  fires.
- **`LIMITED_PSIONICS`**, if you *started* with a path, still takes the +1
  baseline *in addition to* the +1 for that path — so you begin at `N` = 2.

Heart of Fire's +50 isn't a penalty, it's a lockout: `e^(-50/1.7)` works out to
about 0.000000000036%. That scenario means the one path, forever.

### What actually happens when you use one

Before rolling at all, the game checks whether the attempt is possible. It is
**not** if you already have that school, or if you have `CANNOT_GAIN_PSIONICS`.

| Outcome | Crystal | You get |
|---|---|---|
| **Success** | consumed → drained crystal | the path, plus a short school buff and a 5-minute meditation |
| **Failed roll** | consumed → drained crystal | 1 h `psionic_overload`, 10-turn stun, 5-minute meditation |
| **Already have that school**, or `CANNOT_GAIN_PSIONICS` | consumed → **nothing** | 1 h `psionic_overload`, 10-turn stun |

> ⚠️ That last row is worth reading twice. Activating a pink crystal when you are
> already a biokinetic **destroys the crystal, gives you nothing back — not even
> the drained husk — and blinds your psi for an hour.** Check your school before
> you use a colored crystal.

---

## The coruscating crystal

`matrix_crystal_coruscating` — brown, and the odd one out. **None of the above
applies to it.** It ignores `awakening_countup` and Noetic Flexibility
completely.

Instead it picks **one of the nine schools at random, each equally likely**, and
awakens it — unless the school it happened to pick is one you already have, in
which case the attempt simply fails.

So its success chance is just:

```
chance = (9 - paths you already have) / 9
```

| Paths you have | Chance |
|---:|---:|
| 0 | **100%** |
| 1 | 88.9% |
| 2 | 77.8% |
| 3 | 66.7% |
| 4 | 55.6% |
| 5 | 44.4% |

Compare that to a colored crystal at the same point in a typical run — 17.1% for
a third path, 9.51% for a fourth — and the coruscating crystal is worth roughly
**seven colored crystals** to a two-path psion, and only gets better as you go
deeper. It's the single most valuable psionic item in the mod.

It also doesn't need to be wielded, and unlike the colored crystals it leaves you
a drained crystal even when a mundane mind fails to use it.

The one catch: you don't choose the school. And a coruscating awakening still
raises `N` by 1, making every *colored* crystal you find afterwards half as
likely to work.

---

## The short version

Your first path is a coin flip — a fair, known 55.5% — every time. Your third
is a project. Your fifth is a life's work.

- **Save your coruscating crystals for late**, when the colored ones have decayed
  into hopelessness — but note the odds drift down as you collect paths, so
  "late" isn't "never."
- **Noetic Flexibility is worth about ¾ of a path**, everywhere on the curve.
- **Never activate a colored crystal for a school you already have.**
- **Failures cost you nothing but the crystal**, so with a stockpile, grinding
  works. It's just expensive.

---

*Sources: `items/matrix_crystals.json` (items), `lua/gen_iuse_map.lua`
(activation → EOC, `consume`, `need_wielding`), `lua/gen_jmath.lua`
(`J.matrix_awakening_odds`), `lua/gen_eoc.lua` (`EOC_<SCHOOL>_MATRIX_AWAKENING`,
`EOC_CORUSCATING_MATRIX`, `EOC_CONDITION_AWAKENING_X_IN_Y_CHANCE`,
`EOC_GAMESTART_RANDOMIZE_AWAKENING_ODDS`, `EOC_PSI_AWAKENING_*_FINALIZATION`),
`lua/mom_hooks.lua` (`iuse_eoc_item`, `consume_one`). Odds are upstream MoM's
except the removed luck roll — see `tools/eoc_transpile.py`'s
`_fix_awakening_luck_roll` (2026-08-06, fork change).*
