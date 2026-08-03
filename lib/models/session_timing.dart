/// Wall-clock facts recorded while a session is actually performed.
///
/// These are deliberately *raw observations*, not derived metrics: every
/// duration insight (work vs. rest split, plan-estimate accuracy, density)
/// is recalculated by `AnalyticsEngine` from these fields plus the set logs,
/// so a change in how a metric is defined never requires rewriting history.
///
/// Every field is nullable because sessions logged before timing capture
/// existed carry only `SessionLog.date`/`completedAt`/`durationMinutes`.
class SessionTimings {
  /// When the user actually began the session — the logger opening for
  /// strength work, or `completedAt - dose` for a bike-guided cardio attempt.
  final DateTime? startedAt;

  /// Exact elapsed seconds from start to finish. `SessionLog.durationMinutes`
  /// is the same span truncated to whole minutes, which is too coarse for a
  /// 8:40 REHIT preset or for per-set arithmetic.
  final int? elapsedSeconds;

  /// What the planner predicted this session would take, captured at
  /// completion so estimate accuracy can be measured against the plan the
  /// user actually ran (post compression/readiness cuts).
  final int? plannedDurationMinutes;

  const SessionTimings({
    this.startedAt,
    this.elapsedSeconds,
    this.plannedDurationMinutes,
  });

  bool get isEmpty =>
      startedAt == null && elapsedSeconds == null && plannedDurationMinutes == null;

  int? get plannedSeconds =>
      plannedDurationMinutes == null ? null : plannedDurationMinutes! * 60;
}
