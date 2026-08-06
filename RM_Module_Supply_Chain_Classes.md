# RM Module Supply Chain Class Reference
## Version 0.3

---

## Purpose

This document defines the reaction_class vocabulary used across all
RM modules. Reaction classes are the semantic layer that DF's data
structures lack — they describe what a material IS, what has been
DONE to it, and what it CAN DO in industrial processes.

Vanilla DF nearly ignores this system. A handful of classes exist
(FLUX, CALCIUM_CARBONATE) and a few reaction_product codes
(FIRED_MAT, etc.). The module class system extends this vocabulary
to enable articulate supply chain interactions without hardcoded
material references between modules.

With such a system, interactions become possible that aren't possible
when materials can only be identified by their ID. Reaction classes
can describe physical properties, chemical composition, processing
history, and functional eligibility in ways that the raw data
structure cannot express. The key is that reaction classes are a
volume in which we can describe the properties of objects, both
general and specific. This is the foundation for a language of
industrial interaction.

---

## Rules

### Vanilla classes take precedence
If vanilla defines a class or reaction_product code for a concept,
we adopt it. We extend, never duplicate or replace. This ensures
backwards compatibility with vanilla content and forward
compatibility if vanilla ever expands its own class system.

Confirmed vanilla reaction classes:
- `CALCIUM_CARBONATE` — on limestone, marble, chalk, etc.
- `FLUX` — on limestone, marble, chalk, dolomite, etc.

Confirmed vanilla reaction_product codes:
- `FIRED_MAT` — on clays (kaolinite, fire clay)

We cannot add our classes to vanilla materials — they are not ours
to modify. We can only tag materials we create. Interaction with
vanilla materials uses their existing classes (FLUX,
CALCIUM_CARBONATE) or direct mat_id references with future engine
verification for missing asset protection.

### Prefix: REFINISH_
All module-originated classes use the prefix `REFINISH_` to
distinguish them from vanilla classes. This is the project name,
fully spelled out, collision-resistant, and concise enough for
practical use across hundreds of entries.

### Complete words after the prefix
No abbreviations or acronyms in the descriptive portion of the
class name. Each word is an element of identification.

`REFINISH_CALC_SRC` — wrong (abbreviations)
`REFINISH_CALCIUM_SOURCE` — correct
`REFINISH_THERMAL_PROC` — wrong (abbreviation)
`REFINISH_THERMALLY_PROCESSED` — correct

### Classes describe properties
A class says "this material IS" or "this material HAS BEEN."
Reactions decide what properties they need by filtering on classes.

### Build what we need when we need it
This vocabulary covers classes required by the three current
modules (Making Metal, Making Fuel, Making Concrete). New classes
are added when a concrete reaction or interaction requires them.
No speculative vocabulary.

---

## Economic Stone Behavior

DF classifies a stone as "economic" if it carries ANY reaction_class
or ANY material_reaction_product entry. This is important because
the `non_economic` reagent flag on a BOULDER_ANY reagent means
"accept ONLY non-economic stones" — it rejects anything DF considers
economic.

This means: once a module material carries a reaction_class from
this vocabulary, it automatically becomes economic. A BOULDER_ANY
reagent with `non_economic: true` will no longer grab it. This is
the clean solution to the wildcard capture problem — our processed
materials carry classes that describe them, and as a side effect,
those classes make them invisible to generic "any cheap stone"
wildcards. No hacks, no fake reaction_products, just accurate
classification producing correct behavior.

---

## Class Vocabulary

### PROCESSING STATE

These classes describe where a material sits in a processing chain.

| Class | Meaning |
|-------|---------|
| `REFINISH_RAW` | Unprocessed natural material, as-extracted or as-produced as primary output |
| `REFINISH_THERMALLY_PROCESSED` | Has been heated, fired, calcined, or smelted |
| `REFINISH_CHEMICALLY_PROCESSED` | Has undergone a chemical reaction (hydration, setting, slaking) |
| `REFINISH_MECHANICALLY_PROCESSED` | Has been ground, crushed, cut, or pressed |
| `REFINISH_BYPRODUCT` | Secondary output of another process, not the primary intended product |

A material can carry multiple processing state classes. Clinker is
both `REFINISH_THERMALLY_PROCESSED` (it was fired) and
`REFINISH_CHEMICALLY_PROCESSED` (calcium and silica reacted during
firing). The classes are independent true statements.

### FUNCTIONAL ROLE

These classes describe what a material can do in reactions. A reaction
filters on the role it needs. It doesn't care where the material
came from or which module produced it.

| Class | Meaning |
|-------|---------|
| `REFINISH_FUEL_FEEDSTOCK` | Can be processed into fuel (firing, charring, coking) |
| `REFINISH_CALCIUM_SOURCE` | Provides calcium for calcium-dependent reactions |
| `REFINISH_SILICA_SOURCE` | Provides silica for ceramic production |
| `REFINISH_BINDER` | Can bind other materials together (cement, mortar, adhesive) |

### MATERIAL IDENTITY

These classes describe what a material fundamentally is, independent
of processing or use. They enable cross-module recognition.

| Class | Meaning |
|-------|---------|
| `REFINISH_SLAG` | Metal waste from smelting or refining |
| `REFINISH_TAR` | Tar or pitch — condensed volatile distillation product |
| `REFINISH_PEAT` | Organic bog material |
| `REFINISH_CALCIUM_SILICATE` | Calcium-silicate compound (calcium + silica reacted) |

---

## Application to Current Materials

### Making Fuel

| Material | Classes |
|----------|---------|
| Peat | `REFINISH_FUEL_FEEDSTOCK`, `REFINISH_RAW`, `REFINISH_PEAT` |
| Dried peat | `REFINISH_THERMALLY_PROCESSED`, `REFINISH_PEAT` |
| Wood tar | `REFINISH_BYPRODUCT`, `REFINISH_TAR` |
| Charcoite (ceramic) | `REFINISH_THERMALLY_PROCESSED` |
| Potite (ceramic) | `REFINISH_THERMALLY_PROCESSED`, `REFINISH_CALCIUM_SILICATE` |

Peat carries `REFINISH_FUEL_FEEDSTOCK` — it IS fuel feedstock.
Dried peat does NOT carry `REFINISH_FUEL_FEEDSTOCK` — it has
already been partially processed. It is consumed by specific
BOULDER mat_id in the charring reaction, not by wildcard.

All materials carry at least one class, making them economic.
Generic BOULDER_ANY with `non_economic: true` (which means "only
accept non-economic stone") will not grab any of these.

### Making Metal (post-rename, post-glass-removal)

| Material | Classes |
|----------|---------|
| Slag | `REFINISH_SLAG`, `REFINISH_BYPRODUCT`, `REFINISH_FUEL_FEEDSTOCK`, `REFINISH_SILICA_SOURCE` |
| Fired slag ceramic | `REFINISH_THERMALLY_PROCESSED` |
| Calcined slag powder | `REFINISH_THERMALLY_PROCESSED`, `REFINISH_SILICA_SOURCE` |
| Slaked slag | `REFINISH_CHEMICALLY_PROCESSED`, `REFINISH_BINDER` |
| Slag gem | (no supply chain classes — finished product) |
| Refined slag metal | (no supply chain classes — finished product) |
| Alloys (all 13) | (no supply chain classes — finished products) |

Slag carries BOTH `REFINISH_FUEL_FEEDSTOCK` and `REFINISH_SILICA_SOURCE`.
Making Fuel can use it as fuel feedstock. Making Metal's own ceramic
chain can use it as silica source. Neither module references the other.

### Making Concrete (when separated)

| Material | Classes |
|----------|---------|
| Slaked lime | `REFINISH_CALCIUM_SOURCE`, `REFINISH_CHEMICALLY_PROCESSED`, `REFINISH_BINDER` |
| Clinker | `REFINISH_THERMALLY_PROCESSED`, `REFINISH_CHEMICALLY_PROCESSED`, `REFINISH_CALCIUM_SILICATE` |
| Raw cement | `REFINISH_MECHANICALLY_PROCESSED`, `REFINISH_BINDER` |
| Cement (set) | `REFINISH_CHEMICALLY_PROCESSED`, `REFINISH_CALCIUM_SILICATE` |
| Colored variants | `REFINISH_CHEMICALLY_PROCESSED`, `REFINISH_CALCIUM_SILICATE` |

---

## How Reactions Use Classes

### Class-filtered reagent (internal and cross-module)
```json
{ "code": "feedstock", "type": "BOULDER_ANY", "quantity": 2,
  "reaction_class": "REFINISH_FUEL_FEEDSTOCK" }
```
Accepts only boulders carrying `REFINISH_FUEL_FEEDSTOCK`. In
isolation, Making Fuel's own peat qualifies. If Making Metal is
installed, its slag also qualifies. Dried peat, wood tar, and
charcoite don't carry this class, so they're never grabbed.

### Generic stone reagent (any plain stone)
```json
{ "code": "binder", "type": "BOULDER_ANY", "quantity": 1,
  "flags": { "non_economic": true } }
```
No reaction_class — accepts any non-economic boulder. This means
only plain stones with no reaction_classes and no reaction_products.
All module materials carry at least one class and are therefore
economic, so they are excluded. Used when the reaction genuinely
accepts any cheap unprocessed stone from the ground.

### Vanilla class adoption (direct use)
```json
{ "code": "flux", "type": "FLUX", "quantity": 1 }
```
Uses vanilla FLUX class directly via the FLUX reagent type. No
module class needed — vanilla stones already carry this.

### Specific material by mat_id (internal only)
```json
{ "code": "peat_char", "type": "BOULDER",
  "mat_id": "MAKING_FUEL_DRIED_PEAT", "quantity": 2 }
```
Direct mat_id reference to this module's own material. Acceptable
because the module that defines the material also defines the
reaction. Never used across module boundaries.

---

## Reaction Products

Reaction_product entries on materials serve two purposes:

1. **Derivation chains** — defining what a material transforms into
   via `get_material_product` reactions (e.g., clay → fired clay
   via FIRED_MAT)
2. **Economic status** — any reaction_product entry makes the
   material economic (same as reaction_classes)

Reaction_products should be added when the derivation relationship
is real. If a material genuinely transforms into another material
through a process, encode that as a reaction_product. Don't add
reaction_products solely for economic status — reaction_classes
already handle that.

---

## Extending the Vocabulary

When adding a new class:

1. Confirm a concrete reaction or interaction requires it. No
   speculative additions.
2. Check if vanilla already has a class for the concept. Adopt
   vanilla if so.
3. Use the `REFINISH_` prefix.
4. Spell out every word completely.
5. Place it in the correct category (processing state, functional
   role, or material identity).
6. Document it in this reference with its meaning and which
   materials carry it.
7. Update all applicable materials across all modules.
