import 'dart:async';

import 'package:flutter/foundation.dart';

import '../features/campus_card/app/app_runtime.dart';
import '../features/campus_card/app/real_runtime_factory.dart';
import '../features/campus_card/core/config/app_environment.dart';
import '../features/campus_card/core/errors/core_error_catalog.dart';
import '../features/campus_card/data/storage/flutter_secure_credential_store.dart';
import '../features/campus_card/domain/models/auth_models.dart';
import '../features/campus_card/domain/ports/auth_port.dart';
import '../features/campus_card/domain/ports/credential_store.dart';

typedef CampusCardRuntimeFactory = AppRuntime Function();

/// Owns the campus-card runtime and its independent OpenID account.
///
/// TechPie keeps this service alive for the process lifetime so camera,
/// connectivity, and authentication adapters are not recreated for every
/// page visit. Only presentation state is rebuilt when a route is opened.
final class CampusCardService extends ChangeNotifier {
  CampusCardService() : this.withStore(FlutterSecureCredentialStore());

  CampusCardService.withStore(
    SecureCredentialStore secureStore, {
    CampusCardRuntimeFactory? runtimeFactory,
  })  : _sessionStore = SecureSessionCredentialStore(secureStore),
        _runtime = runtimeFactory?.call() ??
            buildRealRuntime(
              AppEnvironment.production,
              secureCredentialStore: secureStore,
            ) {
    unawaited(CoreErrorCatalog.initialize());
    _authSubscription = _runtime.auth.changes.listen((_) {
      unawaited(refreshAccount());
    });
  }

  final SecureSessionCredentialStore _sessionStore;
  final AppRuntime _runtime;

  StreamSubscription<AuthSnapshot>? _authSubscription;
  String? _maskedOpenId;
  bool _busy = false;
  Object? _lastError;

  bool get busy => _busy;
  bool get configured => _maskedOpenId != null;
  String? get maskedOpenId => _maskedOpenId;
  Object? get lastError => _lastError;
  AppRuntime get runtime => _runtime;

  Future<void> refreshAccount() async {
    final openId = await _sessionStore.readOpenId();
    final masked = _maskOpenId(openId);
    if (_maskedOpenId == masked) return;
    _maskedOpenId = masked;
    notifyListeners();
  }

  Future<String?> readOpenId() => _sessionStore.readOpenId();

  Future<void> verifyOpenId(String openId) async {
    final credential = OpenIdAuthCredential(openId: openId.trim());
    credential.validate();
    _setBusy(true);
    _lastError = null;
    try {
      final auth = _runtime.auth;
      if (auth is! OpenIdAuthVerifier) {
        throw StateError('The active eCard runtime cannot verify OPENID');
      }
      await (auth as OpenIdAuthVerifier).verifyOpenId(credential.openId);
    } catch (error) {
      _lastError = error;
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> connect(String openId) async {
    final credential = OpenIdAuthCredential(openId: openId.trim());
    credential.validate();
    _setBusy(true);
    _lastError = null;
    try {
      await _runtime.auth.signIn(credential);
      await refreshAccount();
    } catch (error) {
      _lastError = error;
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  Future<void> disconnect() async {
    _setBusy(true);
    _lastError = null;
    try {
      await _runtime.auth.signOut();
      await refreshAccount();
    } catch (error) {
      _lastError = error;
      rethrow;
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool value) {
    if (_busy == value) return;
    _busy = value;
    notifyListeners();
  }

  static String? _maskOpenId(String? value) {
    final openId = value?.trim();
    if (openId == null || openId.isEmpty) return null;
    if (openId.length <= 8) return '••••';
    return '${openId.substring(0, 4)}••••${openId.substring(openId.length - 4)}';
  }

  @override
  void dispose() {
    unawaited(_authSubscription?.cancel());
    _authSubscription = null;
    unawaited(_runtime.dispose());
    super.dispose();
  }
}
