import 'package:flutter/widgets.dart';

import 'types.dart';

/// App-wide defaults for [SuqoCheckout.open], so `mode`, `debug` and friends are stated
/// once rather than at every call site.
///
/// Entirely optional. Unlike the React Native SDK's provider — which has to exist because
/// it owns the single checkout screen — this holds configuration and nothing else: Flutter's
/// `Navigator` already gives a screen that returns a result, so there is nothing for a
/// provider to own. Mount it or don't; every value here can also be passed per call, and a
/// per-call value always wins.
class SuqoProvider extends InheritedWidget {
  const SuqoProvider({
    super.key,
    required super.child,
    this.mode,
    this.baseUrl,
    this.checkoutPath,
    this.title,
    this.loadingLabel,
    this.debug,
    this.onEvent,
  });

  /// `live` → `app.suqo.ai`, `sandbox` → `test.suqo.ai`. Defaults to sandbox.
  final SuqoMode? mode;

  /// Where the checkout is served from. Overrides [mode] when set.
  final String? baseUrl;

  /// The checkout route, with `:id` for the session id. Defaults to `/c/:id`.
  final String? checkoutPath;

  /// Screen header title. The amount and the seller are rendered by the page, not here.
  final String? title;

  /// The line under the spinner while the page loads. Pass `''` for a spinner alone.
  final String? loadingLabel;

  /// Turns on this package's redacted logging.
  final bool? debug;

  /// A debug stream for the host's own logging. Not a payment signal — the outcome is.
  final SuqoEventSink? onEvent;

  /// The nearest provider, or null when none is mounted.
  ///
  /// Reads without registering a dependency. `SuqoCheckout.open` is called from a tap
  /// handler, not a build, and it wants these values once — depending on them would
  /// rebuild the caller whenever the config changed, for a read that already happened.
  ///
  /// `getInheritedWidgetOfExactType` would say this more directly but needs Flutter 3.7,
  /// above this package's floor; reaching for the element is the same thing and has always
  /// been available.
  static SuqoProvider? maybeOf(BuildContext context) =>
      context.getElementForInheritedWidgetOfExactType<SuqoProvider>()?.widget
          as SuqoProvider?;

  @override
  bool updateShouldNotify(SuqoProvider oldWidget) =>
      mode != oldWidget.mode ||
      baseUrl != oldWidget.baseUrl ||
      checkoutPath != oldWidget.checkoutPath ||
      title != oldWidget.title ||
      loadingLabel != oldWidget.loadingLabel ||
      debug != oldWidget.debug ||
      onEvent != oldWidget.onEvent;
}
