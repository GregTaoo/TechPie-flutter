import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('resolved package language versions fit the active Dart SDK', () {
    final sdk =
        Platform.version.split(' ').first.split('.').map(int.parse).toList();
    final config = jsonDecode(
      File('.dart_tool/package_config.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    for (final entry in config['packages'] as List<dynamic>) {
      final package = entry as Map<String, dynamic>;
      final language = (package['languageVersion'] as String)
          .split('.')
          .map(int.parse)
          .toList();
      expect(
        language[0] < sdk[0] ||
            (language[0] == sdk[0] && language[1] <= sdk[1]),
        isTrue,
        reason:
            '${package['name']} requires Dart ${package['languageVersion']}',
      );
    }
  });

  test('campus-card implementation is part of the TechPie source tree', () {
    expect(Directory('lib/features/campus_card').existsSync(), isTrue);
    expect(Directory('packages/geekpay').existsSync(), isFalse);

    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(pubspec, isNot(contains('path: packages/geekpay')));
    expect(pubspec, contains('- assets/campus_card/images/'));
    expect(pubspec, contains('- assets/campus_card/data/'));
  });

  test('removed Wallet page cannot be routed or rebuilt', () {
    expect(
      File(
        'lib/features/campus_card/presentation/screens/wallet_screen.dart',
      ).existsSync(),
      isFalse,
    );
    final routes = File(
      'lib/features/campus_card/presentation/app/routes.dart',
    ).readAsStringSync();
    final providers = File(
      'lib/features/campus_card/presentation/app/providers.dart',
    ).readAsStringSync();
    expect(routes, isNot(contains('static const wallet')));
    expect(providers, isNot(contains('GpRoutes.wallet')));
  });

  test('runtime campus-card artwork is present', () {
    for (final path in [
      'assets/campus_card/images/card-full.png',
      'assets/campus_card/images/card-top.png',
      'assets/campus_card/images/card-bottom.png',
      'assets/campus_card/images/network-online.png',
      'assets/campus_card/images/network-offline.png',
      'assets/campus_card/images/network-warning.png',
    ]) {
      expect(File(path).lengthSync(), greaterThan(0), reason: path);
    }
  });

  test('TechPie declares scanner permissions on mobile platforms', () {
    final manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(manifest, contains('android.permission.CAMERA'));
    expect(plist, contains('NSCameraUsageDescription'));
    expect(plist, contains('NSPhotoLibraryUsageDescription'));
  });

  test('TechPie home exposes one eCard entry with an account parameter editor', () {
    final features = File('lib/models/feature.dart').readAsStringSync();
    final account = File(
      'lib/pages/campus_card_account_page.dart',
    ).readAsStringSync();

    expect(features, isNot(contains("id: 'payment_code'")));
    expect(features, isNot(contains("description: '消费码'")));
    expect(features, contains("id: 'campus_card'"));
    expect(features, contains('entry: CampusCardEntry.paymentCode'));
    expect(account, contains('AdaptiveTextFieldGroup('));
    expect(account, contains("label: '检查登录'"));
    expect(account, isNot(contains('showAdaptiveTextInputDialog')));
  });

  test('TechPie mounts the process eCard runtime without an outer load gate',
      () {
    final page = File('lib/pages/campus_card_page.dart').readAsStringSync();
    final service = File(
      'lib/services/campus_card_service.dart',
    ).readAsStringSync();

    expect(page, contains('campusCardService.runtime'));
    expect(page, isNot(contains('CampusCardRuntimeBuilder')));
    expect(page, isNot(contains('eCard 初始化失败')));
    expect(page, isNot(contains('CupertinoActivityIndicator')));
    expect(service, contains('AppRuntime get runtime'));
    expect(service, isNot(contains('Future<AppRuntime> runtime()')));
  });

  test('iOS Home Screen widget deep-links directly to the pay code', () {
    final widget = File(
      'ios/EcardPayWidget/EcardPayWidget.swift',
    ).readAsStringSync();
    final delegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final project = File(
      'ios/Runner.xcodeproj/project.pbxproj',
    ).readAsStringSync();

    expect(widget, contains('techpie://ecard/pay'));
    expect(widget, contains('.supportedFamilies([.systemSmall])'));
    expect(delegate, contains('captureEcardPayURL'));
    expect(project, contains('EcardPayWidget.appex'));
  });

  test('campus-card theme and localization are owned by TechPie', () {
    final app = File(
      'lib/features/campus_card/presentation/app/app.dart',
    ).readAsStringSync();
    final settings = File(
      'lib/features/campus_card/presentation/screens/settings_screen.dart',
    ).readAsStringSync();

    expect(app, contains('GeekPayTheme.inherit(hostTheme)'));
    expect(app, isNot(contains('MaterialApp.router')));
    // The feature installs no localization of its own: the host's MaterialApp
    // supplies the framework's, and the feature's copy is hardcoded Chinese.
    expect(app, isNot(contains('Localizations')));
    expect(settings, isNot(contains('appLocaleProvider')));
  });

  test('internal icons use the platform semantic icon layer', () {
    final presentation = Directory(
      'lib/features/campus_card/presentation',
    );
    for (final entity in presentation.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (entity.path.endsWith('/icons/platform_icons.dart')) continue;
      expect(
        entity.readAsStringSync(),
        isNot(contains('CupertinoIcons.')),
        reason: entity.path,
      );
    }
  });

  test('the removed warning geometry cannot appear in error states', () {
    final icons = File(
      'lib/features/campus_card/presentation/icons/geekpay_icons.dart',
    ).readAsStringSync();
    final state = File(
      'lib/features/campus_card/presentation/widgets/gp_state.dart',
    ).readAsStringSync();
    expect(icons, isNot(contains('static const warning =')));
    expect(state, isNot(contains('icon: GpIcons.warning')));
  });
}
