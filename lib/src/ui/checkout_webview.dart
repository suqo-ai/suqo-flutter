import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import '../bridge.dart';
import '../log.dart';
import '../urls.dart';

/// What the screen wants to hear about from the page.
class WebViewHandlers {
  WebViewHandlers({
    required this.onMessage,
    required this.onHandoff,
    required this.onLoadEnd,
    required this.onLoadError,
  });

  final void Function(InboundMessage message) onMessage;
  final void Function(String url, String scheme) onHandoff;
  final VoidCallback onLoadEnd;
  final VoidCallback onLoadError;
}

/// The WebView the checkout page runs in.
///
/// Built once per `open()` and never rebuilt for a state change on the sheet: the controller
/// is created in [initState] from the URL alone. A rebuild that recreated it would reload
/// the page, and if the buyer is already at a gateway that discards their payment session
/// mid-flow — a failure that only shows up against a real gateway.
class CheckoutWebView extends StatefulWidget {
  const CheckoutWebView({
    super.key,
    required this.url,
    required this.debugScript,
    required this.handlers,
  });

  final String url;

  /// Injected when `debug` is on, empty otherwise. See [buildDebugScript] for why this
  /// cannot run before the page's own scripts the way the React Native SDK's does.
  final String debugScript;

  final WebViewHandlers handlers;

  @override
  State<CheckoutWebView> createState() => _CheckoutWebViewState();
}

class _CheckoutWebViewState extends State<CheckoutWebView> {
  late final WebViewController _controller;

  @override
  void initState() {
    super.initState();

    // No platform-specific creation params. The iOS one that looked relevant,
    // `limitsNavigationsToAppBoundDomains`, does not exist at this package's declared
    // webview floor, and its default is already what a checkout page needs — WKWebView
    // only restricts navigation to app-bound domains when the host app declares
    // `WKAppBoundDomains` in its Info.plist, which is the host's call, not ours.
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Transparent ground: the sheet is behind this, and a white flash on load reads as a
      // layout jump on the way in.
      ..setBackgroundColor(Colors.transparent)
      // The channel name is the entire Flutter-specific integration — the page probes for
      // `window.SuqoWebView`. See bridge.dart.
      ..addJavaScriptChannel(
        kJavaScriptChannel,
        onMessageReceived: (JavaScriptMessage message) {
          final parsed = parseInbound(message.message);
          // Not ours: the channel is shared with whatever the page chooses to post.
          if (parsed == null) return;
          widget.handlers.onMessage(parsed);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            return _decide(request.url);
          },
          onPageStarted: (_) {
            // The earliest hook available. Not equivalent to React Native's
            // `injectedJavaScriptBeforeContentLoaded` — it races the page's own scripts —
            // so a throw during the page's first evaluation can be missed. Debug-only.
            if (widget.debugScript.isNotEmpty) {
              _controller.runJavaScript(widget.debugScript);
            }
          },
          onPageFinished: (_) {
            // Not treated as "ready". The page reports that itself, and the distinction
            // matters: a document that loads but never boots the block is the failure the
            // ready deadline exists to catch.
            widget.handlers.onLoadEnd();
          },
          onWebResourceError: (_) => widget.handlers.onLoadError(),
          // Android can bypass `onNavigationRequest` on a same-page redirect, which is
          // exactly how some gateways bounce to a bank app. Mirroring it here is what the
          // React Native SDK does for the same reason; a double call is harmless because
          // handoffs are idempotent and the settle path latches.
          onUrlChange: (UrlChange change) {
            final url = change.url;
            if (url != null) _decide(url);
          },
        ),
      );

    _controller = controller;

    final platform = controller.platform;
    if (platform is AndroidWebViewController) {
      // The checkout page keeps a scoped payment token in `localStorage`; the Android
      // implementation enables DOM storage for us. Third-party cookies are set explicitly
      // because the gateway journey crosses sites and the default is off.
      AndroidWebViewCookieManager(
        const PlatformWebViewCookieManagerCreationParams(),
      ).setAcceptThirdPartyCookies(platform, true);
      // `setSupportMultipleWindows` is deliberately not called: webview_flutter exposes no
      // such API, and Android's own `WebSettings` default is already false, which is what
      // collapses `window.open` into a same-window navigation. React Native sets it
      // explicitly only because react-native-webview's default is true. Nothing to do here.
    }

    controller.loadRequest(Uri.parse(widget.url));
  }

  /// Shared by both navigation hooks. Decides whether the WebView should load [url].
  NavigationDecision _decide(String url) {
    final navigation = classifyNavigation(url);

    switch (navigation.kind) {
      case NavigationKind.handoff:
        widget.handlers.onHandoff(url, navigation.scheme);
        return NavigationDecision.prevent;
      case NavigationKind.block:
        log('nav.blocked', {'scheme': navigation.scheme});
        return NavigationDecision.prevent;
      case NavigationKind.allow:
        return NavigationDecision.navigate;
    }
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _controller);
}
