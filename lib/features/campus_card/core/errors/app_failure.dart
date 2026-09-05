enum FailureKind {
  authenticationExpired,
  authenticationUnconfigured,
  network,
  timeout,
  server,
  protocol,
  invalidInput,
  unavailable,
  permissionDenied,
  credentialMissing,
  offlineAuthorizationExpired,
  offlineQuotaExhausted,
  cancelled,
  unknown,
}

final class AppFailure implements Exception {
  const AppFailure(
    this.kind,
    this.safeMessage, {
    this.code,
    this.retryable = false,
    this.cause,
  });

  final FailureKind kind;
  final String safeMessage;
  final String? code;
  final bool retryable;

  /// Never display or report this value without an explicit redaction pass.
  final Object? cause;

  @override
  String toString() =>
      'AppFailure(kind: $kind, code: $code, retryable: $retryable)';
}

extension AppFailureAvailability on AppFailure {
  bool get permitsCachedFallback =>
      kind == FailureKind.network ||
      kind == FailureKind.timeout ||
      (kind == FailureKind.server && retryable);
}
