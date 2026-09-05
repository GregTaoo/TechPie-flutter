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

final gpRouterProvider = Provider<GoRouter>((ref) {
  final entryLocation =
      ref.watch(campusCardEntryProvider) == CampusCardEntry.cardManagement
          ? '/card/manage'
          : GpRoutes.pay;
  final refresh = _AuthRouterRefresh(
    ref.watch(appRuntimeProvider).auth.changes,
  );
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
        if (snapshot?.state != AuthState.authenticated) {
          return location == GpRoutes.login ? null : GpRoutes.login;
        }
        return location == GpRoutes.login ? entryLocation : null;
      }

      if (auth.isLoading) {
        return ref.read(authControllerProvider.future).then<String?>(
              destination,
              onError: (Object _, StackTrace __) => destination(null),
            );
      }
      return destination(auth.valueOrNull);
    },
    routes: [
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
  _AuthRouterRefresh(Stream<AuthSnapshot> changes) {
    _subscription = changes.listen((snapshot) {
      if (snapshot.state == AuthState.signingIn) return;
      scheduleMicrotask(() {
        if (!_disposed) notifyListeners();
      });
    });
  }

  late final StreamSubscription<AuthSnapshot> _subscription;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
