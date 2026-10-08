// One `open()` call's lifetime, and the latch that makes it report exactly once.
//
// Pure — no Flutter widgets — so the race that matters here is testable directly.

import 'dart:async';

import 'log.dart';
import 'types.dart';

/// What settled a session, before it is shaped into the public [SuqoOutcome].
///
/// Closed the same way [SuqoOutcome] is: a private constructor, so the three cases below are
/// all there will ever be.
abstract class Settlement {
  const Settlement._();

  const factory Settlement.success(ReturnParams params, String? message) =
      _SuccessSettlement;
  const factory Settlement.failure(
    SuqoFailureStatus status,
    ReturnParams params,
    String? message,
  ) = _FailureSettlement;
  const factory Settlement.closed() = _ClosedSettlement;

  bool get isClosed => this is _ClosedSettlement;

  SuqoOutcome toOutcome(String sessionId);
}

class _SuccessSettlement extends Settlement {
  const _SuccessSettlement(this.params, this.message) : super._();
  final ReturnParams params;
  final String? message;

  @override
  SuqoOutcome toOutcome(String sessionId) =>
      SuqoSuccess(sessionId: sessionId, params: params, message: message);
}

class _FailureSettlement extends Settlement {
  const _FailureSettlement(this.status, this.params, this.message) : super._();
  final SuqoFailureStatus status;
  final ReturnParams params;
  final String? message;

  @override
  SuqoOutcome toOutcome(String sessionId) => SuqoFailure(
        sessionId: sessionId,
        status: status,
        params: params,
        message: message,
      );
}

class _ClosedSettlement extends Settlement {
  const _ClosedSettlement() : super._();

  @override
  SuqoOutcome toOutcome(String sessionId) => SuqoClosed(sessionId: sessionId);
}

/// Maps a `suqo:result` status onto a [Settlement].
Settlement settlementFromResult(
  String status,
  ReturnParams params,
  String? message,
) {
  if (status == 'success') return Settlement.success(params, message);
  return Settlement.failure(
    status == 'cancelled'
        ? SuqoFailureStatus.cancelled
        : SuqoFailureStatus.failed,
    params,
    message,
  );
}

int _nextKey = 1;

/// One attempt: its outcome, delivered exactly once.
class CheckoutSession {
  CheckoutSession({
    required this.sessionId,
    this.onEvent,
  }) : key = _nextKey++;

  /// Monotonic. Keys the WebView so a second `open()` gets a fresh one.
  final int key;
  final String sessionId;
  final SuqoEventSink? onEvent;

  final Completer<SuqoOutcome> _completer = Completer<SuqoOutcome>();
  Settlement? _settlement;
  bool _delivered = false;

  /// Completes with the outcome, once.
  Future<SuqoOutcome> get future => _completer.future;

  bool get settled => _settlement != null;

  SuqoOutcome? get outcome => _settlement?.toOutcome(sessionId);

  /// Records the outcome. Returns true if this call is the one that settled the session,
  /// and false if something already had.
  ///
  /// Separate from [deliver] because the two happen at different times: settling is
  /// immediate, so a losing caller can be told to stand down, while the host's outcome is
  /// delivered once the sheet has finished animating away.
  bool settle(Settlement next) {
    // Compare-and-set, synchronous. Two things genuinely race here: a `suqo:result`
    // arriving from the page, and the buyer dismissing the sheet. First one wins, so a
    // duplicate result — the protocol delivers one over several paths on purpose — is a
    // no-op rather than a second outcome.
    final current = _settlement;
    if (current != null) {
      // One exception to first-wins: a verified result beats an earlier dismissal, as long
      // as nothing has been delivered yet.
      //
      // The buyer dismisses the sheet and, a frame later, `suqo:result` arrives — the page
      // had already verified the payment with the backend. Reporting `closed` there would
      // tell the app nothing happened while the customer's money moved. A dismissal is a
      // statement of intent; a result is what the server confirmed, so the result stands.
      final upgradable = !_delivered && current.isClosed && !next.isClosed;
      if (!upgradable) {
        log('settle.ignored');
        return false;
      }
      log('settle.upgraded');
    }
    _settlement = next;
    return true;
  }

  /// Completes the future and fires the event. Idempotent.
  void deliver() {
    final settlement = _settlement;
    if (_delivered || settlement == null) return;
    _delivered = true;

    final result = settlement.toOutcome(sessionId);
    onEvent?.call(SuqoEvent.settled(sessionId, result));
    log('deliver');

    _completer.complete(result);
  }
}
