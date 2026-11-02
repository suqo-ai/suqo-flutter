import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:suqo_checkout/suqo_checkout.dart';

void main() {
  // The release PR bumps both through scripts/set-version.mjs. A hand edit to
  // only one of them would publish a package that reports the wrong version.
  test('suqoCheckoutVersion matches pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match =
        RegExp(r'^version: (\S+)\s*$', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml has no version line');
    expect(suqoCheckoutVersion, match!.group(1));
  });
}
