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
      if (queued == null || !mounted) return;
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
    setState(() {
      _errorReason = reason;
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
    _closing = true;
    _clearTimers();
    if (mounted) Navigator.of(context).maybePop();
  }

  /// Back button. An explicit dismissal.
  void _requestClose() => _settleAndClose(const Settlement.closed());

  Widget _buildWebView() {
    final handlers = WebViewHandlers(
      onMessage: _handleMessage,
      onHandoff: (url, scheme) {
        _emit(SuqoEvent.handoff(widget.session.sessionId, scheme));
        openExternal(url).then((opened) {
          if (opened) return;
          _emit(SuqoEvent.handoffFailed(widget.session.sessionId, scheme));
        });
      },
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
                        onRetry: () {
                          setState(() {
                            _phase = _Phase.loading;
                            _reloadKey += 1;
                          });
                          _armAliveDeadline();
                        },
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
