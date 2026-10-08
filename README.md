# suqo_checkout

Collect a SUQO payment on a full-screen checkout screen, from Flutter. No gateway
integration, no payment UI to build.

[docs/usage.md](./docs/usage.md) covers the same ground as this README with more detail —
every `onEvent` shape, the full options table, and troubleshooting. The wire protocol this
package implements against the SUQO web app is `js-checkout/docs/protocol.md` in the
`js-checkout` repo.

```
flutter pub add suqo_checkout
```

## What it does, and what it does not

Your backend already creates the checkout session through SUQO's API and holds its id. This
package takes that id, opens SUQO's own checkout page for it, and tells you how the payment
went.

It makes **no SUQO API calls of its own and holds no credential**. The gateway list, the
payment call, the hand-off to eSewa / Khalti / ConnectIPS / NPS and the verification all
belong to the page inside the WebView. The session id is the only thing this package knows —
and it is single-use, short-lived, and carries no buyer details of its own, so nothing
sensitive and nothing long-lived ever sits in your app bundle.

**Create the session with a customer already attached.** There is no field anywhere on
`open` for one. A session created without one shows the page's own "can't be paid"
explanation and reports `SuqoUnavailableReason.noCustomer` on `onEvent` rather than ever
becoming payable.

## Usage

```dart
final outcome = await SuqoCheckout.open(context, sessionId: 'cks_9f2c41a8');

if (outcome is SuqoSuccess) {
  // move the buyer on — see "the outcome is a signal to navigate" below
}
```

That is the whole integration. `open` pushes a full-screen route and completes with exactly
one [`SuqoOutcome`](#outcomes) once the buyer is done with it.

Prefer exhaustive handling? `when` takes a callback per case, so it cannot be written
incompletely:

```dart
final message = outcome.when(
  success: (s) => 'Paid — ${s.params}',
  failure: (f) => f.status == SuqoFailureStatus.cancelled
      ? 'Buyer backed out'
      : 'Payment rejected: ${f.message}',
  closed: (_) => 'Dismissed before anything settled',
);
```

### Defaults, once

`SuqoProvider` is optional and holds configuration only — there is no screen for it to own,
because `Navigator` already gives one that returns a result. Mount it to avoid repeating
yourself:

```dart
SuqoProvider(
  mode: SuqoMode.sandbox,
  debug: true,
  child: MaterialApp(home: MyApp()),
)
```

Anything it sets can still be passed per call, and a per-call value always wins.

## Options

| Argument | Default | Notes |
| --- | --- | --- |
| `sessionId` | — | **Required.** The checkout session to pay, e.g. `cks_9f2c41a8`. |
| `mode` | `SuqoMode.sandbox` | `live` → `app.suqo.ai`, `sandbox` → `test.suqo.ai`. |
| `baseUrl` | — | Where SUQO's checkout is served from. Overrides `mode`. |
| `checkoutPath` | `/c/:id` | The route, with `:id` for the session id. |
| `title` | `Secure payment` | Screen header. The amount and seller are rendered by the page. |
| `loadingLabel` | `Loading secure checkout` | The line under the spinner. Pass `''` for a spinner alone. |
| `debug` | `false` | Turns on this package's redacted logging. |
| `onEvent` | — | A debug stream for your own logs. Not a payment signal. |

Sandbox is the default on purpose: an app that names neither `mode` nor `baseUrl` cannot
take a live payment by accident.

## Outcomes

`open` completes with one of three, and never more than one per call:

- **`SuqoSuccess`** — the page verified the payment with SUQO's backend. Carries `params`
  and an optional `message`.
- **`SuqoFailure`** — carries a `status` of `failed` or `cancelled`.
- **`SuqoClosed`** — the screen was dismissed before anything settled. Nothing was charged.

Dart 2.18 has no `sealed`, so an `is`-chain over these is not checked for exhaustiveness by
the compiler. Use `when` where that matters.

### `cancelled` is not `failed`

`SuqoFailure.status` is `cancelled` when the buyer backed out at the gateway, and `failed`
when a payment was attempted and rejected. Check it: a buyer who changed their mind wants
the basket offered again, while a rejected payment is worth looking into. Nothing is charged
in either case.

### `params` is the gateway's, verbatim

Every gateway names its transaction differently — eSewa a signed `data` blob, Khalti a
`pidx`, ConnectIPS a `TXNID`, NPS a `MerchantTxnId`. `params` is passed through with no
renaming or filtering, because you reconcile against whatever your own backend recorded, and
normalising would throw away the only field you can match on.

`message` is what SUQO's backend said when it settled the payment. It is separate from
`params` so our keys never mix into the gateway's, and it is null when the backend said
nothing — so it is never copy this SDK invented. On a failure it is usually the only place
the reason exists.

### A session that can't be paid at all is not a failure

There is no `onUnavailable`. When the session is `notFound`, `expired`, `spent`,
`noCustomer`, `noMethods` or `loadFailed`, the page shows its own explanation and the buyer
dismisses, which completes as `SuqoClosed` — routing it through a failure would claim a
payment was attempted and rejected when none was. Pass `onEvent` and watch for an
`unavailable` event if you want to know *why* in your own logs.

## The outcome is a signal to navigate, not proof of fulfilment

`SuqoSuccess` only arrives after the checkout page verified the payment with SUQO's backend,
so it is a real signal rather than a redirect's claim. Even so, **the webhook is
authoritative.** Treat it as "move the buyer on", and let your own backend decide that an
order is paid from its own record.

## Android: declare the schemes your gateways use

When a bank or wallet needs its own app, this package hands the deeplink to the OS. On
Android 11+ (API 30) the system will not resolve an intent for a scheme the app has not
declared, and a package cannot add manifest entries on your behalf — so add one `<intent>`
block per scheme to your own `AndroidManifest.xml`:

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

## Requirements

| | Minimum |
| --- | --- |
| Flutter | 3.3.0 |
| Dart | 2.18.0 |
| `webview_flutter` | 4.1.0 |
| `url_launcher` | 6.1.11 |

Flutter 3.3.0 rather than 3.0.0 because `setAcceptThirdPartyCookies` arrives in
`webview_flutter_android` 3.7.0, which is the first release requiring it — and the gateway
journey crosses sites, so that setting is not optional.

## Requirements on the SUQO web app

This package is one half of a protocol; `js-checkout/docs/protocol.md` is the contract. It
needs nothing SUQO does not already do: the page recognises any native host that exposes
`window.SuqoWebView.postMessage(string)`, which is exactly what this package's JavaScript
channel is named. The page then delivers `suqo:result` over that channel, treats the host as
a gateway window so it does not follow the seller's `return_url` inside the screen, and
hands off to gateways in the **same** window rather than opening a popup.

## Known difference from `@suqo/react-native`

The debug forwarder cannot run before the page's own scripts. React Native injects it with
`injectedJavaScriptBeforeContentLoaded`; `webview_flutter` has no document-start injection
([flutter#105202](https://github.com/flutter/flutter/issues/105202)), so the earliest hook
available is `onPageStarted`, which races the page's first evaluation. A throw during the
page's very first moments can be missed. Debug-only, and it does not affect payments.

## Development

```bash
flutter analyze
flutter test
dart format lib test

cd example && flutter run
```

The example runs against the React Native example's mock server unchanged — it is a plain
Node script speaking the same protocol. Run `npm run mock` in `suqo-react-native/example`
and point the example's base URL at the address it prints.

## License

Apache-2.0
