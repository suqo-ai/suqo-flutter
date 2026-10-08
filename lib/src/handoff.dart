// Handing a navigation to the OS, for the bank and wallet apps a WebView cannot reach.

import 'package:url_launcher/url_launcher.dart';

import 'log.dart';

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
  final uri = Uri.tryParse(url);
  if (uri == null) {
    log('handoff.failed', {'error': 'unparseable url'});
    return false;
  }

  try {
    // `externalApplication` is the point of the whole function: the OS picker, not an
    // in-app browser tab, is what reaches a bank app.
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    log('handoff.attempt', {'launched': launched});
    if (!launched) log('handoff.failed', {'error': 'no handler'});
    return launched;
  } catch (error) {
    log('handoff.failed', {'error': error.toString()});
    return false;
  }
}
