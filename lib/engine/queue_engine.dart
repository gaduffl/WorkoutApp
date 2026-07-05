import '../models/session_type.dart';

class QueueState {
  final SessionTypeId pointer;
  final Set<SessionTypeId> served;

  const QueueState({this.pointer = SessionTypeId.s1, this.served = const {}});
}

/// §2.1 queue mechanics: a repeating cycle [S1..S5] with a pointer.
/// - The pointer advances past a type only when a session of that exact
///   type completes >= 50% (§8).
/// - A non-pointer cycle type pulled forward (e.g. by floor pressure) is
///   marked served without moving the pointer.
/// - Readiness swaps and time substitutions (S3->S7) never grant credit to
///   the original type - callers simply never call [advance] for those.
class QueueEngine {
  const QueueEngine();

  /// Distance-ordered sequence starting at the pointer, unserved types
  /// first (in cycle order), then served types (lowest cycle priority).
  List<SessionTypeId> _priorityOrder(QueueState state) {
    final pointerIdx = cycleOrder.indexOf(state.pointer);
    final unserved = <SessionTypeId>[];
    final served = <SessionTypeId>[];
    for (var i = 0; i < cycleOrder.length; i++) {
      final t = cycleOrder[(pointerIdx + i) % cycleOrder.length];
      (state.served.contains(t) ? served : unserved).add(t);
    }
    return [...unserved, ...served];
  }

  /// §5 Step 4: 0 for the pointer's type, 1 for the next unserved type, etc.
  /// Already-served types get the lowest cycle priority (still finite, so
  /// floor pressure or other modifiers can still pull them forward).
  int cycleDistance(SessionTypeId candidate, QueueState state) {
    return _priorityOrder(state).indexOf(candidate);
  }

  /// Marks [creditType] served (only meaningful for cycle members) and
  /// advances the pointer if it was the pointer's own type. Starts a new
  /// cycle (served reset, pointer -> S1) once all five are served.
  QueueState advance(QueueState state, SessionTypeId? creditType) {
    if (creditType == null || !cycleOrder.contains(creditType)) return state;
    final newServed = {...state.served, creditType};
    if (newServed.length >= cycleOrder.length) {
      return const QueueState(pointer: SessionTypeId.s1, served: {});
    }
    var pointer = state.pointer;
    if (creditType == state.pointer) {
      final idx = cycleOrder.indexOf(state.pointer);
      pointer = _firstUnservedFrom(idx + 1, newServed);
    }
    return QueueState(pointer: pointer, served: newServed);
  }

  SessionTypeId _firstUnservedFrom(int startIndex, Set<SessionTypeId> served) {
    for (var i = 0; i < cycleOrder.length; i++) {
      final idx = (startIndex + i) % cycleOrder.length;
      if (!served.contains(cycleOrder[idx])) return cycleOrder[idx];
    }
    return cycleOrder[startIndex % cycleOrder.length];
  }
}
