import 'package:flutter/material.dart';

import '../theme.dart';

/// Which deadline elapsed, or a load failure. Decides the copy, not the layout.
enum LoadErrorReason { alive, ready, load }

const Map<LoadErrorReason, List<String>> _copy = {
  LoadErrorReason.alive: [
    "Couldn't reach the payment page",
    'Check the connection and try again.',
  ],
  LoadErrorReason.ready: [
    'The payment page is taking too long',
    'It loaded but never finished starting up.',
  ],
  LoadErrorReason.load: [
    "Couldn't load the payment page",
    'Check the connection and try again.',
  ],
};

/// Shown when a deadline elapses or the page fails to load.
///
/// It reports a *loading* failure and nothing about the payment, because at this point no
/// payment has been attempted. Retry remounts the WebView; close settles the session as
/// dismissed.
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.reason,
    required this.onRetry,
    required this.onClose,
  });

  final LoadErrorReason reason;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final copy = _copy[reason]!;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(kSuqoSpaceXl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              copy[0],
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: kSuqoText,
              ),
            ),
            const SizedBox(height: kSuqoSpaceSm),
            Text(
              copy[1],
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 14, color: kSuqoMuted),
            ),
            const SizedBox(height: kSuqoSpaceXl),
            ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: kSuqoPrimary,
                foregroundColor: Colors.white,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  vertical: kSuqoSpaceMd,
                  horizontal: kSuqoSpaceXl,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(kSuqoButtonRadius),
                ),
              ),
              child: const Text(
                'Try again',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(height: kSuqoSpaceMd),
            TextButton(
              onPressed: onClose,
              child: const Text(
                'Close',
                style: TextStyle(fontSize: 14, color: kSuqoMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
