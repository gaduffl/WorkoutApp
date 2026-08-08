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
- Back-extension recovery work advances only after recorded same-day and next-morning
  symptom tolerance. New/increasing radiating pain, numbness, tingling, weakness,
  saddle/genital sensory change, or bladder/bowel dysfunction blocks training and
  displays the fixed medical escalation guidance.
- Recovery exercises use conservative, pain-tolerated prescriptions and never train
  to failure. Do not represent a self-built apparatus as inspected or certified.
- Keep the existing pain-freeze, substitution, and escalation behavior working for
  users who do not activate the dedicated recovery mode.

## Implementation and validation

- Use RED-GREEN-REFACTOR for behavior changes. Add engine, serialization, controller,
  and widget regressions at the layer where each rule is owned.
- Cover legacy-data defaults, persistence round trips, safety precedence, no-loaded-
  hinge guarantees, frequency spacing, symptom-response progression/regression, and
  recovery-mode exit/re-entry.
- Run `dart format`, `flutter analyze`, and the complete `flutter test` suite. When the
  local runtime lacks Flutter, GitHub Actions is the authoritative validation and every
  failure must be fixed before merge.
- Inspect `git diff --check`, the complete diff, and repository status before staging.

## GitHub delivery

- Work from a focused `agent/<description>` branch and commit only task-related files.
- Push the branch, open a pull request with rationale and validation details, and wait
  for required CI checks.
- Address every blocking review or CI finding, then squash-merge the pull request
  yourself. Do not leave the final merge to the user.
- Verify the merged `main` workflow and its APK release asset before reporting success.
