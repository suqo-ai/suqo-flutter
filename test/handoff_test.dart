import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:suqo_checkout/src/handoff.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Stands in for url_launcher's native side and records the exact string it was handed —
/// which is the whole question for the mixed-case scheme bug, since the case is lost (or
/// not) before the platform is ever reached.
class _FakeLauncher extends UrlLauncherPlatform
    with MockPlatformInterfaceMixin {
  final List<String> opened = [];

  /// Answered false, as the OS answers for a scheme no installed app claims.
  final Set<String> refuse = {};

  /// Thrown on every call, as a platform exception would be.
  Object? error;

  @override
  LinkDelegate? get linkDelegate => null;

  // `launch`, not `launchUrl`: the legacy entry point exists in every version of the
  // platform interface. The Flutter 3.3.0 floor resolves one with no `launchUrl` at all, and
  // newer ones route their default `launchUrl` through this, so one override covers both.
  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    if (error != null) throw error!;
    if (refuse.contains(url)) return false;
    opened.add(url);
    return true;
  }
}

/// `intentTargets` is the whole of the `intent://` fix, and it is pure — the launch itself
/// needs a device, but deciding *what* to launch does not, and that is where the bug was.
void main() {
  group('openExternal', () {
    late _FakeLauncher launcher;

    setUp(() {
      launcher = _FakeLauncher();
      UrlLauncherPlatform.instance = launcher;
    });

    test('keeps a mixed-case scheme exactly as the gateway wrote it', () async {
      // The bug: Dart's Uri lowercases the scheme, IntentFilter matching is case-sensitive,
      // and Fonepay's app registers `fonepayApp`. Launched through `launchUrl(Uri)` this
      // arrived as `fonepayapp://…` and no app on the device claimed it.
      final opened =
          await openExternal('fonepayApp://payment/?emandate=abc%3D%3D');

      expect(opened, isTrue);
      expect(launcher.opened, ['fonepayApp://payment/?emandate=abc%3D%3D']);
    });

    test('launches the deeplink an intent url names, case intact', () async {
      final opened = await openExternal(
          'intent://payment/?qrPayload=probe#Intent;scheme=fonepayApp;package=com.fonepay.stage;end');

      expect(opened, isTrue);
      expect(launcher.opened, ['fonepayApp://payment/?qrPayload=probe']);
    });

    test('falls back to the browser url when no app claims the deeplink',
        () async {
      const fallback =
          'https://play.google.com/store/apps/details?id=com.f1soft.esewa';
      launcher.refuse.add('fonepayApp://pay');

      final opened = await openExternal(
          'intent://pay#Intent;scheme=fonepayApp;S.browser_fallback_url=${Uri.encodeComponent(fallback)};end');

      expect(opened, isTrue);
      expect(launcher.opened, [fallback]);
    });

    test('reports failure when every candidate throws', () async {
      launcher.error = Exception('no activity found');

      final opened = await openExternal(
          'intent://pay#Intent;scheme=fonepayApp;S.browser_fallback_url=https%3A%2F%2Fexample.com;end');

      expect(opened, isFalse);
      expect(launcher.opened, isEmpty);
    });

    test('reports failure when the intent url names no target', () async {
      expect(
          await openExternal('intent://pay#Intent;package=com.x;end'), isFalse);
      expect(launcher.opened, isEmpty);
    });

    test('refuses a rebuilt candidate on a blocked scheme', () async {
      // A gateway page is not SUQO's, and `scheme=file` would otherwise reach the launcher.
      expect(await openExternal('intent://etc/passwd#Intent;scheme=file;end'),
          isFalse);
      expect(launcher.opened, isEmpty);
    });
  });

  group('intentTargets', () {
    const full =
        'intent://payment/?qrPayload=12345#Intent;scheme=fonepayApp;package=com.f1soft.esewa;'
        'S.browser_fallback_url=https%3A%2F%2Fplay.google.com%2Fstore%2Fapps%2Fdetails%3Fid%3Dcom.f1soft.esewa;end';

    test('rebuilds the deeplink the gateway meant, and puts it first', () {
      // This is the entire point: url_launcher cannot launch `intent://` — its Android side
      // builds ACTION_VIEW from Uri.parse, never Intent.parseUri — so the scheme in the
      // fragment has to be recombined with the body before anything can resolve.
      expect(
          intentTargets(full).first, 'fonepayApp://payment/?qrPayload=12345');
    });

    test('decodes the browser fallback and offers it after the deeplink', () {
      expect(intentTargets(full), [
        'fonepayApp://payment/?qrPayload=12345',
        'https://play.google.com/store/apps/details?id=com.f1soft.esewa',
      ]);
    });

    test('a fallback alone is still a target', () {
      // No `scheme=`: nothing to rebuild, but the Play Store page is better than nowhere,
      // and on iOS it is the only candidate that can ever launch.
      const noScheme =
          'intent://pay#Intent;package=com.x;S.browser_fallback_url=https%3A%2F%2Fexample.com%2Fget;end';
      expect(intentTargets(noScheme), ['https://example.com/get']);
    });

    test('a scheme alone is still a target', () {
      const noFallback =
          'intent://pay/?a=1#Intent;scheme=bank;package=com.x;end';
      expect(intentTargets(noFallback), ['bank://pay/?a=1']);
    });

    test('names no target when the fragment carries neither', () {
      expect(intentTargets('intent://pay#Intent;package=com.x;end'), isEmpty);
    });

    test('survives an undecodable fallback and keeps the deeplink', () {
      // Uri.decodeComponent throws on '%', '%ZZ' and a truncated UTF-8 sequence. This runs
      // outside openExternal's try, so a throw here became an unhandled async error with
      // no handoff_failed for the host — for a fallback URL that was never the main path.
      for (final bad in ['%', '%ZZ', '%E0%A4']) {
        final url =
            'intent://pay#Intent;scheme=bank;S.browser_fallback_url=$bad;end';
        expect(intentTargets(url), ['bank://pay'], reason: bad);
      }
    });

    test('drops a fallback that is not http(s)', () {
      // The fallback is the one field naming a whole URL rather than a scheme, so it is
      // what an attacker-controlled gateway page would reach for. Chrome restricts it to
      // http(s) for the same reason.
      for (final bad in [
        'javascript%3Aalert(1)',
        'file%3A%2F%2F%2Fetc%2Fpasswd'
      ]) {
        final url =
            'intent://pay#Intent;scheme=bank;S.browser_fallback_url=$bad;end';
        expect(intentTargets(url), ['bank://pay'], reason: bad);
      }
    });

    test('rewrites the authority-less intent: form too', () {
      // `intent:pay?q=1#Intent;…` is as valid as `intent://pay?q=1#…` and gateways emit
      // both. Slicing at a fixed `intent://` length ate the first two characters of the
      // path on this form, and the old `startsWith('intent://')` gate skipped it entirely.
      expect(
        intentTargets('intent:pay?q=1#Intent;scheme=bank;package=com.x;end'),
        ['bank://pay?q=1'],
      );
    });

    test('isIntentUrl covers both forms and nothing else', () {
      expect(isIntentUrl('intent://pay#Intent;end'), isTrue);
      expect(isIntentUrl('intent:pay#Intent;end'), isTrue);
      expect(isIntentUrl('INTENT://pay#Intent;end'), isTrue);
      expect(isIntentUrl('  intent://pay#Intent;end'), isTrue);
      expect(isIntentUrl('fonepayApp://pay'), isFalse);
      expect(isIntentUrl('https://a.com'), isFalse);
      // A scheme that merely starts with the same letters.
      expect(isIntentUrl('intentional://pay'), isFalse);
    });

    test('a leading space does not shift the body', () {
      // isIntentUrl accepts it, so the slice has to start from the trimmed string — off the
      // raw one, `intent:`'s length lands two characters early and the `//` survives.
      expect(intentTargets('  intent://pay/?q=1#Intent;scheme=bank;end'),
          ['bank://pay/?q=1']);
    });

    test('names no target without a fragment at all', () {
      // Not a real intent URL. Launching `intent://pay` as written is the old behaviour and
      // resolves to nothing, so saying so beats trying.
      expect(intentTargets('intent://pay'), isEmpty);
    });
  });
}
