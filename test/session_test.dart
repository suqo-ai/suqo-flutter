import 'package:flutter_test/flutter_test.dart';
import 'package:suqo_checkout/src/session.dart';
import 'package:suqo_checkout/src/types.dart';

CheckoutSession makeSession({SuqoEventSink? onEvent}) =>
    CheckoutSession(sessionId: 'cks_abc', onEvent: onEvent);

void main() {
  group('settling', () {
    test('the first settlement wins', () {
      final session = makeSession();

      expect(session.settle(const Settlement.success({}, null)), isTrue);
      expect(
        session.settle(
            const Settlement.failure(SuqoFailureStatus.failed, {}, null)),
        isFalse,
      );

      expect(session.outcome, isA<SuqoSuccess>());
    });

    test('a duplicate result is a no-op, not a second outcome', () {
      // The protocol delivers one result over several paths on purpose, so arriving twice
      // is expected. Delivering twice is how a merchant fulfils an order two times.
      final session = makeSession();
      final result = settlementFromResult('success', {'pidx': 'k1'}, null);

      expect(session.settle(result), isTrue);
      expect(session.settle(result), isFalse);
    });

    test('a verified result beats an earlier dismissal', () {
      // The buyer dismisses and, a frame later, the page reports a verified payment.
      // Reporting `closed` would tell the app nothing happened while the money moved.
      final session = makeSession();

      expect(session.settle(const Settlement.closed()), isTrue);
      expect(
        session.settle(const Settlement.success({'pidx': 'k1'}, null)),
        isTrue,
      );

      expect(session.outcome, isA<SuqoSuccess>());
    });

    test('a dismissal does not overwrite an earlier dismissal', () {
      final session = makeSession();
      expect(session.settle(const Settlement.closed()), isTrue);
      expect(session.settle(const Settlement.closed()), isFalse);
    });

    test('nothing beats a result once it has been delivered', () {
      // After delivery the host has already acted on the outcome; changing it then would
      // mean two different answers for one attempt.
      final session = makeSession();
      session.settle(const Settlement.closed());
      session.deliver();

      expect(
        session.settle(const Settlement.success({'pidx': 'k1'}, null)),
        isFalse,
      );
      expect(session.outcome, isA<SuqoClosed>());
    });

    test('reports whether it has settled yet', () {
      final session = makeSession();
      expect(session.settled, isFalse);
      session.settle(const Settlement.closed());
      expect(session.settled, isTrue);
    });
  });

  group('delivering', () {
    test('completes the future with the outcome', () async {
      final session = makeSession();
      session.settle(const Settlement.success({'pidx': 'k1'}, 'Verified'));
      session.deliver();

      final outcome = await session.future;
      expect(outcome, isA<SuqoSuccess>());
      final success = outcome as SuqoSuccess;
      expect(success.sessionId, 'cks_abc');
      expect(success.params, {'pidx': 'k1'});
      expect(success.message, 'Verified');
    });

    test('is idempotent — a second call completes nothing twice', () async {
      // Completing an already-completed Completer throws, which would surface as an
      // unhandled error rather than a payment outcome.
      final session = makeSession();
      session.settle(const Settlement.closed());

      session.deliver();
      expect(session.deliver, returnsNormally);

      expect(await session.future, isA<SuqoClosed>());
    });

    test('does nothing when nothing has settled', () {
      final session = makeSession()..deliver();
      expect(session.future, doesNotComplete);
    });

    test('emits one settled event carrying the outcome', () async {
      final events = <SuqoEvent>[];
      final session = makeSession(onEvent: events.add);

      session.settle(
          const Settlement.failure(SuqoFailureStatus.cancelled, {}, null));
      session.deliver();
      await session.future;

      expect(events, hasLength(1));
      expect(events.single.type, 'settled');
      expect(events.single.outcome, isA<SuqoFailure>());
    });
  });

  group('settlementFromResult', () {
    test('maps success', () {
      final outcome =
          settlementFromResult('success', {'pidx': 'k1'}, null).toOutcome('s');
      expect(outcome, isA<SuqoSuccess>());
    });

    test('keeps cancelled distinct from failed', () {
      // A buyer who changed their mind wants the basket offered again; a rejected payment
      // is worth investigating. Collapsing them loses the only signal that tells them apart.
      final cancelled =
          settlementFromResult('cancelled', {}, null).toOutcome('s');
      final failed = settlementFromResult('failed', {}, null).toOutcome('s');

      expect((cancelled as SuqoFailure).status, SuqoFailureStatus.cancelled);
      expect((failed as SuqoFailure).status, SuqoFailureStatus.failed);
    });
  });

  group('when()', () {
    test('dispatches to exactly one branch', () {
      const outcomes = <SuqoOutcome>[
        SuqoSuccess(sessionId: 's', params: {}),
        SuqoFailure(
            sessionId: 's', status: SuqoFailureStatus.failed, params: {}),
        SuqoClosed(sessionId: 's'),
      ];

      final labels = outcomes
          .map((o) => o.when(
                success: (_) => 'success',
                failure: (_) => 'failure',
                closed: (_) => 'closed',
              ))
          .toList();

      expect(labels, ['success', 'failure', 'closed']);
    });
  });

  test('each session gets its own key, so a second open remounts the WebView',
      () {
    expect(makeSession().key, isNot(makeSession().key));
  });
}
