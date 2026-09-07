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
- Manually logged bouldering is external activity, not a MorningCoach prescription.
  Duration and perceived effort feed one conservative, capped pull/grip stimulus
  adapter for recommendation and muscle-map history, but must never complete the
  daily plan, advance the queue or an exercise ladder, grant cardio/leg credit, or
  progress lower-back recovery stages. The annual activity heatmap includes its
  actual duration; the category-only Classic heatmap remains unchanged.
- The time-allocation chart uses a fixed colorblind-safe categorical palette and
  matching label swatches. Keep segment widths proportional to elapsed time; do not
  replace the category colors with adjacent theme roles or describe it as progress.
- The anatomical muscle-map geometry is pinned to the MIT-licensed upstream
  MuscleMap revision recorded in `THIRD_PARTY_NOTICES.md`. Regenerate only from
  that original source (not openGym's AGPL-converted JavaScript), preserve the
  notice, and keep untracked regions such as the lumbar area visually neutral
  rather than inventing stimulus credit.
- Exercise guides stream only explicitly mapped ExerciseDB V1 animations from the
  official `static.exercisedb.dev` CDN. Keep raw exercise media out of the repository
  and APK, retain the in-card ExerciseDB/AscendAPI and Gym visual attribution, and
  preserve the release Android `INTERNET` permission. Never guess by name or let a
  substitution inherit a demo for different equipment or motion; unsupported variants
  display no graphic.
- Normal strength preparation includes jumping jacks with a pain-aware fallback.
  Recovery v2 has its own comfortable, non-impact preparation: no jumping,
  walking workout entries, forced bending, or end-range backbends.
- Prefer existing repositories and pure engines. New fields must have safe defaults.

## Medical and pain-safety invariants

- The app does not diagnose a disc injury or certify healing or equipment safety.
  Assessment is a user-reported event, not an app-issued clearance.
- Recovery v2 is authoritative. Legacy extension-stage fields remain readable for
  backups and history but must never prescribe or advance current recovery work.
- Four phases advance only explicitly. Complete small exposures, subsequent-morning
  feedback and improving daily function are required for increases. These are
  conservative product rules, not validated clinical milestones.
- New or resolved neurological symptoms block training until a current symptom
  check and explicitly recorded clinical assessment. New weakness, saddle numbness
  or bladder/bowel changes display urgent assessment guidance.
- Worsening resets to flare-up and pauses provoking movements, even at minimum dose.
  Missing feedback, incomplete work, higher effort or an unchanged functional
  trend cannot automatically increase loads. Change only one variable at a time.
- Recovery plans use independent `recovery:v2:` doses at 4+ RIR. No ordinary loaded
  ladder, stimulus deficit, readiness upgrade, or manual session swap may bypass
  these restrictions. No automatic extension-to-deadlift progression.
- Supported DB exercises require an explicit smallest achievable initial load;
  do not prescribe fictional unloaded DB work to unlock initialization. Subsequent
  increases need tolerance credit. Changing selections retains pending feedback.
- Recovery exit needs tolerated return exercises. A normal hinge or bridge resumes
  at the reviewed recovery load, never a pre-injury record or ladder rung.
- Extensions are optional after assessment; loaded hip re-entry also requires
  assessment and the hinge-return phase. Exiting mode is an explicit reviewed step.
- Stationary cycling is paused on activation/flare: Zone 2, REHIT, 4×4, finishers
  and nudges must respect this at planning and action boundaries. Retrospective
  activity remains loggable; history is not rewritten. No automatic cardio restart.
- The separate deadlift-alternative preference replaces canonical hinge work with
  floor glute bridges and sliding hamstring curls. Independent named tracks start
  without deadlift load transfer and cannot bypass existing pain flags. No exercise
  is described as risk-free. Travel uses bodyweight bridge/heel-dig variants.
- Preserve ordinary pain-freeze, detraining and substitution behavior outside recovery.
  Display comeback adjustments using the actual emitted load.
- A continuous Zone 2 completion may exceed prescription up to the existing
  24-hour input bound; interval protocols retain their dose cap.
- Home-screen retrospective Zone 2 rides are unplanned, supplemental records:
  preserve actual dose and normal aerobic credit, without completing/replacing the
  primary plan or advancing the queue. No prospective duration estimate is recorded
  for unplanned activity. Reuse the existing cardio validation and persistence path.

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
- Bouldering regressions must cover same-day replacement, date/duration validation,
  serialization and backup inclusion, the capped duration/effort mapping, muscle-map
  history, no non-pull/cardio credit, and plan timing: yesterday updates an unlocked
  current plan, while bouldering after primary work leaves today fixed for tomorrow.
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
