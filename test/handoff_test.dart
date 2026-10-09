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

    test('names no target without a fragment at all', () {
      // Not a real intent URL. Launching `intent://pay` as written is the old behaviour and
      // resolves to nothing, so saying so beats trying.
      expect(intentTargets('intent://pay'), isEmpty);
    });
  });
}
