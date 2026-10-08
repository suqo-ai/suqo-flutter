import 'package:flutter_test/flutter_test.dart';
import 'package:suqo_checkout/src/errors.dart';
import 'package:suqo_checkout/src/types.dart';
import 'package:suqo_checkout/src/urls.dart';

void main() {
  group('buildCheckoutUrl', () {
    test('builds the default embedded checkout route', () {
      expect(
        buildCheckoutUrl('https://test.suqo.ai', 'cks_abc'),
        'https://test.suqo.ai/c/cks_abc',
      );
    });

    test('trims trailing slashes off the base url', () {
      expect(
        buildCheckoutUrl('https://test.suqo.ai///', 'cks_abc'),
        'https://test.suqo.ai/c/cks_abc',
      );
    });

    test('substitutes :id anywhere in a custom path', () {
      expect(
        buildCheckoutUrl('https://test.suqo.ai', 'cks_abc', '/pay/:id/now'),
        'https://test.suqo.ai/pay/cks_abc/now',
      );
    });

    test('appends the id to a path that names no :id', () {
      expect(
        buildCheckoutUrl('https://test.suqo.ai', 'cks_abc', '/pay/'),
        'https://test.suqo.ai/pay/cks_abc',
      );
    });

    test('percent-encodes the session id', () {
      expect(
        buildCheckoutUrl('https://test.suqo.ai', 'a/b c'),
        'https://test.suqo.ai/c/a%2Fb%20c',
      );
    });

    test('refuses a base url that is not http(s)', () {
      // The sheet would otherwise load whatever this resolved to, which for a
      // `javascript:` value is script execution inside the payment surface.
      expect(
        () => buildCheckoutUrl('javascript:alert(1)', 'cks_abc'),
        throwsA(isA<SuqoConfigError>()),
      );
      expect(
        () => buildCheckoutUrl('test.suqo.ai', 'cks_abc'),
        throwsA(isA<SuqoConfigError>()),
      );
    });

    test('refuses an empty session id', () {
      expect(
        () => buildCheckoutUrl('https://test.suqo.ai', '   '),
        throwsA(isA<SuqoConfigError>()),
      );
    });
  });

  group('resolveBaseUrl', () {
    test('defaults to the sandbox origin when neither is given', () {
      // Defaulting to live would mean an app that configured nothing takes real money.
      expect(resolveBaseUrl(null), kSandboxOrigin);
      expect(resolveBaseUrl(null, null), kSandboxOrigin);
    });

    test('picks the origin for mode when no explicit base url is given', () {
      expect(resolveBaseUrl(null, SuqoMode.live), kLiveOrigin);
      expect(resolveBaseUrl(null, SuqoMode.sandbox), kSandboxOrigin);
      expect(resolveBaseUrl('', SuqoMode.live), kLiveOrigin);
      expect(resolveBaseUrl('   ', SuqoMode.live), kLiveOrigin);
    });

    test('lets an explicit base url override mode', () {
      expect(
        resolveBaseUrl('http://localhost:8787', SuqoMode.live),
        'http://localhost:8787',
      );
    });
  });

  group('classifyNavigation', () {
    test('allows http and https', () {
      expect(classifyNavigation('https://test.suqo.ai/c/x').kind,
          NavigationKind.allow);
      expect(classifyNavigation('http://localhost:3000/c/x').kind,
          NavigationKind.allow);
    });

    test('allows about:blank, the initial load', () {
      expect(classifyNavigation('about:blank').kind, NavigationKind.allow);
    });

    test('allows a relative, scheme-less url', () {
      expect(classifyNavigation('/payment-success?x=1').kind,
          NavigationKind.allow);
    });

    test('allows a gateway return page', () {
      // Intercepting it to read the outcome off the query string would skip the
      // verification call that page exists to make.
      expect(
        classifyNavigation('https://test.suqo.ai/payment-success?pidx=k1').kind,
        NavigationKind.allow,
      );
    });

    test('hands off a bank app deeplink', () {
      final nav = classifyNavigation('fonepayApp://payment/?emandate=abc');
      expect(nav.kind, NavigationKind.handoff);
      expect(nav.scheme, 'fonepayapp');
    });

    test('hands off an Android intent url', () {
      final nav = classifyNavigation('intent://payment/#Intent;scheme=x;end');
      expect(nav.kind, NavigationKind.handoff);
      expect(nav.scheme, 'intent');
    });

    test('blocks the schemes that have no business in a payment flow', () {
      for (final url in [
        'javascript:alert(1)',
        'data:text/html,<h1>hi',
        'file:///etc/passwd',
        'blob:https://test.suqo.ai/1234',
      ]) {
        expect(classifyNavigation(url).kind, NavigationKind.block, reason: url);
      }
    });

    test('is case-insensitive about the scheme', () {
      expect(
          classifyNavigation('JAVASCRIPT:alert(1)').kind, NavigationKind.block);
      expect(classifyNavigation('HTTPS://test.suqo.ai').kind,
          NavigationKind.allow);
    });
  });

  group('isAppHandoff', () {
    test('is true only for a handoff', () {
      expect(isAppHandoff('fonepayApp://x'), isTrue);
      expect(isAppHandoff('https://test.suqo.ai'), isFalse);
      expect(isAppHandoff('javascript:alert(1)'), isFalse);
    });
  });
}
