# Psionic Discipline Atlas

Power-acquisition trees for the eight psionic schools in **Mind Over Matter (BN)**.
Vitakinesis merged into Biokinesis 2026-08-07 (see `HANDOFF.md`'s changelog) — there
were nine schools before that.

## How powers unlock

Powers are not bought — they surface. Once you meet a power's prerequisite spell-levels and log enough practice time (paced by Intelligence and Metaphysics), an insight arrives and the power is learned outright. No dice, no recipe grind.

Reading the trees:

| Notation | Meaning |
|---|---|
| solid arrow | required prerequisite |
| dashed arrow | alternate route — any one of the converging paths opens the power |
| `L7` on an arrow | minimum level of that prerequisite |
| filled node | foundation — known from the moment you take up the school |
| outlined node | trained via prerequisites |
| thick-bordered node | advanced / capstone |
| `(C)` in a name | concentration power, maintained while held |
| ◆ after a name | fork power — behaves differently from its DDA counterpart |

## Disciplines

- [Biokinesis](#biokinesis) — 20 powers
- [Telekinesis](#telekinesis) — 18 powers
- [Pyrokinesis](#pyrokinesis) — 15 powers
- [Electrokinesis](#electrokinesis) — 16 powers
- [Photokinesis](#photokinesis) — 20 powers
- [Clairsentience](#clairsentience) — 18 powers
- [Telepathy](#telepathy) — 14 powers
- [Teleportation](#teleportation) — 20 powers

---

## Biokinesis

*Turn the body into an instrument — reflexes, resilience, reshaped flesh, and
(since the Vitakinesis merge) the body's own repair.*

**20** powers · **5** known at start · **15** trainable

**Foundations:** Healthy Glow (C) · Overcome Pain (C) · Personal Enhancement (C) ·
Radiation Decontamination · Staunch Wound

```mermaid
graph TD
  n_biokin_adrenaline["Adrenaline Trigger"]:::power
  n_biokin_armor_skin["Hardened Skin (C)"]:::power
  n_biokin_breathe_skin["Oxygen Absorption (C)"]:::power
  n_biokin_climate_control["Temperature Adaptability (C)"]:::power
  n_biokin_combat_dance["Combat Dance (C)"]:::apex
  n_biokin_dash["Burst of Speed"]:::power
  n_biokin_enhance_mobility["Enhance Mobility (C)"]:::power
  n_biokin_hammerhand["Hammerhand (C)"]:::power
  n_biokin_hurricane_blows["Hurricane Blows"]:::apex
  n_biokin_metabolism_enhance["Metabolic Hyperefficiency (C)"]:::power
  n_biokin_overcome_pain["Overcome Pain (C)"]:::start
  n_biokin_perfected_motion["Perfected Motion (C)"]:::apex
  n_biokin_physical_enhance["Personal Enhancement (C)"]:::start
  n_biokin_reflex_enhance["Heightened Reflexes (C)"]:::power
  n_biokin_sealed_system["Sealed System"]:::power
  n_vita_health_power["Healthy Glow (C)"]:::start
  n_vita_purge_rads["Radiation Decontamination"]:::start
  n_vita_remove_poison["Detoxification"]:::power
  n_vita_stop_bleeding["Staunch Wound"]:::start
  n_vita_super_heal["Anabolic Rejuvenation (C)"]:::apex
  n_biokin_dash -.->|L8| n_biokin_adrenaline
  n_biokin_breathe_skin -.->|L5| n_biokin_adrenaline
  n_biokin_enhance_mobility -.->|L6| n_biokin_adrenaline
  n_biokin_physical_enhance -.->|L8| n_biokin_armor_skin
  n_vita_remove_poison -.->|L7| n_biokin_armor_skin
  n_biokin_climate_control -.->|L6| n_biokin_armor_skin
  n_biokin_overcome_pain -.->|L6| n_biokin_armor_skin
  n_biokin_physical_enhance -->|L4| n_biokin_breathe_skin
  n_biokin_overcome_pain -->|L3| n_biokin_breathe_skin
  n_biokin_physical_enhance -.->|L9| n_biokin_climate_control
  n_biokin_overcome_pain -.->|L5| n_biokin_climate_control
  n_biokin_metabolism_enhance -.->|L6| n_biokin_climate_control
  n_biokin_physical_enhance -.->|L10| n_biokin_combat_dance
  n_biokin_reflex_enhance -.->|L10| n_biokin_combat_dance
  n_biokin_dash -.->|L6| n_biokin_combat_dance
  n_biokin_adrenaline -.->|L9| n_biokin_combat_dance
  n_biokin_enhance_mobility -.->|L6| n_biokin_dash
  n_biokin_reflex_enhance -.->|L5| n_biokin_dash
  n_biokin_adrenaline -.->|L8| n_biokin_dash
  n_biokin_physical_enhance -.->|L5| n_biokin_dash
  n_biokin_dash -.->|L10| n_biokin_enhance_mobility
  n_biokin_reflex_enhance -.->|L6| n_biokin_enhance_mobility
  n_biokin_overcome_pain -.->|L4| n_biokin_enhance_mobility
  n_vita_remove_poison -.->|L9| n_biokin_enhance_mobility
  n_biokin_combat_dance -.->|L4| n_biokin_enhance_mobility
  n_biokin_physical_enhance -.->|L10| n_biokin_enhance_mobility
  n_biokin_physical_enhance -->|L6| n_biokin_hammerhand
  n_biokin_armor_skin -->|L6| n_biokin_hammerhand
  n_biokin_combat_dance -.->|L10| n_biokin_hurricane_blows
  n_biokin_reflex_enhance -.->|L14| n_biokin_hurricane_blows
  n_biokin_adrenaline -.->|L12| n_biokin_hurricane_blows
  n_biokin_climate_control -.->|L8| n_biokin_metabolism_enhance
  n_biokin_adrenaline -.->|L6| n_biokin_metabolism_enhance
  n_biokin_physical_enhance -.->|L12| n_biokin_metabolism_enhance
  n_biokin_combat_dance -->|L6| n_biokin_perfected_motion
  n_biokin_dash -->|L12| n_biokin_perfected_motion
  n_biokin_physical_enhance -.->|L6| n_biokin_reflex_enhance
  n_biokin_adrenaline -.->|L8| n_biokin_reflex_enhance
  n_biokin_dash -.->|L8| n_biokin_reflex_enhance
  n_vita_remove_poison -.->|L8| n_biokin_reflex_enhance
  n_biokin_breathe_skin -.->|L9| n_biokin_sealed_system
  n_biokin_hammerhand -.->|L7| n_biokin_sealed_system
  n_biokin_climate_control -.->|L10| n_biokin_sealed_system
  n_biokin_armor_skin -.->|L9| n_biokin_sealed_system
  n_biokin_physical_enhance -->|L6| n_vita_remove_poison
  n_biokin_metabolism_enhance -->|L8| n_vita_super_heal
  n_biokin_adrenaline -->|L6| n_vita_super_heal
  classDef start fill:#c0495a,stroke:#82313d,color:#ffffff,stroke-width:1.5px,font-weight:600;
  classDef power fill:#ffffff,stroke:#c0495a,color:#22242b,stroke-width:1.4px;
  classDef apex fill:#eecfd4,stroke:#c0495a,color:#692831,stroke-width:3px,font-weight:700;
```

---

## Telekinesis

*Move matter by will alone: shove, crush, shield, and take to the air.*

**18** powers · **3** known at start · **15** trainable

**Foundations:** Far Hand · Force Shove · No Go Zone (C)

```mermaid
graph TD
  n_telekinetic_aegis["Aegis"]:::apex
  n_telekinetic_earthshaker["Earthshaker"]:::apex
  n_telekinetic_explosion["Wrecking Ball"]:::power
  n_telekinetic_hammer["Mindhammer"]:::power
  n_telekinetic_levitation["Levitation (C)"]:::power
  n_telekinetic_lifting_field["Lifting Field (C)"]:::power
  n_telekinetic_momentum["Momentum Alteration (C)"]:::power
  n_telekinetic_move_large_weight["Megakinesis"]:::apex
  n_telekinetic_nogozone["No Go Zone (C)"]:::start
  n_telekinetic_noise["Noisemaker"]:::power
  n_telekinetic_pull["Far Hand"]:::start
  n_telekinetic_push["Force Shove"]:::start
  n_telekinetic_shield["Inertial Barrier (C)"]:::power
  n_telekinetic_slam_down["Knockdown"]:::power
  n_telekinetic_slowfall["Slowfall"]:::power
  n_telekinetic_strength["Enhance Strength (C)"]:::power
  n_telekinetic_vehicle_lift["Lift Vehicle (C)"]:::power
  n_telekinetic_wave["Wave of Force"]:::power
  n_telekinetic_shield -->|L7| n_telekinetic_aegis
  n_telekinetic_slowfall -.->|L9| n_telekinetic_aegis
  n_telekinetic_wave -.->|L8| n_telekinetic_aegis
  n_telekinetic_strength -.->|L8| n_telekinetic_aegis
  n_telekinetic_momentum -.->|L12| n_telekinetic_aegis
  n_telekinetic_explosion -.->|L8| n_telekinetic_earthshaker
  n_telekinetic_hammer -.->|L9| n_telekinetic_earthshaker
  n_telekinetic_wave -.->|L13| n_telekinetic_earthshaker
  n_telekinetic_move_large_weight -.->|L5| n_telekinetic_earthshaker
  n_telekinetic_push -.->|L10| n_telekinetic_explosion
  n_telekinetic_slam_down -.->|L12| n_telekinetic_explosion
  n_telekinetic_hammer -.->|L7| n_telekinetic_explosion
  n_telekinetic_pull -.->|L10| n_telekinetic_explosion
  n_telekinetic_push -.->|L8| n_telekinetic_hammer
  n_telekinetic_slam_down -->|L6| n_telekinetic_hammer
  n_telekinetic_wave -.->|L4| n_telekinetic_hammer
  n_telekinetic_slowfall -->|L9| n_telekinetic_levitation
  n_telekinetic_push -.->|L12| n_telekinetic_levitation
  n_telekinetic_pull -.->|L7| n_telekinetic_lifting_field
  n_telekinetic_vehicle_lift -.->|L3| n_telekinetic_lifting_field
  n_telekinetic_momentum -.->|L5| n_telekinetic_lifting_field
  n_telekinetic_pull -->|L5| n_telekinetic_momentum
  n_telekinetic_push -->|L5| n_telekinetic_momentum
  n_telekinetic_push -.->|L15| n_telekinetic_move_large_weight
  n_telekinetic_pull -.->|L15| n_telekinetic_move_large_weight
  n_telekinetic_vehicle_lift -.->|L6| n_telekinetic_move_large_weight
  n_telekinetic_momentum -.->|L10| n_telekinetic_move_large_weight
  n_telekinetic_momentum -->|L10| n_telekinetic_shield
  n_telekinetic_wave -->|L8| n_telekinetic_shield
  n_telekinetic_noise -.->|L1| n_telekinetic_slam_down
  n_telekinetic_push -.->|L4| n_telekinetic_slam_down
  n_telekinetic_momentum -->|L6| n_telekinetic_slowfall
  n_telekinetic_pull -.->|L6| n_telekinetic_strength
  n_telekinetic_push -.->|L6| n_telekinetic_strength
  n_telekinetic_momentum -->|L5| n_telekinetic_strength
  n_telekinetic_slowfall -.->|L8| n_telekinetic_vehicle_lift
  n_telekinetic_pull -.->|L8| n_telekinetic_vehicle_lift
  n_telekinetic_strength -.->|L10| n_telekinetic_vehicle_lift
  n_telekinetic_push -->|L7| n_telekinetic_wave
  n_telekinetic_slam_down -->|L4| n_telekinetic_wave
  classDef start fill:#7a80cf,stroke:#52578c,color:#ffffff,stroke-width:1.5px,font-weight:600;
  classDef power fill:#ffffff,stroke:#7a80cf,color:#22242b,stroke-width:1.4px;
  classDef apex fill:#dcddf2,stroke:#7a80cf,color:#434671,stroke-width:3px,font-weight:700;
```

---

## Pyrokinesis

*Kindle and command heat — from a warming cloak to lava underfoot and foes boiled from within.*

**15** powers · **2** known at start · **13** trainable

**Foundations:** Brilliant Flash · Intensify Flames

```mermaid
graph TD
  n_pyrokinetic_aoe_blast["Mass Hydrothermosis ◆"]:::apex
  n_pyrokinetic_aura["Blazing Aura (C)"]:::power
  n_pyrokinetic_blast["Conflagration"]:::power
  n_pyrokinetic_call_flames["Banked Flames (C)"]:::power
  n_pyrokinetic_cauterize["Cauterize"]:::power
  n_pyrokinetic_cloak["Cloak of Warmth (C)"]:::power
  n_pyrokinetic_eruption["Molten Land ◆"]:::power
  n_pyrokinetic_flame_immunity["Flameshield (C)"]:::power
  n_pyrokinetic_flamethrower["Flamethrower"]:::power
  n_pyrokinetic_flash["Brilliant Flash"]:::start
  n_pyrokinetic_incineration["Crucible"]:::apex
  n_pyrokinetic_intensify_flames["Intensify Flames"]:::start
  n_pyrokinetic_lance["Incandescent Lance (C)"]:::power
  n_pyrokinetic_quell_flames["Quell Fire"]:::power
  n_pyrokinetic_thermogenesis["Thermogenesis"]:::power
  n_pyrokinetic_flame_immunity -.->|L6| n_pyrokinetic_aoe_blast
  n_pyrokinetic_thermogenesis -.->|L10| n_pyrokinetic_aoe_blast
  n_pyrokinetic_flamethrower -.->|L12| n_pyrokinetic_aoe_blast
  n_pyrokinetic_blast -.->|L6| n_pyrokinetic_aoe_blast
  n_pyrokinetic_thermogenesis -.->|L5| n_pyrokinetic_aura
  n_pyrokinetic_flamethrower -.->|L6| n_pyrokinetic_aura
  n_pyrokinetic_eruption -->|L7| n_pyrokinetic_aura
  n_pyrokinetic_cloak -->|L8| n_pyrokinetic_aura
  n_pyrokinetic_aura -.->|L6| n_pyrokinetic_blast
  n_pyrokinetic_thermogenesis -.->|L6| n_pyrokinetic_blast
  n_pyrokinetic_flamethrower -.->|L8| n_pyrokinetic_blast
  n_pyrokinetic_eruption -.->|L13| n_pyrokinetic_blast
  n_pyrokinetic_eruption -->|L4| n_pyrokinetic_call_flames
  n_pyrokinetic_lance -.->|L5| n_pyrokinetic_cauterize
  n_pyrokinetic_eruption -.->|L6| n_pyrokinetic_cauterize
  n_pyrokinetic_quell_flames -.->|L6| n_pyrokinetic_cauterize
  n_pyrokinetic_eruption -.->|L6| n_pyrokinetic_cloak
  n_pyrokinetic_call_flames -.->|L6| n_pyrokinetic_cloak
  n_pyrokinetic_intensify_flames -->|L5| n_pyrokinetic_eruption
  n_pyrokinetic_quell_flames -->|L9| n_pyrokinetic_flame_immunity
  n_pyrokinetic_aura -.->|L6| n_pyrokinetic_flame_immunity
  n_pyrokinetic_cloak -.->|L10| n_pyrokinetic_flame_immunity
  n_pyrokinetic_flash -->|L5| n_pyrokinetic_flamethrower
  n_pyrokinetic_call_flames -->|L7| n_pyrokinetic_flamethrower
  n_pyrokinetic_flamethrower -.->|L10| n_pyrokinetic_incineration
  n_pyrokinetic_blast -->|L10| n_pyrokinetic_incineration
  n_pyrokinetic_eruption -.->|L14| n_pyrokinetic_incineration
  n_pyrokinetic_aoe_blast -->|L6| n_pyrokinetic_incineration
  n_pyrokinetic_eruption -.->|L9| n_pyrokinetic_lance
  n_pyrokinetic_call_flames -.->|L6| n_pyrokinetic_lance
  n_pyrokinetic_quell_flames -.->|L6| n_pyrokinetic_lance
  n_pyrokinetic_call_flames -->|L5| n_pyrokinetic_quell_flames
  n_pyrokinetic_intensify_flames -->|L6| n_pyrokinetic_quell_flames
  n_pyrokinetic_call_flames -.->|L10| n_pyrokinetic_thermogenesis
  n_pyrokinetic_flash -.->|L7| n_pyrokinetic_thermogenesis
  n_pyrokinetic_intensify_flames -.->|L8| n_pyrokinetic_thermogenesis
  n_pyrokinetic_cloak -.->|L6| n_pyrokinetic_thermogenesis
  classDef start fill:#e05f34,stroke:#984023,color:#ffffff,stroke-width:1.5px,font-weight:600;
  classDef power fill:#ffffff,stroke:#e05f34,color:#22242b,stroke-width:1.4px;
  classDef apex fill:#f6d5ca,stroke:#e05f34,color:#7b341c,stroke-width:3px,font-weight:700;
```

---

## Electrokinesis

*Command current: spark, arc, and read the hidden circuits of the world.*

**16** powers · **3** known at start · **13** trainable

**Foundations:** Circuit Sense (C) · Lightning Strike · Spark Sight (C)

```mermaid
graph TD
  n_electrokinetic_circuit_sense["Circuit Sense (C)"]:::start
  n_electrokinetic_hacking_interface["Hacking Interface (C)"]:::power
  n_electrokinetic_kill_robot["Short Circuit"]:::power
  n_electrokinetic_lightning_aura["Galvanic Aura (C)"]:::apex
  n_electrokinetic_lightning_blast["Ion Blast"]:::apex
  n_electrokinetic_lightning_bolt["Electrocutioner"]:::power
  n_electrokinetic_lightning_strike["Lightning Strike"]:::start
  n_electrokinetic_pain_immune["Analgesic Block"]:::power
  n_electrokinetic_paralysis["Neural Spasms"]:::power
  n_electrokinetic_personal_battery["Electron Overflow (C)"]:::power
  n_electrokinetic_reduce_pain["Pain Suppression (C)"]:::power
  n_electrokinetic_revive["Revivification"]:::apex
  n_electrokinetic_robot_interface["Robotic Interface"]:::apex
  n_electrokinetic_see_electric["Spark Sight (C)"]:::start
  n_electrokinetic_speed_boost["Neuro-acceleration"]:::power
  n_electrokinetic_zap_enemies["Electrical Discharge (C)"]:::power
  n_electrokinetic_personal_battery -->|L4| n_electrokinetic_hacking_interface
  n_electrokinetic_see_electric -->|L4| n_electrokinetic_hacking_interface
  n_electrokinetic_lightning_bolt -.->|L8| n_electrokinetic_kill_robot
  n_electrokinetic_see_electric -->|L8| n_electrokinetic_kill_robot
  n_electrokinetic_personal_battery -.->|L15| n_electrokinetic_lightning_aura
  n_electrokinetic_zap_enemies -->|L12| n_electrokinetic_lightning_aura
  n_electrokinetic_kill_robot -.->|L6| n_electrokinetic_lightning_blast
  n_electrokinetic_lightning_bolt -.->|L10| n_electrokinetic_lightning_blast
  n_electrokinetic_zap_enemies -->|L8| n_electrokinetic_lightning_bolt
  n_electrokinetic_reduce_pain -->|L9| n_electrokinetic_pain_immune
  n_electrokinetic_see_electric -->|L6| n_electrokinetic_paralysis
  n_electrokinetic_see_electric -->|L5| n_electrokinetic_personal_battery
  n_electrokinetic_zap_enemies -->|L8| n_electrokinetic_personal_battery
  n_electrokinetic_paralysis -.->|L4| n_electrokinetic_reduce_pain
  n_electrokinetic_see_electric -.->|L8| n_electrokinetic_reduce_pain
  n_electrokinetic_zap_enemies -.->|L8| n_electrokinetic_reduce_pain
  n_electrokinetic_reduce_pain -.->|L13| n_electrokinetic_revive
  n_electrokinetic_pain_immune -.->|L6| n_electrokinetic_revive
  n_electrokinetic_speed_boost -->|L8| n_electrokinetic_revive
  n_electrokinetic_hacking_interface -->|L8| n_electrokinetic_robot_interface
  n_electrokinetic_kill_robot -->|L8| n_electrokinetic_robot_interface
  n_electrokinetic_see_electric -->|L12| n_electrokinetic_robot_interface
  n_electrokinetic_paralysis -.->|L6| n_electrokinetic_speed_boost
  n_electrokinetic_personal_battery -.->|L11| n_electrokinetic_speed_boost
  n_electrokinetic_see_electric -.->|L5| n_electrokinetic_speed_boost
  n_electrokinetic_zap_enemies -.->|L8| n_electrokinetic_speed_boost
  classDef start fill:#4a83e0,stroke:#325998,color:#ffffff,stroke-width:1.5px,font-weight:600;
  classDef power fill:#ffffff,stroke:#4a83e0,color:#22242b,stroke-width:1.4px;
  classDef apex fill:#cfdef6,stroke:#4a83e0,color:#28487b,stroke-width:3px,font-weight:700;
```

---

## Photokinesis

*Bend light itself — blinding, cloaking, and conjured luminous constructs.*

**20** powers · **2** known at start · **18** trainable

**Foundations:** Candle's Glow (C) · Field of Light

```mermaid
graph TD
  n_photokinetic_blinding_glare["Blinding Radiance (C)"]:::power
  n_photokinetic_camouflage["Chameleoflage (C)"]:::power
  n_photokinetic_create_light["Field of Light"]:::start
  n_photokinetic_flash_bang["Flashbang"]:::power
  n_photokinetic_hide_ugly["Mirror-Mask (C)"]:::power
  n_photokinetic_invisibility["Veil of Light (C)"]:::power
  n_photokinetic_light_arms["Refracted Arms"]:::power
  n_photokinetic_light_army["Phantom Legion (C)"]:::apex
  n_photokinetic_light_beam["Photon Beam"]:::power
  n_photokinetic_light_disintegrate["Luminous Disintegration"]:::apex
  n_photokinetic_light_dodge["Trick of the Light (C)"]:::power
  n_photokinetic_light_flash["Star Flash"]:::power
  n_photokinetic_light_image["Lucid Shadows"]:::power
  n_photokinetic_light_local["Candle's Glow (C)"]:::start
  n_photokinetic_light_up_enemy["Illuminate"]:::power
  n_photokinetic_rad_immunity["Lucent Barrier (C)"]:::power
  n_photokinetic_radio["Radio Transception (C)"]:::power
  n_photokinetic_snuff_light["Blackout"]:::power
  n_photokinetic_sterilize_food["Gamma Sterilization"]:::power
  n_photokinetic_stun_robots["Sensor Jamming"]:::power
  n_photokinetic_light_flash -.->|L6| n_photokinetic_blinding_glare
  n_photokinetic_flash_bang -.->|L7| n_photokinetic_blinding_glare
  n_photokinetic_rad_immunity -.->|L10| n_photokinetic_blinding_glare
  n_photokinetic_create_light -.->|L12| n_photokinetic_blinding_glare
  n_photokinetic_light_dodge -->|L6| n_photokinetic_camouflage
  n_photokinetic_create_light -.->|L9| n_photokinetic_flash_bang
  n_photokinetic_light_beam -.->|L5| n_photokinetic_flash_bang
  n_photokinetic_light_up_enemy -->|L6| n_photokinetic_flash_bang
  n_photokinetic_camouflage -->|L8| n_photokinetic_hide_ugly
  n_photokinetic_rad_immunity -->|L5| n_photokinetic_hide_ugly
  n_photokinetic_light_image -.->|L6| n_photokinetic_invisibility
  n_photokinetic_camouflage -.->|L10| n_photokinetic_invisibility
  n_photokinetic_hide_ugly -.->|L6| n_photokinetic_invisibility
  n_photokinetic_rad_immunity -.->|L6| n_photokinetic_invisibility
  n_photokinetic_camouflage -->|L6| n_photokinetic_light_arms
  n_photokinetic_light_local -->|L6| n_photokinetic_light_arms
  n_photokinetic_light_dodge -->|L8| n_photokinetic_light_arms
  n_photokinetic_light_image -->|L10| n_photokinetic_light_army
  n_photokinetic_blinding_glare -.->|L6| n_photokinetic_light_army
  n_photokinetic_light_arms -.->|L10| n_photokinetic_light_army
  n_photokinetic_create_light -.->|L14| n_photokinetic_light_army
  n_photokinetic_light_local -.->|L8| n_photokinetic_light_beam
  n_photokinetic_create_light -.->|L6| n_photokinetic_light_beam
  n_photokinetic_light_flash -.->|L8| n_photokinetic_light_disintegrate
  n_photokinetic_blinding_glare -->|L5| n_photokinetic_light_disintegrate
  n_photokinetic_light_beam -.->|L14| n_photokinetic_light_disintegrate
  n_photokinetic_snuff_light -->|L5| n_photokinetic_light_dodge
  n_photokinetic_create_light -->|L5| n_photokinetic_light_dodge
  n_photokinetic_light_arms -.->|L6| n_photokinetic_light_flash
  n_photokinetic_rad_immunity -.->|L6| n_photokinetic_light_flash
  n_photokinetic_light_beam -->|L8| n_photokinetic_light_flash
  n_photokinetic_light_arms -.->|L6| n_photokinetic_light_image
  n_photokinetic_camouflage -.->|L6| n_photokinetic_light_image
  n_photokinetic_light_beam -->|L6| n_photokinetic_light_image
  n_photokinetic_snuff_light -.->|L6| n_photokinetic_rad_immunity
  n_photokinetic_camouflage -.->|L5| n_photokinetic_rad_immunity
  n_photokinetic_light_dodge -.->|L9| n_photokinetic_rad_immunity
  n_photokinetic_create_light -.->|L8| n_photokinetic_radio
  n_photokinetic_rad_immunity -->|L6| n_photokinetic_radio
  n_photokinetic_light_beam -.->|L7| n_photokinetic_radio
  n_photokinetic_light_local -.->|L5| n_photokinetic_snuff_light
  n_photokinetic_create_light -.->|L4| n_photokinetic_snuff_light
  n_photokinetic_light_flash -.->|L3| n_photokinetic_sterilize_food
  n_photokinetic_camouflage -->|L4| n_photokinetic_sterilize_food
  n_photokinetic_rad_immunity -->|L7| n_photokinetic_sterilize_food
  n_photokinetic_light_up_enemy -.->|L9| n_photokinetic_sterilize_food
  n_photokinetic_light_beam -.->|L5| n_photokinetic_sterilize_food
  n_photokinetic_light_flash -.->|L5| n_photokinetic_stun_robots
  n_photokinetic_radio -.->|L6| n_photokinetic_stun_robots
  n_photokinetic_light_beam -.->|L4| n_photokinetic_stun_robots
  classDef start fill:#c99327,stroke:#88631a,color:#ffffff,stroke-width:1.5px,font-weight:600;
  classDef power fill:#ffffff,stroke:#c99327,color:#22242b,stroke-width:1.4px;
  classDef apex fill:#f0e2c6,stroke:#c99327,color:#6e5015,stroke-width:3px,font-weight:700;
```

---

## Clairsentience

*Perception unbound from the eyes: the unseen, the distant, the yet-to-come.*

**18** powers · **4** known at start · **14** trainable

**Foundations:** Heightened Senses (C) · Radiation Sense · See Mechanisms · Speed Reader (C)

```mermaid
graph TD
  n_clair_better_senses["Heightened Senses (C)"]:::start
  n_clair_clear_sight["Clarity (C)"]:::apex
  n_clair_craft_bonus["Intuitive Artisan (C)"]:::power
  n_clair_danger_sense["Premonition (C)"]:::power
  n_clair_dodge_power["Combat Sense (C)"]:::power
  n_clair_examine_item["Psychometry"]:::power
  n_clair_group_tactics["Prescient Tactician (C)"]:::apex
  n_clair_night_vision["Night Eyes (C)"]:::power
  n_clair_omniscience["Omniscence"]:::apex
  n_clair_perfect_shot["One Perfect Shot"]:::power
  n_clair_ranged_enhance["Marksman's Eye (C)"]:::power
  n_clair_see_auras["Aura Sight (C)"]:::power
  n_clair_see_map["Satellite View"]:::power
  n_clair_see_mechanisms["See Mechanisms"]:::start
  n_clair_sense_hostile_creatures["Sense Hostility (C)"]:::power
  n_clair_sense_rads["Radiation Sense"]:::start
  n_clair_speed_reading["Speed Reader (C)"]:::start
  n_clair_voyance["Clairvoyance"]:::power
  n_clair_dodge_power -.->|L5| n_clair_clear_sight
  n_clair_night_vision -->|L10| n_clair_clear_sight
  n_clair_speed_reading -.->|L8| n_clair_clear_sight
  n_clair_danger_sense -->|L6| n_clair_craft_bonus
  n_clair_speed_reading -->|L8| n_clair_craft_bonus
  n_clair_better_senses -->|L6| n_clair_danger_sense
  n_clair_voyance -->|L6| n_clair_dodge_power
  n_clair_danger_sense -.->|L10| n_clair_dodge_power
  n_clair_sense_hostile_creatures -.->|L10| n_clair_dodge_power
  n_clair_speed_reading -.->|L10| n_clair_dodge_power
  n_clair_danger_sense -.->|L8| n_clair_examine_item
  n_clair_see_auras -.->|L6| n_clair_examine_item
  n_clair_speed_reading -.->|L8| n_clair_examine_item
  n_clair_dodge_power -->|L8| n_clair_group_tactics
  n_clair_ranged_enhance -->|L7| n_clair_group_tactics
  n_clair_clear_sight -->|L5| n_clair_group_tactics
  n_clair_better_senses -->|L8| n_clair_night_vision
  n_clair_voyance -.->|L14| n_clair_omniscience
  n_clair_see_map -.->|L8| n_clair_omniscience
  n_clair_clear_sight -->|L5| n_clair_omniscience
  n_clair_ranged_enhance -->|L9| n_clair_perfect_shot
  n_clair_better_senses -->|L5| n_clair_see_auras
  n_clair_voyance -->|L8| n_clair_see_map
  n_clair_danger_sense -.->|L6| n_clair_see_map
  n_clair_danger_sense -->|L6| n_clair_sense_hostile_creatures
  n_clair_better_senses -->|L8| n_clair_sense_hostile_creatures
  n_clair_danger_sense -->|L6| n_clair_voyance
  n_clair_night_vision -.->|L10| n_clair_voyance
  classDef start fill:#2f9aa8,stroke:#1f6872,color:#ffffff,stroke-width:1.5px,font-weight:600;
  classDef power fill:#ffffff,stroke:#2f9aa8,color:#22242b,stroke-width:1.4px;
  classDef apex fill:#c8e4e8,stroke:#2f9aa8,color:#19545c,stroke-width:3px,font-weight:700;
```

---

## Telepathy

*Reach into other minds — to read, soothe, deceive, or shatter them.*

**14** powers · **2** known at start · **12** trainable

**Foundations:** Concentration Trance (C) · Mind Sonar (C)

```mermaid
graph TD
  n_telepathic_animal_mind_control["Beastmaster"]:::power
  n_telepathic_beast_taming["Beast Tamer"]:::power
  n_telepathic_blast["Synaptic Overload"]:::power
  n_telepathic_blast_radius["Psychic Scream"]:::power
  n_telepathic_concentration["Concentration Trance (C)"]:::start
  n_telepathic_confusion["Sensory Deprivation"]:::power
  n_telepathic_fear["Primal Terror"]:::power
  n_telepathic_invisibility["Obscurity"]:::power
  n_telepathic_mesmerize["Mesmerize"]:::power
  n_telepathic_mind_control["Mind Control"]:::apex
  n_telepathic_mind_sense["Mind Sonar (C) ◆"]:::start
  n_telepathic_morale["Mood Stabilization (C)"]:::power
  n_telepathic_network["Network Effect"]:::apex
  n_telepathic_shield["Telepathic Shield (C)"]:::power
  n_telepathic_morale -->|L8| n_telepathic_animal_mind_control
  n_telepathic_animal_mind_control -->|L10| n_telepathic_beast_taming
  n_telepathic_morale -->|L4| n_telepathic_blast
  n_telepathic_mind_sense -->|L7| n_telepathic_blast
  n_telepathic_blast -.->|L11| n_telepathic_blast_radius
  n_telepathic_fear -.->|L7| n_telepathic_blast_radius
  n_telepathic_shield -->|L5| n_telepathic_blast_radius
  n_telepathic_morale -->|L4| n_telepathic_confusion
  n_telepathic_blast -.->|L6| n_telepathic_confusion
  n_telepathic_morale -->|L8| n_telepathic_fear
  n_telepathic_blast -->|L8| n_telepathic_fear
  n_telepathic_confusion -->|L8| n_telepathic_invisibility
  n_telepathic_morale -.->|L6| n_telepathic_invisibility
  n_telepathic_blast -.->|L11| n_telepathic_invisibility
  n_telepathic_shield -.->|L8| n_telepathic_invisibility
  n_telepathic_mind_sense -->|L6| n_telepathic_mesmerize
  n_telepathic_animal_mind_control -.->|L8| n_telepathic_mind_control
  n_telepathic_confusion -.->|L7| n_telepathic_mind_control
  n_telepathic_morale -.->|L12| n_telepathic_mind_control
  n_telepathic_invisibility -.->|L6| n_telepathic_mind_control
  n_telepathic_fear -.->|L5| n_telepathic_mind_control
  n_telepathic_mind_sense -->|L5| n_telepathic_morale
  n_telepathic_concentration -->|L6| n_telepathic_morale
  n_telepathic_mind_sense -->|L10| n_telepathic_network
  n_telepathic_blast_radius -->|L6| n_telepathic_network
  n_telepathic_morale -.->|L12| n_telepathic_network
  n_telepathic_invisibility -.->|L6| n_telepathic_network
  n_telepathic_concentration -->|L5| n_telepathic_shield
  classDef start fill:#a25fca,stroke:#6e4089,color:#ffffff,stroke-width:1.5px,font-weight:600;
  classDef power fill:#ffffff,stroke:#a25fca,color:#22242b,stroke-width:1.4px;
  classDef apex fill:#e6d5f1,stroke:#a25fca,color:#59346f,stroke-width:3px,font-weight:700;
```

---

## Teleportation

*Fold space to cross the battlefield — or drag others through the gap.*

**20** powers · **4** known at start · **16** trainable

**Foundations:** Blink · Farstep · Flickerflash Stance · Stutterstep

```mermaid
graph TD
  n_teleport_banish["Oubliette"]:::power
  n_teleport_blink["Blink"]:::start
  n_teleport_collapse["Spacial Vortex"]:::power
  n_teleport_dilated_gateway["Dilated Gateway"]:::apex
  n_teleport_displacement["Displacement"]:::power
  n_teleport_farstep["Farstep"]:::power
  n_teleport_farstep_real["Farstep"]:::start
  n_teleport_gateway["Gateway"]:::apex
  n_teleport_item_apport["Apportation"]:::power
  n_teleport_loci_establishment["Loci Establishment (C)"]:::power
  n_teleport_phase["Phase"]:::power
  n_teleport_reactive_displacement["Reactive Displacement (C)"]:::power
  n_teleport_reality_tear["Reality Tear"]:::apex
  n_teleport_relocation["Relocation"]:::power
  n_teleport_slow["Stutterstep"]:::start
  n_teleport_stride["Extended Stride (C)"]:::power
  n_teleport_summon["Breach"]:::apex
  n_teleport_transpose["Transposition"]:::power
  n_teleport_warped_strikes["Warped Strikes (C)"]:::power
  n_teleport_warper_combat["Flickerflash Stance"]:::start
  n_teleport_farstep -.->|L6| n_teleport_banish
  n_teleport_collapse -.->|L8| n_teleport_banish
  n_teleport_displacement -->|L10| n_teleport_banish
  n_teleport_transpose -.->|L8| n_teleport_banish
  n_teleport_slow -.->|L10| n_teleport_collapse
  n_teleport_transpose -.->|L6| n_teleport_collapse
  n_teleport_stride -->|L4| n_teleport_collapse
  n_teleport_banish -->|L2| n_teleport_dilated_gateway
  n_teleport_gateway -->|L8| n_teleport_dilated_gateway
  n_teleport_slow -->|L10| n_teleport_displacement
  n_teleport_item_apport -->|L5| n_teleport_displacement
  n_teleport_phase -->|L10| n_teleport_farstep
  n_teleport_collapse -.->|L6| n_teleport_farstep
  n_teleport_stride -.->|L8| n_teleport_farstep
  n_teleport_farstep -->|L10| n_teleport_gateway
  n_teleport_loci_establishment -->|L6| n_teleport_gateway
  n_teleport_slow -->|L4| n_teleport_item_apport
  n_teleport_blink -->|L4| n_teleport_item_apport
  n_teleport_farstep -->|L6| n_teleport_loci_establishment
  n_teleport_stride -->|L6| n_teleport_loci_establishment
  n_teleport_blink -->|L6| n_teleport_phase
  n_teleport_displacement -->|L5| n_teleport_reactive_displacement
  n_teleport_summon -->|L10| n_teleport_reality_tear
  n_teleport_gateway -->|L10| n_teleport_reality_tear
  n_teleport_gateway -->|L8| n_teleport_relocation
  n_teleport_item_apport -->|L6| n_teleport_relocation
  n_teleport_slow -->|L6| n_teleport_stride
  n_teleport_phase -->|L4| n_teleport_stride
  n_teleport_displacement -.->|L12| n_teleport_summon
  n_teleport_banish -.->|L7| n_teleport_summon
  n_teleport_gateway -->|L6| n_teleport_summon
  n_teleport_displacement -->|L5| n_teleport_transpose
  n_teleport_stride -->|L5| n_teleport_transpose
  n_teleport_stride -->|L10| n_teleport_warped_strikes
  n_teleport_item_apport -->|L6| n_teleport_warped_strikes
  classDef start fill:#cf5aa8,stroke:#8c3d72,color:#ffffff,stroke-width:1.5px,font-weight:600;
  classDef power fill:#ffffff,stroke:#cf5aa8,color:#22242b,stroke-width:1.4px;
  classDef apex fill:#f2d4e8,stroke:#cf5aa8,color:#71315c,stroke-width:3px,font-weight:700;
```

---

*Generated from the Psionic Discipline Atlas. Power names and prerequisites are derived from the mod's own `lua/gen_learn_map.lua` and `spells/*.json`, so this file tracks the shipped data rather than being maintained by hand.*
