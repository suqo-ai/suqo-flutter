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
    this.onReloader,
  });

  final void Function(InboundMessage message) onMessage;
  final void Function(String url, String scheme) onHandoff;
  final VoidCallback onLoadEnd;

  /// A main-frame load failure. Subresource failures do not reach this.
  final VoidCallback onLoadError;

  /// Hands the screen a way to reload whatever the WebView is currently showing.
  ///
  /// Retrying by remounting the WebView reloads the *original* checkout URL, which is
  /// right while still loading it and wrong once the buyer has moved on to a gateway —
  /// that would throw away their payment session. This reloads where they actually are.
  final void Function(Future<void> Function() reload)? onReloader;
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

  /// Whether the document currently loaded is SUQO's own.
  ///
  /// Starts true: the first thing loaded is the checkout URL, and `onPageStarted` has not
  /// fired yet to say so.
  bool _onCheckoutOrigin = true;

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
          // The browser SDK's `event.origin` check, which a JavaScript channel has no
          // equivalent of: the channel is installed into *every* document this WebView
          // loads, so the gateway's page and the bank's can post a `suqo:result` the SDK
          // would otherwise report to the merchant as a verified payment. Per
          // protocol.md §8 a native host's result always comes from SUQO's own return
          // page in this same window, so nothing legitimate is refused here.
          if (!_onCheckoutOrigin) {
            log('bridge.off_origin_dropped', {'type': parsed.runtimeType});
            return;
          }
          widget.handlers.onMessage(parsed);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (NavigationRequest request) {
            return _decide(request.url);
          },
          onPageStarted: (String pageUrl) {
            // Which origin the channel is currently speaking from. Re-evaluated on every
            // navigation, so the gateway leg turns protocol messages off and SUQO's own
            // return page — the one that posts `suqo:result` — turns them back on.
            _onCheckoutOrigin = _isCheckoutOrigin(pageUrl);

            // The earliest hook available. Not equivalent to React Native's
            // `injectedJavaScriptBeforeContentLoaded` — it races the page's own scripts —
            // so a throw during the page's first evaluation can be missed. Debug-only.
            //
            // Only on our own origin. `onPageStarted` fires for every navigation, the
            // gateway's and the bank's included, and the forwarder wraps `console` and
            // `XMLHttpRequest.prototype.open` — on a card-entry page that would ship the
            // buyer's request URLs to logcat, where `redactString` is no help because it
            // only knows the shapes SUQO's own URLs have.
            if (widget.debugScript.isNotEmpty && _onCheckoutOrigin) {
              _controller
                  .runJavaScript(widget.debugScript)
                  // Dropped futures become unhandled zone errors, which in a host running
                  // under `runZonedGuarded` surface as a crash report from inside the
                  // payment sheet. The page being torn down mid-eval is not a crash.
                  .catchError((Object error) =>
                      log('debug.inject_failed', {'error': error.toString()}));
            }
          },
          onPageFinished: (_) {
            // Not treated as "ready". The page reports that itself, and the distinction
            // matters: a document that loads but never boots the block is the failure the
            // ready deadline exists to catch.
            widget.handlers.onLoadEnd();
          },
          // Main frame only. Android reports *every* failing request here — a 404 favicon,
          // a blocked font, an analytics beacon a corporate DNS swallows — and treating
          // those as a page failure paints the full-screen error panel over a checkout
          // that is working. `isForMainFrame` is null on platforms that do not say, and
          // those report main-frame failures only, so null means yes.
          onWebResourceError: (WebResourceError error) {
            if (error.isForMainFrame ?? true) widget.handlers.onLoadError();
          },
          // `onUrlChange` is deliberately NOT registered.
          //
          // Two reasons, either sufficient. It throws on iOS at this package's declared
          // floor: `NavigationDelegate` forwards the callback to the platform
          // unconditionally (webview_flutter 4.1.0 navigation_delegate.dart:139) and
          // `webview_flutter_wkwebview` has no implementation until long after 3.0.0, so
          // the platform-interface base throws `UnimplementedError` while this screen is
          // being built — the sheet never renders and the awaited `open` never completes.
          //
          // And it could not do the job it was added for. It is backed by Android's
          // `doUpdateVisitedHistory`, which fires only for navigations the WebView
          // *committed*; a `fonepayApp://` or `intent://` bounce never commits, so the
          // case the old comment named could never reach it. `onNavigationRequest` is
          // what catches those, and it already does.
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
      ).setAcceptThirdPartyCookies(platform, true).catchError(
            (Object error) =>
                log('cookies.third_party_failed', {'error': error.toString()}),
          );
      // `setSupportMultipleWindows` is deliberately not called: webview_flutter exposes no
      // such API, and Android's own `WebSettings` default is already false, which is what
      // collapses `window.open` into a same-window navigation. React Native sets it
      // explicitly only because react-native-webview's default is true. Nothing to do here.
    }

    // `buildCheckoutUrl` has already proved this parses, so `Uri.parse` cannot throw here
    // — but the load itself can fail, and a dropped future is an unhandled zone error in
    // a host running under `runZonedGuarded`. A failed load is `onWebResourceError`'s
    // business, not a crash report.
    controller.loadRequest(Uri.parse(widget.url)).catchError(
          (Object error) =>
              log('webview.load_failed', {'error': error.toString()}),
        );

    // The screen keeps this for a post-`ready` retry, where remounting the WebView would
    // reload the original checkout URL and discard a gateway session.
    widget.handlers.onReloader?.call(() => _controller.reload());
  }

  /// Whether [pageUrl] is served from the same origin as the checkout page.
  ///
  /// The WebView visits the gateway and the bank inside the same control; anything scoped
  /// to SUQO's own page has to ask, because the control itself does not distinguish them.
  bool _isCheckoutOrigin(String pageUrl) {
    final page = Uri.tryParse(pageUrl);
    final checkout = Uri.tryParse(widget.url);
    if (page == null || checkout == null) return false;
    return page.scheme == checkout.scheme &&
        page.host == checkout.host &&
        page.port == checkout.port;
  }

  /// Decides whether the WebView should load [url].
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
