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
- **§2.5 warm-up protocol (40/60/80 ramp + feeder sets) is not emitted** in plans;
  §2.3/§2.5 ATG/knee-health block is defined (`hasKneeHealthBlock`) but never
  rendered. Both queued as follow-up work, not silently dropped.
- **S5 "Flex/Pump" trains push-vertical/pull-horizontal/core** instead of direct
  arm work (no curl/raise ladders exist). Follow-up: dedicated accessory ladders.
- **§2.6.4's "54 → 49 (uneven)" rounding example is unsatisfiable**: 50 (matched
  2×25) is achievable, ≤54, and >49, and §2.6.3 says uneven totals *join* the
  set. Round-down over the union yields 50. Tests assert 50; the spec example
  appears internally inconsistent.
- **History screen is a plain list** — no calendar heat / progression charts /
  floor ring yet (spec §11.4, Phase 2 scope).
- **Spec-internal tension**: a +15 recency boost can outrank S6's weekend base 60
  (50+15=65), contradicting §2.1's "S6 becomes top-ranked iff ALL hold". The
  numeric scoring (§5 Step 4, v1.1) is treated as authoritative.
