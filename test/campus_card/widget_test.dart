import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:techpie/features/campus_card/app/app_providers.dart';
import 'package:techpie/features/campus_card/app/demo_runtime_factory.dart';
import 'package:techpie/features/campus_card/presentation/app/app.dart';
import 'package:techpie/features/campus_card/presentation/screens/login_screen.dart';

void main() {
  testWidgets(
    'signed-out feature sends OpenID setup to TechPie Account settings',
    (tester) async {
      final runtime = await buildDemoRuntime();
      addTearDown(runtime.dispose);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [appRuntimeProvider.overrideWithValue(runtime)],
          child: const CampusCardFeature(),
        ),
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 30));
      }

      expect(find.byType(LoginScreen), findsOneWidget);
      expect(find.text('打开 Account 设置'), findsOneWidget);
      expect(find.textContaining('演示数据'), findsNothing);
    },
  );
}
