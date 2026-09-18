import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../localization/geekpay_localizations.dart';
import '../theme/theme.dart';

/// Campus-card feature root.
///
/// The host owns the app theme, locale, navigator, and system chrome. This
/// widget only supplies the feature router and its semantic color extension.
final class CampusCardFeature extends ConsumerWidget {
  const CampusCardFeature({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(gpRouterProvider);
    final hostTheme = Theme.of(context);
    final dark = hostTheme.brightness == Brightness.dark;
    final hostLocale = Localizations.maybeLocaleOf(context);
    final locale = GeekPayLocalizations.supportedLocales.firstWhere(
      (candidate) => candidate.languageCode == hostLocale?.languageCode,
      orElse: () => const Locale('zh'),
    );

    final routedFeature = AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: hostTheme.scaffoldBackgroundColor,
        systemNavigationBarIconBrightness:
            dark ? Brightness.light : Brightness.dark,
        systemNavigationBarContrastEnforced: false,
      ),
      child: NavigatorPopHandler<Object?>(
        onPopWithResult: (result) => router.pop(result),
        child: Router<Object>.withConfig(config: router),
      ),
    );
    final localizedFeature = hostLocale == null
        ? Localizations(
            locale: locale,
            delegates: const [
              GeekPayLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            child: routedFeature,
          )
        : Localizations.override(
            context: context,
            locale: locale,
            delegates: const [GeekPayLocalizations.delegate],
            child: routedFeature,
          );

    return Theme(
      data: GeekPayTheme.inherit(hostTheme),
      child: localizedFeature,
    );
  }
}
