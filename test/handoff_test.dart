import 'package:flutter_test/flutter_test.dart';
import 'package:suqo_checkout/src/handoff.dart';

/// `intentTargets` is the whole of the `intent://` fix, and it is pure — the launch itself
/// needs a device, but deciding *what* to launch does not, and that is where the bug was.
void main() {
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
      expect(isIntentUrl('fonepayApp://pay'), isFalse);
      expect(isIntentUrl('https://a.com'), isFalse);
    });

    test('names no target without a fragment at all', () {
      // Not a real intent URL. Launching `intent://pay` as written is the old behaviour and
      // resolves to nothing, so saying so beats trying.
      expect(intentTargets('intent://pay'), isEmpty);
    });
  });
}
