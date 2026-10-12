import 'dart:async';

import 'package:flutter/material.dart';

import '../bridge.dart';
import '../handoff.dart';
import '../log.dart';
import '../session.dart';
import '../theme.dart';
import '../types.dart';
import 'checkout_webview.dart';
import 'error_state.dart';
import 'header.dart';

/// Nothing came back at all. Generous on purpose: a cold Next.js compile on a dev server has
/// been measured at 4.8s, and a short deadline there draws a failure panel over a page that
/// was merely still building.
const Duration kAliveDeadline = Duration(seconds: 12);

/// The document is running our script but the block never mounted.
const Duration kReadyDeadline = Duration(seconds: 25);

enum _Phase { loading, ready, error }

/// The payment screen: full height, its own back button, and the page scrolling inside it.
///
/// Pushed as an ordinary route rather than presented as a dialog, so the platform's own back
/// gesture and the Android hardware back button work without anything being wired up. The
/// outcome travels on [CheckoutSession], not on the route's pop value — a result can arrive
/// while the sheet is already animating away, and the session's latch is what decides which
/// of the two the host hears about.
class CheckoutScreen extends StatefulWidget {
  const CheckoutScreen({
    super.key,
    required this.session,
    required this.url,
    required this.title,
    required this.loadingLabel,
    required this.debug,
    this.onEvent,
    this.webViewBuilder,
  });

  /// A seam, deliberately.
  ///
  /// `webview_flutter` renders a platform view, which the widget tester has no way to
  /// create — so everything around the WebView would be untestable without this. Tests pass
  /// a stub and drive the state machine through the handlers it hands back. Null in
  /// production, where the real [CheckoutWebView] is built.
  final Widget Function(WebViewHandlers handlers)? webViewBuilder;

  final CheckoutSession session;
  final String url;
  final String title;

  /// The line under the spinner while the page loads. Empty for a spinner alone.
  final String loadingLabel;

  final bool debug;
  final SuqoEventSink? onEvent;

  @override
  State<CheckoutScreen> createState() => _CheckoutScreenState();
}

class _CheckoutScreenState extends State<CheckoutScreen> {
  _Phase _phase = _Phase.loading;
  LoadErrorReason _errorReason = LoadErrorReason.alive;
  int _reloadKey = 0;
  bool _closing = false;

  /// Whether the failure happened past `ready`, so retrying must reload the current page
  /// rather than remount on the original checkout URL. See [_fail].
  bool _recoverable = false;

  /// Reloads whatever the WebView is showing. Supplied by the WebView once it exists.
  Future<void> Function()? _reload;

  Timer? _aliveTimer;
  Timer? _readyTimer;

  late final String _debugScript = widget.debug ? buildDebugScript() : '';

  /// Events raised before the frame that mounts this screen has finished.
  ///
  /// `initState` runs inside that frame's build phase, so calling `onEvent` from it hands
  /// the host a callback mid-build — and a host that calls `setState` there, which is the
  /// obvious thing to do and what the example does, gets "setState() called during build".
  /// Null once the first frame is behind us, after which every event is delivered straight
  /// away: the rest come from timers, the JS channel and navigation callbacks, none of
  /// which run during a build.
  List<SuqoEvent>? _queued = <SuqoEvent>[];

  @override
  void initState() {
    super.initState();
    _emit(SuqoEvent.open(widget.session.sessionId));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final queued = _queued;
      _queued = null;
      if (queued == null) return;
      // Flushed even when the screen is already gone. A host that opened and immediately
      // dismissed still asked for these; dropping them would make `open` the one event
      // that silently does not arrive, and a host counting opens against settles would
      // never balance.
      for (final event in queued) {
        widget.onEvent?.call(event);
      }
    });
    _armAliveDeadline();
  }

  @override
  void dispose() {
    _clearTimers();
    super.dispose();
  }

  /// The one path events leave by, so the mid-build case above is handled once.
  void _emit(SuqoEvent event) {
    final queued = _queued;
    if (queued != null) {
      queued.add(event);
      return;
    }
    widget.onEvent?.call(event);
  }

  void _clearTimers() {
    _aliveTimer?.cancel();
    _readyTimer?.cancel();
    _aliveTimer = null;
    _readyTimer = null;
  }

  void _armAliveDeadline() {
    // Cancelled before reassigning, always. The React Native SDK reassigns its ready timer
    // without cancelling, so a second `suqo:alive` orphans the first — it then fires later
    // and paints the error panel over a screen that had already reached `ready`. Both
    // timers here are cancelled before they are replaced, so that cannot happen.
    _aliveTimer?.cancel();
    _aliveTimer = Timer(kAliveDeadline, () {
      _emit(SuqoEvent.loadTimeout(widget.session.sessionId, 'alive'));
      _fail(LoadErrorReason.alive);
    });
  }

  void _armReadyDeadline() {
    _readyTimer?.cancel();
    _readyTimer = Timer(kReadyDeadline, () {
      _emit(SuqoEvent.loadTimeout(widget.session.sessionId, 'ready'));
      _fail(LoadErrorReason.ready);
    });
  }

  void _fail(LoadErrorReason reason) {
    if (!mounted) return;
    // What "try again" has to mean depends on where the buyer is.
    //
    // While loading, the page to retry is the checkout URL, and remounting the WebView is
    // how that happens. Past `ready` the buyer has moved on — very often to the gateway's
    // own page — and remounting there would reload the original checkout URL and discard
    // the payment session they are in the middle of, which the class comment above says
    // must never happen. So a post-`ready` failure retries by reloading wherever they
    // actually are.
    //
    // Only main-frame failures reach this at all; the WebView filters subresource noise,
    // which is what used to paint this panel over a working checkout.
    setState(() {
      _errorReason = reason;
      _recoverable = _phase != _Phase.loading;
      _phase = _Phase.error;
    });
  }

  void _handleMessage(InboundMessage message) {
    final sessionId = widget.session.sessionId;

    if (message is AliveMessage) {
      _aliveTimer?.cancel();
      _aliveTimer = null;
      _emit(SuqoEvent.alive(sessionId));
      // The frame is real, just not mounted yet — extend the budget.
      _armReadyDeadline();
      return;
    }

    if (message is ReadyMessage) {
      _clearTimers();
      _emit(SuqoEvent.ready(sessionId));
      if (mounted) setState(() => _phase = _Phase.ready);
      return;
    }

    if (message is ResizeMessage) {
      // Reported to the host for its own logs, but nothing here is sized by it: the screen
      // is full height and the page scrolls inside it.
      _emit(SuqoEvent.resize(sessionId, message.height));
      return;
    }

    if (message is GatewayMessage) {
      // The page is navigating this WebView to a gateway. The screen stays exactly as it
      // is; the gateway's own page is what the buyer sees next, inside it.
      _clearTimers();
      _emit(SuqoEvent.gateway(sessionId));
      if (mounted) setState(() => _phase = _Phase.ready);
      return;
    }

    if (message is UnavailableMessage) {
      // Reported, not acted on. The page has already rendered its own explanation and the
      // buyer will dismiss, which settles as closed. Turning this into a failure would tell
      // the host a payment was attempted and rejected, when none was.
      _emit(SuqoEvent.unavailable(sessionId, message.reason));
      return;
    }

    if (message is DebugMessage) {
      // The page is otherwise opaque from out here: a hang and a throw look the same.
      log('page.${message.level}', {'detail': message.text});
      return;
    }

    if (message is ResultMessage) {
      _settleAndClose(
        settlementFromResult(message.status, message.params, message.message),
      );
      return;
    }
  }

  /// Records the outcome and dismisses. The latch in [CheckoutSession] decides what the host
  /// finally hears; this only ever offers.
  void _settleAndClose(Settlement settlement) {
    widget.session.settle(settlement);
    if (_closing) return;
    if (!mounted) return;

    // This screen's own route, not whatever happens to be on top. `maybePop` pops the
    // topmost one, so a host dialog or a notification deeplink sitting above the checkout
    // would be dismissed instead — leaving the checkout on screen with `_closing` already
    // latched, which makes the back button and the error panel's "Close" both dead. The
    // buyer could then only escape with a system gesture.
    final route = ModalRoute.of(context);
    if (route == null) return;

    _closing = true;
    _clearTimers();
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  /// Back button. An explicit dismissal.
  void _requestClose() => _settleAndClose(const Settlement.closed());

  /// "Try again" on the failure panel.
  void _retry() {
    // Every timer from the previous attempt, cancelled before the next one is armed. This
    // used to arm the alive deadline without clearing, so a ready timer left running from
    // the first attempt would fire mid-way through the second and paint "taking too long"
    // over a page that had only just started loading — the exact orphaned-timer bug this
    // package was written to avoid inheriting.
    _clearTimers();

    final reload = _reload;
    if (_recoverable && reload != null) {
      // Past `ready`: reload where the buyer actually is. The WebView is not remounted,
      // so a gateway session survives.
      setState(() {
        _phase = _Phase.loading;
        _recoverable = false;
      });
      reload().catchError(
        (Object error) =>
            log('webview.reload_failed', {'error': error.toString()}),
      );
      // No deadline re-armed: `suqo:alive` and `suqo:ready` belong to SUQO's own page, and
      // the buyer is on the gateway's. Arming one here would paint the panel again over a
      // gateway that is loading perfectly well.
      return;
    }

    setState(() {
      _phase = _Phase.loading;
      _reloadKey += 1;
    });
    _armAliveDeadline();
  }

  Widget _buildWebView() {
    final handlers = WebViewHandlers(
      onMessage: _handleMessage,
      onHandoff: (url, scheme) {
        _emit(SuqoEvent.handoff(widget.session.sessionId, scheme));
        openExternal(url).then((opened) {
          if (opened) return;
          _emit(SuqoEvent.handoffFailed(widget.session.sessionId, scheme));
        }).catchError((Object error) {
          // A throw here is still a failed hand-off, not a crash. Without this it became
          // an unhandled zone error — a crash report from inside the payment sheet in any
          // host running under `runZonedGuarded` — and the host never heard that the bank
          // app did not open.
          log('handoff.threw', {'error': error.toString()});
          _emit(SuqoEvent.handoffFailed(widget.session.sessionId, scheme));
        });
      },
      onReloader: (reload) => _reload = reload,
      onLoadEnd: () => log('webview.loaded'),
      onLoadError: () {
        _emit(SuqoEvent.loadError(widget.session.sessionId));
        _fail(LoadErrorReason.load);
      },
    );

    final builder = widget.webViewBuilder;
    if (builder != null) return builder(handlers);

    return CheckoutWebView(
      key: ValueKey('${widget.session.key}:$_reloadKey'),
      url: widget.url,
      debugScript: _debugScript,
      handlers: handlers,
    );
  }

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.of(context).viewPadding;

    return Scaffold(
      backgroundColor: kSuqoSurface,
      body: Column(
        children: [
          SizedBox(height: insets.top),
          SuqoHeader(title: widget.title, onBack: _requestClose),
          Expanded(
            child: Stack(
              children: [
                // The WebView and the overlays are siblings filling the remaining height.
                // The WebView is never hidden, resized by phase, or wrapped in a changing
                // parent — any of those rebuilds it, and a rebuild reloads the gateway page
                // underneath the buyer. Only `_reloadKey` may replace it, and only on an
                // explicit retry.
                Positioned.fill(child: _buildWebView()),
                if (_phase == _Phase.loading)
                  Positioned.fill(
                    child: ColoredBox(
                      color: kSuqoSurface,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(
                              color: kSuqoPrimary,
                            ),
                            if (widget.loadingLabel.isNotEmpty) ...[
                              const SizedBox(height: kSuqoSpaceLg),
                              Text(
                                widget.loadingLabel,
                                style: const TextStyle(
                                  fontSize: 14,
                                  color: kSuqoMuted,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_phase == _Phase.error)
                  Positioned.fill(
                    child: ColoredBox(
                      color: kSuqoSurface,
                      child: ErrorState(
                        reason: _errorReason,
                        onRetry: _retry,
                        onClose: _requestClose,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(height: insets.bottom),
        ],
      ),
    );
  }
}
