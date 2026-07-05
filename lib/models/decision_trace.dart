import 'check_in.dart';
import 'plan.dart';
import 'rule_key.dart';
import 'session_type.dart';

enum ReadinessBucket { green, yellow, red }

/// §4.2 recovery summary embedded in the trace.
class RecoveryTrace {
  final double? hrvZToday;
  final double? hrvTrend3;
  final int? sleepScore;
  final double? rhrDev;
  final ReadinessBucket bucket;
  final double compositeScore;
  final List<String> inputsMissing;

  const RecoveryTrace({
    required this.hrvZToday,
    required this.hrvTrend3,
    required this.sleepScore,
    required this.rhrDev,
    required this.bucket,
    required this.compositeScore,
    this.inputsMissing = const [],
  });
}

class ScoredCandidate {
  final SessionTypeId sessionId;
  final SessionTier tier;
  final int score;
  final Map<String, int> scoreTerms;

  const ScoredCandidate({
    required this.sessionId,
    required this.tier,
    required this.score,
    required this.scoreTerms,
  });
}

class QueueTraceInfo {
  final SessionTypeId pointerBefore;
  final Set<SessionTypeId> servedBefore;
  final SessionTypeId? pointerAfterIfCompleted;

  const QueueTraceInfo({
    required this.pointerBefore,
    required this.servedBefore,
    this.pointerAfterIfCompleted,
  });
}

/// §9.6 DecisionTrace - the sole channel the AI layer is allowed to read
/// from. Every evaluated rule that fired is appended here in order.
class DecisionTrace {
  final DateTime date;
  final CheckIn checkin;
  final RecoveryTrace recovery;
  final List<ScoredCandidate> candidates;
  final List<FiredRule> firedRules;

  /// Null when the outcome is a rest day / forced rest (no session plan).
  final SessionPlan? plan;
  final String? restReason;
  final QueueTraceInfo queue;

  const DecisionTrace({
    required this.date,
    required this.checkin,
    required this.recovery,
    required this.candidates,
    required this.firedRules,
    required this.plan,
    required this.queue,
    this.restReason,
  });

  List<String> get firedRuleCodes => firedRules.map((r) => r.code).toList();
}
