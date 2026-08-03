import 'cardio_protocol.dart';
import 'floor_category.dart';
import 'session_timing.dart';
import 'session_type.dart';
import 'set_log.dart';

/// How precisely [SessionLog.completedAt] was persisted.
///
/// Old rows stored only a calendar date. Keeping that distinction explicit
/// lets recovery safety treat their unknown completion time conservatively
/// without changing stimulus-ledger timing for historical records.
enum CompletionTimePrecision { exact, dateOnlyInferred }

/// §2.4 / §8: planned vs completed exercises, completion ratio, duration.
class SessionLog {
  final String id;
  final SessionTypeId templateId;
  final SessionTier tier;
  final DateTime date;

  /// Completion timestamp when known. Date-only legacy records retain their
  /// normalized [date] here and are identified by [completedAtPrecision].
  final DateTime completedAt;
  final CompletionTimePrecision completedAtPrecision;
  final List<SetLog> setLogs;

  /// Work sets planned in the *final emitted plan* (post compression,
  /// readiness cuts, pain substitutions) - §8's denominator.
  final int plannedWorkSets;
  final int completedWorkSets;
  final int durationMinutes;

  /// Exact wall-clock facts about the performance itself. Null for sessions
  /// logged before timing capture existed; every consumer must degrade to
  /// [durationMinutes] rather than assume it is present.
  final SessionTimings? timings;
  final String? notes;

  /// Exact cardio dose actually completed. Null for strength sessions and
  /// legacy cardio logs that predate structured cardio logging.
  final CardioCompletion? cardioCompletion;

  /// Whether a structured cardio attempt completed the exact dose in the
  /// prescription used to validate it. This is intentionally independent of
  /// category/queue credit. Null identifies legacy rows written before the
  /// app persisted prescription adherence explicitly.
  final bool? cardioCompletedAsPrescribed;

  /// Resolved at completion: handles the conditional S2 intensity credit
  /// (only if the REHIT finisher was actually done, §2.1).
  final Set<FloorCategory> countsAs;
  final bool rehitFinisherCompleted;

  /// Additional work logged outside today's primary prescription. It still
  /// contributes its real dose to stimulus and recovery accounting, but it
  /// cannot complete or lock the primary plan.
  final bool isSupplemental;

  /// True only for work entered retrospectively without a prospective app
  /// recommendation. Every unplanned log is necessarily supplemental.
  final bool isUnplanned;
  final bool travelMode;
  final bool endedEarly;

  SessionLog({
    required this.id,
    required this.templateId,
    required this.tier,
    required this.date,
    DateTime? completedAt,
    CompletionTimePrecision? completedAtPrecision,
    required this.setLogs,
    required this.plannedWorkSets,
    required this.completedWorkSets,
    required this.durationMinutes,
    this.timings,
    required this.countsAs,
    this.cardioCompletion,
    this.cardioCompletedAsPrescribed,
    this.rehitFinisherCompleted = false,
    bool isSupplemental = false,
    this.isUnplanned = false,
    this.travelMode = false,
    this.endedEarly = false,
    this.notes,
  })  : assert(!isUnplanned || isSupplemental),
        isSupplemental = isSupplemental || isUnplanned,
        completedAt = completedAt ?? date,
        completedAtPrecision = completedAtPrecision ??
            (completedAt == null
                ? CompletionTimePrecision.dateOnlyInferred
                : CompletionTimePrecision.exact);

  bool get _isCardioOnlyTemplate =>
      templateId == SessionTypeId.s3 ||
      templateId == SessionTypeId.s6 ||
      templateId == SessionTypeId.s7;

  /// Structured cardio attempts qualify only when their protocol-specific
  /// minimum was completed. A null completion on an old cardio-only log is
  /// deliberately treated as qualifying so upgrading does not erase history.
  bool get cardioDoseQualifies {
    if (!_isCardioOnlyTemplate) return false;
    final completion = cardioCompletion;
    if (completion == null) return true;
    final expectedProtocol = switch (templateId) {
      SessionTypeId.s3 => CardioProtocolType.norwegian4x4,
      SessionTypeId.s6 => CardioProtocolType.zone2Base,
      SessionTypeId.s7 => CardioProtocolType.rehit,
      _ => null,
    };
    return completion.protocol.type == expectedProtocol &&
        completion.meetsCreditableDose;
  }

  double get completionRatio {
    if (_isCardioOnlyTemplate) return cardioDoseQualifies ? 1.0 : 0.0;
    return plannedWorkSets == 0 ? 1.0 : completedWorkSets / plannedWorkSets;
  }

  /// §8: >=50% -> counts & queue advances; <50% -> partial, queue frozen.
  bool get countsTowardQueueAndFloor =>
      _isCardioOnlyTemplate ? cardioDoseQualifies : completionRatio >= 0.5;

  /// Best available start instant: the recorded one, else back-calculated
  /// from an exact completion timestamp and the elapsed time. Null when only
  /// a calendar date is known, so time-of-day analysis can skip the row
  /// instead of inventing a plausible hour for it.
  DateTime? get startedAtOrNull {
    final recorded = timings?.startedAt;
    if (recorded != null) return recorded;
    if (completedAtPrecision != CompletionTimePrecision.exact) return null;
    final seconds = timings?.elapsedSeconds ?? durationMinutes * 60;
    if (seconds <= 0) return null;
    return completedAt.subtract(Duration(seconds: seconds));
  }

  /// Elapsed seconds, exact when recorded and otherwise reconstructed from
  /// the whole-minute legacy field.
  int get elapsedSecondsOrEstimate =>
      timings?.elapsedSeconds ?? durationMinutes * 60;

  /// Whether [elapsedSecondsOrEstimate] came from a real measurement rather
  /// than a minute-rounded legacy value.
  bool get hasExactElapsedSeconds => timings?.elapsedSeconds != null;

  /// Home/Today completion is prescription adherence, not stimulus credit.
  /// Legacy records retain their historical counted-session behavior because
  /// their original plan prescription is no longer available for comparison.
  bool get completesTodaysPlan {
    if (isSupplemental) return false;
    if (_isCardioOnlyTemplate && cardioCompletion != null) {
      return cardioCompletedAsPrescribed ?? countsTowardQueueAndFloor;
    }
    return countsTowardQueueAndFloor;
  }
}
