# implementation.md — decision log

Short-form log of non-obvious decisions, newest last. Spec references are to
`workout-app-design-v1.4.md` (content header says v1.2 — the §-numbering matches;
treat filename as canonical version).

## Session 2026-07-05 (spec review + fixes on the Flutter app)

1. **Pivoted mid-session from a fresh TypeScript build to the existing Flutter app.**
   `main` contained no code at session start (the Flutter implementation lives on
   `claude/flutter-android-app-0bih6p`, PR #1, never merged), so a TS rebuild was
   started before the real app was discovered. The TS scaffold was stashed, not
   committed; this branch is rebased onto the Flutter branch.

2. **Oura HRV/RHR bug — root cause is the sleep-route date window, not the fields.**
   `oura_client.dart` already read the correct fields (`average_hrv`,
   `lowest_heart_rate` exist only on `/v2/usercollection/sleep`; the daily_* routes
   carry scores only — verified against `docs/Oura-openapi-1.35.json`). But the
   sleep-periods route was queried with `start_date == end_date`, which misses the
   overnight period; daily_* routes tolerate it, which is why sleep score/readiness
   worked while HRV/RHR stayed empty. Fix: query `[date−1, date+1]` and pick the
   period whose `day` equals the target date, preferring `type == long_sleep`,
   else the longest. Also added `next_token` pagination (previously unpaginated).

3. **90-day snapshot backfill added (spec §10 "cache last 90 days").** Previously
   only today's snapshot was saved at check-in, so HRV/RHR baselines (§4.1, ≥14
   nights) stayed inactive for 2 weeks after connecting Oura. Backfill runs
   opportunistically once per day, fire-and-forget so check-in never blocks on it;
   manual-entry days are never overwritten (manual wins, §3.3).

4. **Pain flags now persist by rule, not by re-tapping the body map.** The engine
   substituted/reduced only when *today's* check-in tapped the region; on later
   days a sharp-flagged pattern came back at full load (frozen but unsubstituted),
   and the §7.2 scheduled-counter only ticked on tap days. Added
   `ExerciseState.painRegion` so the freeze itself carries enough info to keep
   applying the §7.1 table until the flag decays/clears. Severity can escalate
   (mild→sharp) while frozen but never soften from a tap — decay is by rule only.

5. **Mild-flag decay and sharp re-entry now actually run.** `advanceFlagState(...,
   sessionRanPainFree: true)` and `markPainReentryTestPassed` existed but were
   never called from the app. Wired both into `completeSession`: a pain-free
   session on the pattern decays a mild flag; a pain-free completed re-entry test
   auto-passes and resumes via §6.6 precedence (lower of detrain-adjusted vs.
   pre-pain −1 increment). Decision: auto-pass on pain-free completion instead of
   a separate confirmation dialog — the test set itself is the confirmation.

6. **Re-entry resume runs before progression evaluation** in `completeSession`,
   because `evaluateSession` stamps `lastTrainedDate = today` and would zero the
   detraining gap that §6.6 needs. Also added the missing `<10 days → 100%`
   branch to `_detrainPercent` (it silently returned 90% for any short gap).

7. **§6.5 deload parameters were never applied to the plan** — the rule key fired
   but sets/loads/RIR were emitted unchanged. Now applied per-exercise at plan
   assembly: load ×0.6 (rounded down to achievable), sets ×0.5 (floor, min 1),
   RIR ≥ 4. Applied per-exercise, not session-wide, since deload is per-pattern.

8. **RED technique sessions no longer advance the queue.** §5 Step 6 calls the
   technique session a *swap* ("the original queue item stays pending"), but
   completion credited the session type and moved the pointer. Added
   `SessionPlan.grantsQueueCredit` (serialized, defaults true for old traces).

9. **Detraining loads persist on completion** via
   `PlannedExercise.persistLoadOnCompletion`: previously the 90/80/70% ramp load
   existed only inside the day's plan, and the next session snapped back to the
   pre-break load (and the progress trigger would increment from the *old* load).
   Persisting at completion (not at plan time) so a skipped day doesn't cut the
   stored load. Not persisted when a RED 60% multiplier is also active.

10. **QUEUE_NEXT now fires only when the pick really is the pointer's type** with
    no hard floor force — it previously fired on every plan, making the (template)
    explanation claim "next in queue" for floor-forced and weekend-S6 picks.

11. **REHIT-finisher credit wired to a finish-dialog** on S2 extended
    (§2.1: S2 counts as intensity only if the finisher was done). The
    `rehitFinisherCompleted` parameter existed but no UI ever set it.

12. **§7.2 escalation enforced in the planner**: an escalated flag (>7 days sharp
    or radiating/numbness/tingling) removes the pattern from the plan outright
    until manually cleared; previously `isEscalated` was implemented but unused.

## Session 2026-07-05, later (merge-order rescue + APK update fix)

13. **PR #2's fixes were stranded off `main`.** PR #1 (flutter branch → main) was
    merged from `2cef43f`, *before* PR #2 landed on the flutter branch — so main
    never received the spec-review fixes. This branch re-merges
    `origin/claude/flutter-android-app-0bih6p` (which contains the PR #2 merge)
    into a main-based branch rather than cherry-picking, preserving history.

14. **"App not updating on the phone" diagnosis**: the pinned keystore
    (`android/app/debug.keystore`, PKCS12, alias `androiddebugkey`, verified with
    keytool) and the Gradle signing config are both correct. The installed APK
    predates the pinning commit and is signed with an ephemeral CI key — Android
    never accepts an update across signatures, so a **one-time uninstall +
    reinstall** is required; every later artifact updates cleanly. Additionally
    CI now passes `--build-number=${{ github.run_number }}` so each artifact has
    a strictly increasing versionCode (equal codes are legal but ambiguous;
    increasing codes make "did it update?" verifiable in Settings → App info).

## Session 2026-07-06 (warm-up protocol + ATG block emission)

15. **§2.5 warm-up protocol now emitted in plans**: 40/60/80 ramp (x8/x5/x3)
    before the session's first compound, one 60% x 5 feeder before every later
    loaded lift; `isWarmup` entries are excluded from the §8 completion
    denominator and from progression evaluation, and the logger stamps their
    sets `isWarmup`. Decisions: (a) substitutes get no warm-up — they onboard
    deliberately light per §7.1; (b) bodyweight/backpack steps get none — no
    meaningful percent-load; (c) a warm-up entry that rounds to >= the work
    load is dropped (very light prescriptions need no ramp).
16. **ATG block interpretation**: on S4 the block runs first and replaces the
    *ramp* only — each lift keeps its 60% feeder. The spec says the block
    "replaces general warm-up"; walking into 90 lb deadlifts with zero
    exercise-specific prep read as unsafe, so feeders stay.

17. **S5 direct arm work via the named-exercise registry, not new patterns.**
    DB curl / lateral raise / overhead triceps are `SubstituteExercise`-style
    named exercises with their own state tracks (single-DB achievable set,
    8–15 rep range) rather than new `MovementPattern` enum values — the enum
    drives serialization, pain mapping and recency logic, and arms don't need
    any of that machinery. Pattern assignment is deliberate for §7.1: curls →
    `coreGrip` (sharp elbow/wrist removes direct arm work), raises/triceps →
    `pushVertical` (sharp shoulder removes overhead). `ladderStepFor` is now
    registry-aware, which also fixes §7.1 substitutes incrementing on the
    wrong achievable-load set (bridge curls previously used the hinge
    ladder's 2-DB steps).

18. **§11.4 History charts, hand-rolled with CustomPaint** (no chart package —
    keeps the dependency surface flat): rolling-7-day floor rings
    (count/requirement, labeled, not color-alone), a 12-week calendar heat
    whose cell shade is a single-hue alpha ramp of completed work sets,
    per-pattern top-set sparklines (main-ladder tracks only; named accessories
    excluded to keep the panel to the six spec patterns), and a 28-day HRV
    sparkline. Theme-derived colors so light/dark both work.

## Documented deviations left as-is (deliberate, not bugs introduced today)

- **Both floors hard-forced**: the engine suppresses the intensity +100 rather
  than letting both score and resolving by precedence; same winner as spec rule
  §5-Step-3.5 in all cases (strength always outranks), but the trace omits
  `FLOOR_FORCE_INTENSITY`. Kept: behavior matches, only trace verbosity differs.
- **Leg-heavy escape hatch** requires *all* feasible candidates leg-heavy before
  cutting volume (spec's parenthetical reading); a floor-forced leg session after
  a leg day therefore runs at full volume. Spec is ambiguous here; kept.
- **Served cycle types stay scoreable** at lowest priority instead of being
  excluded from candidacy; harmless (they only win when nothing else is feasible).
- **S7 remains a primary candidate at slots ≥35 min** (spec limits it to <35);
  base 10 makes it effectively unreachable except in contrived states.
- ~~§2.5 warm-up protocol / ATG block not emitted~~ — fixed 2026-07-06 (entries 15–16).
- ~~S5 trains push/pull proxies instead of arms~~ — fixed 2026-07-06 (entry 17).
- **§2.6.4's "54 → 49 (uneven)" rounding example is unsatisfiable**: 50 (matched
  2×25) is achievable, ≤54, and >49, and §2.6.3 says uneven totals *join* the
  set. Round-down over the union yields 50. Tests assert 50; the spec example
  appears internally inconsistent.
- ~~History screen is a plain list~~ — fixed 2026-07-06 (entry 18).
- **Spec-internal tension**: a +15 recency boost can outrank S6's weekend base 60
  (50+15=65), contradicting §2.1's "S6 becomes top-ranked iff ALL hold". The
  numeric scoring (§5 Step 4, v1.1) is treated as authoritative.
