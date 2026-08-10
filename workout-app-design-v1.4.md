# Design Document: Adaptive Workout Recommendation App
**Working title: "MorningCoach"**
Version 1.2 — Draft for implementation (e.g., via Claude Code)
*Changelog v1.2:* added concrete PowerBlock weight steps and derived achievable-load sets, increment guard, and uneven-pair mode (§2.6).
*Changelog v1.1:* resolved ambiguities found in an implementer-LLM review. All fixes are marked **[v1.1]**: precise queue mechanics, numeric candidate scoring (replaces verbal "demote/boost"), deterministic floor-pressure formula, prescription defaults (§2.5), state-machine middle zone, load semantics & rounding, conflict precedence (pain vs. detraining), explicit step order of operations, and a closed DecisionTrace schema + rule-key enum for the AI layer.

---

## 1. Purpose & Product Principle

A single-user (later multi-user) app that removes all morning decision-making about training. Every morning the user answers a 10-second check-in; the app returns exactly one recommended session, fully specified (exercises, sets, reps, loads), adapted to available time, recovery state, pain flags, and training history.

**Core architectural principle:** A **deterministic rules engine decides. An AI layer explains.** The LLM never selects exercises, loads, or sets — it only generates the natural-language rationale and coaching commentary from the engine's decision trace. This keeps recommendations reproducible, testable, and safe.

**Secondary principle:** The unit of success is the **rolling 4-week average**, not the week. Nothing is ever "missed and made up" — a session queue simply advances.

---

## 2. Domain Model

### 2.1 Session Types (the queue)

| ID | Name | Full duration | Min duration | Leg-heavy | Counts as |
|----|------|--------------|--------------|-----------|-----------|
| S1 | Lower Strength | 35 min | 20 min | yes | strength |
| S2 | Upper Strength (+ optional REHIT finisher) | 60 min | 25 min | no | strength (+intensity if finisher done) |
| S3 | Norwegian 4×4 (CAROL) | 35 min | — (not compressible; substitute REHIT 8 min) | yes (cycling) | intensity |
| S4 | Full Body + ATG Mobility Block | 60 min | 30 min | yes | strength |
| S5 | Flex / Pump (arms, shoulders, core = "ATG 1") | 35 min | 15 min | no | strength (accessory) |
| S6 | Zone 2 (bike or brisk walk) | 60 min | 30 min (or 2×30 split) | no | aerobic base |
| S7 | REHIT (CAROL, 8 min) | 10 min | 8 min | no | intensity |

**Queue mechanics [v1.1 — replaces "loosely anchored" wording]:** The queue is a repeating cycle `[S1, S2, S3, S4, S5]` with a pointer. Only these five types live in the cycle.

- The pointer advances past a type only when a session of that type completes ≥ 50% (§8).
- If the engine selects a cycle type *other than* the pointer's (e.g., floor pressure pulls S3 forward), that type is marked `served` for the current cycle and the pointer subsequently skips served types. When all five are served, a new cycle begins.
- Readiness swaps (§5 Step 6 RED) and time substitutions (S3→S7) do **not** mark the original type served — the original stays pending.
- **S6 selection rule:** S6 sits outside the cycle. It becomes top-ranked candidate iff ALL hold: local weekday ∈ {Sat, Sun}; no S6 completed in trailing 7 days; available time ≥ 30 min; no floor category at hard pressure (§5 Step 3). Declining S6 has no queue effect.
- **S7 rules:** outside the cycle; eligible any day as primary session when slot < 35 min, or as a same-day second session if no intensity session completed in the trailing 48 h. **Leg-heavy exemption:** although S7 is cycling, it is exempt from leg-heavy spacing (8 min is below the fatigue threshold). S3 is NOT exempt. (This resolves the apparent contradiction with the table above.)
- **Intensity credit for S2** counts only if the REHIT finisher was actually completed; otherwise S2 logs as strength only.

### 2.2 Weekly Floor (configurable)

- ≥ 2 sessions counting as *strength* (any size)
- ≥ 1 session counting as *intensity* (S3 or S7)
- S6 is desirable but explicitly the most skippable element.

The floor is evaluated on a rolling 7-day window, not calendar weeks.

### 2.3 Movement Patterns & Difficulty Ladders

Every exercise belongs to a pattern. Progression beyond the 2×50 lb dumbbell cap happens by climbing a **difficulty ladder** within the pattern, not by chasing reps past ~12–15 on compounds.

| Pattern | Ladder (easiest → hardest) |
|---------|---------------------------|
| Squat | Goblet squat → DB squat (2×DB) → Rear-foot-elevated split squat → ATG split squat → ATG split squat, front foot elevated → +tempo (3s down) / +pause |
| Hinge | Elevated-start DB deadlift (on blocks) → DB deadlift floor → DB RDL → Deficit RDL (standing on blocks) → Single-leg RDL → SL-RDL +tempo |
| Push horizontal | Push-up → DB bench on bolster (2×DB) → One-arm DB bench → One-arm +3s eccentric → Deficit push-up (blocks) weighted |
| Push vertical | Seated DB press → Standing DB press → Single-arm standing press → +pause / +tempo |
| Pull vertical | Assisted pull-up → Pull-up → Weighted pull-up (backpack/DB) → Weighted +pause at top |
| Pull horizontal | DB row → Chest-supported row (bolster) → Single-arm row +pause |
| Knee health (ATG) | Backward treadmill, tibialis raise, calf raises (slant board), reverse step-up — programmed as warm-up/filler, progression by reps/slope, not load |
| Core/grip | Plank → L-sit progression → hanging → weighted hanging; wrist curls |

Each ladder step also has micro-progressions in order: **load → reps (within range) → tempo → pause → deficit/ROM → next ladder step.**

### 2.4 Entities (data model)

- **User**: equipment list, weekly floor config, Oura token, units (lb/kg), rep-range prefs.
- **SessionTemplate**: session type + exercise slots at three time tiers (20/35/60 min variants defined per template).
- **ExerciseState** (per pattern per user): current ladder step, current load, current rep target, state machine status (`PROGRESS / HOLD / REGRESS / DELOAD`), last-trained date, consecutive-hold counter, regression counter (4-week window).
- **CheckIn** (daily): available time (20/35/60/0), subjective readiness 1–5, pain flags (body-region map), optional mood/notes, timestamp.
- **RecoverySnapshot** (daily, from Oura or manual): nightly HRV (rMSSD avg), resting HR, sleep score, Oura readiness score; plus computed baseline stats.
- **SetLog**: exercise, weight, reps, RIR (reps in reserve: 0/1/2/3+), pain flag, timestamp.
- **SessionLog**: template, planned vs completed exercises, completion ratio, duration, notes.
- **DecisionTrace** (per recommendation): ordered list of rules that fired, inputs, final output — feeds the AI layer and debugging.

### 2.5 Prescription Defaults **[v1.1 — new; previously implementers would have had to invent these numbers]**

**Work sets per exercise (before readiness modulation):**

| Tier | Compounds | Accessories |
|------|-----------|-------------|
| Extended (60 min) | 3 | 3 |
| Full (35 min) | 3 | 2 |
| Compressed (20–25 min) | 2 (first superset pair only) | 0 |

**Warm-up protocol:** for the session's *first* compound only: 40% × 8, 60% × 5, 80% × 3 (percent of first work load, round down to achievable total, rest ≤ 60 s). Every subsequent exercise: one feeder set at 60% × 5. When the ATG/knee-health block is present it runs first and replaces general warm-up (backward treadmill 3–4 min, tibialis + calf raises).

**Load semantics:** all loads are stored, computed, and displayed as **totals** (both dumbbells summed when two are used; single-DB exercises = that dumbbell's weight). The equipment table in Settings lists each dumbbell's achievable weight steps — §2.6 specifies the user's actual PowerBlocks, and Settings must ship pre-filled with these values. The engine derives the set of achievable *totals* per exercise (1-DB vs 2-DB). "One increment" = the next achievable total above/below current. All percentage-derived loads round **down** to the nearest achievable total. Units per user setting (lb default; kg conversion at display layer only, storage stays in the equipment's native unit).

**Rep display:** the prescription always shows the range (6–10 or 8–15), never a single number; load stays fixed until the progress trigger fires (§6.2) — the user's job between progressions is to close the rep gap.

**Rest defaults:** compounds 90 s (superset partner fills the rest), accessories 60 s; timer pre-set accordingly.

**Cardio prescriptions (engine-emitted targets):**
- S3 Norwegian 4×4: 4 × (4 min @ 85–95% HRmax + 3 min easy spin), plus 5 min warm-up / 3 min cool-down ≈ 36 min.
- S7 REHIT: CAROL native protocol (2 × 20 s max sprints); no engine-side targets, the bike controls it.
- S6 Zone 2: HR 60–70% HRmax or "full sentences possible"; CAROL manual mode or brisk walk.
- HRmax default = 208 − 0.7 × age; user-overridable in Settings.

### 2.6 Equipment Specification — actual PowerBlock steps **[v1.2 — user-provided; ships as pre-filled Settings default]**

| Block | Achievable weights per dumbbell (lb) | Step size |
|-------|--------------------------------------|-----------|
| Small PowerBlock (×2) | 6, 9, 12, 15, 18, 21, 24 | 3 lb |
| Large PowerBlock (×2) | 10, 15, 20, 25, 30, 35, 40, 45, 50 | 5 lb |

**Derived achievable-load sets (the engine computes these once from the table; listed here so tests can assert against them):**

- **Single-DB exercises** (goblet squat, one-arm bench/press/row, curls, raises): union of both blocks = `{6, 9, 10, 12, 15, 18, 20, 21, 24, 25, 30, 35, 40, 45, 50}`. Fine-grained below 25 lb, 5-lb steps above. Hard cap 50 lb → single-DB exercises hit the cap-ladder-jump rule (§6.4) earliest.
- **Matched small pair** (2-DB totals): `{12, 18, 24, 30, 36, 42, 48}` — 6-lb increments.
- **Matched large pair** (2-DB totals): `{20, 30, 40, 50, 60, 70, 80, 90, 100}` — 10-lb increments.
- **Combined 2-DB total set** (union, matched pairs only): `{12, 18, 20, 24, 30, 36, 40, 42, 48, 50, 60, 70, 80, 90, 100}`.

**Engine rules on top of these sets:**

1. **Pair-family switching:** for 2-DB exercises the engine may cross between block families when stepping (e.g., 48 [2×24 small] → 50 [2×25 large]). The prescription display MUST name the blocks and per-dumbbell weight ("2× large @ 25 lb"), not just the total — otherwise the user has to reverse-engineer the setup each morning.
2. **Increment guard [v1.2]:** if the next achievable total exceeds the current load by **> 10%**, the engine inserts one micro-progression (tempo, then pause — §2.3 order) before permitting the load jump, even when below equipment max. This tames the large relative jumps of the 10-lb pair steps at low absolute loads (e.g., presses 30 → 40 = +33%) and the single-DB 45 → 50 step. For that instance the guard *replaces* the "load" slot in the micro-progression order of §6.2.1.
3. **Uneven-pair mode (opt-in, default OFF):** allows a 2-DB prescription with per-hand difference ≤ 5 lb, with a **mandatory side swap between sets** (logged automatically). This roughly halves the effective increment exactly where it matters most — the heavy range: matched large pairs jump 10 lb (60→70→80…), while uneven pairs add `{55, 65, 75, 85, 95}` (e.g., 25+30, 30+35, …, 45+50) and, below 50, fillers like 39, 44, 45, 46, 49. When enabled, these totals join the achievable set for 2-DB exercises; the display shows both dumbbells explicitly ("L: 45 / R: 50, swap after each set"). Not offered for single-leg/single-arm exercises (asymmetry would load the sides unequally across the session).
4. **Rounding restated with real numbers:** a 60% deload of a 90-lb DB deadlift = 54 → rounds down to **50** (matched) or **49** (uneven mode, 24+25). A 90% detraining re-entry from 100 = 90 → exact match. Tests should assert these concrete values.
5. **Weighted pull-ups/dips:** loading via backpack or a small-block DB held between the feet; achievable set = single-DB union above, increments follow the same rules; backpack contents are user-entered free weight (any value allowed, engine rounds nothing).

---

## 3. Morning Check-In Flow

1. **Push notification** at user-configured wake window ("Ready to plan today?"). If Oura is connected, the app has already pulled last night's data before the notification.
2. **Screen 1 (single screen, ≤10 s):**
   - Time available today: `0 / 20 / 35 / 60` (buttons; 0 = rest/no slot)
   - How do you feel? `1–5` (1 = wrecked, 5 = great)
   - Pain anywhere? Tap body region(s): lower back, knee L/R, shoulder L/R, elbow, wrist, hip. Each tapped region: `mild / sharp`.
3. Oura fields (HRV, sleep, readiness) are shown pre-filled and can be manually overridden or entered if the API is down.
4. Submit → recommendation appears within 1 s (rules engine) with the AI explanation streaming in after (or template fallback text).

Home-office flexibility is handled entirely by the **time selector** — the app never needs to know which weekday is home office. (Optional Phase-3 feature: calendar read access to pre-suggest the time budget.)

---

## 4. Readiness Computation

### 4.1 Baseline statistics (rolling, recomputed nightly)

- `HRV_baseline` = mean of nightly rMSSD over trailing 60 days (min 14 days of data before HRV logic activates)
- `HRV_sd` = standard deviation over same window
- `HRV_z_today` = (today − baseline) / sd
- `HRV_trend3` = mean z of last 3 nights
- `RHR_dev` = today's resting HR − 60-day mean (in bpm)
- **Data sufficiency [v1.1]:** HRV and RHR logic each require ≥ 14 nights of data within the trailing 60 days; below that threshold the input is treated as *missing* (see renormalization rule in §4.2). Baselines are computed over whatever qualifying subset exists — never over synthetic or default values.

### 4.2 Composite readiness score (0–100)

Weighted blend, defaults:

| Input | Weight | Mapping |
|-------|--------|---------|
| Subjective 1–5 | 40% | linear 1→0, 5→100 |
| HRV_trend3 (z) | 30% | z ≤ −1.5 → 0; z ≥ +0.5 → 100; linear between |
| Sleep score (Oura) | 20% | direct 0–100 |
| RHR_dev | 10% | ≥ +5 bpm → 0; ≤ 0 → 100; linear between |

**Missing-input renormalization [v1.1 — generalizes the old "Oura missing → subjective 100%" rule]:** drop each missing input individually and renormalize the remaining weights proportionally. Example: only HRV missing → subjective 40/70, sleep 20/70, RHR 10/70 of the total. All Oura inputs missing is simply the special case where subjective becomes 100%. Never impute a neutral value (e.g., z = 0) for a missing input — that silently biases the score toward GREEN.

### 4.3 Buckets & override rules

- **GREEN** ≥ 65 · **YELLOW** 40–64 · **RED** < 40
- **Subjective override (down):** subjective ≤ 2 → cap at YELLOW; subjective = 1 → force RED. The human always wins downward.
- **Subjective override (up):** subjective ≥ 4 with objective YELLOW → lift to GREEN *unless* HRV_trend3 ≤ −1.5 (persistent suppression blocks the upgrade).
- **Single-night rule:** one isolated low HRV night with normal subjective feel never forces YELLOW on its own — trend beats snapshot.
- **Illness guard:** RHR_dev ≥ +7 bpm AND HRV_z_today ≤ −2 → force RED and surface a "possible incoming illness — consider full rest" note.

---

## 5. The Decision Tree (core recommendation algorithm)

Runs on check-in submit. Every evaluated rule is appended to the `DecisionTrace`.

### Step 0 — Input gathering
Inputs: CheckIn, RecoverySnapshot + readiness bucket, queue position, SessionLogs (trailing 7 days), ExerciseStates, pain flags (active from today + unresolved from prior days).

### Step 1 — Rest-day short-circuit
- Time = 0 → output "Rest day", advance nothing, done.
- Readiness RED **and** yesterday's bucket was also RED (regardless of whether a session was done) → recommend full rest or an optional 20–30 min walk; queue does not advance. **[v1.1 clarification]:** a first, isolated RED day does *not* short-circuit here — it falls through to Step 6's RED modulation (swap/technique session). Only the second consecutive RED forces the rest recommendation.

### Step 2 — Candidate filtering by time
Keep every session type whose `min duration ≤ available time`. Each surviving candidate is tagged with the tier it would run at (compressed / full / extended).
- Special case 20-min slot: candidates are {S1-compressed, S5-compressed, S7, S6-split(30 only if user overrides)}.

### Step 3 — Weekly-floor pressure (priority injection)
**[v1.1 — replaces the "pressure = needed ÷ realistic remaining slots" formula, which required estimating future availability and was not deterministically computable.]** Pure count-based test per floor category (strength, intensity):

1. `deficit = floor_requirement − completed_count(category, trailing days [today−6 … today−1])`
2. `deficit ≤ 0` → no pressure.
3. `deficit ≥ 2` → **hard force**: score bonus +100 (Step 4/5) for candidates of that category.
4. `deficit = 1` → check the *aging-out horizon*: find the oldest session of that category still inside the trailing window. If it drops out of the window within the next 2 days (or none exists) → **hard force** (+100); otherwise **soft boost** (+10).
5. Both categories hard-forced simultaneously → strength candidate wins the slot; the engine additionally surfaces "add an 8-min REHIT as a second session today" to cover intensity (S7 second-session rule, §2.1). Rationale: intensity has a 10-min option, strength doesn't.

No estimate of future free slots is used anywhere — every term is a count over logged history, so the rule is unit-testable with fixture data.

### Step 4 — Candidate scoring **[v1.1 — replaces verbal "demote / boost by one rank", which two implementers would code two different ways]**
Every surviving candidate receives `score = base + Σ modifiers`. All values are fixed constants:

- **base (cycle candidates):** `50 − 10 × cycle_distance`, where cycle_distance = 0 for the pointer's type, 1 for the next unserved type, etc.
- **base (non-cycle):** S7 = 10; S6 = 10, or 60 when its full selection rule (§2.1) is satisfied.
- **+100** floor hard force · **+10** floor soft boost (Step 3).
- **−30** for leg-heavy candidates (S1, S3, S4 — S7 exempt) if a leg-heavy session was completed yesterday.
- **+15** to the single highest-priority candidate covering any pattern untrained > 5 days (apply at most once per candidate, using the longest-untrained pattern for tie-breaking).
- Deload status is **not** a scoring factor: a pattern in `DELOAD` still trains, just with deload parameters (§6.5).

### Step 5 — Selection
Highest score wins; ties resolve by cycle order (S1 < S2 < … ), then S7 before S6. **Escape hatch:** if the winner is leg-heavy after yesterday's leg-heavy session (i.e., the −30 didn't change the outcome because everything feasible was leg-heavy), it runs with volume −20% (drop 1 work set per exercise, floor of 1) and the trace records `LEGHEAVY_BACKTOBACK_VOLUMECUT`. The complete ranked list is written to the DecisionTrace; ranks 2–3 feed the "swap session" UI. The queue pointer advances **only when a session completes ≥ 50%** (§8).

### Step 6 — Readiness modulation of the chosen session
**Order of operations [v1.1]:** although listed 6 → 7 for readability, the engine resolves Step 7's tier template FIRST to fix the set baseline; Step 6's volume cuts then apply to that baseline. Both modifications stack multiplicatively, always rounding down, with an absolute floor of 1 work set per remaining exercise. (Without this rule, an implementer could cut 25% from the full template and then compress — yielding different set counts.)

- **GREEN:** run as planned; progression attempts allowed (engine marks exercises eligible for a load/step increase per §6).
- **YELLOW:**
  - Strength session: keep exercise selection, cut work sets ~25% (round down, min 1 set per exercise), no progression attempts, target RIR ≥ 2.
  - S3 (4×4) → replace with S7 (REHIT) or 3×4 at lower watt target (user picks, default REHIT).
  - S6 unchanged (Zone 2 is the recovery-friendly option anyway).
- **RED:**
  - Intensity sessions (S3/S7) → replaced by S6-30min or ATG-2 mobility block.
  - Strength sessions → "technique session": same exercises at 60% of current loads, half sets, RIR ≥ 4. If user declines → rest, queue frozen.
  - This is a *swap*, so the original queue item stays pending.

### Step 7 — Time compression
Apply the tier from Step 2 to the session template:
- **60 → 35:** drop accessory block and/or REHIT finisher; keep all primary superset pairs.
- **35 → 20:** warm-up (shortened: 2 min backward treadmill or band work) + first superset pair only, 2 hard sets each. Rationale surfaced to user: 1–2 hard sets retain the large majority of the hypertrophy stimulus.
- **Non-compressible (S3):** if slot < 35 → substitute S7 and tag the trace ("4x4 swapped for REHIT due to time").

### Step 8 — Pain substitution pass (see §7)
For every active pain flag, run the substitution table over the exercise list. Sharp-pain regions remove/replace exercises outright; mild-pain regions replace with the flagged-region-friendly variant and reduce load one increment.

### Step 9 — Load & target resolution
For each remaining exercise, read `ExerciseState` → emit `sets × rep-target @ load (or ladder step) with RIR instruction`. Detraining adjustment (§6.6) applies here.

### Step 10 — Output assembly
Emit: session name, tier, ordered exercise list with targets, estimated duration, and the full DecisionTrace → handed to the AI layer for the "why" text.

### Worked example (this morning's real case)
Inputs: time = 35, subjective = 3, HRV normal (GREEN), pain flag = lower back **sharp** (from yesterday's deadlift, logged mid-session), queue next = S1.
Trace: Step 2 keeps {S1-full, S3, S5, S7}; Step 3 no floor pressure; Step 4 no leg-heavy yesterday; Step 5 picks S1; Step 6 GREEN, no change; Step 8 fires: hinge pattern with *sharp lower-back* → DB deadlift removed, replaced by bridge hamstring curl, and squat pattern load capped at −1 increment with "stop on any twinge" instruction; hinge `ExerciseState` frozen (no progression/regression recorded while flagged).
Output: Lower Strength (modified), with AI text explaining exactly this.

---

## 6. Progression Engine (per-pattern state machine)

### 6.1 Rep ranges
- Compound patterns (squat, hinge, pushes, pulls): **6–10** target reps per work set.
- Accessories (curls, raises, calves, core): **8–15**.
- ATG/knee-health block: rep/ROM progression only, no state machine.

### 6.2 States & transitions
States: `PROGRESS` (default) · `HOLD` · `REGRESS` · `DELOAD`

After each completed session, per exercise:

1. **Progress trigger:** all work sets hit top of rep range with RIR ≥ 2 → apply next micro-progression (§2.3 order: load +5 lb total (or smallest increment) → if load capped: reps → tempo → pause → deficit → next ladder step). State stays `PROGRESS`, consecutive-hold counter resets.
2. **Hold trigger:** any work set below bottom of range, OR any set at RIR 0 (grinding) → `HOLD`: repeat identical prescription next time. 
3. **Regress trigger:** 2 consecutive `HOLD` sessions with missed reps → step back one micro-progression, state `REGRESS` for one session, then back to `PROGRESS`.
4. **Pain freeze:** pain flag on the pattern → state frozen entirely; sessions while flagged don't count as holds or progressions.
5. **Middle zone — neither trigger [v1.1; previously unspecified, an implementer might wrongly progress here]:** sets land inside the range (e.g., 8/8/7 @ RIR 1–2), nothing below bottom, no RIR-0 set → state stays `PROGRESS`, prescription repeats **unchanged** (same load, same range). Double progression means the user closes the rep gap across sessions; load never increases on partial-range performance. No counter increments in this zone.

**Evaluation timing [v1.1]:** transitions are evaluated once, at session completion, per exercise, using only that session's completed work sets. Warm-up/feeder sets never count.

### 6.3 Deload trigger
Any of:
- ≥ 2 regressions on the same pattern within a rolling 28 days
- ≥ 3 RED days in 7 days
- User manual trigger ("feeling beat up")

→ `DELOAD` for that pattern (or globally for the RED case): next 2 sessions touching it run at 60% load, half sets, RIR ≥ 4. Then auto-return to `PROGRESS` at the pre-deload prescription minus one micro-step.

### 6.4 Rep-cap rule (dumbbell ceiling)
When load is at equipment max and reps reach top of range: engine proposes the next **ladder step** at a reduced load, re-entering the 6–10 range. **[v1.1 defaults]:** reduction per ladder jump = −30% for squat/hinge steps, −20% for push/pull steps (each ladder edge can override); round down to the nearest achievable total. **Undershoot correction:** if the first session at the new step comes in at RIR ≥ 3 on all sets, apply one immediate increment next session instead of waiting for the full progress trigger. This is the codified answer to "maxed out the 2×50s".

### 6.5 Deload parameters
60% of current working load (or two ladder micro-steps easier), 50% of sets, tempo emphasis, RIR ≥ 4. Explicitly labelled in UI as deload so it doesn't read as regression.

### 6.6 Detraining adjustment
Pattern untrained 10–20 days → resume at 90% of last load, state `PROGRESS`. > 21 days → 80% and one ladder micro-step easier. > 42 days → treat as re-onboarding (start 70%, fast double-progression will restore quickly). All percentages round down to achievable totals (§2.5).

**Precedence vs. pain re-entry [v1.1 — these two rules previously conflicted]:** if the gap was caused by a pain freeze, §7.2's graded re-entry test (50% × 8) runs FIRST and overrides the detraining percentage for that session. After one pain-free test session, resume at the **lower** of (detraining-adjusted load, pre-pain load − 1 increment). Detraining percentages never stack on top of an active pain protocol.

### 6.7 What counts as a "small setback" (the user's stated reality)
Lowering weight after a break or a twinge is a **first-class engine event**, not failure: it's either a detraining adjustment (§6.6), a pain freeze (§6.2.4), or a deload (§6.3) — each with a defined re-entry ramp. The UI never shows "you got weaker"; it shows "re-entry ramp, week 1 of 2".

---

## 7. Pain Module

### 7.1 Regions & substitution table (initial)

| Region | Affected patterns | Mild → substitute | Sharp → substitute |
|--------|-------------------|-------------------|--------------------|
| Lower back | Hinge, squat | Elevated-start DL (blocks), −1 load increment | Remove hinge loading: bridge hamstring curl, light SL-RDL (bodyweight/12 lb); squats → goblet, reduced ROM if pain-free |
| Knee | Squat, step-ups, 4×4 | Reduce ROM/load; extra backward treadmill + tibialis work | Remove squat pattern; hinge + upper focus; REHIT only if pain-free seated |
| Shoulder | Push vert/horiz, pull | Neutral-grip, reduce load; band rotations extended | Remove overhead; floor-angle push variants only if pain-free; rows over pull-ups |
| Elbow/wrist | Pulls, curls, presses | Neutral grips, −1 increment | Remove direct arm work; leg session preferred today |
| Hip | Squat, hinge, lunges | Reduce ROM, extra mobility block | Swap to upper session |

**Substitute loading [v1.1]:** a substitute exercise uses its own existing `ExerciseState` if the user has trained it before; otherwise it onboards at the ladder's entry load (bodyweight, or the lightest achievable total) with rep range 8–15, tagged `ONBOARD_SUBSTITUTE` in the trace so the AI text can explain the deliberately easy start. Never estimate a substitute's load from the replaced exercise's load — the strength transfer between variants is not predictable enough.

### 7.2 Flag lifecycle
- Flag set at check-in or mid-session (logger has a per-set pain button).
- **Sharp** flags: pattern substituted for a minimum of 2 sessions *in which the pattern was scheduled* (whether it was then substituted or the exercise skipped — both count **[v1.1 clarification]**), then the app *asks* ("test light today?") and offers a graded re-entry set (50% of pre-pain load × 8, stop on symptoms).
- **Mild** flags: decay automatically after 1 pain-free session on the pattern.
- **Escalation rule (hard-coded, deterministic, not AI):** sharp flag persisting > 7 days, OR user tags "radiating / numbness / tingling" → app displays a fixed medical-advice notice and stops recommending the pattern until the user clears the flag manually. The AI layer is prohibited from softening or overriding this text.

### 7.3 Dedicated lower-back recovery mode

This is a conservative training modification, not a diagnosis of disc injury
and not a promise of healing. Activation explicitly screens for spreading leg
pain, numbness/tingling, weakness, saddle sensory change, bladder/bowel change,
fever, major trauma, and rapid worsening. Emergency neurological signs direct
the user to urgent care; persistent symptoms direct the user to a qualified
clinical assessment.

While active, the normal hinge `ExerciseState` is snapshotted and frozen:
loaded deadlifts and their load progression cannot appear. A scheduled hinge
slot becomes either the due recovery exposure or a deliberately light bridge
hamstring-curl substitute. The self-built stool/block/PowerBlock setup is never
described as inspected or certified.

The mode also replaces the normal strength catalogue rather than filtering
only the hinge slot. No saved ladder position may reintroduce weighted squats,
unsupported rows or presses, externally loaded pull-ups, L-sits, weighted
hangs, or weighted dips. Strength sessions retain their original session IDs
and queue credit but display as `Lower-back recovery · Pull + ATG 1` and use:

- assisted-as-needed bodyweight pull-ups at 4+ RIR with normal pull-up
  progression frozen;
- floor press and chest-supported dumbbell row for supported upper-body work;
- alternating curls, lateral raises, and bodyweight-only dips for ATG 1 / pump
  work at 3+ RIR;
- the existing low-load ATG/knee-health preparation where the template owns
  it; and
- the symptom-gated back-extension or bridge-hamstring-curl hinge dose.

Compressed 20-minute sessions keep only the first safe pair. A 60-to-35-minute
compression removes the pump accessories before supported primary work. Cardio
sessions remain governed by their existing readiness and pain gates because
they do not use the strength-exercise ladder.

1. Start with `3 × 30 s` static back-extension holds, neutral-to-near-neutral,
   at least 4 RIR and no failure. Progress by 10 s only after two tolerated
   exposures, capped at `3 × 60 s`.
2. Continue with `2 × 6` slow, unloaded repetitions through a comfortable
   range. Progress by 2 reps after two tolerated exposures, capped at
   `2 × 12`.
3. Re-enter with `1 × 8` elevated-start deadlifts at the nearest achievable
   total no higher than 50% of the snapshotted load, at least 4 RIR and no
   increase that day. Two tolerated re-entry exposures complete the mode; the
   re-entry load becomes the new hinge baseline.

Recovery exposures are capped at two per rolling seven days with at least 48
hours between them. Completion alone never advances the dose: the logger
requires an immediate better/same/worse response and Home requires the same
comparison the following morning. Any worse response regresses one dose step;
the pending morning response blocks another exposure.

Evidence boundary: NICE NG59 supports self-management, continued normal
activity, and exercise selected around the person's needs and capabilities;
the WHO 2023 guideline supports structured exercise as one component of care
for chronic primary low-back pain. Neither establishes one back-extension
protocol as a cure or a way to diagnose a herniated disc. NHS cauda-equina
guidance supplies the emergency bladder/bowel, saddle-sensation, and weakness
warning signs used by the activation gate.

Sources: https://www.nice.org.uk/guidance/ng59/chapter/recommendations ·
https://www.who.int/publications/i/item/9789240081789 ·
https://www.buckshealthcare.nhs.uk/pifs/cauda-equina-syndrome/

---

## 8. Abort & Partial-Session Handling

- Logger tracks completion ratio = completed work sets ÷ planned work sets **of the final emitted plan** — i.e., after time compression, readiness cuts, and pain substitutions; never the full-tier template **[v1.1: previously ambiguous denominator]**.
- **≥ 50%** → session counts, queue advances, progression rules evaluate only completed exercises.
- **< 50%** → session logged as partial, queue does *not* advance; tomorrow the same session is offered again in compressed form.
- Mid-session time crunch: a "wrap up" button re-plans the remainder into a 5-min finisher (one compound superset, 1 set each).

---

## 9. AI Layer

### 9.1 Role boundaries
- **Never decides.** Input is the frozen DecisionTrace + output plan; the LLM cannot modify sets, loads, exercises, or safety text.
- Produces: (a) daily "Why this session today" (2–4 sentences), (b) one optional coaching cue for the day's main lift, (c) weekly review (Sunday or on demand).
- If the API call fails or exceeds 3 s → deterministic template fallback ("Next in queue: Lower. HRV normal. Back flagged → deadlifts swapped for bridge curls.") so the product never blocks on the LLM.

### 9.2 Daily explanation — context payload
Assembled server-side (or on-device) into a structured prompt:
- Today: readiness bucket + which inputs drove it (e.g., "subjective 3, HRV z −0.2, sleep 81"), fired rules in plain keys (`FLOOR_PRESSURE_INTENSITY`, `PAIN_SUB_HINGE_SHARP`, `TIME_COMPRESS_35→20`…), final plan summary.
- Last 7 days: sessions done, floor status, notable progression events ("weighted pull-up +5 lb").
- Persistent facts: goals (hypertrophy + VO2max), equipment cap, tone preference.

### 9.3 Prompt contract (system-prompt requirements, described)
- Output ≤ 70 words for the daily text, plain language, no medical claims, no emojis unless user opts in.
- Must reference the *actual* fired rules only — the prompt instructs the model to explain, not invent; the rule keys and their human meanings are provided as a glossary.
- Pain-related sentences must be followed by the app's fixed advisory line (appended deterministically after generation, not by the model).
- German or English per user setting.

### 9.4 Weekly review (LLM, richer)
Inputs: 4-week rolling adherence vs floor, per-pattern progression timeline, readiness trend, skipped/aborted stats. Output: ~150-word narrative + exactly 1 recommended focus for next week, phrased as an option ("If you want one thing to nudge: the couch stretch got skipped 3× — keep it anchored inside Thursday's block"). Any *structural* suggestion (e.g., change weekly floor) is presented as a button the user confirms → only then does it change engine config. The LLM proposes; the user disposes; the engine executes.

### 9.5 Model & cost
Daily text: small/fast model (e.g., Haiku class), ~500 input / 100 output tokens → negligible cost. Weekly review: mid-tier model. Both via Anthropic API; on-device fallback templates ship with the app.

### 9.6 DecisionTrace schema & rule-key enum **[v1.1 — new; without this, an implementer invents ad-hoc keys and the LLM prompt drifts into free-form (i.e., deciding) territory]**

**DecisionTrace fields (flat, serializable):**

| Field | Content |
|-------|---------|
| `date` | local calendar date of the recommendation |
| `checkin` | `{time_min, subjective, pain[]: {region, side?, severity}}` |
| `recovery` | `{hrv_z_today, hrv_trend3, sleep_score, rhr_dev, bucket, inputs_missing[]}` |
| `candidates[]` | `{session_id, tier, score, score_terms{}}` — the FULL ranked list incl. losers |
| `fired_rules[]` | ordered keys from the closed enum below |
| `plan` | `{session_id, tier, exercises[]: {pattern, name, sets, rep_range, load_total, rir_target, substituted_from?}}` |
| `queue` | `{pointer_before, served_before[], pointer_after_if_completed}` |

**Rule-key enum (closed list — adding a rule requires adding key + glossary entry + fallback template; the LLM prompt receives this glossary and may ONLY reference fired keys):**

`REST_TIME_ZERO · REST_DOUBLE_RED · FLOOR_FORCE_STRENGTH · FLOOR_FORCE_INTENSITY · FLOOR_SOFT_BOOST · LEGHEAVY_DEMOTED · LEGHEAVY_BACKTOBACK_VOLUMECUT · RECENCY_BOOST_<pattern> · QUEUE_NEXT · S6_WEEKEND_RULE · S7_TIME_SUB · S7_SECOND_SESSION_OFFER · YELLOW_VOLUME_CUT · YELLOW_4X4_TO_REHIT · RED_SWAP_TECHNIQUE · RED_SWAP_Z2 · TIME_COMPRESS_60_35 · TIME_COMPRESS_35_20 · PAIN_SUB_<pattern>_MILD · PAIN_SUB_<pattern>_SHARP · PAIN_FREEZE_<pattern> · PAIN_REENTRY_TEST_<pattern> · DELOAD_ACTIVE_<pattern> · DETRAIN_ADJUST_<pattern> · CAP_LADDER_JUMP_<pattern> · ONBOARD_SUBSTITUTE · ILLNESS_GUARD · SUBJ_OVERRIDE_DOWN · SUBJ_OVERRIDE_UP_BLOCKED`

**Fallback templates:** exactly one fixed string per rule key, in EN and DE, shipped with the app; on LLM failure they are concatenated in fired order. Examples of the required style: `QUEUE_NEXT` → "Next in queue: {session}." · `PAIN_SUB_HINGE_SHARP` → "Deadlifts swapped for bridge curls — lower back is flagged." · `YELLOW_4X4_TO_REHIT` → "Recovery is middling, so an 8-min REHIT replaces the 4×4 today." The template file is the source of truth for rule semantics; the AI layer is optional polish, never a dependency.

- Auth: Personal Access Token (single user) — Settings screen field; later OAuth2 for multi-user.
- Endpoints (REST v2): `daily_readiness`, `daily_sleep`, `sleep` (for nightly average rMSSD and lowest RHR).
- Pull schedule: on morning notification trigger + retry at check-in open; cache last 90 days locally for baseline math.
- Failure behavior: silent fallback to subjective-only weighting (§4.2); banner "Oura data unavailable today".
- Manual mode: all three fields editable, so the engine works with zero integrations.

---

## 11. Screens (concise)

1. **Check-in** — time buttons, feel 1–5, body map, Oura strip (pre-filled), submit.
2. **Today** — session card: name/tier, AI "why" text, exercise list with targets, start button, "swap session" (shows the 2 next-ranked alternatives from the decision trace, keeping user agency).
3. **Logger** — one exercise at a time; big steppers for weight/reps; RIR buttons (0/1/2/3+); pain button; rest timer; "wrap up" button.
4. **History** — calendar heat, per-pattern progression charts, HRV/readiness overlay, floor-compliance ring (rolling 7 days).
5. **Settings** — equipment & max loads, weekly floor, rep ranges, Oura token, language, AI tone.

---

## 12. Edge Cases

- **No check-in by cutoff (e.g., 10:00):** push "No plan yet — tap for a 20-min default"; engine assumes YELLOW + 20 min.
- **Two slots in one day** (home office): after a completed morning session, the Today screen exposes "add lunch REHIT" if no intensity session in 48 h.
- **Travel / no equipment:** equipment toggle → ladders resolve to bodyweight steps (push-up, split squat, SL-RDL bodyweight, hanging where possible).
- **Long illness gap:** first check-in after ≥ 10 idle days routes through detraining adjustment globally and forces week 1 = all-YELLOW modulation.
- **Conflicting signals** (subjective 5, HRV z −2): trend rule + upward-override block resolves to YELLOW; AI text explains the "engine vs. feel" mismatch transparently.
- **Day boundary [v1.1]:** all "yesterday/today" logic uses the device's local calendar date at check-in time; sessions logged before 03:00 count toward the previous date (late-evening training). DST shifts follow the OS clock — no custom handling.

---

## 13. Build Phases

- **Phase 1 (MVP):** session templates, queue, check-in (manual recovery entry), decision tree steps 0–10, logger, progression state machine, template explanations. → Fully useful without any integration.
- **Phase 2:** Oura API + baseline math, pain-flag lifecycle automation, history charts.
- **Phase 3:** AI layer (daily + weekly), calendar-based time pre-suggestion, equipment/travel mode.

### Testing notes
The engine must be pure-function testable: `(CheckIn, RecoverySnapshot, History, States) → (Plan, DecisionTrace)`. Ship with a scenario test suite including at minimum: the worked example in §5, floor-pressure day, RED-day swap, dumbbell-cap ladder jump, deload trigger, detraining re-entry, and the illness guard. **[v1.1 additions]:** score tie-break (two candidates at equal score), floor deficit=1 aging-out horizon firing vs. not firing, all-feasible-candidates-leg-heavy escape hatch, state-machine middle zone (must NOT progress), missing-HRV renormalization (must not bias GREEN), pain-freeze + detraining precedence, and compression×readiness stacking (assert exact set counts for 20-min YELLOW). **[v1.2 additions]:** pair-family switch at 48→50, increment guard firing on 30→40 press (+33%), uneven-pair set expansion (55–95 present only when enabled), and the concrete rounding assertions from §2.6.4.
