import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:suqo_checkout/src/bridge.dart';
import 'package:suqo_checkout/src/types.dart';

/// An envelope as the page sends it.
String envelope(Map<String, Object?> fields) =>
    jsonEncode({'source': kMessageSource, ...fields});

void main() {
  group('the envelope', () {
    test('drops anything without our source tag', () {
      // A WebView's message channel is shared with whatever the page chooses to post.
      expect(parseInbound(jsonEncode({'type': 'suqo:ready'})), isNull);
      expect(
        parseInbound(jsonEncode({'source': 'other', 'type': 'suqo:ready'})),
        isNull,
      );
    });

    test('drops unparseable json rather than throwing', () {
      expect(parseInbound('not json at all'), isNull);
      expect(parseInbound(''), isNull);
    });

    test('drops a type it does not recognise', () {
      expect(parseInbound(envelope({'type': 'suqo:whatever'})), isNull);
    });
  });

  group('the signal messages', () {
    test('parses alive, ready and gateway', () {
      expect(
          parseInbound(envelope({'type': 'suqo:alive'})), isA<AliveMessage>());
      expect(
          parseInbound(envelope({'type': 'suqo:ready'})), isA<ReadyMessage>());
      expect(parseInbound(envelope({'type': 'suqo:gateway'})),
          isA<GatewayMessage>());
    });
  });

  group('suqo:resize', () {
    test('takes a usable height', () {
      final message =
          parseInbound(envelope({'type': 'suqo:resize', 'height': 412}));
      expect(message, isA<ResizeMessage>());
      expect((message! as ResizeMessage).height, 412.0);
    });

    test('drops a height that would collapse the sheet', () {
      for (final height in <Object?>[0, -10, 'tall', null]) {
        expect(
          parseInbound(envelope({'type': 'suqo:resize', 'height': height})),
          isNull,
          reason: '$height',
        );
      }
    });
  });

  group('suqo:result', () {
    test('round-trips each status', () {
      for (final status in ['success', 'failed', 'cancelled']) {
        final message = parseInbound(envelope({
          'type': 'suqo:result',
          'status': status,
          'params': {'pidx': 'k1'},
        }));
        expect(message, isA<ResultMessage>(), reason: status);
        expect((message! as ResultMessage).status, status);
      }
    });

    test('drops a status it does not recognise', () {
      expect(
        parseInbound(
            envelope({'type': 'suqo:result', 'status': 'maybe', 'params': {}})),
        isNull,
      );
    });

    test('passes the gateway params through verbatim', () {
      // Every gateway names its transaction id differently and the host reconciles against
      // what their own backend recorded. Renaming anything here throws away the only field
      // they can match on.
      final message = parseInbound(envelope({
        'type': 'suqo:result',
        'status': 'success',
        'params': {
          'data': 'e1',
          'pidx': 'k2',
          'MerchantTxnId': 'n3',
          'TXNID': 'c4',
        },
      }))! as ResultMessage;

      expect(message.params, {
        'data': 'e1',
        'pidx': 'k2',
        'MerchantTxnId': 'n3',
        'TXNID': 'c4',
      });
    });

    test('coerces primitives and drops everything else', () {
      // A map stringified into a reconciliation field looks like a real transaction
      // reference to code trying to match one.
      final message = parseInbound(envelope({
        'type': 'suqo:result',
        'status': 'success',
        'params': {
          'good': 'yes',
          'count': 7,
          'flag': true,
          'nested': {'a': 1},
          'nothing': null,
        },
      }))! as ResultMessage;

      expect(message.params, {'good': 'yes', 'count': '7', 'flag': 'true'});
    });

    test('omits message when the backend said nothing', () {
      // Null must be distinguishable from a real sentence: the host should never be handed
      // copy this package invented.
      final blank = parseInbound(envelope({
        'type': 'suqo:result',
        'status': 'failed',
        'params': {},
        'message': '',
      }))! as ResultMessage;
      expect(blank.message, isNull);

      final absent = parseInbound(envelope(
              {'type': 'suqo:result', 'status': 'failed', 'params': {}}))!
          as ResultMessage;
      expect(absent.message, isNull);
    });

    test("keeps the backend's own sentence when it sent one", () {
      final message = parseInbound(envelope({
        'type': 'suqo:result',
        'status': 'failed',
        'params': {},
        'message': 'Card declined.',
      }))! as ResultMessage;
      expect(message.message, 'Card declined.');
    });
  });

  group('suqo:unavailable', () {
    test('parses every reason the page can send', () {
      const expected = {
        'not-found': SuqoUnavailableReason.notFound,
        'expired': SuqoUnavailableReason.expired,
        'spent': SuqoUnavailableReason.spent,
        'no-customer': SuqoUnavailableReason.noCustomer,
        'no-methods': SuqoUnavailableReason.noMethods,
        'load-failed': SuqoUnavailableReason.loadFailed,
      };

      expected.forEach((wire, reason) {
        final message = parseInbound(
            envelope({'type': 'suqo:unavailable', 'reason': wire}));
        expect(message, isA<UnavailableMessage>(), reason: wire);
        expect((message! as UnavailableMessage).reason, reason, reason: wire);
      });
    });

    test('drops a reason it does not recognise rather than widening', () {
      expect(
        parseInbound(envelope({'type': 'suqo:unavailable', 'reason': 'vibes'})),
        isNull,
      );
    });
  });

  group('suqo:debug', () {
    test('defaults the level when the page sent none', () {
      final message =
          parseInbound(envelope({'type': 'suqo:debug', 'text': 'boom'}))!
              as DebugMessage;
      expect(message.level, 'log');
      expect(message.text, 'boom');
    });

    test('drops a payload with no text', () {
      expect(parseInbound(envelope({'type': 'suqo:debug'})), isNull);
    });
  });

  test('drops suqo:redirect, which cannot apply to this host', () {
    // It exists for a plain WebView that injects no bridge. Under this SDK the page always
    // sees a native host, opens the gateway in this same window, and never asks anyone to
    // navigate for it.
    expect(
      parseInbound(
          envelope({'type': 'suqo:redirect', 'url': 'https://x.test/y'})),
      isNull,
    );
  });

  test('drops suqo:intent, which cannot apply to this host', () {
    // It exists for the browser SDKs, whose sandboxed frame cannot navigate the merchant's
    // page. This WebView already navigates to a deeplink in the same window, and
    // classifyNavigation lifts it to the OS — acting on this too would be a second,
    // redundant path to the same picker.
    expect(
      parseInbound(envelope(
          {'type': 'suqo:intent', 'url': 'intent://payment/#Intent;end'})),
      isNull,
    );
  });

  group('buildDebugScript', () {
    test('posts through the channel name the page probes for', () {
      // If this drifts from `kJavaScriptChannel` the forwarder silently stops reporting.
      final script = buildDebugScript();
      expect(script, contains('window.$kJavaScriptChannel'));
      expect(script, contains(kMessageSource));
    });
  });
}
