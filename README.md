# Mind Over Matter (BN)

Psionics for **Cataclysm: Bright Nights** — nine psychic power paths and 160 powers that
unlock through use rather than study.

This is a Lua-based port of [Mind Over Matter](https://github.com/CleverRaven/Cataclysm-DDA/tree/master/data/mods/MindOverMatter)
by **Standing-Storm**, originally written for Cataclysm: DDA. BN lacks several engine
features MoM depends on (EOC spell effects, enchantments on effects, proficiencies,
vitamins-as-resource), so most of the mod is re-implemented on top of a hand-written Lua
runtime. See [Architecture](#architecture-for-the-curious) if you want to know how.

> **Status: beta, seeking testers.** It loads clean and the whole content set is in, but
> a number of powers are known-broken or unconfirmed. Please read
> [Known issues](#known-issues) before filing a bug — several are already on the list.

---

## Requirements

- **Cataclysm: Bright Nights**, a recent **nightly** with Lua support
  (`lua_api_version 2`). Developed and tested against the **2026-07-22** nightly.
- No other mods are required. Depends only on the base `bn` content.

## Install

1. Grab the newest zip from **[Releases](../../releases)** — releases are dated, e.g.
   `2026.8.1`, so you always know which build you're on. (**Code → Download ZIP** gets the
   latest in-progress `main` instead, which is fine but harder to report bugs against.)

   Or install it from the **[BN Mod Registry](https://mods.cataclysmbn.org/)**, which
   handles the unpacking below for you.
2. Inside the zip there is a folder named **`mindovermatter_bn`**. Copy *that inner folder*
   into your BN install's `mods/` directory — **not** the zip's top-level
   `Mind-Over-Matter-for-Bright-Nights-…` wrapper:

   ```
   <your BN folder>/mods/mindovermatter_bn/modinfo.json
   ```

   The folder must keep the name `mindovermatter_bn`.
3. Start BN, create a **new world**, and enable **Mind Over Matter (BN)** in the mod list.

### Confirm it actually loaded

Lua load failures are quiet. After starting a world, open `config/debug.log` and look for:

```
MoM-BN: main loaded (1790 EOC handlers)
```

If that line is missing, the Lua runtime didn't come up and nothing psionic will work —
please file an issue and attach `debug.log`.

> **Restart, don't save-reload.** Spell, description, and EOC data is read at *startup*.
> If you update the mod, fully quit and relaunch the game — a save-reload will not pick
> up changes. A change that appears to "do nothing" is almost always this.

---

## Getting powers

- **Easiest:** pick one of the psionic **professions** at character creation.
-  Each path has a themed starting profession — Star Athlete (biokinetic),
  Doomseer (clairsentient), Firestarter (pyrokinetic), Faith Healer (vitakinetic), and so
  on. **Awakening Psion** rolls a random path.
- **In world:** strange crystals found in Nether-touched places or carried by psychic
  ferals can awaken a latent path.
- Powers run on **Stamina**. Heavy use causes **Nether Attunement**, which
  come with negative effects like damage and vomiting. Clear it with time or the "Grounding meditation"
  crafting recipe.

### Powers unlock by using powers

There are **no skill books to grind**. Once you have a path, using your powers levels
them, and reaching the right levels in the right combination causes the next power to
surface on its own:

> *"Use of your powers has led to an insight. You could harden your skin to protect
> yourself from damage, if you can figure out the technique."*

Pacing is driven by **Intelligence** and the **metaphysics** skill. Every power's
description also lists what unlocks it, so you can plan a build without a wiki.
Also see the pretty mermaid chart, Psionic Discipline Atlas, linked below. 
*(This differs from DDA, which requires a 16-hour meditation activity per power. That
grind is removed here — see [Fork changes](#fork-changes-deliberate-differences-from-dda).)*

## The nine paths

| Path | Powers | From start | Theme |
|---|---:|---:|---|
| **Biokinesis** | 19 | 4 | Control of the body — strength, speed, armored skin, sealed physiology |
| **Clairsentience** | 18 | 4 | Senses beyond the body — night vision, danger sense, seeing through walls |
| **Electrokinesis** | 16 | 3 | Electricity — shocks, charging batteries, short-circuiting machines |
| **Photokinesis** | 20 | 2 | Light — illumination, blinding glare, invisibility |
| **Pyrokinesis** | 15 | 2 | Fire and heat — ignition, heat immunity, lava, boiling a target from within |
| **Telekinesis** | 18 | 3 | Force at a distance — pulling, hurling, barriers, collapsing structures |
| **Telepathy** | 14 | 2 | Mind — persuasion, concealment, seizing control of an enemy |
| **Teleportation** | 20 | 4 | Moving without crossing the distance — escapes, long jumps, banishment |
| **Vitakinesis** | 20 | 4 | Health and injury — wound-binding, accelerated healing, limb repair |

**160 powers** in total: 28 are foundations you get the moment you take up a school, and
the remaining **132** unlock through play. Plus **psychic knacks** — talents that start at level 6 and
don't advance any further. 

### Reference documents

- **[Psionic Discipline Atlas](mindovermatter_bn/PSIONIC_ATLAS.md)** — the full
  power-acquisition tree for all nine schools, with every prerequisite and minimum level.
  Renders as diagrams directly on GitHub. Start here if you want to plan a build.
- **[Crystalline Elixirs](mindovermatter_bn/CRYSTALLINE_ELIXIRS.md)** — ⚠️ **spoilers.**
  The nine school elixirs deliberately tell you nothing in their item descriptions; this
  documents what each actually does, including the attunement cost and the comedown.

---

## Fork changes (deliberate differences from DDA)

Not everything is a 1:1 copy. Where BN couldn't express something, or where the DDA design
worked poorly, this port diverges on purpose:

- **Power acquisition rewritten.** DDA's 16-hour meditation-per-power grind is gone;
  powers auto-grant on prerequisites plus Int/metaphysics-paced time.
- **Transparency doctrine.** Every power description states what it unlocks and what
  unlocked it. DDA leaves this mysterious; this port does not.
- **Mass Hydrothermosis** replaces Hellfire as the pyrokinetic capstone — boils the fluids
  inside every monster in line of sight. No ground fire, no self-immunity. Pets and
  psi-null creatures are spared; everything else boils.
- **Molten Land** replaces Fountain of Flames — turns a tile of ground into **permanent
  lava**. A zoning tool, not a burst. Monsters keep the old fire burst, so ferals can't
  permanently scar your map.
- **Mind Sonar** replaces Sense Minds, as a readable census rather than a map overlay
  (BN has no creature-sensing hook).
- **Lifting Field raises your carrying capacity** (2 kg at level 1 up to 467 kg at level 30,
  upstream's own curve) instead of hovering one named object weightlessly beside you. DDA does
  it with a zero-weight holster pocket; BN is pre-pocket and no container can discount its
  contents' weight. It lifts **weight, not bulk** — your pack is no roomier.
- **Cut as unportable:** Nether Banish (BN monster spells cannot target other monsters),
  Re-energize (no vehicle-charge binding), Water Walking (inert in BN).

## Known issues

Please check here first — these are known and do not need new reports.

**Powers that don't work correctly yet**
- **Displacement / Reactive Displacement** don't teleport the target monster.
- **Beast Tamer** can't extend an already-friendly animal's duration (BN's charm only
  applies to non-friendly monsters).
- **Maintained-power costs are probably too lenient.** Only 3 of ~64 maintained powers count toward
  concentration-break odds and calorie drain, so holding many at once is underpenalized.
- Some feral-psychic monster attacks are stubs (their Banish, Electrokinetic Revive).

**Content wiring**
- The **OBSIDIAN RING** dialogue-computer is inert (flavor-only even in DDA).
- The **Devourer** lab boss exists but nothing spawns it yet.
- Phavian city buildings are present but never placed.

**Monster behaviour BN cannot express** *(found via issue #3, fixed as far as BN allows)*
- **Psionic monsters only cast their self-buffs when they can see a target.** In DDA a
  buff like a mi-go juggernaut's speed boost can be cast with no one around
  (`allow_no_target`). BN's monster spellcasting bails whenever the monster has no
  attack target, with no way to opt out, so buffs land at the start of a fight rather
  than before one. No BN-side lever for this.
- **Reach melee attacks are adjacent-only.** BN melee has no range field, so the
  psychic shriek and the telekinetic hurl are touch attacks rather than ranged ones.
- **Monster melee ignores DDA's dodge/block flags**, so a few attacks MoM marked
  undodgeable can be dodged.
- **Lab and lockbox item groups spawn their contents loose** rather than inside a box
  or wallet — BN item groups have no container field.

**Want playtest confirmation especially on:**
- **Nether Attunement** and per-cast costs — do they actually hurt?
- **Auto-learn pacing** — do powers arrive too fast, too slow, or about right?
- **Mass Hydrothermosis** — does LOS-wide reach feel fair, does the Stamina cost hurt enough?
- **Duration powers** — any that last a suspiciously wrong amount of time.
- **Summoned tools now disappear when you stop concentrating.** Previously the lifting jack,
  hacking interface, fire tool, radio, hammerhand and friends stayed in your inventory
  forever. If you find a psionic tool that *outlives* its power, that's a bug worth reporting.
- **Photon Regulation** (Photokinetics) — newly working as of this build. You should acquire a
  worn "photon regulation" item you can't take off, which should let you look at the sun
  without pain and **weld without goggles**. Please confirm both.
- **Lifting Field** — confirmed working: the `[Ψ]lifting field` aura appears, raises your
  carrying capacity, and is taken back when you stop concentrating. See
  [Fork changes](#fork-changes-deliberate-differences-from-dda) for how it differs from DDA.
  What's still worth an opinion: **does the trade feel worth the stamina and the concentration
  slot?** Note the capacity gain can read larger than the number in the item description —
  worn gear with a carry-weight modifier multiplies the bonus, which is normal BN behavior.

Also worth knowing: the mod emits some harmless load-time warnings, and occasional
`Bad intensity` messages in the log are cosmetic.

## Reporting bugs

Open an **Issue** and include:

1. What you did and what you expected.
2. **Which mod version** you're on — shown next to the mod in the in-game mod list, and in
   `modinfo.json`. Releases are dated, e.g. `2026.8.1`.
3. Your BN version (main menu shows the build date).
4. **`config/debug.log`** — attach it. This matters more than anything else; the Lua
   runtime logs there.
5. A screenshot if it's visual.

If a power silently does nothing, say so explicitly — "no message, no effect" is a
distinct and useful bug report.

---

## Architecture (for the curious)

BN is missing engine features MoM was built on, so the port bridges them:

- **Marker bridge** — BN has no EOC spell effect. EOC-backed spells apply a 1-turn marker
  effect that a Lua hook catches and dispatches to transpiled EOC code.
- **Carrier traits** — BN `effect_type`s can't hold enchantments, so effects that grant
  stat changes are moved onto hidden per-level mutations, granted to match spell level.
- **Math transpile** — MoM's `math` expressions are fitted onto BN's native
  base/increment/final triples; nonlinear formulas fall back to Lua at cast time.
- **Vitamins designed out** — Nether Attunement rides on an effect's intensity instead.

The generator pipeline that produces this mod from DDA source is not published here.

## Credits

- **Standing-Storm** — original Mind Over Matter mod, and all of its design, content, and prose.
- **CleverRaven** and DDA contributors — Cataclysm: Dark Days Ahead.
- **Cataclysm: Bright Nights** contributors — the target game and its Lua API.
- **Mike Cantrell** — this BN port and the fork changes above.

## License

**CC BY-SA 3.0**, inherited from upstream Cataclysm: DDA. See [LICENSE](LICENSE).
