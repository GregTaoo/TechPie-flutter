import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/campus_card/app/app_providers.dart';
import '../features/campus_card/app/app_runtime.dart';
import '../features/campus_card/presentation/app/app.dart';
import '../services/service_provider.dart';
import '../widgets/adaptive_page_navigation.dart';
import 'campus_card_account_page.dart';

/// Presents the campus-card routes inside TechPie's theme and navigation.
///
/// The OpenID/JSESSIONID account remains independent from TechPie's primary
/// SSO and CpDaily sessions, while the feature runtime is owned by TechPie.
class CampusCardPage extends StatelessWidget {
  const CampusCardPage({
    super.key,
    this.runtime,
    this.entry = CampusCardEntry.paymentCode,
  });

  /// Test-only runtime override. Production uses TechPie's process runtime.
  final AppRuntime? runtime;
  final CampusCardEntry entry;

  void _exit(BuildContext context) {
    unawaited(Navigator.of(context).maybePop());
  }

  void _openAccount(BuildContext context) {
    unawaited(
      pushAdaptivePage<void>(
        context,
        builder: (_) => const CampusCardAccountPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final value =
        runtime ?? ServiceProvider.of(context).campusCardService.runtime;
    return ProviderScope(
      overrides: [
        appRuntimeProvider.overrideWithValue(value),
        geekPayHostExitProvider.overrideWithValue(() => _exit(context)),
        campusCardAccountProvider.overrideWithValue(
          () => _openAccount(context),
        ),
        campusCardEntryProvider.overrideWithValue(entry),
      ],
      child: const CampusCardFeature(),
    );
  }
}
