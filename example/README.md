# suqo_checkout example

Drives the SDK end to end. Runs with **no backend and no SUQO frontend** if you point it at
the mock server.

## Against the mock server

The React Native example's mock works unchanged — it is a plain Node script speaking the
same `postMessage` protocol, and it serves `/c/<anything>`.

```bash
cd ../../suqo-react-native/example && npm run mock   # one terminal
cd ../../suqo-flutter/example && flutter run         # another
```

Then set **Base URL override** in the app:

- Android emulator → `http://10.0.2.2:8787` (`10.0.2.2` is the host machine)
- Physical device → the LAN address the mock prints; `localhost` on a phone is the phone

What you can exercise there: a successful pay, a decline, a cancel-at-gateway, the block
growing, and a bank-app deeplink. With no bank app installed the OS refuses the deeplink and
the event log shows `handoff_failed` — which is the interesting case to see, because the
screen must stay exactly as it was rather than settling the payment.

## Against a real deployment

Point the base URL at a real checkout origin and paste a real `cks_…` session id created by
your backend. Clear the base URL entirely to let the Mode toggle decide
(`test.suqo.ai` / `app.suqo.ai`).

A real session must already carry a customer — one created without it reports
`unavailable reason=noCustomer` in the event log and never becomes payable.

## Android note

`android/app/src/main/AndroidManifest.xml` carries two things a real host app also needs:

- a `<queries>` block per deeplink scheme, without which Android 11+ silently refuses to
  resolve the bank app
- `usesCleartextTraffic="true"`, only so the http mock server is reachable. A real
  integration talks https and does not need it.
