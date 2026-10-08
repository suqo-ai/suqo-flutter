// The only module in this package permitted to print.
//
// Everything routes through here because this is where redaction happens. A session id
// identifies a payable thing and a gateway's return params carry transaction references; in
// a host app's logs — or in a crash reporter's breadcrumbs, which scoop up console output —
// neither belongs in the clear.
//
// Logging is off unless the host passes `debug`.

import 'package:flutter/foundation.dart';

bool _enabled = false;

/// Turns SDK logging on or off. Called by the SDK; not part of the public API.
void setDebug(bool on) {
  _enabled = on;
}

/// Readable by tests, so they can assert the default without reaching into private state.
@visibleForTesting
bool get debugEnabled => _enabled;

final RegExp _uuidRe = RegExp(
  r'\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b',
  caseSensitive: false,
);

/// Checkout session ids, which are not UUID-shaped.
///
/// Without this the shape-based half of redaction quietly stops working: [_uuidRe] was the
/// only thing catching a bare id in free text, and a session id matches none of it. A backend
/// error string mentioning one would print in full.
final RegExp _sessionIdRe = RegExp(r'\bcks_[A-Za-z0-9_-]+');

/// Scrubs identifiers out of a string by **shape**, not by the key that carried it.
///
/// Shape-based is the load-bearing half: an id interpolated into a message, or embedded in a
/// backend error string, never arrives under a name we could deny-list.
String redactString(String value) {
  return value
      .replaceAll(_uuidRe, '<id>')
      .replaceAll(_sessionIdRe, '<id>')
      .replaceAllMapped(RegExp(r'(/c/)[^/?#\s]+'), (m) => '${m[1]}<id>')
      .replaceAllMapped(RegExp(r'(/checkout/)[^/?#\s]+'), (m) => '${m[1]}<id>')
      .replaceAllMapped(RegExp(r'(/r/)[^/?#\s]+'), (m) => '${m[1]}<id>')
      .replaceAll(RegExp(r'\?[^\s]*'), '?<params>');
}

const Set<String> _redactedKeys = {
  'sessionId',
  'session_id',
  'id',
  'params',
  'url',
  'uri',
  'message',
};

/// Scrubs a field bag by key name **and** by value shape. Both, because either alone leaks.
Map<String, Object?> redactFields(Map<String, Object?> fields) {
  final out = <String, Object?>{};
  fields.forEach((key, value) {
    if (_redactedKeys.contains(key)) {
      out[key] = '<redacted>';
    } else if (value is String) {
      out[key] = redactString(value);
    } else {
      out[key] = value;
    }
  });
  return out;
}

/// Emits one redacted log line.
///
/// Redaction runs **before** the enabled check on purpose. Were it after, a redaction bug
/// would only ever manifest with debug on — which is precisely the configuration no test
/// runs in by default.
void log(String event, [Map<String, Object?>? fields]) {
  final safe = fields == null ? null : redactFields(fields);
  if (!_enabled) return;
  debugPrint('[suqo] $event ${safe ?? ''}');
}
