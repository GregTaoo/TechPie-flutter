enum AuthState { signedOut, signingIn, authenticated, unconfigured, expired }

sealed class AuthCredential {
  const AuthCredential();
}

final class DemoAuthCredential extends AuthCredential {
  const DemoAuthCredential();
}

final class OpenIdAuthCredential extends AuthCredential {
  const OpenIdAuthCredential({
    required this.openId,
    this.expectedIdSerial,
    this.expectedCardId,
  });

  final String openId;

  /// Optional one-shot guard values supplied by an authorized caller.
  /// They must never be logged or persisted.
  final String? expectedIdSerial;
  final String? expectedCardId;

  void validate() {
    final value = openId.trim();
    if (value.length < 16 ||
        value.length > 256 ||
        value.contains(RegExp(r'\s'))) {
      throw const FormatException('OpenID format is invalid');
    }
  }
}

final class AuthSession {
  const AuthSession({
    required this.subjectId,
    required this.orgId,
    this.maskedIdentity,
  });

  /// Opaque local subject identifier. It must not be logged.
  final String subjectId;
  final String orgId;

  /// Presentation-safe identifier. Implementations may expose only a short
  /// first/last mask; the complete credential never leaves secure storage.
  final String? maskedIdentity;
}

final class AuthSnapshot {
  const AuthSnapshot({required this.state, this.session, this.message});

  final AuthState state;
  final AuthSession? session;
  final String? message;
}
