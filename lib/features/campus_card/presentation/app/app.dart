import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../theme/theme.dart';

/// Campus-card feature root.
///
/// The host owns the app theme, locale, navigator and system chrome. This
/// widget only supplies the feature router and its semantic color extension —
/// the copy inside it is Chinese, the way the rest of TechPie's is, and no
/// localization delegates are installed here or above: the framework's own
/// defaults are what the host's MaterialApp already provides.
final class CampusCardFeature extends ConsumerWidget {
  const CampusCardFeature({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(gpRouterProvider);
    final hostTheme = Theme.of(context);
    final dark = hostTheme.brightness == Brightness.dark;

    return Theme(
      data: GeekPayTheme.inherit(hostTheme),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
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
      ),
    );
  }
}
