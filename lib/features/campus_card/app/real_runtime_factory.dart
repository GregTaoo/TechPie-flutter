import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

import '../application/offline_payment_service.dart';
import '../core/config/app_environment.dart';
import '../data/api/ecard_api_client.dart';
import '../data/auth/ecard_openid_auth_port.dart';
import '../data/crypto/sm2_offline_crypto.dart';
import '../data/repositories/ecard_card_repository.dart';
import '../data/repositories/ecard_offline_authorization_remote.dart';
import '../data/repositories/ecard_payment_code_repository.dart';
import '../data/repositories/ecard_scan_payment_repository.dart';
import '../data/repositories/ecard_security_settings_repository.dart';
import '../data/repositories/ecard_transaction_history_repository.dart';
import '../data/storage/flutter_secure_credential_store.dart';
import '../data/storage/secure_card_cache.dart';
import '../data/storage/secure_offline_credential_repository.dart';
import '../domain/ports/credential_store.dart';
import '../platform/scanner/mobile_scanner_session.dart';
import '../platform/system_ports.dart';
import 'app_runtime.dart';

AppRuntime buildRealRuntime(
  AppEnvironment environment, {
  SecureCredentialStore? secureCredentialStore,
}) {
  if (environment == AppEnvironment.demo) {
    throw ArgumentError('The real composition root cannot build demo');
  }
  final secureStore = secureCredentialStore ?? FlutterSecureCredentialStore();
  final sessionStore = SecureSessionCredentialStore(secureStore);
  Future<String?> readSubjectId() async {
    final openId = await sessionStore.readOpenId();
    if (openId == null || openId.isEmpty) return null;
    return sha256.convert(utf8.encode(openId)).toString();
  }

  final cardCache = SecureCardCache(
    secureStore,
    subjectReader: readSubjectId,
    verifiedIdSerialReader: sessionStore.readVerifiedIdSerial,
  );
  final offlineCredentials = SecureOfflineCredentialRepository(secureStore);
  Future<String?> readPinnedIdSerial() async {
    final openId = await sessionStore.readOpenId();
    if (openId == null || openId.isEmpty) return null;
    final authorization = await offlineCredentials.readMostRecent(
      deviceCode: openId,
    );
    return authorization?.cardId;
  }

  final connectivity = SystemConnectivityPort();
  final brightness = SystemBrightnessPort();
  final lifecycle = FlutterAppLifecyclePort();
  final haptics = SystemHapticsPort();
  final scannerSupported = !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);
  final scanner = scannerSupported ? MobileScannerSession() : null;
  late final EcardTransactionHistoryRepository transactions;
  Future<void> purgeAccountMaterial() async {
    await offlineCredentials.removeAll();
    await cardCache.clear();
    transactions.clearCachedDetails();
  }

  final auth = EcardOpenIdAuthPort(
    sessionStore: sessionStore,
    purgeAccountBoundCredentials: purgeAccountMaterial,
    pinnedIdSerialReader: readPinnedIdSerial,
  );
  final client = EcardApiClient(
    sessionReader: auth.readSession,
    identityGuard: auth.verifyCurrentIdentity,
    onAuthenticationExpired: auth.handleAuthenticationFailure,
    onIdentityMismatch: auth.rejectCurrentOnlineSession,
  );
  transactions = EcardTransactionHistoryRepository(
    client,
    subjectReader: readSubjectId,
  );
  final offline = OfflinePaymentService(
    credentials: offlineCredentials,
    remote: EcardOfflineAuthorizationRemote(
      client: client,
      backendSecurityApproval: true,
    ),
    connectivity: connectivity,
    crypto: Sm2OfflineCrypto(),
    deviceCodeReader: sessionStore.readOpenId,
  );
  return AppRuntime(
    environment: environment,
    capabilities: AppCapabilities.forEnvironment(environment),
    auth: auth,
    cards: EcardCardRepository(
      client,
      purgeLocalSecurityState: auth.signOut,
      cache: cardCache,
      verifiedIdSerialReader: sessionStore.readVerifiedIdSerial,
    ),
    paymentCodes: EcardPaymentCodeRepository(client),
    scanPayments: EcardScanPaymentRepository(client),
    transactions: transactions,
    securitySettings: EcardSecuritySettingsRepository(client),
    offlinePayments: offline,
    brightness: brightness,
    connectivity: connectivity,
    lifecycle: lifecycle,
    haptics: haptics,
    scanner: scanner,
    disposeRuntime: () async {
      await scanner?.dispose();
      await lifecycle.dispose();
      client.dispose();
      await auth.dispose();
    },
  );
}
