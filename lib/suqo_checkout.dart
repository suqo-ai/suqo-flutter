/// `suqo_checkout` — collect a SUQO payment on a full-screen checkout screen.
///
/// The host app's own backend creates the checkout session and holds its id. This package
/// opens SUQO's own checkout page for that id, lets the buyer pay, and reports the outcome
/// the page verified. It makes **no SUQO API calls of its own and holds no credential**.
///
/// ```dart
/// final outcome = await SuqoCheckout.open(context, sessionId: 'cks_9f2c41a8');
/// if (outcome is SuqoSuccess) {
///   // move the buyer on — the webhook is what settles the order
/// }
/// ```
library suqo_checkout;

export 'src/errors.dart' show SuqoConfigError;
export 'src/suqo_checkout.dart' show SuqoCheckout;
export 'src/suqo_provider.dart' show SuqoProvider;
export 'src/types.dart'
    show
        ReturnParams,
        SuqoClosed,
        SuqoEvent,
        SuqoEventSink,
        SuqoFailure,
        SuqoFailureStatus,
        SuqoMode,
        SuqoOutcome,
        SuqoSuccess,
        SuqoUnavailableReason;
export 'src/urls.dart'
    show kDefaultCheckoutPath, kLiveOrigin, kSandboxOrigin, resolveBaseUrl;

/// This package's version, as published. The release PR keeps it equal to pubspec.yaml
/// (scripts/set-version.mjs), and test/version_test.dart checks it.
const String suqoCheckoutVersion = '0.1.1';
