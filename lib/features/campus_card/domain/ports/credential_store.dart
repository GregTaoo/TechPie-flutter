abstract interface class SecureCredentialStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
  Future<void> deleteAll(Iterable<String> keys);

  /// Replace all entries as one logical transaction or fail closed.
  Future<void> replaceAtomically(Map<String, String?> values);
}

abstract interface class SessionCredentialStore {
  Future<String?> readSessionCookie();
  Future<String?> readOpenId();
  Future<String?> readOrgId();
  Future<String?> readVerifiedIdSerial();
  Future<String?> readVerifiedCardId();
  Future<void> writeSession({
    required String sessionCookie,
    required String openId,
    required String orgId,
    required String verifiedIdSerial,
    required String verifiedCardId,
  });
  Future<void> clearSessionCookie();
  Future<void> clear();
}
