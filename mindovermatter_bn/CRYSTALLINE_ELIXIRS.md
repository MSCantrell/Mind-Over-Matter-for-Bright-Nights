# Crystalline Elixirs

Eight "psionic performance drugs," one per school, brewed from refined matrix
crystal dust. Each is a `... crystalline elixir` (`matrix_crystal_<school>_dust_potion`)
— a plastic bottle of faintly glowing water, quench 50, drunk cold.

The item description tells you *nothing* about the effect (just the color/glow) —
this doc is the hidden truth.

**Fork change (2026-08-07):** the green Vitakinesis elixir is gone — Vitakinesis
merged into Biokinesis (see `HANDOFF.md`'s changelog), and its former healing
powers don't have a matching elixir of their own.

---

## How they work (shared mechanics)

**Brewing** — `recipes/chemistry.json`. Cooking skill (chemistry maps to cooking
in BN), difficulty 1, ~1 minute, from **1 refined matrix-crystal dust of that
school + 1 clean water**. Autolearn at cooking 5 / metaphysics 3, or from the
matrix-crystal schematic / survivor recipe books.

**Who benefits** — the consume EOC (`EOC_<SCHOOL>_POTION`) branches on whether you
can hold psi:

- **Non-psychic** (`CANNOT_GAIN_PSIONICS`): no benefit at all. You just get
  `effect_matrix_potion_headblind` for **6–15 h** — vomiting, pain, and failing
  health. Drinking raw concentrated nether crystal does nothing good for a
  mundane mind.
- **Psychic**: the **30-hour school buff** below, *plus* a hidden
  `effect_matrix_potion_nether_boost`.

**The catch — nether attunement (corruption).** While the hidden nether-boost is
active, a recurring tick (`mom_potion_nether_boost`, every 300 turns) adds
**+1–2 attunement** each pulse, which outpaces the normal −1 decay. In upstream
MoM this was a raw psionic-drain vitamin; the fork re-added it as a deliberate
cost so the elixirs aren't free power. Riding elixirs pushes you toward the
nether the whole time they're up.

**The comedown.** 12–30 h after drinking, `EOC_<SCHOOL>_POTION_COMEDOWN` fires and
swaps the buff for an aftereffect — stat/speed penalties and pain. Fork-shortened
to **4 h** (upstream ran up to 55 h; the hangover was lightened deliberately).
Re-drinking clears a pending comedown first, so you *can* chain them — at an
ever-climbing attunement price.

> **Flag legend:** `ARMOR_* -N` = reduces incoming damage of that type by N
> (negative = protection). `LUMINATION` = you emit light (a stealth tradeoff).

---

## The eight elixirs

### Pink — Biokinesis (`biokin`)
The bruiser. **STR +4, DEX +4, Speed +25**, immune to bleeding (`BLEED_IMMUNE`),
can't be knocked off your feet (`STEADY`), and **−6 bash / −4 cut / −3 stab**
armor. A flat-out combat stimulant.
- **Comedown:** STR −6, DEX −6, Speed −40, pain (partially offset by +4 bash armor).

### Gray — Clairsentience (`clair`)
The scout. **PER +4**, **clairvoyance (see through walls, range 8)**, hearing
×2.5, +1 dodge, sees while asleep (`SEESLEEP`), cracks safes by feel
(`SAFECRACK_NO_TOOL`), immune to hearing damage.
- **Comedown:** PER −6, pain, and blurred vision (both far- and near-sighted).

### Cyan — Electrokinesis (`electrokin`)
The live wire. **DEX +2**, immune to EMP, **−5 electric** armor. **Retaliation:**
anything that melees you takes **3–7 × nether electric damage + a brief daze**,
every hit (elec-immune foes shrug it off).
- **Comedown:** pain, twitching muscles.

### Golden — Photokinesis (`photokin`)
The infiltrator. **+25 stealth**, immune to glare/flash-blindness
(`GLARE_RESIST`), and slowly **purges radiation** (−1 rad on a 30%/60-turn tick).
Tradeoff: you **glow** faintly (`LUMINATION` 10) — the light can give you away in
the dark.
- **Comedown:** **−25 stealth** (you become *easier* to spot than baseline), pain.

### Red — Pyrokinesis (`pyrokin`)
The fire-walker. **Speed +10**, heat-immune (`HEATSINK`), bark-tough skin
(`BARKY`), and a massive **−50 heat** armor — near-total fire protection.
**Retaliation:** anything that melees you takes **5–20 × nether heat + catches
fire**, every hit.
- **Comedown:** cold-blooded (body temp tracks ambient), pain, and you **glow
  brightly** (`LUMINATION` 80) — no hiding.

### Yellow — Telekinesis (`telekin`)
The pack mule / brawler. **STR +2**, **carry weight ×1.25**, and instant recovery
from being knocked prone (`DOWNED_RECOVERY`).
- **Comedown:** STR −2, Speed −25, carry weight ×0.75, pain.

### White — Telepathy (`telepath`)
The warded mind. **+15 effective focus** (faster learning / better concentration)
and a **telepathic shield** (`TEEPSHIELD`) against mental attacks.
- **Comedown:** INT −4, effective focus −30, pain — a real cognitive crash.

### Blue — Teleportation (`teleport`)
The blink-fighter. **Feather fall** (no falling damage). **On offense:** every
blow **you** land warp-slows the enemy ("stutterstepping," `effect_teleport_slow`,
~20–30 turns).
- **Comedown:** Speed −15, pain.

---

## Quick reference

| Color | School | Headline benefit | Signature extra | Comedown sting |
|---|---|---|---|---|
| Pink | Biokinesis | STR/DEX +4, Speed +25 | phys. armor, no bleed/knockdown | STR/DEX −6, Speed −40 |
| Gray | Clairsentience | PER +4 | see-through-walls, ×2.5 hearing | PER −6, blurred vision |
| Cyan | Electrokinesis | DEX +2, EMP/elec resist | shock-back + daze on being hit | twitching, pain |
| Golden | Photokinesis | +25 stealth, glare immune | purges radiation (but you glow) | −25 stealth |
| Red | Pyrokinesis | Speed +10, −50 heat armor | burn-back + ignite on being hit | glow brightly, cold-blooded |
| Yellow | Telekinesis | STR +2, carry ×1.25 | instant up-from-prone | STR −2, Speed −25 |
| White | Telepathy | focus +15, mind shield | — | INT −4, focus −30 |
| Blue | Teleportation | feather fall | your hits warp-slow foes | Speed −15 |

*Every psychic drink also silently raises nether attunement for its full 30 h.*

---

*Sources: `items/comestibles.json` (items), `effects/gen_effects.json` +
`mutations/gen_carrier_traits.json` (buff/comedown mods & enchantments),
`lua/gen_eoc.lua` (`EOC_*_POTION` consume + comedown), `lua/mom_hooks.lua`
(`melee_auras` — the electro/pyro/teleport on-hit procs),
`lua/mom_eoc.lua` (`mom_potion_nether_boost` attunement tick),
`recipes/chemistry.json` (brewing). Generated data — see
`reference_mom_crystal_elixirs` for the port audit.*
