import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:techpie/features/campus_card/app/app_providers.dart';
import 'package:techpie/features/campus_card/domain/models/auth_models.dart';
import 'package:techpie/features/campus_card/presentation/app/routes.dart';
import 'package:techpie/features/campus_card/presentation/icons/geekpay_icons.dart';
import 'package:techpie/features/campus_card/presentation/localization/geekpay_localizations.dart';
import 'package:techpie/features/campus_card/presentation/theme/tokens.dart';
import 'package:techpie/features/campus_card/presentation/widgets/gp_state.dart';

/// S0 splash/session guard (PRODUCT_SPEC §3, B3 §3.1). Uses the restored
/// session for every environment. A locally restored account enters the target
/// page immediately; card and network refreshes continue behind that page.
final class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  static const _timeout = Duration(seconds: 10);
  Timer? _timer;
  bool _timedOut = false;
  bool _routing = false;

  @override
  void initState() {
    super.initState();
    _armTimeout();
  }

  void _armTimeout() {
    _timer?.cancel();
    _timer = Timer(_timeout, () {
      if (mounted) setState(() => _timedOut = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _route(AuthSnapshot snapshot) async {
    if (_routing) return;
    _routing = true;
    try {
      switch (snapshot.state) {
        case AuthState.authenticated:
          if (!mounted) return;
          _timer?.cancel();
          final entry = ref.read(campusCardEntryProvider);
          context.go(
            entry == CampusCardEntry.cardManagement
                ? '/card/manage'
                : GpRoutes.pay,
          );
        case AuthState.signedOut:
        case AuthState.expired:
        case AuthState.unconfigured:
          if (!mounted) return;
          _timer?.cancel();
          context.go(GpRoutes.login);
        case AuthState.signingIn:
          return;
      }
    } finally {
      _routing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_timedOut) {
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(GpTokens.space4),
            child: GpStateView.error(
              TimeoutException('启动超时'),
              onRetry: () {
                setState(() => _timedOut = false);
                _routing = false;
                _armTimeout();
                ref.invalidate(authControllerProvider);
                ref.invalidate(cardControllerProvider);
              },
            ),
          ),
        ),
      );
    }

    final auth = ref.watch(authControllerProvider);
    auth.whenData((snapshot) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _timedOut) return;
        unawaited(_route(snapshot));
      });
    });

    if (auth case AsyncError(:final error)) {
      _timer?.cancel();
      return Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(GpTokens.space4),
            child: GpStateView.error(
              error,
              onRetry: () {
                _routing = false;
                _armTimeout();
                ref.invalidate(authControllerProvider);
              },
            ),
          ),
        ),
      );
    }

    return const Scaffold(
      body: SafeArea(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GpIcon(GpIcons.wallet, size: 56),
              SizedBox(height: GpTokens.space4),
              _SplashLabel(),
              SizedBox(height: GpTokens.space4),
              CircularProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}

final class _SplashLabel extends StatelessWidget {
  const _SplashLabel();

  @override
  Widget build(BuildContext context) {
    return Text(
      context.l10n.t('campusCardShort'),
      style: Theme.of(context).textTheme.headlineMedium,
    );
  }
}
