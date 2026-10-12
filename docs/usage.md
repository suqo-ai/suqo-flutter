# Using `suqo_checkout`

A guide for apps collecting a SUQO payment from Flutter. For the wire protocol this package
implements against the SUQO web app, see `js-checkout/docs/protocol.md` in the `js-checkout`
repo — §8 and the "Host" checklist cover the native-host contract specifically.

## What it is

Your backend creates a **checkout session** through SUQO's API and hands your app its id. This
package opens SUQO's own checkout page for that id on a full-screen route, lets the buyer pay,
and tells you how it went.

It makes **no SUQO API calls of its own and holds no credential**. The gateway list, the
payment call, the hand-off to eSewa / Khalti / ConnectIPS / NPS, and the verification all
belong to the page inside the WebView. The session id is the only thing this package knows —
single-use, short-lived, and carrying no buyer details of its own — so nothing sensitive and
nothing long-lived ever sits in your app bundle.

**The session must already have a customer assigned when you create it.** This package has no
way to attach one — there is no buyer-detail argument anywhere on `open` — so a session created
without one opens the screen, shows the page's own "can't be paid" explanation, and reports
`SuqoUnavailableReason.noCustomer` on `onEvent` rather than ever reaching a payable state.
Assign the customer on your backend, through the checkout-session API, before you hand the id
to `open`.

```
flutter pub add suqo_checkout
```

That pulls `webview_flutter` and `url_launcher` with it. The only platform configuration is
[one manifest block on Android](#android-declare-the-schemes-your-gateways-use), and only if
your gateways hand off to bank apps.

## Quick start

```dart
import 'package:suqo_checkout/suqo_checkout.dart';

final outcome = await SuqoCheckout.open(context, sessionId: 'cks_9f2c41a8');

if (outcome is SuqoSuccess) {
  // move the buyer on
}
```

That is the whole integration. `open` pushes a full-screen route and completes with **exactly
one** `SuqoOutcome` once the buyer is done with it.

`SuqoMode.live` points at `app.suqo.ai`; the default, `SuqoMode.sandbox`, points at
`test.suqo.ai` — so an app that names neither cannot accidentally take a live payment. Pass
`baseUrl` to go somewhere else entirely (a staging mirror, a local mock server); it overrides
`mode` when set.

### There is no provider to mount

Unlike `@suqo/react-native`, which needs one because it owns the single checkout sheet,
`SuqoProvider` here holds configuration and nothing else — `Navigator` already gives a screen
that returns a result, so there is nothing for a provider to own. Mount it only to stop
repeating yourself:

```dart
SuqoProvider(
  mode: SuqoMode.sandbox,
  debug: true,
  child: MaterialApp(home: MyApp()),
)
```

Every value it sets can also be passed per call, and a per-call value always wins. With no
provider mounted, the package defaults apply.

## There is nothing about the buyer here

The checkout session is created on your own backend with your API key, and it must already
carry the buyer by the time you pass its id to `open`. Their name, email and address never
pass through this SDK, never reach the device, and never end up in a log, because there is
nothing for you to validate or supply here. Create the session with a customer attached; this
package cannot attach one for you.

`open` throws `SuqoConfigError` **before anything is shown**, for exactly two reasons: an empty
session id, or a base URL that is not `http(s)` and so cannot produce a checkout URL. Catch it
with `on SuqoConfigError` rather than matching its message.

Note what is *not* on that list: there is no "a checkout is already open" guard, because there
is no single sheet to guard. Two overlapping `open` calls push two routes and settle two
independent sessions. That is coherent but rarely what you meant — if your UI can fire the
same button twice, disable it while the future is pending.

## Outcomes

```dart
final outcome = await SuqoCheckout.open(context, sessionId: 'cks_9f2c41a8');
```

One of three, and never more than one per call. All three carry `sessionId`:

| Type | Carries | Means |
| --- | --- | --- |
| `SuqoSuccess` | `params`, `message?` | The page verified the payment with SUQO's backend. |
| `SuqoFailure` | `status`, `params`, `message?` | `failed` or `cancelled` — see below. |
| `SuqoClosed` | — | Dismissed before anything settled. Nothing was charged. |

There is no callback API — no `onSuccess` / `onFailure` / `onClose` as the JavaScript SDKs
have. The awaited outcome *is* the result.

Dart 2.18 has no `sealed`, so the compiler will not tell you an `is`-chain missed a case.
`when` will — it takes a callback per case and cannot be written incompletely:

```dart
final message = outcome.when(
  success: (s) => 'Paid — ${s.params}',
  failure: (f) => f.status == SuqoFailureStatus.cancelled
      ? 'Buyer backed out'
      : 'Payment rejected: ${f.message}',
  closed: (_) => 'Dismissed before anything settled',
);
```

### Dismissing it yourself

There is no `close()`. The screen is an ordinary route, so `Navigator.of(context).pop()`
dismisses it and the pending `open` completes as `SuqoClosed` — the same outcome a buyer gets
from the back button or an Android hardware back press. A caller that drives both sees one
consistent shape regardless of who ended it.

A result that arrives from the page **after** that pop (the buyer dismissed, but the page had
already verified the payment with the backend a frame later) still wins: a verified result
always beats an earlier dismissal, because telling the app "nothing happened" while the buyer's
money moved would be the one actionable lie this SDK could tell. Only one outcome is ever
delivered either way.

## `cancelled` is not `failed`

`SuqoFailure.status` is `SuqoFailureStatus.cancelled` when the buyer backed out at the gateway,
and `failed` when a payment was attempted and rejected. Check it: a buyer who changed their
mind wants the basket offered again, while a rejected payment is worth looking into. Nothing is
charged in either case.

## `params` is the gateway's, verbatim

Every gateway names its transaction differently — eSewa a signed `data` blob, Khalti a `pidx`,
ConnectIPS a `TXNID`, NPS a `MerchantTxnId`. `params` is passed through with no renaming or
filtering, because you reconcile against whatever your own backend recorded, and normalising
would throw away the only field you can match on.

`message` is what SUQO's backend said when it settled the payment — separate from `params` so
our keys never mix into the gateway's. It is `null` when the backend said nothing, so it is
never copy this SDK invented; on a failure it is usually the only place the reason exists.

## The outcome is a signal to navigate, not proof of fulfilment

`SuqoSuccess` arrives only after the checkout page verified the payment with SUQO's backend, so
it is a real signal rather than a redirect's claim. Even so, **the webhook is authoritative**.
Treat it as "move the buyer on", and let your own backend decide an order is paid from its own
record.

## Options

Every argument is named, and falls back to the nearest `SuqoProvider`, then to the package
default.

| Argument       | Default                    | Notes                                                         |
| -------------- | -------------------------- | ------------------------------------------------------------- |
| `sessionId`    | —                          | **Required.** The checkout session to pay, e.g. `cks_9f2c41a8`. |
| `mode`         | `SuqoMode.sandbox`         | `live` → `app.suqo.ai`, `sandbox` → `test.suqo.ai`.             |
| `baseUrl`      | —                          | Where SUQO's checkout is served from. Overrides `mode`.         |
| `checkoutPath` | `/c/:id`                   | The route, with `:id` for the checkout session id.              |
| `title`        | `Secure payment`           | Screen header. The amount and seller are rendered by the page.  |
| `loadingLabel` | `Loading secure checkout`  | The line under the spinner. Pass `''` for a spinner alone.      |
| `debug`        | `false`                    | Turns on this package's redacted logging.                       |
| `onEvent`      | —                          | A debug stream for your own logs. Not a payment signal.         |

There is no `insets` argument. The React Native package has one because React Native has no
built-in safe-area values and has to measure them with a platform heuristic; Flutter has
`MediaQuery.viewPadding`, which is the real thing, so the screen reads it and there is nothing
to pass.

### `onEvent` — every shape it can send

`onEvent` is a debug stream, not a payment signal — the awaited outcome is that. Every event
carries `sessionId` and a `type`; the other fields are null unless the row below names them.

| `type`           | When                                                                          |
| ---------------- | ----------------------------------------------------------------------------- |
| `open`           | `open` was called and the screen is about to show.                             |
| `alive`          | The document loaded and ran scripts.                                           |
| `ready`          | The payment block is on screen.                                                |
| `resize`         | `height` — reported, but nothing here is sized by it.                          |
| `gateway`        | The page is navigating this WebView to a gateway.                              |
| `handoff`        | `scheme` — a bank/wallet deeplink was handed to the OS.                        |
| `handoff_failed` | `scheme` — the OS had nothing registered to open it.                           |
| `load_timeout`   | `stage` (`'alive'` or `'ready'`) — a load deadline elapsed.                    |
| `load_error`     | The WebView itself failed to load the page.                                    |
| `unavailable`    | `reason` — the session cannot be paid at all. See below.                       |
| `settled`        | `outcome` — the screen's one outcome, mirroring what `open` completed with.    |

Events are delivered after the frame that mounts the screen, never during it, so a handler that
calls `setState` is safe. (`open` is raised from `initState`, which runs inside the pushing
frame's build; emitting it straight through would hand you a callback mid-build and
`setState` there throws.)

### `unavailable` is an event, not a callback

There is no `onUnavailable`. When the session cannot be paid at all — `notFound`, `expired`,
`spent`, `noCustomer`, `noMethods`, `loadFailed` — the page renders its own explanation and the
buyer dismisses, which completes as `SuqoClosed`. Routing it through a failure would tell your
app a payment was attempted and rejected, when none was.

```dart
await SuqoCheckout.open(
  context,
  sessionId: sessionId,
  onEvent: (event) {
    if (event.type == 'unavailable') {
      debugPrint('session not payable: ${event.reason!.name}');
    }
  },
);
```

It is usually a sign your own integration created the session wrong — most often an expired or
already-used id, or `noCustomer`: the session was created with no buyer attached, which this
package has no field to supply after the fact.

## Environments and exports

```dart
import 'package:suqo_checkout/suqo_checkout.dart'
    show
        SuqoCheckout, SuqoProvider,
        SuqoOutcome, SuqoSuccess, SuqoFailure, SuqoClosed,
        SuqoMode, SuqoFailureStatus, SuqoUnavailableReason,
        SuqoEvent, SuqoEventSink, ReturnParams,
        SuqoConfigError,
        kLiveOrigin, kSandboxOrigin, kDefaultCheckoutPath, resolveBaseUrl,
        suqoCheckoutVersion;
```

`kLiveOrigin` / `kSandboxOrigin` are the two origins `mode` picks between; `resolveBaseUrl` is
the same resolution `open` runs internally (`baseUrl`, else `mode`, defaulting to sandbox),
exported for anywhere else in your app that needs to build a SUQO URL consistently.

## What the buyer sees

A full-height screen slides in from the trailing edge with the SUQO payment block inside it: a
back button, a title, and the block filling the rest. The block scrolls — a seller with NPS
enabled lists every supported bank, which runs well past a phone screen.

It is pushed as an ordinary route rather than presented as a dialog, so the platform's own back
gesture and Android's hardware back button work without anything being wired up. Back, hardware
back, or your own `Navigator.pop` all dismiss it and complete as `SuqoClosed`.

When the buyer's bank needs its own app, the screen hands the deeplink to the OS and the bank
app opens over yours. Coming back leaves the screen exactly as it was, mid-payment.

### Android: declare the schemes your gateways use

On Android 11+ (API 30) the system will not resolve an intent for a scheme the app has not
declared, and a package cannot add manifest entries on your behalf. Add one `<intent>` block
per scheme to your own `AndroidManifest.xml`, above `<application>`:

```xml
<queries>
    <intent>
        <action android:name="android.intent.action.VIEW"/>
        <data android:scheme="fonepayApp"/>
    </intent>
</queries>
```

Without it the launch fails silently and you will see a `handoff_failed` event. See
`example/android/app/src/main/AndroidManifest.xml`.

This package does **not** probe with `canLaunchUrl` first. `url_launcher`'s own README says the
probe returns false in most cases from Android 11 for exactly the schemes that are missing from
`<queries>` — so the probe answers the same question as the launch, less reliably. It calls
`launchUrl` inside a `try`/`catch` and treats a throw or a `false` as "no handler".

### `intent://` is Android-only

An intent URI is rewritten before it is launched, because `url_launcher` cannot launch one
as written — its Android side builds an `ACTION_VIEW` intent from `Uri.parse`, never
`Intent.parseUri`, so the scheme it sees is the literal `intent`, nothing declares a filter
for it, and the launch fails. The package reads the real target out of the fragment instead:

    intent://payment/?q=1#Intent;scheme=fonepayApp;package=…;S.browser_fallback_url=…;end

`scheme=` plus the body rebuilds the deeplink the gateway meant (`fonepayApp://payment/?q=1`)
and that is tried first; `S.browser_fallback_url` — Android's own documented fallback, in
practice a Play Store page — is tried second. `handoff_failed` is reported only when both
fail. Both spellings are handled: `intent://pay#…` and the authority-less `intent:pay#…`.

Two things are refused rather than launched. The fallback must be `http(s)` — it is the one
field that names a whole URL rather than a scheme, so it is what a compromised gateway page
would reach for — and every rebuilt candidate goes back through the same scheme classifier
the WebView's own navigation does, so `javascript:`, `data:`, `file:` and `blob:` cannot
reach the OS through this path either.

On iOS the rebuilt deeplink is launched the same way, and the fallback URL opens in the
browser when the bank app is not installed. An `intent://` that carries neither a `scheme=`
nor a fallback has no target on any platform and reports `handoff_failed` immediately.

iOS needs no `LSApplicationQueriesSchemes` entry for this, which is worth saying because the
advice is everywhere: that key gates `canOpenURL`, and this package does not call it. Opening
a URL outright has never required declaring its scheme.

## Troubleshooting

**The screen shows an error panel instead of the payment block.**
One of three load deadlines elapsed — the copy tells you which:

| Panel says | Deadline | Likely cause |
| --- | --- | --- |
| "Couldn't load the payment page" | the WebView itself never finished loading (`load_error`) | no connection, a blocked host |
| "Couldn't reach the payment page" | 12s, no `suqo:alive` | the document loaded but never ran its scripts |
| "The payment page is taking too long" | 25s after `alive`, no `suqo:ready` | the page ran but the block never mounted |

"Try again" remounts the WebView fresh; "Close" completes the session as `SuqoClosed`, same as a
buyer backing out. Turn on `debug` and read `onEvent` before assuming it is this package rather
than the session itself (expired, wrong environment).

**`open` throws immediately.**
`SuqoConfigError`, for one of its two reasons — check you are not passing an empty session id,
and that `mode` or `baseUrl` points at the environment the session was actually created
against.

**The buyer paid but the app reports `cancelled`.**
Should not happen: the page only reports `cancelled` from the gateway's own return URL, never
from the screen closing. If you see it, confirm the checkout page itself is up to date with
`js-checkout`'s protocol (§5.14 — a closed gateway window is not treated as an outcome) rather
than assuming this SDK invented the status.

**Nothing comes back at all; the screen just sits there.**
The checkout page is not recognising this as a native host. This package names its JavaScript
channel `SuqoWebView`, which is the vendor-neutral name in the protocol — confirm the page
still probes for it (not only `ReactNativeWebView`), treats a native host as a gateway window
(skips `return_url`), and hands off to gateways in the *same* window rather than a popup. See
[Requirements on the SUQO web app](../README.md#requirements-on-the-suqo-web-app) in the
README.

**A bank/wallet deeplink does nothing.**
Watch for a `handoff_failed` event — it means the OS had no app registered for that scheme: the
bank app is not installed, the scheme is missing from `<queries>` on Android 11+, or the scheme
is wrong for the platform you are testing on.

**Debug console output from the page is missing its first moments.**
Expected, and debug-only. React Native injects the forwarder with
`injectedJavaScriptBeforeContentLoaded`; `webview_flutter` has no document-start injection
([flutter#105202](https://github.com/flutter/flutter/issues/105202)), so the earliest hook
available is `onPageStarted`, which races the page's first evaluation. A throw during the
page's very first moments can be missed. It does not affect payments.
