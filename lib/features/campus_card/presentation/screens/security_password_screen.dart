import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/app_providers.dart';
import '../../domain/ports/platform_ports.dart';
import '../icons/platform_icons.dart';
import '../localization/geekpay_localizations.dart';
import '../theme/colors.dart';
import '../widgets/apple_wallet_components.dart';
import '../widgets/gp_state.dart';

final class SecurityPasswordScreen extends ConsumerStatefulWidget {
  const SecurityPasswordScreen({super.key});

  @override
  ConsumerState<SecurityPasswordScreen> createState() =>
      _SecurityPasswordScreenState();
}

class _SecurityPasswordScreenState
    extends ConsumerState<SecurityPasswordScreen> {
  final _old = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _old.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final initialization =
        ref.read(spendingPasswordInitializationProvider).valueOrNull;
    if (initialization == null) return;
    final valid = [
      _old,
      _next,
      _confirm,
    ].every((controller) => RegExp(r'^\d{6}$').hasMatch(controller.text));
    if (!valid || _next.text != _confirm.text) {
      await _showMessage(context.l10n.t('enterPassword'));
      await ref.read(appRuntimeProvider).haptics.play(HapticEvent.error);
      return;
    }
    setState(() => _loading = true);
    try {
      await ref.read(spendingLimitsControllerProvider.notifier).changePassword(
            accountKey: initialization.accountKey,
            oldPassword: _old.text,
            newPassword: _next.text,
          );
      await ref.read(appRuntimeProvider).haptics.play(HapticEvent.success);
      if (!mounted) return;
      await _showMessage(context.l10n.t('passwordChanged'));
      if (mounted) context.pop();
    } catch (error) {
      if (mounted) await _showMessage(GpStateView.safeUiError(error));
    } finally {
      _old.clear();
      _next.clear();
      _confirm.clear();
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _showMessage(String message) => showAdaptiveDialog<void>(
        context: context,
        useRootNavigator: false,
        builder: (dialogContext) => AlertDialog.adaptive(
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(context.l10n.t('done')),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final initialization = ref.watch(spendingPasswordInitializationProvider);
    final l10n = context.l10n;
    return Scaffold(
      body: AppleWalletPage(
        child: ApplePinnedHeaderLayout(
          leading: CampusCardHeaderAction(
            id: 'back',
            sfSymbol: 'chevron.left',
            icon: GpPlatformIcons.back(context),
            label: l10n.t('back'),
            onPressed: () => context.pop(),
          ),
          title: l10n.t('changePassword'),
          child: ListView(
            physics: const BouncingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              20,
              ApplePinnedHeaderLayout.contentTop,
              20,
              52,
            ),
            children: [
              switch (initialization) {
                AsyncData(:final value) when value.haveCard => Column(
                    children: [
                      AppleSection(
                        children: [
                          _PasswordRow(
                            label: l10n.t('oldPassword'),
                            controller: _old,
                          ),
                          _PasswordRow(
                            label: l10n.t('newPassword'),
                            controller: _next,
                          ),
                          _PasswordRow(
                            label: l10n.t('confirmPassword'),
                            controller: _confirm,
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      FilledButton(
                        onPressed: _loading ? null : _submit,
                        style: FilledButton.styleFrom(
                          backgroundColor: context.gpColors.action,
                          minimumSize: const Size.fromHeight(54),
                          shape: const StadiumBorder(),
                        ),
                        child: _loading
                            ? const CupertinoActivityIndicator(
                                color: Colors.white,
                              )
                            : Text(l10n.t('save')),
                      ),
                    ],
                  ),
                AsyncData() => GpStateView(
                    title: l10n.t('cardUnavailable'),
                  ),
                AsyncError(:final error) => GpStateView.error(
                    error,
                    onRetry: () =>
                        ref.invalidate(spendingPasswordInitializationProvider),
                  ),
                _ => const Padding(
                    padding: EdgeInsets.all(42),
                    child: CupertinoActivityIndicator(radius: 13),
                  ),
              },
            ],
          ),
        ),
      ),
    );
  }
}

final class _PasswordRow extends StatelessWidget {
  const _PasswordRow({required this.label, required this.controller});

  final String label;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      child: TextField(
        controller: controller,
        obscureText: true,
        maxLength: 6,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: label,
          counterText: '',
          border: InputBorder.none,
        ),
      ),
    );
  }
}
