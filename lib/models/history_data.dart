import 'bouldering_log.dart';
import 'recovery_snapshot.dart';
import 'session_log.dart';
import 'stimulus_ledger.dart';
import 'training_status.dart';
import 'training_targets.dart';

/// Immutable data needed by the History screen.
///
/// The raw records remain available for the existing heatmap, progression,
/// HRV, and session-list views. The ledger and target-relative status are
/// calculated once by the app controller from the same history window.
class HistoryData {
  final DateTime asOf;
  final List<SessionLog> logs;
  final List<BoulderingLog> boulderingLogs;
  final List<RecoverySnapshot> recoverySnapshots;
  final TrainingTargets targets;
  final StimulusLedgerSnapshot ledger;
  final TrainingStatus trainingStatus;

  HistoryData({
    required this.asOf,
    required List<SessionLog> logs,
    List<BoulderingLog> boulderingLogs = const [],
    required List<RecoverySnapshot> recoverySnapshots,
    required this.targets,
    required this.ledger,
    required this.trainingStatus,
  })  : logs = List<SessionLog>.unmodifiable(logs),
        boulderingLogs = List<BoulderingLog>.unmodifiable(boulderingLogs),
        recoverySnapshots =
            List<RecoverySnapshot>.unmodifiable(recoverySnapshots);
}
