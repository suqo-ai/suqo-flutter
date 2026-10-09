// URL construction and navigation classification. Pure — no Flutter, no plugins.

import 'errors.dart';
import 'types.dart';

/// The embedded checkout route, with `:id` standing in for the checkout session id.
///
/// Configurable because this route is owned by a different repo and may be renamed. The
/// default is the route that exists today.
const String kDefaultCheckoutPath = '/c/:id';

/// Where a live checkout is served from.
const String kLiveOrigin = 'https://app.suqo.ai';

/// Where a sandbox checkout is served from.
const String kSandboxOrigin = 'https://test.suqo.ai';

String _originForMode(SuqoMode? mode) =>
    mode == SuqoMode.live ? kLiveOrigin : kSandboxOrigin;

/// Resolves the base URL [buildCheckoutUrl] loads.
///
/// An explicit [baseUrl] always wins — it is how an app points at something other than
/// `app.suqo.ai` / `test.suqo.ai` (a staging mirror, a local mock server). Otherwise [mode]
/// picks between [kLiveOrigin] and [kSandboxOrigin], defaulting to sandbox so an app that
/// names neither cannot accidentally take a live payment.
String resolveBaseUrl(String? baseUrl, [SuqoMode? mode]) {
  if (baseUrl != null && baseUrl.trim().isNotEmpty) return baseUrl;
  return _originForMode(mode);
}

/// The URL the sheet loads.
///
/// Nothing is appended to the query string, ever. NPS appends its own return parameters with
/// a literal `?` rather than `&`, so anything added to a query string that reaches a gateway
/// comes back mangled and swallows the gateway's own transaction id. That constraint is why
/// the browser SDK puts its host origin in the URL hash, and it applies equally here.
///
/// Throws [SuqoConfigError] for a base URL that is not http(s), or an empty session id.
String buildCheckoutUrl(
  String baseUrl,
  String sessionId, [
  String checkoutPath = kDefaultCheckoutPath,
]) {
  final trimmed = baseUrl.trim();
  if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(trimmed)) {
    throw SuqoConfigError(
        'baseUrl must be an http(s) URL — received "$baseUrl"');
  }
  // Validated and used as the same value. Guarding on `sessionId.trim()` and then encoding
  // the raw string let ' cks_9f2c41a8 ' through as `/c/%20cks_9f2c41a8%20` — a 404 the
  // buyer meets as the generic 12-second timeout panel, for a session id that is correct
  // apart from whitespace a form or a backend response left on it.
  final id = sessionId.trim();
  if (id.isEmpty) {
    throw const SuqoConfigError('sessionId is required');
  }

  final origin = trimmed.replaceAll(RegExp(r'/+$'), '');
  final path = checkoutPath.contains(':id')
      ? checkoutPath.replaceFirst(':id', Uri.encodeComponent(id))
      : '${checkoutPath.replaceAll(RegExp(r'/+$'), '')}/${Uri.encodeComponent(id)}';

  return origin + (path.startsWith('/') ? path : '/$path');
}

/// What the WebView should do with a navigation it is about to start.
enum NavigationKind {
  /// Let the WebView load it.
  allow,

  /// Hand it to the OS — a bank or wallet app. The WebView cannot resolve these itself.
  handoff,

  /// Neither load nor hand off. A scheme with no business in a payment flow.
  block,
}

/// The classification of one navigation, and the scheme it was made on.
class Navigation {
  const Navigation(this.kind, this.scheme);

  final NavigationKind kind;

  /// Lower-cased, without the trailing colon. Empty for a relative or scheme-less URL.
  final String scheme;
}

/// Schemes that must never reach a navigation sink or the OS.
const Set<String> kBlockedSchemes = {'javascript', 'data', 'file', 'blob'};

final RegExp _schemeRe = RegExp(r'^([a-z][a-z0-9+.-]*):', caseSensitive: false);

/// Classifies a navigation.
///
/// The interesting case is [NavigationKind.handoff]. ConnectIPS and NPS hand off to bank apps
/// through custom-protocol deeplinks (`fonepayApp://…`) and, on Android, `intent://` URLs. A
/// WebView resolves neither — an `intent://` navigation inside one simply fails, and an
/// unhandled custom scheme does nothing at all. Both have to be lifted out to the OS, which
/// is the single reason this function exists rather than the WebView being left to itself.
///
/// Return pages are deliberately **allowed** to load. `/payment-success` is what posts the
/// verification call; intercepting it to read the outcome off the query string would skip
/// verification entirely and report a payment nobody confirmed.
Navigation classifyNavigation(String url) {
  final match = _schemeRe.firstMatch(url.trim());
  // Relative or scheme-less: same-document.
  if (match == null) return const Navigation(NavigationKind.allow, '');

  final scheme = (match.group(1) ?? '').toLowerCase();
  if (scheme == 'http' || scheme == 'https') {
    return Navigation(NavigationKind.allow, scheme);
  }
  // about:blank, the initial load.
  if (scheme == 'about') return Navigation(NavigationKind.allow, scheme);
  if (kBlockedSchemes.contains(scheme)) {
    return Navigation(NavigationKind.block, scheme);
  }
  return Navigation(NavigationKind.handoff, scheme);
}

/// Whether [url] needs the OS rather than the WebView.
bool isAppHandoff(String url) =>
    classifyNavigation(url).kind == NavigationKind.handoff;
