import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

final maximizePaymentCodeBrightnessProvider =
    AsyncNotifierProvider<MaximizePaymentCodeBrightnessController, bool>(
  MaximizePaymentCodeBrightnessController.new,
);

final class MaximizePaymentCodeBrightnessController
    extends AsyncNotifier<bool> {
  static const _key = 'geekpay.maximize_payment_code_brightness';

  @override
  Future<bool> build() async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getBool(_key) ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_key, enabled);
    state = AsyncData(enabled);
  }
}
