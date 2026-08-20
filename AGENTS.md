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
  not create a second stimulus-accounting path.
- The anatomical muscle-map geometry is pinned to the MIT-licensed upstream
  MuscleMap revision recorded in `THIRD_PARTY_NOTICES.md`. Regenerate only from
  that original source (not openGym's AGPL-converted JavaScript), preserve the
  notice, and keep untracked regions such as the lumbar area visually neutral
  rather than inventing stimulus credit.
- Exercise guides are original local vectors selected only through an explicit
  `PlannedExercise.visualId`. Never guess by name, let a substitution inherit an
  approximate visual, or copy exercise media whose redistribution license has not
  been verified.
- Prefer existing models, repositories, and engines over parallel state or duplicate
  rule paths. Avoid new dependencies unless they materially reduce risk or complexity.

## Medical and pain-safety invariants

- The app does not diagnose an injury, a herniated disc, or tissue healing. UI copy
  must describe symptoms, training modifications, and escalation actions without cure
  claims or medical certainty.
- Deterministic safety gates outrank readiness, weekly targets, manual session swaps,
  progression, and AI-generated explanations. The AI layer may never weaken them.
- While lower-back recovery mode is active, loaded hinge work and hinge progression
  stay blocked. Preserve the pre-recovery state for a graded return; merely completing
  a session must never unlock or advance it.
- Every strength plan in lower-back recovery mode must come from the closed
  low-lumbar-load catalogue. Normal weighted squat, unsupported row/press, loaded
  pull-up, L-sit, weighted-hang, and weighted-dip ladder state must never leak into
  the plan. Use the dedicated unweighted/assisted pull-up, supported press/row, ATG 1
  accessories, and symptom-gated hinge tracks instead.
- Recovery pull-ups carry no added load, stay at 4+ RIR, and cannot advance the normal
  pull-up ladder. Bodyweight recovery dips likewise cannot unlock loaded dip work.
- Back-extension recovery work advances only after recorded same-day and next-morning
  symptom tolerance. New/increasing radiating pain, numbness, tingling, weakness,
  saddle/genital sensory change, or bladder/bowel dysfunction blocks training and
  displays the fixed medical escalation guidance.
- A comeback prescription after a training pause must describe the currently
  emitted reduced load/target or easier difficulty. Never carry a stale
  `Load increased` milestone into a detraining-adjusted plan.
- Recovery exercises use conservative, pain-tolerated prescriptions and never train
  to failure. Do not represent a self-built apparatus as inspected or certified.
- Keep the existing pain-freeze, substitution, and escalation behavior working for
  users who do not activate the dedicated recovery mode.

## Implementation and validation

- Use RED-GREEN-REFACTOR for behavior changes. Add engine, serialization, controller,
  and widget regressions at the layer where each rule is owned.
- Cover legacy-data defaults, persistence round trips, safety precedence, no-loaded-
  hinge guarantees, the complete recovery strength catalogue across S1/S2/S4/S5,
  advanced normal ladder states, frequency spacing, symptom-response
  progression/regression, and recovery-mode exit/re-entry.
- Run `dart format`, `flutter analyze`, and the complete `flutter test` suite. When the
  local runtime lacks Flutter, GitHub Actions is the authoritative validation and every
  failure must be fixed before merge.
- Inspect `git diff --check`, the complete diff, and repository status before staging.
- The logger may keep the Android display awake only while its route is active and
  the app is resumed. Clear the platform flag on pause, detach, and dispose; a
  missing platform bridge must never block logging.

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
