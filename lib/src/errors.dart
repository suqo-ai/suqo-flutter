/// Configuration or usage mistakes the SDK refuses to proceed on.
class SuqoConfigError implements Exception {
  const SuqoConfigError(this.message);

  final String message;

  @override
  String toString() => 'SuqoConfigError: $message';
}
