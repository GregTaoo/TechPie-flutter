import 'dart:async';

import 'package:flutter/material.dart';

import '../features/campus_card/core/errors/app_failure.dart';
import '../services/campus_card_service.dart';
import '../services/service_provider.dart';
import '../utils/platform.dart';
import '../widgets/adaptive_button.dart';
import '../widgets/adaptive_confirmation_button.dart';
import '../widgets/adaptive_page_navigation.dart';
import '../widgets/adaptive_text_field_group.dart';
import '../widgets/app_shell/app_shell_metrics.dart';
import '../widgets/blurred_app_bar.dart';
import '../widgets/ios/ios_native_navigation_bar.dart';

class CampusCardAccountPage extends StatefulWidget {
  const CampusCardAccountPage({super.key});

  @override
  State<CampusCardAccountPage> createState() => _CampusCardAccountPageState();
}

class _CampusCardAccountPageState extends State<CampusCardAccountPage> {
  final _openIdController = TextEditingController();
  bool _loaded = false;
  bool _checking = false;
  bool _saving = false;
  String? _inlineMessage;
  bool _inlineError = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    unawaited(_loadOpenId());
  }

  @override
  void dispose() {
    _openIdController.dispose();
    super.dispose();
  }

  Future<void> _loadOpenId() async {
    final service = ServiceProvider.of(context).campusCardService;
    await service.refreshAccount();
    final openId = await service.readOpenId();
    if (!mounted) return;
    setState(() => _openIdController.text = openId ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final service = ServiceProvider.of(context).campusCardService;
    final theme = Theme.of(context);
    final useIosChrome = isIos();
    final useLegacyIosChrome = usesLegacyIosChrome();
    final topInset = useIosChrome || useLegacyIosChrome
        ? 0.0
        : adaptiveTopBarHeight() + MediaQuery.viewPaddingOf(context).top;
    final busy = service.busy || _checking || _saving;

    return Scaffold(
      extendBodyBehindAppBar: !useIosChrome && !useLegacyIosChrome,
      appBar: useIosChrome
          ? IosNativeNavigationBar(
              title: 'OPENID',
              leadingItems: const [
                IosNativeNavigationBarItem(
                  id: 'back',
                  title: 'Settings',
                  sfSymbol: 'chevron.left',
                  accessibilityLabel: '返回 Settings',
                  placementGroup: 'leading-main',
                ),
              ],
              onItemPressed: (id) {
                if (id == 'back') {
                  unawaited(maybePopAdaptivePage<void>(context));
                }
              },
            )
          : const BlurredAppBar(title: Text('OPENID')),
      body: ListenableBuilder(
        listenable: service,
        builder: (context, _) => ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            topInset + 16,
            16,
            AppShellMetrics.bottomContentPaddingOf(context),
          ),
          children: [
            Text('eCard OPENID', style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'OPENID 用于登录上海科技大学 eCard。它与 TechPie 主账号、CpDaily 和其他关联账号相互独立，并仅保存在本机安全存储中。',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            AdaptiveTextFieldGroup(
              items: [
                AdaptiveTextFieldGroupItem(
                  controller: _openIdController,
                  placeholder: 'OPENID',
                  textInputAction: TextInputAction.done,
                  enabled: !busy,
                  onSubmitted: (_) => unawaited(_save(service)),
                ),
              ],
            ),
            if (_inlineMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                key: const Key('openid-inline-status'),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: (_inlineError
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary)
                      .withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _inlineMessage!,
                  style: TextStyle(
                    color: _inlineError
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            AdaptiveButton(
              key: const Key('openid-save-button'),
              onPressed: busy ? null : () => unawaited(_save(service)),
              icon: Icons.save_outlined,
              sfSymbol: 'checkmark',
              label: service.configured ? '更新 OPENID' : '保存 OPENID',
              role: AdaptiveButtonRole.prominent,
              loading: _saving,
              width: double.infinity,
              accessibilityLabel:
                  service.configured ? '更新 OPENID' : '保存 OPENID',
            ),
            const SizedBox(height: 8),
            AdaptiveButton(
              key: const Key('openid-check-button'),
              onPressed: busy ? null : () => unawaited(_check(service)),
              icon: Icons.verified_user_outlined,
              sfSymbol: 'checkmark.shield',
              label: '检查登录',
              role: AdaptiveButtonRole.standard,
              loading: _checking,
              width: double.infinity,
              accessibilityLabel: '检查 OPENID 登录',
            ),
            if (service.configured) ...[
              const SizedBox(height: 8),
              AdaptiveConfirmationButton(
                label: '移除 OPENID',
                icon: Icons.link_off,
                sfSymbol: 'link.badge.minus',
                confirmTitle: '移除 OPENID？',
                confirmLabel: '移除',
                destructive: true,
                width: double.infinity,
                onConfirmed: () => unawaited(_disconnect(service)),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _check(CampusCardService service) async {
    final openId = _openIdController.text.trim();
    setState(() {
      _checking = true;
      _inlineMessage = null;
    });
    try {
      await service.verifyOpenId(openId);
      if (!mounted) return;
      setState(() {
        _inlineError = false;
        _inlineMessage = 'OPENID 可以正常登录 eCard';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _inlineError = true;
        _inlineMessage = _safeMessage(error);
      });
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _save(CampusCardService service) async {
    final openId = _openIdController.text.trim();
    setState(() {
      _saving = true;
      _inlineMessage = null;
    });
    try {
      await service.connect(openId);
      if (!mounted) return;
      setState(() {
        _inlineError = false;
        _inlineMessage = 'OPENID 已验证并保存';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _inlineError = true;
        _inlineMessage = _safeMessage(error);
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _disconnect(CampusCardService service) async {
    try {
      await service.disconnect();
      if (!mounted) return;
      setState(() {
        _openIdController.clear();
        _inlineError = false;
        _inlineMessage = 'OPENID 已移除';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _inlineError = true;
        _inlineMessage = _safeMessage(error);
      });
    }
  }

  String _safeMessage(Object error) {
    if (error is AppFailure) return error.safeMessage;
    if (error is FormatException) return 'OPENID 格式无效';
    return '无法验证 OPENID，请检查网络后重试';
  }
}
