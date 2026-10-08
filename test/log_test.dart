import 'package:flutter_test/flutter_test.dart';
import 'package:suqo_checkout/src/log.dart';

void main() {
  group('redactString', () {
    test('scrubs a UUID wherever it appears', () {
      expect(
        redactString(
            'subscription 3f2504e0-4f89-11d3-9a0c-0305e82c3301 failed'),
        'subscription <id> failed',
      );
    });

    test('scrubs a checkout session id, which is not UUID-shaped', () {
      // The shape half of redaction is what catches an id interpolated into a backend
      // error string, where no key name could.
      expect(
        redactString('Session cks_9f2c41a8 is already spent'),
        'Session <id> is already spent',
      );
    });

    test('scrubs the id out of every route that carries one', () {
      expect(redactString('https://test.suqo.ai/c/cks_abc'),
          'https://test.suqo.ai/c/<id>');
      expect(redactString('https://test.suqo.ai/checkout/cks_abc'),
          'https://test.suqo.ai/checkout/<id>');
      expect(redactString('https://test.suqo.ai/r/abc'),
          'https://test.suqo.ai/r/<id>');
    });

    test('scrubs the whole query string', () {
      // Gateway return params ride in it, and those are transaction references.
      expect(
        redactString('https://test.suqo.ai/payment-success?pidx=k1&amt=900'),
        'https://test.suqo.ai/payment-success?<params>',
      );
    });

    test('leaves text with nothing sensitive in it alone', () {
      expect(redactString('webview.loaded'), 'webview.loaded');
    });
  });

  group('redactFields', () {
    test('redacts by key name', () {
      expect(
        redactFields({
          'sessionId': 'cks_abc',
          'session_id': 'cks_abc',
          'id': 'cks_abc',
          'params': {'pidx': 'k1'},
          'url': 'https://test.suqo.ai/c/cks_abc',
          'uri': 'https://test.suqo.ai/c/cks_abc',
          'message': 'Card declined',
        }),
        {
          'sessionId': '<redacted>',
          'session_id': '<redacted>',
          'id': '<redacted>',
          'params': '<redacted>',
          'url': '<redacted>',
          'uri': '<redacted>',
          'message': '<redacted>',
        },
      );
    });

    test('redacts by value shape under a key nobody deny-listed', () {
      // Both halves are needed: either alone leaks.
      expect(
        redactFields({'detail': 'GET https://test.suqo.ai/c/cks_abc -> 200'}),
        {'detail': 'GET https://test.suqo.ai/c/<id> -> 200'},
      );
    });

    test('passes non-string values through untouched', () {
      expect(
        redactFields({'supported': false, 'height': 412, 'nothing': null}),
        {'supported': false, 'height': 412, 'nothing': null},
      );
    });
  });

  group('log', () {
    test('is off until the host asks for it', () {
      // The default matters: a host that never passes `debug` should get no output at all.
      expect(debugEnabled, isFalse);
    });

    test('redacts before checking whether logging is on', () {
      // Redaction runs first on purpose. Were it after the enabled check, a redaction bug
      // would only ever manifest with debug on — the configuration no test runs in.
      expect(() => log('handoff.attempt', {'url': 'cks_abc'}), returnsNormally);
      expect(debugEnabled, isFalse);
    });

    test('setDebug flips it both ways', () {
      addTearDown(() => setDebug(false));

      setDebug(true);
      expect(debugEnabled, isTrue);
      setDebug(false);
      expect(debugEnabled, isFalse);
    });
  });
}
