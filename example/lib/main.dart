import 'package:flutter/material.dart';
import 'package:suqo_checkout/suqo_checkout.dart';

/// Drives the SDK against either a real checkout or the mock server.
///
/// The React Native example's `example/mock-server.mjs` works unchanged — it is a plain
/// Node script speaking the same `postMessage` protocol, and it serves `/c/<anything>`. Run
/// `npm run mock` in `suqo-react-native/example`, then point the base URL below at the
/// address it prints. On a device or emulator, `localhost` means the device.
void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    // The provider is optional and holds defaults only. Everything here can also be passed
    // per call to SuqoCheckout.open, and a per-call value always wins.
    return SuqoProvider(
      mode: SuqoMode.sandbox,
      debug: true,
      child: MaterialApp(
        title: 'SUQO SDK example',
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF635BFF),
          useMaterial3: true,
        ),
        home: const HomePage(),
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _baseUrl = TextEditingController(
    text: 'http://10.0.2.2:8787',
  );
  final TextEditingController _sessionId = TextEditingController(
    text: 'cks_mock1',
  );

  SuqoMode _mode = SuqoMode.sandbox;
  final List<SuqoEvent> _events = <SuqoEvent>[];
  String _lastOutcome = '(nothing yet)';

  @override
  void dispose() {
    _baseUrl.dispose();
    _sessionId.dispose();
    super.dispose();
  }

  Future<void> _pay() async {
    setState(() {
      _events.clear();
      _lastOutcome = '(waiting)';
    });

    try {
      final outcome = await SuqoCheckout.open(
        context,
        sessionId: _sessionId.text.trim(),
        mode: _mode,
        // Empty means "let mode decide" — mirrors how baseUrl overrides mode in the SDK.
        baseUrl: _baseUrl.text.trim().isEmpty ? null : _baseUrl.text.trim(),
        onEvent: (event) => setState(() => _events.add(event)),
      );

      if (!mounted) return;
      setState(() {
        _lastOutcome = outcome.when(
          success: (s) =>
              'success — ${s.message ?? '(backend sent no message)'}\n${s.params}',
          failure: (f) =>
              'failure ${f.status.name} — '
              '${f.message ?? '(backend sent no message)'}\n${f.params}',
          closed: (_) => 'closed — dismissed before anything settled',
        );
      });
    } on SuqoConfigError catch (error) {
      // Thrown before anything is shown: an empty session id, or a base URL that cannot
      // produce a checkout URL.
      if (!mounted) return;
      setState(() => _lastOutcome = 'open() refused — ${error.message}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('SUQO SDK example')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('MODE'),
            const SizedBox(height: 8),
            SegmentedButton<SuqoMode>(
              segments: const [
                ButtonSegment(value: SuqoMode.sandbox, label: Text('Sandbox')),
                ButtonSegment(value: SuqoMode.live, label: Text('Live')),
              ],
              selected: {_mode},
              onSelectionChanged: (s) => setState(() => _mode = s.first),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _baseUrl,
              decoration: const InputDecoration(
                labelText: 'Base URL override',
                helperText:
                    'Empty lets mode decide. From an Android emulator, '
                    '10.0.2.2 is the host machine.',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _sessionId,
              decoration: const InputDecoration(
                labelText: 'Checkout session id',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _pay, child: const Text('Pay')),
            const SizedBox(height: 24),
            const Text('OUTCOME'),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: const Color(0xFFF5F6FA),
              child: Text(
                _lastOutcome,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            const SizedBox(height: 24),
            const Text('EVENT LOG'),
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(minHeight: 90),
              padding: const EdgeInsets.all(12),
              color: const Color(0xFF2B2B2B),
              child: Text(
                _events.isEmpty
                    ? '(nothing yet)'
                    : _events.map(_describe).join('\n'),
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 12,
                  color: Color(0xFFEEEEEE),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'No backend? Run `npm run mock` in suqo-react-native/example and point the '
              'base URL at the address it prints — the mock speaks the same protocol.',
              style: TextStyle(fontSize: 12, color: Color(0xFF667080)),
            ),
          ],
        ),
      ),
    );
  }

  /// Only the fields a given event actually carries — the rest are null by construction.
  static String _describe(SuqoEvent event) {
    final detail = <String>[
      if (event.stage != null) 'stage=${event.stage}',
      if (event.scheme != null) 'scheme=${event.scheme}',
      if (event.height != null) 'height=${event.height}',
      if (event.reason != null) 'reason=${event.reason!.name}',
      if (event.outcome != null) 'outcome=${event.outcome.runtimeType}',
    ].join(' ');
    return detail.isEmpty ? event.type : '${event.type} $detail';
  }
}
