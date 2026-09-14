import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:techpie/features/campus_card/app/app_providers.dart';
import 'package:techpie/features/campus_card/domain/models/auth_models.dart';
import 'package:techpie/features/campus_card/presentation/app/routes.dart';
import 'package:techpie/features/campus_card/presentation/screens/bill_transaction_screen.dart';
import 'package:techpie/features/campus_card/presentation/screens/bind_card_screen.dart';
import 'package:techpie/features/campus_card/presentation/screens/card_manage_screen.dart';
import 'package:techpie/features/campus_card/presentation/screens/login_screen.dart';
import 'package:techpie/features/campus_card/presentation/screens/me_screen.dart';
import 'package:techpie/features/campus_card/presentation/screens/offline_screen.dart';
import 'package:techpie/features/campus_card/presentation/screens/payment_code_page.dart';
import 'package:techpie/features/campus_card/presentation/screens/security_hub_screen.dart';
import 'package:techpie/features/campus_card/presentation/screens/security_limit_screen.dart';
import 'package:techpie/features/campus_card/presentation/screens/security_password_screen.dart';
import 'package:techpie/features/campus_card/presentation/screens/settings_screen.dart';
import 'package:techpie/features/campus_card/presentation/screens/widget_setup_screen.dart';

import '../screens/session_restore_screen.dart';

final gpRouterProvider = Provider<GoRouter>((ref) {
  final entryLocation =
      ref.watch(campusCardEntryProvider) == CampusCardEntry.cardManagement
          ? '/card/manage'
          : GpRoutes.pay;
  final refresh = _AuthRouterRefresh();
  ref.listen(authControllerProvider, (_, next) {
    if (next.valueOrNull?.state != AuthState.signingIn) refresh.changed();
  });
  ref.onDispose(refresh.dispose);
  final router = GoRouter(
    initialLocation: entryLocation,
    debugLogDiagnostics: false,
    refreshListenable: refresh,
    redirect: (context, state) {
      final location = state.uri.path;
      // Restore only the local session before mounting account-owned pages.
      // Network verification continues in AuthController behind the target page.
      final auth = ref.read(authControllerProvider);
      String? destination(AuthSnapshot? snapshot) {
        final String? target;
        if (snapshot?.state == AuthState.authenticated) {
          target = location == GpRoutes.login || location == GpRoutes.sessionRestore ? entryLocation : null;
        } else if (snapshot?.state == AuthState.signedOut || snapshot?.state == AuthState.unconfigured) {
          target = GpRoutes.login;
        } else {
          // An expired session or unreadable credential is not a missing OpenID.
          target = GpRoutes.sessionRestore;
        }
        return target == location ? null : target;
      }

      if (auth.isLoading) {
        return ref.read(authControllerProvider.future).then<String?>(
              destination,
              onError: (Object _, StackTrace __) => destination(null),
            );
      }
      return destination(auth.hasError ? null : auth.valueOrNull);
    },
    routes: [
      GoRoute(path: GpRoutes.sessionRestore, pageBuilder: (context, state) => gpPlatformPage(context, state, const SessionRestoreScreen())),
      GoRoute(
        path: GpRoutes.widgetSetup,
        pageBuilder: (context, state) =>
            gpPlatformPage(context, state, const WidgetSetupScreen()),
      ),
      GoRoute(
        path: GpRoutes.login,
        pageBuilder: (context, state) =>
            gpPlatformPage(context, state, const LoginScreen()),
      ),
      GoRoute(
        path: GpRoutes.bindCard,
        pageBuilder: (context, state) =>
            gpPlatformPage(context, state, const BindCardScreen()),
      ),
      GoRoute(
        path: GpRoutes.offline,
        pageBuilder: (context, state) =>
            gpPlatformPage(context, state, const OfflineAuthorizationScreen()),
      ),
      GoRoute(
        path: '/card/manage',
        pageBuilder: (context, state) =>
            gpPlatformPage(context, state, const CardManageScreen()),
      ),
      GoRoute(
        path: '${GpRoutes.me}/security',
        pageBuilder: (context, state) =>
            gpPlatformPage(context, state, const SecurityHubScreen()),
        routes: [
          GoRoute(
            path: 'password',
            pageBuilder: (context, state) =>
                gpPlatformPage(context, state, const SecurityPasswordScreen()),
          ),
          GoRoute(
            path: 'limit',
            pageBuilder: (context, state) =>
                gpPlatformPage(context, state, const SecurityLimitScreen()),
          ),
        ],
      ),
      GoRoute(
        path: '${GpRoutes.me}/settings',
        pageBuilder: (context, state) =>
            gpPlatformPage(context, state, const SettingsScreen()),
      ),
      GoRoute(
        path: GpRoutes.pay,
        pageBuilder: (context, state) =>
            gpPlatformPage(context, state, const PaymentCodePage()),
      ),
      GoRoute(
        path: '${GpRoutes.transactions}/:id',
        pageBuilder: (context, state) => gpPlatformPage(
          context,
          state,
          BillTransactionScreen(transactionId: state.pathParameters['id']!),
        ),
      ),
      GoRoute(
        path: GpRoutes.me,
        pageBuilder: (context, state) =>
            gpPlatformPage(context, state, const MeScreen()),
      ),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

Page<void> gpPlatformPage(
  BuildContext context,
  GoRouterState state,
  Widget child,
) {
  return gpPageForPlatform(
    Theme.of(context).platform,
    key: state.pageKey,
    child: _AccountPage(child: child),
  );
}

/// Clears page-local state, including offline QR codes, when the account changes.
final class _AccountPage extends ConsumerWidget {
  const _AccountPage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subject = ref.watch(
      authControllerProvider.select(
        (snapshot) => snapshot.valueOrNull?.session?.subjectId,
      ),
    );
    return KeyedSubtree(key: ValueKey(subject), child: child);
  }
}

Page<void> gpPageForPlatform(
  TargetPlatform platform, {
  required LocalKey key,
  required Widget child,
}) {
  if (platform == TargetPlatform.iOS || platform == TargetPlatform.macOS) {
    // CupertinoPage creates a CupertinoPageRoute, which supplies the native
    // interactive edge-pop gesture and moves the current page with the finger.
    return CupertinoPage<void>(key: key, child: child);
  }
  return MaterialPage<void>(key: key, child: child);
}

final class _AuthRouterRefresh extends ChangeNotifier {
  bool _scheduled = false;
  bool _disposed = false;

  void changed() {
    if (_scheduled || _disposed) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
