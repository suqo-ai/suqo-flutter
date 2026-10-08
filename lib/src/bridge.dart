// The wire between this SDK and the SUQO checkout page inside the WebView.
//
// It runs in one direction. The page is a checkout session — created on the merchant's
// backend, already carrying the buyer — so there is nothing this SDK knows that the page
// needs, and nothing is ever injected into it but the optional debug forwarder.
//
// What makes the page reachable at all is the channel name below. The page probes for
// `window.SuqoWebView` first and `window.ReactNativeWebView` second, and treats either as a
// native host; the SUQO web app calls `SuqoWebView` "vendor-neutral — any host in any
// language implements it and needs no SDK from us". Registering a Flutter JavaScript
// channel under that exact name is therefore the whole integration: no change is required
// on the page's side for Flutter specifically.

import 'dart:convert';

import 'types.dart';

/// Every message carries this. Anything without it is ignored.
const String kMessageSource = 'suqo-checkout';

/// The JavaScript channel name the checkout page probes for.
///
/// Must stay exactly this. `webview_flutter`'s `addJavaScriptChannel` exposes a channel as
/// `window.<name>.postMessage(string)`, which is precisely the shape the page's
/// `nativeBridge()` looks for. Rename it and the page stops recognising a native host — it
/// then renders, reports nothing, and the sheet sits on its loading state forever.
const String kJavaScriptChannel = 'SuqoWebView';

/// A message the page sends us. Mirrors the frame-to-host half of the browser protocol.
///
/// Closed by a private constructor, like [SuqoOutcome].
abstract class InboundMessage {
  const InboundMessage._();
}

/// The document loaded and is running scripts.
class AliveMessage extends InboundMessage {
  const AliveMessage() : super._();
}

/// The payment block is on screen.
class ReadyMessage extends InboundMessage {
  const ReadyMessage() : super._();
}

/// The block's content height, in CSS pixels.
class ResizeMessage extends InboundMessage {
  const ResizeMessage(this.height) : super._();
  final double height;
}

/// The page is handing off to a gateway.
class GatewayMessage extends InboundMessage {
  const GatewayMessage() : super._();
}

/// Only when `debug` is on: something the page logged, threw, or requested.
class DebugMessage extends InboundMessage {
  const DebugMessage(this.level, this.text) : super._();
  final String level;
  final String text;
}

/// The session cannot be paid at all. Not a payment outcome — nothing was attempted.
///
/// The page renders its own explanation and the buyer dismisses, so this changes nothing
/// about the sheet; it exists so the reason reaches the host's event stream.
class UnavailableMessage extends InboundMessage {
  const UnavailableMessage(this.reason) : super._();
  final SuqoUnavailableReason reason;
}

/// The payment settled, and the page has already verified it with the backend.
class ResultMessage extends InboundMessage {
  const ResultMessage(this.status, this.params, this.message) : super._();

  /// `success` | `failed` | `cancelled`.
  final String status;
  final ReturnParams params;
  final String? message;
}

const Set<String> _resultStatuses = {'success', 'failed', 'cancelled'};

const Map<String, SuqoUnavailableReason> _unavailableReasons = {
  'not-found': SuqoUnavailableReason.notFound,
  'expired': SuqoUnavailableReason.expired,
  'spent': SuqoUnavailableReason.spent,
  'no-customer': SuqoUnavailableReason.noCustomer,
  'no-methods': SuqoUnavailableReason.noMethods,
  'load-failed': SuqoUnavailableReason.loadFailed,
};

/// Narrows the gateway's return params to string values.
///
/// Values arrive as whatever the page put in them; anything non-primitive is dropped rather
/// than stringified into a map's `toString()`, which would look like a real transaction
/// reference to code trying to reconcile one.
ReturnParams _coerceParams(Object? value) {
  if (value is! Map) return <String, String>{};
  final out = <String, String>{};
  value.forEach((key, raw) {
    if (key is! String) return;
    if (raw is String) {
      out[key] = raw;
    } else if (raw is num || raw is bool) {
      out[key] = raw.toString();
    }
  });
  return out;
}

/// Parses one channel payload, returning null for anything this SDK does not own.
///
/// A WebView's message channel is shared with whatever the page chooses to post, so this is
/// the boundary that decides what counts as a protocol message. Unparseable JSON, a missing
/// `source`, or an unrecognised `type` are all normal traffic, not errors.
InboundMessage? parseInbound(String raw) {
  Object? data;
  try {
    data = jsonDecode(raw);
  } on FormatException {
    return null;
  }

  if (data is! Map) return null;
  if (data['source'] != kMessageSource) return null;

  switch (data['type']) {
    case 'suqo:alive':
      return const AliveMessage();

    case 'suqo:ready':
      return const ReadyMessage();

    case 'suqo:gateway':
      return const GatewayMessage();

    case 'suqo:resize':
      final height = data['height'];
      // A non-finite or non-positive height would collapse the sheet. The page measures a
      // real element, so anything else means the measurement, not the sheet, is wrong.
      if (height is! num || !height.isFinite || height <= 0) return null;
      return ResizeMessage(height.toDouble());

    case 'suqo:debug':
      final text = data['text'];
      if (text is! String) return null;
      final level = data['level'];
      return DebugMessage(level is String ? level : 'log', text);

    case 'suqo:result':
      final status = data['status'];
      if (status is! String || !_resultStatuses.contains(status)) return null;
      final message = data['message'];
      return ResultMessage(
        status,
        _coerceParams(data['params']),
        message is String && message.isNotEmpty ? message : null,
      );

    case 'suqo:unavailable':
      final reason = data['reason'];
      // An unrecognised reason is dropped rather than widened. Passing an arbitrary string
      // through would make the host's own handling non-exhaustive for a value we never send.
      if (reason is! String) return null;
      final parsed = _unavailableReasons[reason];
      if (parsed == null) return null;
      return UnavailableMessage(parsed);

    // `suqo:redirect` lands here and is dropped, correctly. It exists for a plain WebView
    // that injects no bridge at all; under this SDK the page always sees a native host,
    // opens the gateway in this same window, and never asks anyone to navigate on its behalf.
    //
    // `suqo:intent` lands here too, also correctly. It exists for the browser SDKs, where
    // the checkout frame is sandboxed and cannot navigate the merchant's page itself — so it
    // asks the host to forward a deeplink to the merchant's own code instead. Nothing here is
    // sandboxed: this WebView already navigates to a bank/wallet deeplink in the same window,
    // and `classifyNavigation` in `urls.dart` lifts it to the OS without anyone having to
    // ask. Handling this message too would be a second, redundant path to the same OS picker.
    default:
      return null;
  }
}

/// Forwards the page's own failures to the host's console. Only used when `debug` is on.
///
/// A WebView is otherwise opaque: a page that hangs mid-load looks identical to a page that
/// threw, and neither reaches the Dart console the developer is already watching.
///
/// Unlike the React Native SDK, this cannot be injected before the page's own scripts run —
/// `webview_flutter` has no document-start injection (flutter/flutter#105202), so the
/// earliest available hook is `onPageStarted`. A throw during the page's very first
/// evaluation can therefore be missed. Best-effort on purpose, and debug-only.
String buildDebugScript() {
  return '''
(function(){
  if (window.__suqoDebug) return;
  window.__suqoDebug = true;
  var send = function (level, text) {
    try {
      if (!window.$kJavaScriptChannel) return;
      window.$kJavaScriptChannel.postMessage(JSON.stringify({
        source: '$kMessageSource', type: 'suqo:debug', level: level, text: String(text).slice(0, 500)
      }));
    } catch (e) {}
  };
  window.addEventListener('error', function (event) {
    send('error', (event && event.message) || 'script error');
  });
  window.addEventListener('unhandledrejection', function (event) {
    var reason = event && event.reason;
    send('error', 'unhandled rejection: ' + ((reason && (reason.message || reason)) || 'unknown'));
  });
  var wrap = function (level) {
    var original = console[level];
    console[level] = function () {
      try { send(level, Array.prototype.join.call(arguments, ' ')); } catch (e) {}
      if (original) original.apply(console, arguments);
    };
  };
  wrap('error');
  wrap('warn');
  // Every request the page makes, so a call that never comes back is visible as a request
  // with no matching response.
  var open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.addEventListener('loadend', function () {
      send('net', method + ' ' + url + ' -> ' + this.status);
    });
    send('net', method + ' ' + url + ' ...');
    return open.apply(this, arguments);
  };
})();
''';
}
