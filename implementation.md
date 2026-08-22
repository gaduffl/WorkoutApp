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
42. **35-minute sessions genuinely overran their window (three defects).**
    Reported: a 35-min slot advertised "compressed" but emitted the 60-min S4.
    Reproduced with the real engine — at 35 min S4 emitted 4 compounds × 3 =
    **12 work sets**, identical to the 60-min plan minus one plank.
    - **(A) Compression now cuts volume, not just the accessory block.**
      §5 Step 7's "60 → 35" only dropped accessories; every primary pair kept
      its 3 hard sets, so a 35-minute slot carried the entire 60-minute
      compound workload. `setsFor(..., timeCompressed:)` now resolves the
      *compressed* set counts (2) while `slotsForTier` still keeps all primary
      superset pairs. S4 @ 35 min: 12 → 8 work sets.
    - **(B) The duration model was blind to unilateral work.** `LadderStep`
      already knew `unilateral`, but it was only consumed for uneven-pair load
      resolution and never reached `PlannedExercise` or the estimator, which
      charged a flat 45 s per set. A per-side prescription is written per side,
      so one logged set is two working bouts. Added `PlannedExercise.unilateral`
      (plumbed from the step, serialized with a legacy-false default) and a
      side factor in the estimator. Also flagged the five single-DB one-arm
      compound steps that were missing `unilateral` — safe for loads, because
      that flag only alters *2-DB* uneven-pair resolution. Honest estimates
      also let the existing budgeter trim on its own when a slot is too small.
    - **(C) The plan no longer mislabels itself.** 35 min resolves to
      `SessionTier.full`, so tier alone cannot distinguish "full 35-min
      session" from "60-min session squeezed into 35". Added
      `SessionPlan.timeCompressed` (via the shared `isTimeCompressedSession`
      helper, replacing two subtly different inline conditions) and Today now
      shows "compressed to fit" instead of "full tier".

## Session 2026-08-03 (training-time analytics + rest-day REHIT reminder)

43. **Timing is captured as raw observations, never as derived metrics.**
    Persisted: `SetLog.startedAt` + `plannedRestSecondsBefore` per set, and
    `SessionLog.timings` (`startedAt`, exact `elapsedSeconds`, and the
    `plannedDurationMinutes` the planner predicted for the plan that was
    actually run). Everything else — work/rest split, density, estimate bias,
    latencies — is recalculated by `AnalyticsEngine` on read. Redefining a
    metric therefore never requires rewriting history. `durationMinutes` is
    left untouched so no existing consumer changes behavior; the exact
    seconds sit beside it, which matters for an 8:40 REHIT preset that the
    whole-minute field renders as "8".
44. **Prescribed rest is the only defensible work/rest boundary.** The app
    cannot observe when the user *stops* resting, so a set's cycle
    (activation → submission) is split into `min(cycle, prescribedRest)` and
    the remainder, and the remainder is named `activeSecondsEstimate` — it is
    setup + execution + any rest overrun, and the naming says so rather than
    implying time-under-tension. Session time no logged step accounts for is
    reported separately as "unaccounted" instead of being smeared over the
    steps; the four buckets sum exactly to elapsed time.
45. **A day-level event timeline (`analytics_events`, schema v1→v2).** Session
    logs cannot answer "how long from check-in to actually starting" or "how
    long from the app suggesting a REHIT to the REHIT happening", so
    check-in / plan-generated / session-started / session-completed /
    REHIT-suggested / nudge-scheduled / REHIT-completed are appended as
    timestamped events. Milestone events are once-per-local-day, so
    "suggested at" is the first such decision rather than the most recent
    re-evaluation. Writes are swallowed on failure — analytics is observation,
    never a precondition for training — and the table joins the OneDrive
    backup and "Reset day"'s per-day delete.
46. **Rest-day REHIT reminder gates exactly like the second-session one,
    except for the day shape.** `RestDayRehitEngine` reuses the same
    `HighIntensitySafetyStatus` (48-hour intensity window, contraindicating
    pain, escalation, deload, travel) plus the rolling high-intensity target,
    and adds "nothing logged today" where the existing engine requires a
    completed first session. The two are mutually exclusive by construction.
    The once-per-day scheduling/marker machinery was generalized to
    `DailyNudgeEligibility` rather than duplicated; the old
    `secondRehitNudge*` names remain as typedefs/wrappers.
47. **A missing check-in blocks logging, not the reminder.** The commonest
    untrained day has no check-in at all, so requiring GREEN readiness would
    silence the reminder precisely when it is wanted. A no-check-in day is
    therefore still eligible, and the notification asks for a check-in first
    ("Check in first so the app can confirm today is a good day for it").
    The *logging* path is stricter: `canLogRestDayRehit` additionally requires
    a check-in on file, so `logCardioSession`'s new plan-less opening never
    records high-intensity work without a readiness decision, and the Today
    card is hidden in that state.
48. **"Fits my schedule" is learned, not configured.** `ScheduleFitEngine`
    derives per-weekday median start times from the trailing 56 days
    (2+ same-weekday samples, else 3+ overall, else a 17:00 fallback) and
    proposes today's slot, pushed to at least 45 minutes out (rounded up to a
    quarter hour) and clamped into the user's earliest/latest hours; a slot
    that cannot fit before the cutoff returns null rather than being shoved
    into the evening. `ScheduleSlot.source` travels with the result so the
    reminder claims "the time you usually train" only when that is true.
    Start times come from `SessionLog.startedAtOrNull`, which refuses to
    invent an hour for date-only legacy rows.
49. **Habit history is read into its own list.** `_scheduleLogs` (56 days) is
    separate from `_recentLogs` (7 days) so that widening the window for
    schedule learning cannot silently change what the recovery, ledger, or
    queue logic sees.
50. **Insights screen answers "what should the app change", not "how fit am
    I".** History keeps stimulus and progression; the new screen is time only:
    session length vs. plan estimate per session type (with a median *signed*
    bias, suppressed below three sessions as inconclusive), where the time
    goes, per-exercise cost per set, observed training rhythm by weekday,
    the REHIT suggested→nudged→done funnel with its latencies, and
    consistency. Plain Material, no chart package — same flat-dependency rule
    as the §11.4 charts.

## Session 2026-08-08 (lower-back recovery mode)

51. **Recovery state is persisted inside `UserSettings`, but only dedicated
    controller methods mutate it.** This keeps backup/import compatibility and
    lets old settings default to an inactive mode, while preventing a stale
    Settings draft from overwriting a same-day or next-morning response.
52. **The normal hinge track is never repurposed for recovery work.** The mode
    snapshots its load/ladder state and emits a distinct
    `recovery:lower_back:back_extension` track with progression disabled.
    Non-due days use the existing bridge-hamstring-curl substitute. Therefore
    neither an extension log nor a substitute can advance loaded deadlifts.
53. **Dose progression requires two observations across time.** A completed
    exposure saves same-day better/same/worse and becomes pending. A response
    on a later calendar day is mandatory; two consecutive non-worse pairs
    unlock one small dose step. A worse response regresses the stage/dose.
54. **Frequency and return are hard engine gates.** Recovery work is limited
    to two rolling-seven-day exposures, at least 48 hours apart. The final
    stage is two tolerated `1 × 8` elevated-start hinge exposures at an
    achievable load no higher than 50% of the pre-mode load; that performed
    load becomes the normal hinge baseline on automatic completion.
55. **Medical boundaries are fixed product copy.** Activation refuses to
    proceed unless the user denies neurological/emergency warning signs, the
    logger repeats the stop/escalate instruction, and the mode never labels a
    diagnosis, tissue healing, cure, or a self-built apparatus as certified.

## Session 2026-08-10 (low-lumbar-load recovery strength catalogue)

56. **Recovery mode owns a closed strength-slot catalogue across S1/S2/S4/S5.**
    Filtering only `MovementPattern.hinge` allowed an advanced squat, standing
    press, unsupported row, weighted pull-up, or demanding core ladder step to
    survive. Plan scoring, pain feasibility, travel resolution, and final
    assembly now consume the same recovery slots, so no separate UI filter can
    drift from the engine decision.
57. **Original session identity and queue semantics remain intact.** Lower and
    full-body slots become symptom-gated hinge work plus pull/ATG-1 work; upper
    becomes supported press/row plus unweighted pull and pump work; S5 gains the
    unweighted pull while dropping its general core ladder and loaded dip. The
    plan title makes the substitution visible without pretending that a lower
    workout was performed normally.
58. **Recovery pull-ups and dips have dedicated substitute tracks.** Pull-ups
    are bodyweight/assisted, fixed at 4+ RIR, and progression-ineligible; dips
    are bodyweight-only and cannot advance the normal loaded-dip state.
    Chest-supported rows also use a dedicated track, while floor press, curls,
    and lateral raises reuse their existing explicit tracks and muscle maps.
59. **Advanced normal ladder state is treated as hostile test input.** Engine
    regressions force every strength family with the ordinary ladders at their
    highest or loaded steps, then assert that the emitted recovery plan contains
    none of their names and only work at 3+ RIR (4+ for pull-ups/hinge work).
60. **A squash merge has exactly one APK publishing trigger.** Pull-request
    validation still runs on open, synchronize, and reopen, but `closed` no longer
    launches a second post-merge workflow. The `main` push is the sole automatic
    publisher (with manual dispatch retained for recovery), preventing two CI run
    numbers and two APK filenames from sharing one commit-tagged release.

## Session 2026-08-19 (history and in-workout visual context)

61. **Annual activity heat uses stable minute bins, not personal quartiles.**
    History loads 371 days to render 53 complete Monday-first week columns and
    assigns `<10`, `10–19`, `20–34`, and `35+` minute levels from the best
    available elapsed seconds. A later workout cannot recolor an older day by
    shifting a percentile boundary. Tapping a trained day shows its actual
    sessions and dose. The former 12-week strength / Zone 2 / VO₂-REHIT grid
    remains intact behind the persisted, legacy-safe `Classic heatmap` toggle.
62. **The muscle picture is a projection, never a new training model.** Its
    28-day view normalizes the existing `TrainingStatus` dose against each
    target maximum; Recency reads `daysSinceLastStimulus` and explicitly says
    it is not a fatigue score; Today applies the same `ExerciseMuscleMap` to
    qualifying planned sets. The original MorningCoach painter uses the nine
    existing major-muscle groups and adds no diagnostic or recovery claim.
63. **Exercise visuals require an explicit resolved-plan identifier.** A
    curated set of original Dart vector start/finish guides is attached at the
    ladder, named-substitute, travel-resolution, or dedicated recovery source.
    `PlannedExercise.visualId` is persisted with a null legacy default. Logger
    never performs fuzzy name lookup, so advanced variants and unknown imports
    display no misleading graphic. The stool/blocks back-extension hold and
    dynamic movement have dedicated guides.
64. **Logger context remains observational.** It shows global exercise/set
    progress and a concise last exposure from the controller's separate
    schedule-history cache; neither value affects progression. A small native
    Android channel sets `FLAG_KEEP_SCREEN_ON` while Logger is active/resumed
    and clears it on pause, detach, or route disposal. Missing platform support
    fails open to normal screen behavior rather than blocking a workout.
65. **The muscle picture uses licensed anatomical geometry, not approximate
    body primitives.** Front/back paths are mechanically transcribed from the
    pinned MIT-licensed MuscleMap source and parsed by a dependency-free SVG
    path renderer. Color still comes exclusively from the existing nine-group
    ledger projection. Regions MorningCoach does not track independently
    remain neutral; notably, generic upper-back work does not imply a measured
    lower-back recovery dose. The Classic heatmap preference is unaffected.
66. **Training-pause adjustments replace stale advancement narration.** The
    detraining resolver compares the pre-pause planned state with the actual
    comeback prescription and snapshots that change into the plan. Logger and
    Today therefore say `Reduced after training pause` and show planned versus
    current load/target/difficulty; an earlier `Load increased` message cannot
    survive beside a lower emitted load. The load calculation itself is
    unchanged.
67. **Exercise demos come from the official hosted source, not openGym's media
    checkout.** openGym's exercise GIFs are fetched from a separately licensed
    dataset and are not covered by openGym's AGPL. MorningCoach therefore commits
    no exercise media. Logger streams a curated set of the same ExerciseDB V1 media
    IDs from AscendAPI's public CDN, shows ExerciseDB/AscendAPI and Gym visual
    attribution in the card, and falls back to a clear offline message. Each demo
    is attached by an explicit `visualId`; assisted, elevated, ATG, slant-board,
    self-resisted, and other unmatched variants get no approximate graphic. The
    former schematic Dart pose painter has been removed.

## Session 2026-08-22 (clear time allocation and extended Zone 2 logging)

68. **Time allocation is a composition chart, not a progress meter.** Warm-up,
    working, prescribed rest, and unaccounted time keep their existing definitions
    and proportional segment widths. A fixed colorblind-safe categorical palette
    plus matching label swatches now makes the four categories independently
    identifiable in both light and dark themes.
69. **Continuous Zone 2 records the performed duration, even beyond the plan.** A
    rider may save more than the prescribed 60 minutes, and the complete duration
    and work dose persist and receive normal completion credit. The existing 24-hour
    validation ceiling remains; 4 x 4 and REHIT/CAROL interval work still cannot
    exceed its prescribed work dose.
