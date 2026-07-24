# Progression Targets and Visibility Implementation Plan

> **For Hermes:** Execute with RED-GREEN-REFACTOR and an independent pre-merge review.

**Goal:** Start the personalized Plank prescription at an established 60-second target, make progression state and distance to the next difficulty visible, clearly call out prescription changes since the previous exercise exposure, and repair the material state-machine defects found by the progression audit.

**Architecture:** Persist an optional per-track `currentTargetValue` plus the most recent prescription-change message in `ExerciseState`. The progression engine owns target initialization, transitions, rollback/deload/detraining, and a pure presentation descriptor. `DecisionEngine` snapshots that descriptor into each `PlannedExercise`, so Today, Logger, restored traces, and History render the same authoritative state without recomputing it in widgets. Legacy states remain readable: Plank migrates to the user's established 60-second target; other timed steps default to their lower bound.

**Tech Stack:** Flutter/Dart, Provider, existing JSON/database repositories, GitHub Actions.

---

## Acceptance criteria

1. A legacy/new Plank state is prescribed at exactly 60 seconds, and Logger opens each Plank set at 60 seconds.
2. Completing all prescribed 60-second Plank sets at RIR 2+ advances one real progression milestone. The next plan clearly says what changed and shows progress toward L-sit.
3. A visible indicator on Today and Logger shows current target/stage, fraction to the next ladder difficulty, and the next milestone.
4. When load, target, micro-stage, or exercise difficulty changed after the last eligible exposure, the next plan displays a prominent `Progressed since last time` message with before/after details. An unchanged exposure clears stale change messaging.
5. Timed targets persist through JSON/database reload and old JSON remains readable.
6. Timed undershoot, detraining, regression, and deload modify the timed prescription rather than operating on zero load.
7. Regression reverses micro-stages before lowering load. Pain re-entry takes precedence over deload so the combined state cannot deadlock.
8. Backpack-loaded steps stop adding weight indefinitely: the configured single-dumbbell maximum acts as the automatic-load cap, after which normal micro-stage/ladder progression resumes.
9. History exposes core/grip timed progression and prescription-change events instead of filtering them out as zero-weight work.
10. Travel, warm-up, partial, YELLOW/RED, and pain-frozen work cannot advance progression.

## Task 1: Encode failing model and state-machine tests

**Files:**
- Modify: `test/engine/progression_engine_test.dart`
- Modify: `test/data/serializers_test.dart`

**Tests:**
- Legacy Plank resolves to `currentTargetValue == 60`.
- A successful 60-second Plank advances stage 0 → 1 and records a change message.
- An unchanged middle-zone exposure clears an old message.
- Timed rollback reduces stage before target; timed deload/detraining/undershoot change `currentTargetValue`.
- Loaded rollback removes an active micro-stage before lowering load.
- Pending pain re-entry resolves before deload.
- Backpack load at configured maximum advances a micro-stage instead of exceeding the maximum.
- New state fields round-trip; missing legacy fields use safe null defaults.

Run focused tests in CI and verify they fail for missing fields/behavior before production code.

## Task 2: Implement persisted target and transition metadata

**Files:**
- Modify: `lib/models/exercise_state.dart`
- Modify: `lib/data/serializers.dart`
- Modify: `lib/models/ladders.dart`
- Modify: `lib/engine/progression_engine.dart`

**Implementation:**
- Add nullable `currentTargetValue` and `lastPrescriptionChange` fields, clone and serialize them.
- Expand Plank's supported range to `(20, 60)` but seed its personalized current target at 60.
- Resolve a timed target within the active step range; increment non-Plank timed targets by 5 seconds until the cap.
- At the cap, use existing micro-stages and then advance the ladder.
- Reset target to the new step's lower bound on ladder advance; restore the preceding step's cap on reverse transition.
- Make target changes participate in undershoot, deload, detraining, and pain resume.
- Generate deterministic change messages only when the actual next prescription changed.
- Fix micro-stage-first regression, pain-re-entry precedence, and backpack cap behavior.

## Task 3: Snapshot authoritative progression UI metadata into plans

**Files:**
- Modify: `lib/models/plan.dart`
- Modify: `lib/data/serializers.dart`
- Modify: `lib/engine/decision_engine.dart`
- Modify: `test/engine/decision_engine_test.dart`
- Modify: `test/data/serializers_test.dart`

**Fields on `PlannedExercise`:**
- `suggestedValue`
- `progressionFraction`
- `progressionLabel`
- `nextProgressionLabel`
- `prescriptionChange`

**Tests:**
- Plank plan uses 60 seconds, exposes a bounded indicator fraction, and names the next milestone/difficulty.
- A stage-advanced state snapshots its persisted change message.
- Plan serialization round-trips all fields; legacy plans default safely.
- Recovery/travel/warm-up entries do not advertise advancement they cannot earn.

## Task 4: Add Today and Logger progress UX

**Files:**
- Modify: `lib/ui/screens/today_screen.dart`
- Modify: `lib/ui/screens/logger_screen.dart`
- Modify: `test/ui/today_screen_rehit_test.dart`
- Modify: `test/ui/logger_screen_test.dart`

**UI:**
- Add a reusable compact progression panel for progression-eligible work: linear indicator, current label, next milestone, and difficulty level.
- Show a highlighted `Progressed since last time` banner when `prescriptionChange` is present.
- Initialize metric input from `suggestedValue`, clamped to the target range, instead of always using the lower bound.
- Preserve manual ±5-second adjustments.

**Widget tests:**
- Today shows Plank `60 seconds`, progress to L-sit, and changed-prescription copy.
- Logger starts at 60, renders the same progress, and does not overflow on a narrow phone.
- Legacy plans without metadata retain current behavior.

## Task 5: Add core/grip progression to History

**Files:**
- Modify: `lib/ui/screens/history_screen.dart`
- Modify: `lib/ui/view_models/history_feedback_view_model.dart` if aggregation belongs there
- Modify: `test/ui/history_screen_test.dart`

**Behavior:**
- Include core/grip in progression selection.
- Plot timed values in seconds rather than discarding zero-weight sets.
- Show exercise/difficulty changes as labeled events or summary rows.
- Keep existing load charts unchanged for weighted patterns.

## Task 6: Controller integration and persistence regression

**Files:**
- Modify/create focused test under `test/state/`
- Modify `lib/state/app_controller.dart` only where non-eligible completion must clear stale change metadata or target persistence requires it.

**Scenario:**
- Seed/load Plank at 60 seconds.
- Complete the planned 60-second sets.
- Persist and reinitialize the controller.
- Generate the next plan and assert stage progress, same 60-second target, next milestone, and visible change metadata.
- Assert partial/YELLOW/pain work does not advance.

## Task 7: Verify, review, and deliver

1. `git diff --check` and inspect all changed files.
2. Push branch and run GitHub Actions: `flutter analyze`, full `flutter test`, debug APK build.
3. Independently review correctness, migration safety, state-machine ordering, UI overflow/accessibility, and test quality.
4. Fix every blocking review/CI finding and rerun.
5. Mark PR ready, squash-merge, then verify the merged-main workflow and `MorningCoach-debug.apk` release asset.
