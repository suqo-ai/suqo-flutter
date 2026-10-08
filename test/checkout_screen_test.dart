import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suqo_checkout/src/bridge.dart';
import 'package:suqo_checkout/src/session.dart';
import 'package:suqo_checkout/src/types.dart';
import 'package:suqo_checkout/src/ui/checkout_screen.dart';
import 'package:suqo_checkout/src/ui/checkout_webview.dart';
import 'package:suqo_checkout/src/ui/error_state.dart';

/// The screen with its WebView stubbed out.
///
/// `webview_flutter` renders a platform view the widget tester cannot create, so these
/// tests drive the screen's own state machine — deadlines, phases, settling — through the
/// handlers the real WebView would otherwise call. The WebView itself is covered by the
/// manual run against a real checkout page.
class Harness {
  Harness(this.session, this.events);

  final CheckoutSession session;
  final List<SuqoEvent> events;
  late WebViewHandlers handlers;

  /// Stands in for a message arriving on the JavaScript channel.
  void send(InboundMessage message) => handlers.onMessage(message);
}

Future<Harness> pumpScreen(
  WidgetTester tester, {
  String loadingLabel = 'Loading secure checkout',
}) async {
  final events = <SuqoEvent>[];
  final session = CheckoutSession(sessionId: 'cks_abc', onEvent: events.add);
  final harness = Harness(session, events);

  await tester.pumpWidget(
    MaterialApp(
      home: CheckoutScreen(
        session: session,
        url: 'https://test.suqo.ai/c/cks_abc',
        title: 'Secure payment',
        loadingLabel: loadingLabel,
        debug: false,
        onEvent: events.add,
        webViewBuilder: (handlers) {
          harness.handlers = handlers;
          return const SizedBox.expand();
        },
      ),
    ),
  );

  return harness;
}

void main() {
  testWidgets('starts on the loading state, with the label under the spinner',
      (tester) async {
    await pumpScreen(tester);

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading secure checkout'), findsOneWidget);
    expect(find.text('Secure payment'), findsOneWidget);
  });

  testWidgets('an empty loading label leaves the spinner alone',
      (tester) async {
    await pumpScreen(tester, loadingLabel: '');

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading secure checkout'), findsNothing);
  });

  testWidgets('reports open as soon as it mounts', (tester) async {
    final harness = await pumpScreen(tester);
    expect(harness.events.map((e) => e.type), contains('open'));
  });

  testWidgets('a host that calls setState from onEvent is not torn down',
      (tester) async {
    // The screen mounts during the pushing frame's build, so `open` used to reach the host
    // mid-build and anything that rebuilt there threw "setState() called during build" —
    // which is what a host does with these events, and what the example app does.
    final events = <SuqoEvent>[];
    final session = CheckoutSession(sessionId: 'cks_abc');

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => CheckoutScreen(
            session: session,
            url: 'https://test.suqo.ai/c/cks_abc',
            title: 'Secure payment',
            loadingLabel: '',
            debug: false,
            onEvent: (event) => setState(() => events.add(event)),
            webViewBuilder: (_) => const SizedBox.expand(),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(events.map((e) => e.type), contains('open'));
  });

  testWidgets('suqo:ready drops the loading state', (tester) async {
    final harness = await pumpScreen(tester);

    harness.send(const ReadyMessage());
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(harness.events.map((e) => e.type), contains('ready'));
  });

  testWidgets('the alive deadline paints the failure panel', (tester) async {
    final harness = await pumpScreen(tester);

    await tester.pump(kAliveDeadline + const Duration(seconds: 1));

    expect(find.text("Couldn't reach the payment page"), findsOneWidget);
    expect(
      harness.events.where((e) => e.type == 'load_timeout').map((e) => e.stage),
      ['alive'],
    );
  });

  testWidgets('suqo:alive disarms that deadline and arms the ready one',
      (tester) async {
    final harness = await pumpScreen(tester);

    harness.send(const AliveMessage());
    // Well past the alive deadline, but alive already arrived.
    await tester.pump(kAliveDeadline + const Duration(seconds: 1));
    expect(find.byType(ErrorState), findsNothing);

    // The ready deadline is the one running now.
    await tester.pump(kReadyDeadline);
    expect(find.text('The payment page is taking too long'), findsOneWidget);
  });

  testWidgets('a second suqo:alive does not strand a timer that fires later',
      (tester) async {
    // The React Native SDK reassigns its ready timer without cancelling the first, so a
    // second `alive` orphans one that later paints the error panel over a ready screen.
    final harness = await pumpScreen(tester);

    harness.send(const AliveMessage());
    await tester.pump(const Duration(seconds: 5));
    harness.send(const AliveMessage());
    harness.send(const ReadyMessage());
    await tester.pump();

    expect(find.byType(ErrorState), findsNothing);

    // Long past both deadlines. Nothing orphaned may fire.
    await tester.pump(kReadyDeadline + const Duration(seconds: 5));
    expect(find.byType(ErrorState), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('suqo:gateway leaves the screen exactly as it is',
      (tester) async {
    final harness = await pumpScreen(tester);

    harness.send(const GatewayMessage());
    await tester.pump();

    // The gateway's own page is what the buyer sees next, inside this same WebView.
    expect(find.byType(ErrorState), findsNothing);
    expect(harness.events.map((e) => e.type), contains('gateway'));

    await tester.pump(kReadyDeadline + const Duration(seconds: 5));
    expect(find.byType(ErrorState), findsNothing);
  });

  testWidgets('suqo:resize is reported but resizes nothing', (tester) async {
    // The screen is full height and the page scrolls inside it.
    final harness = await pumpScreen(tester);

    harness.send(const ResizeMessage(412));
    await tester.pump();

    final resize = harness.events.firstWhere((e) => e.type == 'resize');
    expect(resize.height, 412);
  });

  testWidgets('suqo:unavailable is reported but settles nothing',
      (tester) async {
    // No payment was attempted, so reporting a failure would be a lie. The buyer dismisses,
    // which settles as closed.
    final harness = await pumpScreen(tester);

    harness.send(const UnavailableMessage(SuqoUnavailableReason.noCustomer));
    await tester.pump();

    expect(harness.session.settled, isFalse);
    expect(
      harness.events.firstWhere((e) => e.type == 'unavailable').reason,
      SuqoUnavailableReason.noCustomer,
    );
  });

  testWidgets('suqo:result settles the session', (tester) async {
    final harness = await pumpScreen(tester);

    harness.send(const ResultMessage('success', {'pidx': 'k1'}, 'Verified'));
    await tester.pump();

    expect(harness.session.settled, isTrue);
    expect(harness.session.outcome, isA<SuqoSuccess>());
  });

  testWidgets('a duplicate result does not settle twice', (tester) async {
    // The protocol delivers one result over several paths on purpose.
    final harness = await pumpScreen(tester);

    harness.send(const ResultMessage('success', {'pidx': 'k1'}, null));
    harness.send(const ResultMessage('failed', {}, null));
    await tester.pump();

    expect(harness.session.outcome, isA<SuqoSuccess>());
  });

  testWidgets('a cancelled result stays distinct from a failed one',
      (tester) async {
    final harness = await pumpScreen(tester);

    harness.send(const ResultMessage('cancelled', {}, null));
    await tester.pump();

    expect((harness.session.outcome! as SuqoFailure).status,
        SuqoFailureStatus.cancelled);
  });

  testWidgets('the back button settles as closed', (tester) async {
    final harness = await pumpScreen(tester);

    await tester.tap(find.byTooltip('Go back'));
    await tester.pump();

    expect(harness.session.outcome, isA<SuqoClosed>());
  });

  testWidgets('a load error paints the failure panel', (tester) async {
    final harness = await pumpScreen(tester);

    harness.handlers.onLoadError();
    await tester.pump();

    expect(find.text("Couldn't load the payment page"), findsOneWidget);
    expect(harness.events.map((e) => e.type), contains('load_error'));
  });

  testWidgets('retry returns to loading and re-arms the deadline',
      (tester) async {
    await pumpScreen(tester);

    await tester.pump(kAliveDeadline + const Duration(seconds: 1));
    expect(find.byType(ErrorState), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pump();
    expect(find.byType(ErrorState), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // The fresh attempt gets the full budget again.
    await tester.pump(kAliveDeadline + const Duration(seconds: 1));
    expect(find.byType(ErrorState), findsOneWidget);
  });

  testWidgets('close from the failure panel settles as closed', (tester) async {
    final harness = await pumpScreen(tester);

    await tester.pump(kAliveDeadline + const Duration(seconds: 1));
    await tester.tap(find.text('Close'));
    await tester.pump();

    expect(harness.session.outcome, isA<SuqoClosed>());
  });

  testWidgets('a verified result arriving after a dismissal still wins',
      (tester) async {
    // Reporting `closed` there would tell the app nothing happened while the money moved.
    final harness = await pumpScreen(tester);

    await tester.tap(find.byTooltip('Go back'));
    harness.send(const ResultMessage('success', {'pidx': 'k1'}, null));
    await tester.pump();

    expect(harness.session.outcome, isA<SuqoSuccess>());
  });
}
