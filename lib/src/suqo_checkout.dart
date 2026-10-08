import 'package:flutter/material.dart';

import 'errors.dart';
import 'log.dart';
import 'session.dart';
import 'suqo_provider.dart';
import 'types.dart';
import 'ui/checkout_screen.dart';
import 'urls.dart';

/// Opens the SUQO checkout.
///
/// The host app's own backend creates the checkout session and holds its id. This opens
/// SUQO's own checkout page for that id, lets the buyer pay, and returns the outcome the
/// page verified. It makes no SUQO API calls of its own and holds no credential.
class SuqoCheckout {
  // Static-only namespace. A private constructor is the pre-Dart-3 way to say that — class
  // modifiers (`abstract final`) need Dart 3, and this package's floor is 2.18.
  const SuqoCheckout._();

  /// Pushes the payment screen and completes with exactly one [SuqoOutcome].
  ///
  /// Every named argument falls back to the nearest [SuqoProvider], then to the package
  /// default. [baseUrl] overrides [mode]; [mode] defaults to [SuqoMode.sandbox], so an app
  /// naming neither cannot take a live payment by accident.
  ///
  /// There is nothing about the buyer here. The session is created on the merchant's own
  /// backend and already carries them, so their name, email and address never pass through
  /// this SDK, never reach the device, and never end up in a log.
  ///
  /// Throws [SuqoConfigError] **before anything is shown** when [sessionId] is empty or the
  /// resolved base URL cannot produce a checkout URL.
  static Future<SuqoOutcome> open(
    BuildContext context, {
    required String sessionId,
    SuqoMode? mode,
    String? baseUrl,
    String? checkoutPath,
    String? title,
    String? loadingLabel,
    bool? debug,
    SuqoEventSink? onEvent,
  }) {
    final defaults = SuqoProvider.maybeOf(context);

    final resolvedDebug = debug ?? defaults?.debug ?? false;
    // Applied before anything else so a failure in the URL build below is itself loggable.
    // Idempotent: it sets one library-level boolean.
    setDebug(resolvedDebug);

    final resolvedEvents = onEvent ?? defaults?.onEvent;

    // Validated synchronously, before the route is pushed, so a caller has one failure
    // channel rather than two.
    final url = buildCheckoutUrl(
      resolveBaseUrl(baseUrl ?? defaults?.baseUrl, mode ?? defaults?.mode),
      sessionId,
      checkoutPath ?? defaults?.checkoutPath ?? kDefaultCheckoutPath,
    );

    final session = CheckoutSession(
      sessionId: sessionId,
      onEvent: resolvedEvents,
    );

    return _push(
      context,
      session: session,
      url: url,
      title: title ?? defaults?.title ?? 'Secure payment',
      loadingLabel:
          loadingLabel ?? defaults?.loadingLabel ?? 'Loading secure checkout',
      debug: resolvedDebug,
      onEvent: resolvedEvents,
    );
  }

  static Future<SuqoOutcome> _push(
    BuildContext context, {
    required CheckoutSession session,
    required String url,
    required String title,
    required String loadingLabel,
    required bool debug,
    SuqoEventSink? onEvent,
  }) async {
    await Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        // Matches the React Native SDK: a trailing-edge slide, the way a pushed screen
        // moves, rather than a sheet rising from the bottom.
        transitionDuration: const Duration(milliseconds: 260),
        reverseTransitionDuration: const Duration(milliseconds: 200),
        pageBuilder: (_, __, ___) => CheckoutScreen(
          session: session,
          url: url,
          title: title,
          loadingLabel: loadingLabel,
          debug: debug,
          onEvent: onEvent,
        ),
        transitionsBuilder: (_, animation, __, child) {
          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(1, 0),
              end: Offset.zero,
            ).animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
            child: child,
          );
        },
      ),
    );

    // The route is gone and its exit animation has finished. Anything that dismissed the
    // screen without going through the sheet's own handlers — a system back gesture, a
    // `Navigator.pop` from host code — lands here unsettled, and a dismissal is the honest
    // reading of it. The latch ignores this when a verified result already won.
    session.settle(const Settlement.closed());
    session.deliver();
    return session.future;
  }
}
