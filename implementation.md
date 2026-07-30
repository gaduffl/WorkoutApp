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

19. **§12 travel mode: bodyweight resolution without state churn.** A settings
    toggle maps each pattern to a fixed bodyweight variant (split squat, SL-RDL,
    push-up, pike push-up, pull-up, table row, plank) at 8–15 reps. DB-only arm
    accessories drop out of S5 entirely. Completed travel sessions count toward
    queue + floor and stamp `lastTrained` (so §6.6 detraining doesn't misfire on
    return) but never advance the load-based state machine — bodyweight rep
    counts say nothing about dumbbell loads.

## Session 2026-07-06, later (user-reported 35-min overflow + notifications)

20. **User-reported bug: 60-min sessions offered "full tier" in a 35-min slot.**
    `tierForTime` was global (35 -> full for every session), so S2/S4 swaps in a
    35-min slot kept 4 compounds x3 AND the accessory block AND warm-ups (~45+
    min). §5 Step 7's "60 -> 35" now actually drops the accessory block for
    natively-60-minute sessions at full tier (superset pairs kept, 12 work sets
    ~= 32 min with warm-ups); the swap card labels these "compressed to 35 min".

21. **§3.1 + §12 notifications via flutter_local_notifications (opt-in).**
    Daily wake-window nudge + cutoff-hour "no plan yet" reminder, both
    inexact-scheduled (no exact-alarm permission needed) and rescheduled on app
    open / settings change / check-in (a check-in pushes today's cutoff nudge to
    tomorrow). tz.local is resolved by matching the device's UTC offset against
    the tz database instead of adding a platform plugin - re-run on every
    schedule call so DST self-corrects. All service methods swallow platform
    errors: notifications are polish and must never break check-in or tests.
    Android: POST_NOTIFICATIONS + BOOT_COMPLETED receivers, core-library
    desugaring enabled (plugin requirement).

## Session 2026-07-06, later still (user-reported logger bugs)

22. **Weight stepper now follows the PowerBlock steps (§2.6), not a flat ±5.**
    Each work/warm-up `PlannedExercise` carries `loadSteps` (the exercise's
    achievable dumbbell totals: single-DB union or matched/uneven 2-DB set).
    The logger's +/- snaps to the next/prev entry in that list; backpack/free
    entries fall back to ±5, bodyweight hides the stepper. Weight is tracked
    per exercise so interleaved superset sets keep independent loads.

23. **Supersets are now explicit and toggleable (§2.5).** Templates order
    compounds as antagonist pairs, so the engine pairs consecutive compound
    WORK exercises into `supersetGroup` (0,0,1,1,...); accessories and any odd
    remainder stay straight. Today shows an A/B badge; the logger builds its
    play order from the groups (warm up both partners, then alternate work
    sets, rest after each pair) and offers a "Superset mode" switch that
    rebuilds the remaining order as straight sets (rest after every set).
    Toggling mid-session preserves already-logged sets by (exIdx:setNumber).

24. **Incidental fix:** the old logger picked rest duration via
    `repRange.low <= 10`, which is true for both compounds (6) and accessories
    (8) — so every rest was 90 s. Now keyed on `PatternClass.compound`
    (90 s compound / 60 s accessory). The body is also scrollable now, so
    small screens / large font scales don't overflow.

## Session 2026-07-07 (more hands-on-testing fixes)

25. **Rest timer resets when a set is logged early.** Logging always cancels
    the running rest countdown first, then starts a fresh one only if the
    just-logged set is followed by rest. Previously an early "Log set"
    (superset partner or next straight set) left the old countdown running.

26. **Logging the final set auto-finishes the workout.** `_logSet` detects the
    last step and calls `_finish()` itself; the primary button reads
    "Log set & finish" on the last set, and "Finish early" only appears before
    then. Removed the separate always-on finish button.

27. **Cardio sessions are loggable (and no longer crash the logger).** S3/S6/S7
    are cardio-only, so their plan carries zero exercises — pushing the set
    logger crashed on an empty step list. Today now shows "Mark {session} done"
    for empty-exercise plans and records it via `logCardioSession` (empty set
    list → completionRatio 1.0 → counts + credits; queue advances only for
    cycle types). The §2.1/§12 second-session REHIT offer is now a real
    "Log REHIT" button (credits intensity, never moves the pointer).

28. **Home and Today reflect a completed day.** The controller tracks the
    trailing 3 days of logs; `sessionDoneToday` drives a "Session complete"
    card on Today (Start button + swap options hidden) and a green
    "Today's session is done" state on Home.

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

## Session 2026-07-07, later (OneDrive backup/sync)

29. **OneDrive backup via manual PKCE OAuth, not the MSAL SDK.** The Entra app
    is a public client ("Mobile and desktop applications" platform); the app
    reuses the existing Oura pattern (`app_links` custom-scheme redirect +
    `url_launcher` + manual token exchange) rather than pulling in a heavy
    MSAL/AAD plugin. Client id is a compile-time constant; **no client secret**
    is stored — PKCE (S256, `package:crypto`) protects the code exchange.
    Redirect `morningcoach://onedrive-callback`; scopes
    `Files.ReadWrite.AppFolder offline_access User.Read` so the app only ever
    sees its own OneDrive folder.
30. **Whole-DB JSON blob backup.** `AppDatabase.exportAll/importAll` dump and
    restore every row of every table (the schema is already JSON-blob-per-row),
    wrapped in an envelope `{app, schema, exportedAt, data}` uploaded to
    `/approot/morningcoach-backup.json`. `importAll` runs in one transaction and
    ignores unknown tables/columns so a newer backup can't corrupt an older
    schema. Restore preserves *this device's* OneDrive tokens (re-applied after
    import) so a restore never signs you out.
31. **Auto-backup** (opt-in) fires best-effort after each completed session;
    all OneDrive failures surface via `oneDriveError` and never block training
    flow. Access token refreshes 1 min early via the stored refresh token.

32. **OneDrive redirect switched to the MSAL scheme.** The custom
    `morningcoach://onedrive-callback` was rejected by Entra ("invalid
    redirect_uri") because the "Mobile and desktop applications" platform only
    accepts the MSAL-format redirect, not arbitrary custom schemes. Changed to
    `msal29d50c5e-…://auth` (registerable via that platform's one-click
    checkbox); AndroidManifest intent-filter and the link handler updated to
    the new scheme/host.

## Session 2026-07-28 (reset-day, dips, manual progression override)

33. **"Reset today" = dated-row delete + progression/queue rollback, airtight to
    one day.** `Repository.deleteDayData` deletes only rows whose date column
    `LIKE 'YYYY-MM-DD%'` (new `AppDatabase.deleteByDatePrefix`) across
    `check_ins`/`recovery_snapshots`/`decision_traces`/`session_logs`; the full
    `YYYY-MM-DD` prefix means a same-day-of-month row in another month never
    matches. Because a completed session already mutated progression + queue,
    deleting rows alone wouldn't undo the day — so a **day-start snapshot**
    (`meta:day_start_snapshot`, keyed by its own date) is persisted the first
    time each day is touched (`_ensureDayStartSnapshot` at the top of
    `submitCheckIn`). `resetDay` restores that snapshot's exercise-states +
    queue, deletes any track that only came into existence today (absent from
    the snapshot), then wipes today's rows and the snapshot itself. A stale
    snapshot from a previous day is treated as absent. Confirm dialog required
    before it runs (destructive, irreversible). Tests in
    `app_controller_reset_day_test.dart` prove other days survive.
34. **Dips replace the S5 overhead-triceps isolation, modeled single-DB.** Yes,
    dips make sense — they're a compound triceps/lower-chest push and a strict
    upgrade over the overhead-extension isolation for the S5 arm slot.
    Bodyweight dips are *not* used directly because load is uncontrollable
    (§2.6 the whole app is built on quantized load steps). Instead the dip is a
    **weighted dip with a DB held between the feet** (`dumbbells: 1`), which is
    behaviorally identical to the isolation it replaces — same single-DB
    achievable-load ladder, same PowerBlock step granularity — so the
    progression/pain engines needed zero behavioral change, only the
    slug/name/muscle-map rename (`sub:pushVertical:dip`, primary = triceps).
    Travel/bodyweight variant is a bench/chair dip.
35. **Manual progression override (`setPatternProgression`).** Settings can jump
    any compound pattern straight to a chosen ladder step (e.g. push-ups far
    past the entry step). It clones the state to a clean `PROGRESS` at the new
    step — clears deload/hold/micro bookkeeping, resets load to the step's
    achievable floor (or a user-entered start load, rounded down to an
    achievable total; backpack steps take the raw load) — and stamps
    `lastPrescriptionChange` "Set manually to …". Index is clamped to the
    ladder bounds.
36. **Manual-load memory is reference-only.** The override dialog now shows the
    load the user last typed *for that pattern+level* ("You last entered N lb
    for this level"), persisted in `meta:manual_load_entries` keyed by
    `<pattern>:<ladderIndex>` and recorded only when a non-blank load is
    entered. Deliberately **not** pre-filled into the field: a blank field
    still means "auto", so the remembered value is never silently re-applied —
    it is purely informational so the user can recall what they set before.
37. **CI publish: harden APK release upload against a GitHub race.** The
    single-call `gh release create <tag> <asset>` intermittently 404'd on
    `uploads.github.com` (the freshly-created release hadn't propagated),
    failing the job and leaving an empty release. Split into create-then-upload
    with a bounded retry loop. Also added a manual `release-cleanup.yml`
    (`workflow_dispatch`, tag input) to prune stray debug prereleases —
    used to remove the empty `debug-aa91c96` release the race left behind.

## Session 2026-07-29 (logger view polish)

38. **Logger view: four ergonomics changes.**
    - **Warm-up timer.** Minute-based warm-ups (general prep + S4 ATG block,
      `metric == minutes`) now carry a mm:ss countdown (start/pause/reset) so
      the timed schedule in their instruction is easy to follow. It is a guide
      only — it never changes what gets logged; loaded-rep ramp/feeder
      warm-ups are unaffected (they keep their rep steppers + 45 s rest).
    - **Default value = top of range.** Rep work now prefills the *top* of the
      target range instead of the bottom (`targetRange.$2`), so the user rarely
      steps it up. Timed holds still use their progression-driven
      `suggestedValue`.
    - **Vertical daily-progress bar.** A thin bar down the left edge fills
      top→bottom as `loggedSteps / totalSteps`. Built from a
      `FractionallySizedBox` (not a `LinearProgressIndicator`, so it never
      collides with the ProgressionPanel's indicator in tests).
    - **Layout: timer + pain above the fold.** The interactive controls
      (steppers, timer, RIR, pain) were reordered to sit directly under the
      target line, with the bulky reference copy (instruction, ProgressionPanel)
      moved below them. The log/finish buttons stay pinned. A single scroll
      view is kept, so the existing narrow-phone overflow guard still holds.
39. **ProgressionPanel header wrapped.** On the Today card the panel renders
    inside a `ListTile` subtitle squeezed by the trailing "RIR n"; its header
    text lacked a `Flexible`, so it overflowed ~16 px. Wrapped in `Expanded`.
40. **Second-REHIT nudge is now its own opt-in.** The later-day "add a short
    REHIT" push nudge already existed end-to-end (eligibility engine →
    `suggestedNudgeTime` → `syncSecondRehitNudge`) but was gated by the shared
    `notificationsEnabled` flag with no dedicated control. Added
    `UserSettings.secondRehitNudgeEnabled` (opt-in, its own Settings switch
    with its own permission request) and switched the sync's `enabled` gate to
    it — so the user can take just this reminder, or just the morning ones,
    independently.
41. **APK filename carries the version.** The published debug APK is now named
    `MorningCoach-v<versionName>-build<runNumber>-debug.apk` (versionName from
    pubspec, build number = the CI run number / versionCode), and the release
    title/notes include the same, so a downloaded file is self-identifying.
