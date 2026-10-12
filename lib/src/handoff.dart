// Handing a navigation to the OS, for the bank and wallet apps a WebView cannot reach.

import 'package:url_launcher/url_launcher.dart';

import 'log.dart';
import 'urls.dart';

/// Opens [url] outside the WebView. Returns true when the OS accepted it.
///
/// There is deliberately no `canLaunchUrl` probe first. On Android 11+ it answers false for
/// any scheme the host app has not declared in its manifest `<queries>`, and a package
/// cannot add manifest entries on a consumer's behalf — `url_launcher`'s own README says it
/// "will return false in most cases starting on Android 11" and that "`canLaunchUrl` can
/// return false even if `launchUrl` would work". A probe that cannot say no is pure cost, so
/// this fails open: attempt the launch and let it either work or throw.
///
/// The React Native SDK keeps its probe for a log line; here the attempt itself produces the
/// same signal, so the round trip is dropped rather than kept for symmetry.
///
/// Host apps still need the `<queries>` entries for the launch itself to resolve on Android
/// 11+ — one `<intent>` block per scheme. That is documented in the README; it cannot be
/// shipped from inside this package.
Future<bool> openExternal(String url) async {
  // An `intent:` URI cannot be launched as written, so it is rewritten first. See
  // [intentTargets].
  final candidates = isIntentUrl(url) ? intentTargets(url) : <String>[url];

  if (candidates.isEmpty) {
    log('handoff.failed', {'error': 'intent url named no target'});
    return false;
  }

  for (final candidate in candidates) {
    // Back through the same classifier the WebView's navigation goes through. A rebuilt
    // candidate is attacker-influenced input: after a handoff the WebView is on the
    // gateway's and the bank's pages, not SUQO's, and one of those naming
    // `scheme=file` — or a `javascript:` fallback — would otherwise hand `launchUrl`
    // exactly the schemes `kBlockedSchemes` exists to refuse. Chrome restricts
    // `browser_fallback_url` to http(s) for this same reason.
    final navigation = classifyNavigation(candidate);
    if (navigation.kind == NavigationKind.block) {
      log('handoff.blocked', {'scheme': navigation.scheme});
      continue;
    }

    final uri = Uri.tryParse(candidate);
    if (uri == null) {
      log('handoff.failed', {'error': 'unparseable url'});
      continue;
    }

    try {
      // `externalApplication` is the point of the whole function: the OS picker, not an
      // in-app browser tab, is what reaches a bank app.
      final launched =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      log('handoff.attempt', {'launched': launched, 'url': candidate});
      if (launched) return true;
    } catch (error) {
      log('handoff.failed', {'error': error.toString()});
    }
  }

  log('handoff.failed', {'error': 'no handler'});
  return false;
}

/// The URLs an `intent://` URI actually means, best first.
///
/// `url_launcher` cannot launch `intent://` at all. Its Android side builds
/// `new Intent(ACTION_VIEW).setData(Uri.parse(url))` and never
/// `Intent.parseUri(url, URI_INTENT_SCHEME)` — verified in url_launcher_android 6.0.13
/// (this package's floor) and still true in 6.3.33 — so the parsed scheme is the literal
/// `intent`, nothing on the device declares a filter for it, and the launch fails. Handing
/// one straight to [launchUrl] is therefore guaranteed to do nothing, which is what this
/// package used to do while its README promised otherwise.
///
/// The fragment carries the real target:
///
///     intent://pay/?q=1#Intent;scheme=fonepay;package=com.x;S.browser_fallback_url=https%3A%2F%2F…;end
///
/// `scheme=` plus the body rebuilds the deeplink the gateway meant (`fonepay://pay/?q=1`),
/// and `S.browser_fallback_url` is Android's own documented fallback — usually a Play Store
/// page for the app that is not installed. Both are returned, deeplink first, so a buyer
/// without the bank app still lands somewhere useful instead of nowhere.
///
/// iOS cannot resolve `intent:` under any circumstances, but it can resolve what this
/// rebuilds: the deeplink launches there too when the bank app is installed and claims that
/// scheme, and the fallback URL opens in the browser when it is not.
List<String> intentTargets(String url) {
  if (!isIntentUrl(url)) return const [];

  final hash = url.indexOf('#');
  if (hash < 0) return const [];

  // Everything between the scheme and the fragment. The authority-less form `intent:pay`
  // is as valid as `intent://pay` and gateways emit both, so the body is taken from after
  // `intent:` and any `//` stripped, rather than sliced at a fixed `intent://` length —
  // which on the short form would have eaten the first two characters of the path.
  var body = url.substring('intent:'.length, hash);
  if (body.startsWith('//')) body = body.substring(2);

  final targets = <String>[];

  String? scheme;
  String? fallback;
  for (final part in url.substring(hash + 1).split(';')) {
    if (part.startsWith('scheme=')) {
      scheme = part.substring('scheme='.length);
    } else if (part.startsWith('S.browser_fallback_url=')) {
      final raw = part.substring('S.browser_fallback_url='.length);
      try {
        fallback = Uri.decodeComponent(raw);
      } on FormatException {
        // A truncated or invalid escape — `%`, `%ZZ`, a half-written UTF-8 sequence.
        // `decodeComponent` throws on all three, and this runs outside `openExternal`'s
        // own try, so letting it propagate turned a bad fallback URL into an unhandled
        // async error with no `handoff_failed` for the host. The deeplink is usually
        // still good, so drop this one target rather than the whole handoff.
        log('handoff.bad_fallback', {'error': 'undecodable fallback url'});
      } on ArgumentError {
        log('handoff.bad_fallback', {'error': 'undecodable fallback url'});
      }
    }
  }

  if (scheme != null && scheme.isNotEmpty) targets.add('$scheme://$body');
  // http(s) only. The fallback is the one field here that names a whole URL rather than a
  // scheme, so it is the one an attacker-controlled page would reach for.
  if (fallback != null && _isHttpUrl(fallback)) targets.add(fallback);
  return targets;
}

/// Whether [url] is an Android intent URI, in either the authority-less or `//` form.
bool isIntentUrl(String url) =>
    url.trimLeft().toLowerCase().startsWith('intent:');

final RegExp _httpRe = RegExp(r'^https?://', caseSensitive: false);

bool _isHttpUrl(String url) => _httpRe.hasMatch(url.trim());
