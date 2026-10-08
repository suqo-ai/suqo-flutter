// The public type surface. Everything a host app touches is declared here.

import 'package:meta/meta.dart';

/// A gateway's return parameters, exactly as the gateway sent them.
///
/// Deliberately not normalised. Every Nepali gateway names its transaction id differently —
/// eSewa a signed `data` blob, Khalti a `pidx`, ConnectIPS a `TXNID`, NPS a `MerchantTxnId` —
/// and the host app reconciles against whatever its own backend recorded. Renaming or
/// filtering here would throw away the only field it can match on.
typedef ReturnParams = Map<String, String>;

/// Which SUQO deployment a checkout is served from.
enum SuqoMode {
  /// `test.suqo.ai`. The default, so an app that names neither mode nor base URL cannot
  /// accidentally take a live payment.
  sandbox,

  /// `app.suqo.ai`.
  live,
}

/// The two statuses that reach a [SuqoFailure].
///
/// `cancelled` and `failed` need opposite handling downstream and must not be collapsed: a
/// buyer who backed out wants the basket offered again, while a rejected payment is worth
/// investigating. Nothing is charged in either case.
enum SuqoFailureStatus { failed, cancelled }

/// Why a session cannot be paid at all.
///
/// Finer-grained than what the buyer is shown, on purpose: `spent` and `expired` read the
/// same to them and are opposite facts to whoever built the integration.
enum SuqoUnavailableReason {
  notFound,
  expired,
  spent,
  noCustomer,
  noMethods,
  loadFailed,
}

/// The outcome of one `SuqoCheckout.open` call. Exactly one is delivered per attempt.
///
/// A closed set of three: [SuqoSuccess], [SuqoFailure], [SuqoClosed]. The private
/// constructor is what closes it — nothing outside this library can add a fourth case.
///
/// Dart 2.18 has no `sealed`, so the compiler cannot check a `switch` or an `is`-chain for
/// exhaustiveness. [when] exists for that reason: it takes a callback per case and so
/// *cannot* be written incompletely.
@immutable
abstract class SuqoOutcome {
  const SuqoOutcome._(this.sessionId);

  /// The checkout session this outcome belongs to.
  final String sessionId;

  /// Exhaustive handling, checked by the compiler because every branch is a required
  /// argument. Prefer this to an `is`-chain, which silently falls through a case you forgot.
  R when<R>({
    required R Function(SuqoSuccess success) success,
    required R Function(SuqoFailure failure) failure,
    required R Function(SuqoClosed closed) closed,
  });
}

/// A payment that settled successfully, after the checkout page verified it with the backend.
@immutable
class SuqoSuccess extends SuqoOutcome {
  const SuqoSuccess({
    required String sessionId,
    required this.params,
    this.message,
  }) : super._(sessionId);

  /// The gateway's return parameters, verbatim. See [ReturnParams].
  final ReturnParams params;

  /// What SUQO's backend said when it settled the payment. Null when it said nothing.
  final String? message;

  @override
  R when<R>({
    required R Function(SuqoSuccess success) success,
    required R Function(SuqoFailure failure) failure,
    required R Function(SuqoClosed closed) closed,
  }) =>
      success(this);

  @override
  String toString() => 'SuqoSuccess(sessionId: $sessionId, params: $params)';
}

/// A payment that did not settle. See [SuqoFailureStatus] for why the two statuses differ.
@immutable
class SuqoFailure extends SuqoOutcome {
  const SuqoFailure({
    required String sessionId,
    required this.status,
    required this.params,
    this.message,
  }) : super._(sessionId);

  final SuqoFailureStatus status;

  /// The gateway's return parameters, verbatim. Empty for a cancellation — there was no
  /// transaction to report.
  final ReturnParams params;

  /// What SUQO's backend said. Null when it said nothing — on a failure this is usually the
  /// only place the reason exists.
  final String? message;

  @override
  R when<R>({
    required R Function(SuqoSuccess success) success,
    required R Function(SuqoFailure failure) failure,
    required R Function(SuqoClosed closed) closed,
  }) =>
      failure(this);

  @override
  String toString() =>
      'SuqoFailure(sessionId: $sessionId, status: $status, params: $params)';
}

/// The sheet was dismissed before anything settled. Nothing was charged.
@immutable
class SuqoClosed extends SuqoOutcome {
  const SuqoClosed({required String sessionId}) : super._(sessionId);

  @override
  R when<R>({
    required R Function(SuqoSuccess success) success,
    required R Function(SuqoFailure failure) failure,
    required R Function(SuqoClosed closed) closed,
  }) =>
      closed(this);

  @override
  String toString() => 'SuqoClosed(sessionId: $sessionId)';
}

/// A debug stream for the host app's own logging. Not a payment signal — the outcome is.
///
/// Ids are redacted on the way into this SDK's own log output, but events handed to the host
/// carry the real [sessionId]: it is the host's own identifier, and it is what makes an event
/// useful in their logs. Redaction is about what *this* package prints.
@immutable
class SuqoEvent {
  const SuqoEvent._(this.type, this.sessionId,
      {this.height, this.scheme, this.stage, this.reason, this.outcome});

  /// One of: `open`, `alive`, `ready`, `resize`, `gateway`, `handoff`, `handoff_failed`,
  /// `load_timeout`, `load_error`, `unavailable`, `settled`.
  final String type;
  final String sessionId;

  /// `resize` only — the block's content height in logical pixels.
  final double? height;

  /// `handoff` / `handoff_failed` only — the URL scheme handed to the OS.
  final String? scheme;

  /// `load_timeout` only — `alive` or `ready`.
  final String? stage;

  /// `unavailable` only.
  final SuqoUnavailableReason? reason;

  /// `settled` only — the outcome that was delivered.
  final SuqoOutcome? outcome;

  const SuqoEvent.open(String sessionId) : this._('open', sessionId);
  const SuqoEvent.alive(String sessionId) : this._('alive', sessionId);
  const SuqoEvent.ready(String sessionId) : this._('ready', sessionId);
  const SuqoEvent.gateway(String sessionId) : this._('gateway', sessionId);
  const SuqoEvent.loadError(String sessionId) : this._('load_error', sessionId);

  const SuqoEvent.resize(String sessionId, double height)
      : this._('resize', sessionId, height: height);

  const SuqoEvent.handoff(String sessionId, String scheme)
      : this._('handoff', sessionId, scheme: scheme);

  const SuqoEvent.handoffFailed(String sessionId, String scheme)
      : this._('handoff_failed', sessionId, scheme: scheme);

  const SuqoEvent.loadTimeout(String sessionId, String stage)
      : this._('load_timeout', sessionId, stage: stage);

  /// The session cannot be paid at all — expired, already spent, created without a customer.
  ///
  /// Deliberately an event and not a callback. No payment was attempted, so reporting a
  /// failure would be a lie; the buyer sees the page's own explanation and dismisses, which
  /// settles as [SuqoClosed]. This is here so the host can find out *why* in their own logs.
  const SuqoEvent.unavailable(String sessionId, SuqoUnavailableReason reason)
      : this._('unavailable', sessionId, reason: reason);

  const SuqoEvent.settled(String sessionId, SuqoOutcome outcome)
      : this._('settled', sessionId, outcome: outcome);

  @override
  String toString() => 'SuqoEvent($type, sessionId: $sessionId)';
}

/// Receives [SuqoEvent]s when the host passes one to `SuqoProvider` or `SuqoCheckout.open`.
typedef SuqoEventSink = void Function(SuqoEvent event);
