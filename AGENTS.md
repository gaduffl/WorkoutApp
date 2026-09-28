# WorkoutApp agent guide

This file applies to the entire repository. Keep it updated whenever architecture,
safety rules, validation, or delivery workflow changes.

## Product and architecture

- WorkoutApp is a deterministic Flutter/Dart training planner. Core decisions belong
  in pure, unit-testable engines; widgets render authoritative model output and must
  not independently recreate training rules.
- `workout-app-design-v1.4.md` is the product specification.
  `implementation.md` records non-obvious implementation decisions and deliberate
  deviations. Update both when behavior changes materially.
- Persisted JSON and database models must remain backward compatible. New fields need
  safe defaults for existing installations and backups.
- History defaults to the fixed-scale 53-week activity heatmap. The persisted
  `Classic heatmap` setting restores the compact 12-week strength/cardio category
  view; this preference is display-only and must never alter history aggregation or
  recommendation inputs.
- Muscle-map views render the existing stimulus ledger and current plan. Label
  recency as recency, never fatigue, recovery, or injury readiness; the visual must
  not create a second stimulus-accounting path. The Today tab may separately render
  completed non-zero work as clearly labelled exposure, including conservative RIR 4+
  work, but that projection must never feed dose targets, progression or recommendations.
- Activity log rows form one newest-first feed across MorningCoach sessions and
  bouldering. Exact completion times order sessions within a day; date-only external
  activities follow exact entries on that day with a deterministic stable tie-break.
- Manually logged bouldering is external activity, not a MorningCoach prescription.
  Duration and perceived effort feed one conservative, capped pull/grip stimulus
  adapter for recommendation and muscle-map history, but must never complete the
  daily plan, advance the queue or an exercise ladder, grant cardio/leg credit, or
  advance Back rebuild stages or the bike return. The annual activity heatmap
  includes its actual duration; the category-only Classic heatmap remains unchanged.
- The time-allocation chart uses a fixed colorblind-safe categorical palette and
  matching label swatches. Keep segment widths proportional to elapsed time; do not
  replace the category colors with adjacent theme roles or describe it as progress.
- The anatomical muscle-map geometry is pinned to the MIT-licensed upstream
  MuscleMap revision recorded in `THIRD_PARTY_NOTICES.md`. Regenerate only from
  that original source (not openGym's AGPL-converted JavaScript), preserve the
  notice. Keep the lumbar area neutral in dose/recency modes. Today may light it
  only for exact direct-lumbar exposure (canonical hinge, a Back rebuild deadlift, or
  the dedicated back extension), never by inheriting the broad hinge slot from a
  named bridge or hamstring curl.
- Exercise guides stream only explicitly mapped ExerciseDB V1 animations from the
  official `static.exercisedb.dev` CDN. Keep raw exercise media out of the repository
  and APK, retain the in-card ExerciseDB/AscendAPI and Gym visual attribution, and
  preserve the release Android `INTERNET` permission. Never guess by name or let a
  substitution inherit a demo for different equipment or motion; unsupported variants
  display no graphic.
- Every app-authored strength preparation block includes jumping jacks inside its
  existing time allocation. Pain-aware and Back rebuild plans must retain the
  low-impact step-jack or marching fallback when jumping or impact reproduces
  symptoms. Cardio-owned preset warm-ups remain unchanged.
- The `McGill Big 3` setting (default on) adds a fixed, non-progressing Big 3 entry
  after the preparation block of every strength session, in its own 2/4/6 minutes
  for the 20/35/60-minute windows, with or without Back rebuild. On rest and
  cardio-only days Home offers the same routine plus an easy uphill walk with one
  Done tap; it never completes, replaces or changes the daily plan.
- Prefer existing models, repositories, and engines over parallel state or duplicate
  rule paths. Avoid new dependencies unless they materially reduce risk or complexity.

## Medical and pain-safety invariants

- The app does not diagnose an injury, a herniated disc, or tissue healing. UI copy
  must describe symptoms, training modifications, and escalation actions without cure
  claims or medical certainty.
- Deterministic safety gates outrank readiness, weekly targets, manual session swaps,
  progression, and AI-generated explanations. The AI layer may never weaken them.
- Back rebuild (the lower-back recovery mode) changes only the hinge slot, the bike,
  and the general preparation (jumping jacks, then an uphill forward walk on the ATG
  treadmill). Every other slot is the normal plan with its normal ladders, RIR, queue,
  time budget, and pain, partial-work, travel, readiness and deload gates. Never add a
  second planner, a closed recovery catalogue, mandatory phases or daily dose forms.
- The hinge slot has three stages: (1) floor glute bridge and sliding hamstring curl
  on the separate deadlift-alternative tracks, credited only to glutes and hamstrings
  respectively; (2) DB deadlift from blocks at RIR 3+, 50–70% of the preserved
  pre-rebuild hinge load; (3) DB Romanian deadlift at RIR 2, 70–100%. Loaded steps use
  their own tracks, are clamped to the stage cap, run last and unpaired with their
  warm-up, at most twice per rolling 7 days and at least 48 hours apart, and never while
  the lower back or hip is flagged or in travel mode; stage-1 work fills the slot
  otherwise. Mild flags ease rebuild tracks through the ordinary pain table; sharp
  lower-back pain removes all rebuild hinge work. The normal hinge ladder stays frozen
  until hand-off, and no rebuild track advances it.
- Stages, optional back extensions and bike steps advance only after a recorded
  next-morning check: one Better/Same/Worse question at check-in, required when due.
  There is no same-day question; a pain-flagged rebuild set makes the check a
  setback. Two same-or-better mornings advance a stage (stages 2–3 also need the cap
  reached); a worse morning steps back one stage, and the stage it leaves resumes one
  load step lighter (never below its floor). Completing a session never advances
  anything by itself.
- Finishing stage 3 ends Back rebuild and hands the hinge to the normal ladder at DB
  RDL with the capped RDL-track load. A manual end hands off at the rebuild's level
  (elevated start from stages 1–2, RDL from stage 3), never the old load, and
  completes the bike return. Tolerated extension sessions never end the rebuild.
  Reset day drops today's rebuild exposures and never undoes a same-day hand-off.
- Back extensions are optional (off by default), unloaded, join stages 1–2 at the end
  of the session when spacing allows, and share the next-morning check.
- Back rebuild starts a stepped bike return: walk only → Zone 2 rides → 4×4 → all
  cycling. A ≥10-minute test ride, a creditable ≥30-minute Zone 2 ride and a creditable
  4×4 each open the next step after a same-or-better morning; a worse morning steps
  back; walks never count. Whenever rides are not allowed, Zone 2 is an uphill forward
  walk on the ATG treadmill with the same dose and normal aerobic credit, and 4×4,
  REHIT, finishers and nudges stay closed. The manual `Pause stationary cycling` switch
  outranks every step. An active legacy recovery profile converts on load to stage 1
  with the bike return at walk only, clearing the old forced pause. Retrospective
  activity remains loggable. The independent deadlift-alternative setting replaces
  normal hinge work with the separate floor-bridge/curl tracks without load transfer.
- Home displays one compact Back rebuild card (stage, next step, bike step). Settings
  keeps the extension, cycling and deadlift-alternative controls collapsed.
- New/increasing radiating pain, numbness, tingling, weakness, saddle/genital sensory
  change, or bladder/bowel dysfunction blocks training and displays the fixed medical
  escalation guidance.
- A comeback prescription after a training pause must describe the currently
  emitted reduced load/target or easier difficulty. Never carry a stale
  `Load increased` milestone into a detraining-adjusted plan.
- Back rebuild hinge work uses conservative, pain-tolerated prescriptions and never
  trains to failure. Do not represent a self-built apparatus as inspected or certified.
- Keep the existing pain-freeze, substitution, and escalation behavior working for
  users who do not activate Back rebuild. A mild lower-back regression of the normal
  hinge skips the floor DB deadlift and lands on the elevated start.
- A continuous Zone 2 completion may exceed its prescribed duration and must retain
  the full actual dose, subject to the existing 24-hour input bound. Interval cardio
  protocols remain capped at their prescribed work dose.
- Home-screen retrospective Zone 2 rides or uphill walks are unplanned, supplemental
  records: preserve actual dose and normal aerobic credit, without completing/replacing
  the primary plan or advancing the queue. No prospective duration estimate is
  recorded for unplanned activity. Reuse the existing cardio validation and
  persistence path.

## Implementation and validation

- Use RED-GREEN-REFACTOR for behavior changes. Add engine, serialization, controller,
  and widget regressions at the layer where each rule is owned.
- Cover legacy-data defaults and conversion, persistence round trips, safety
  precedence, stage caps and last-position loaded steps across S1/S2/S4/S5 and the
  20/35/60 windows, non-hinge slots matching normal training from advanced ladder
  states, frequency spacing, next-morning progression/regression, the stepped bike
  return, and automatic/manual hand-off.
- Run `dart format`, `flutter analyze`, and the complete `flutter test` suite. When the
  local runtime lacks Flutter, GitHub Actions is the authoritative validation and every
  failure must be fixed before merge.
- Bouldering regressions must cover same-day replacement, date/duration validation,
  serialization and backup inclusion, the capped duration/effort mapping, muscle-map
  history, no non-pull/cardio credit, and plan timing: yesterday updates an unlocked
  current plan, while bouldering after primary work leaves today fixed for tomorrow.
- Inspect `git diff --check`, the complete diff, and repository status before staging.
- The logger may keep the Android display awake only while its route is active and
  the app is resumed. Clear the platform flag on pause, detach, and dispose; a
  missing platform bridge must never block logging.
- Strength workouts persist a single active draft in the existing database meta
  table. Checkpoint the plan snapshot, completed sets, current inputs, and timer
  deadlines at user actions; await each logged-set checkpoint before allowing
  another submission. Offer same-day resume only while the original plan and
  safety gates still match. Never resubmit a final set already in the draft.
  Clear the draft after a successful session log or an explicit discard, and
  recognize a committed log on startup even if draft cleanup was interrupted.
  Do not request sensor permissions or battery-optimization exemptions merely
  to keep this manual logger alive in the background.

## GitHub delivery

- Work from a focused `agent/<description>` branch and commit only task-related files.
- Push the branch, open a pull request with rationale and validation details, and wait
  for required CI checks.
- Address every blocking review or CI finding, then squash-merge the pull request
  yourself. Do not leave the final merge to the user.
- Publish APK releases only from the resulting `main` push (or an explicit manual
  dispatch), never from the pull-request `closed` event; one merge must produce one
  release/build identity.
- Verify the merged `main` workflow and its APK release asset before reporting success.
