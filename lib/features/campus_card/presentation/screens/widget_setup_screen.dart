import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:techpie/widgets/adaptive_button.dart';

import '../../app/app_providers.dart';
import '../../domain/ports/platform_ports.dart';
import '../icons/platform_icons.dart';
import '../localization/geekpay_localizations.dart';
import '../theme/colors.dart';
import '../theme/tokens.dart';
import '../widgets/apple_wallet_components.dart';

final class WidgetSetupScreen extends ConsumerStatefulWidget {
  const WidgetSetupScreen({super.key});

  @override
  ConsumerState<WidgetSetupScreen> createState() => _WidgetSetupScreenState();
}

class _WidgetSetupScreenState extends ConsumerState<WidgetSetupScreen> {
  late Future<HomeWidgetAvailability> _availability;
  bool _pinning = false;
  String? _messageKey;

  @override
  void initState() {
    super.initState();
    _availability = Future.sync(
      () async =>
          await ref.read(homeWidgetPortProvider)?.availability() ??
          HomeWidgetAvailability.manual,
    );
  }

  Future<void> _requestPin() async {
    if (_pinning) return;
    setState(() => _pinning = true);
    var requested = false;
    try {
      requested = await ref.read(homeWidgetPortProvider)?.requestPin() ?? false;
    } catch (_) {
      // The manual guide remains usable if the launcher rejects the request.
    }
    if (!mounted) return;
    setState(() {
      _pinning = false;
      _messageKey = requested ? 'widgetConfirmAdd' : 'widgetManualFallback';
      if (!requested) {
        _availability = Future.value(HomeWidgetAvailability.manual);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final apple = Theme.of(context).platform == TargetPlatform.iOS;
    return Scaffold(
      body: AppleWalletPage(
        child: ApplePinnedHeaderLayout(
          title: l10n.t('addPayWidget'),
          leading: CampusCardHeaderAction(
            id: 'back',
            sfSymbol: 'chevron.left',
            icon: GpPlatformIcons.back(context),
            label: l10n.t('back'),
            onPressed: () => context.pop(),
          ),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              20,
              ApplePinnedHeaderLayout.contentTop + 20,
              20,
              40,
            ),
            children: [
              const Center(child: PayWidgetPreview()),
              const SizedBox(height: 24),
              Text(l10n.t('widgetGuideSummary'), textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FutureBuilder<HomeWidgetAvailability>(
                future: _availability,
                builder: (context, snapshot) {
                  final availability =
                      snapshot.data ?? HomeWidgetAvailability.manual;
                  if (availability == HomeWidgetAvailability.unsupported) {
                    return AppleSection(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(l10n.t('widgetUnsupported')),
                        ),
                      ],
                    );
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (availability == HomeWidgetAvailability.nativePin) ...[
                        AdaptiveButton(
                          key: const Key('request-pin-widget'),
                          onPressed: _pinning ? null : _requestPin,
                          icon: GpPlatformIcons.homeWidget(context),
                          sfSymbol: 'square.grid.2x2',
                          label: l10n.t('addToHomeScreen'),
                          role: AdaptiveButtonRole.prominent,
                          loading: _pinning,
                          width: double.infinity,
                        ),
                        const SizedBox(height: 18),
                      ],
                      if (_messageKey != null) ...[
                        Text(l10n.t(_messageKey!), textAlign: TextAlign.center),
                        const SizedBox(height: 18),
                      ],
                      AppleSection(
                        header: l10n.t('widgetGuideSteps'),
                        children: [
                          for (var step = 1; step <= 3; step++)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 16,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  CircleAvatar(
                                    radius: 13,
                                    backgroundColor:
                                        context.gpColors.surfaceRaised,
                                    foregroundColor: context.gpColors.action,
                                    child: Text(
                                      '$step',
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      l10n.t(
                                        'widget${apple ? 'Ios' : 'Android'}Step$step',
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

final class PayWidgetPreview extends StatelessWidget {
  const PayWidgetPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Semantics(
      label: l10n.t('widgetTitle'),
      image: true,
      child: ExcludeSemantics(
        child: Container(
          width: 176,
          height: 176,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            image: const DecorationImage(
              image: AssetImage(GeekPayAssets.widgetBackground),
              fit: BoxFit.cover,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x18000000),
                blurRadius: 16,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                GpPlatformIcons.qrCode(context),
                size: 36,
                color: GpTokens.campusRed,
              ),
              const Spacer(),
              Text(
                l10n.t('widgetTitle'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF242428),
                ),
              ),
              const SizedBox(height: 3),
              Text(
                l10n.t('widgetSubtitle'),
                style: const TextStyle(fontSize: 12, color: Color(0xFF76656A)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
