import 'package:flutter/material.dart';

import '../theme.dart';

/// Title and a back affordance, and nothing else.
///
/// There is no amount or seller name here on purpose: the payment page inside the WebView
/// renders both, from the session it already resolved. Repeating them in native chrome would
/// mean this SDK holding a second copy of figures it never fetched, and the two disagreeing
/// the moment an offer or a VAT rule changes.
class SuqoHeader extends StatelessWidget {
  const SuqoHeader({super.key, required this.title, required this.onBack});

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: kSuqoSurface,
        border: Border(bottom: BorderSide(color: kSuqoBorder)),
      ),
      child: SizedBox(
        height: 52,
        child: Row(
          children: [
            // Sized so the row's height does not depend on the icon, and so the title's
            // optical centre survives a long title eliding.
            SizedBox(
              width: 52,
              child: IconButton(
                onPressed: onBack,
                tooltip: 'Go back',
                icon: const Icon(Icons.arrow_back_ios_new,
                    size: 18, color: kSuqoText),
              ),
            ),
            Expanded(
              child: Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: kSuqoText,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // Balances the back button so the title stays optically centred.
            const SizedBox(width: 52),
          ],
        ),
      ),
    );
  }
}
