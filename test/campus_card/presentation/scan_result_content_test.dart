import 'package:flutter/material.dart';
import 'package:techpie/features/campus_card/presentation/theme/tokens.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:techpie/features/campus_card/domain/models/scan_models.dart';
import 'package:techpie/features/campus_card/domain/money_fen.dart';
import 'package:techpie/features/campus_card/presentation/scanner/scan_result_content.dart';
import 'package:techpie/features/campus_card/presentation/theme/theme.dart';

Widget _host(Widget child) => MaterialApp(
      theme: GeekPayTheme.inherit(ThemeData.dark())
          .copyWith(platform: TargetPlatform.android),
      home: Scaffold(body: child),
    );

void main() {
  group('ScanResultContent', () {
    testWidgets('payment success renders amount, fee, and balance only', (
      tester,
    ) async {
      const result = ScanSucceeded(
        kind: ScanSuccessKind.payment,
        amount: MoneyFen(4250),
        fee: MoneyFen(50),
        balance: MoneyFen(123456),
        message: null,
      );
      await tester.pumpWidget(
        _host(ScanResultContent(success: result, onDone: () {})),
      );
      await tester.pump();

      expect(find.text('支付成功'), findsOneWidget);
      expect(find.text('¥42.50'), findsOneWidget);
      expect(tester.widget<Text>(find.text('支付成功')).style!.color, GpTokens.campusRed);
      expect(tester.widget<Text>(find.text('¥42.50')).style!.color, GpTokens.campusRed);
      expect(find.text('含管理费 ¥0.50'), findsOneWidget);
      expect(find.text('交易后余额 ¥1,234.56'), findsOneWidget);
      // Merchant/location must not be rendered (they are not provided).
      expect(find.textContaining('商户'), findsNothing);
      expect(find.textContaining('门店'), findsNothing);
    });

    testWidgets('attendance renders attendance confirm text only', (
      tester,
    ) async {
      const result = ScanSucceeded(kind: ScanSuccessKind.attendance);
      await tester.pumpWidget(
        _host(ScanResultContent(success: result, onDone: () {})),
      );
      await tester.pump();

      expect(find.text('签到成功'), findsOneWidget);
      expect(find.text('¥'), findsNothing);
    });

    testWidgets('openDevice renders open-device confirm text only', (
      tester,
    ) async {
      const result = ScanSucceeded(kind: ScanSuccessKind.openDevice);
      await tester.pumpWidget(
        _host(ScanResultContent(success: result, onDone: () {})),
      );
      await tester.pump();

      expect(find.text('开阀成功'), findsOneWidget);
    });

    testWidgets('bindTray renders bind-tray confirm text only', (tester) async {
      const result = ScanSucceeded(kind: ScanSuccessKind.bindTray);
      await tester.pumpWidget(
        _host(ScanResultContent(success: result, onDone: () {})),
      );
      await tester.pump();

      expect(find.text('绑盘成功'), findsOneWidget);
    });

    testWidgets('unknown kind renders neutral completion text', (tester) async {
      const result = ScanSucceeded(kind: ScanSuccessKind.unknown);
      await tester.pumpWidget(
        _host(ScanResultContent(success: result, onDone: () {})),
      );
      await tester.pump();

      expect(find.text('处理完成'), findsOneWidget);
      expect(find.text('支付成功'), findsNothing);
    });
  });
}
