import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../models/pairing_bundle.dart';
import '../state/app_state.dart';
import '../theme/trio_design.dart';
import '../widgets/trio_controls.dart';

/// Pairing: what this app is for, the three things to do on the Trio phone,
/// and the scanner.
///
/// A numbered checklist rather than a paragraph, because it is read once,
/// standing next to someone else's phone, while doing the steps.
class PairScreen extends StatefulWidget {
  const PairScreen({super.key});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  bool _scanning = false;
  bool _handlingScan = false;
  String? _error;

  static const _steps = [
    'Settings → Remote Control, and turn remote control on.',
    'Tap Pair New Follower and name this device.',
    'A QR code appears. Scan it below, then check both phones show the '
        'same six digits.',
  ];

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    if (_scanning) return _buildScanner(colors);

    return TrioScreen(
      showBack: false,
      action: TrioButton(
        label: 'Scan pairing code',
        icon: Icons.qr_code_scanner,
        onPressed: () => setState(() {
          _scanning = true;
          _error = null;
        }),
      ),
      child: TrioPanelList(
        children: [
          TrioPanel(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 22),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'TRIO FOLLOWER',
                  style: TrioType.micro(color: colors.inkFaint, size: 10, tracking: 0.18),
                ),
                const SizedBox(height: 10),
                Text(
                  'Watch a Trio phone, and act for it when you need to.',
                  style: TrioType.title(
                    color: colors.ink,
                    size: 30,
                    height: 1.15,
                    tracking: -0.023,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Glucose, insulin and carbs come straight from that phone, '
                  'encrypted end to end. No Nightscout, no third party in between.',
                  style: TrioType.body(color: colors.inkMuted, size: 13.5),
                ),
              ],
            ),
          ),
          TrioPanel(
            child: Column(
              children: [
                const TrioSectionHeader(label: 'On the Trio phone'),
                for (var index = 0; index < _steps.length; index++)
                  Container(
                    decoration: index == _steps.length - 1
                        ? null
                        : BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: colors.hairlineSoft),
                            ),
                          ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: TrioMetrics.inset,
                      vertical: 14,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 20,
                          child: Text(
                            '0${index + 1}',
                            style: TrioType.numeral(
                              size: 12,
                              weight: FontWeight.w600,
                              color: colors.accent,
                            ),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Text(
                            _steps[index],
                            style: TrioType.body(color: colors.ink, size: 14, height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (_error != null)
            TrioPanel(
              padding: const EdgeInsets.fromLTRB(
                TrioMetrics.inset,
                14,
                TrioMetrics.inset,
                14,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TrioTick(color: colors.danger, height: 32),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TrioType.body(color: colors.ink, size: 13.5),
                    ),
                  ),
                ],
              ),
            ),
          TrioPanel(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Column(
              children: [
                Container(
                  width: 150,
                  height: 150,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.ground,
                    border: Border.all(color: colors.hairline),
                  ),
                  child: Icon(Icons.qr_code_2, size: 64, color: colors.rule),
                ),
                const SizedBox(height: 14),
                Text(
                  'TREAT THE CODE LIKE A PASSWORD',
                  style: TrioType.micro(
                    color: colors.inkFaint,
                    size: 10,
                    weight: FontWeight.w500,
                    tracking: 0.12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScanner(TrioColors colors) {
    return Scaffold(
      backgroundColor: colors.ink,
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (capture) {
              final value = capture.barcodes.firstOrNull?.rawValue;
              if (value != null) _handleScan(value);
            },
          ),
          Positioned(
            left: 12,
            right: 12,
            bottom: 32,
            child: TrioButton(
              label: 'Cancel',
              background: colors.panel,
              foreground: colors.ink,
              onPressed: () => setState(() => _scanning = false),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleScan(String raw) async {
    if (_handlingScan) return;
    _handlingScan = true;

    final PairingBundle bundle;
    try {
      bundle = PairingBundle.fromQrString(raw);
    } on PairingParseException catch (error) {
      setState(() {
        _scanning = false;
        _error = error.message;
      });
      _handlingScan = false;
      return;
    }

    setState(() => _scanning = false);

    if (!mounted) {
      _handlingScan = false;
      return;
    }

    final confirmed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => _VerificationDialog(bundle: bundle),
        ) ??
        false;

    if (confirmed && mounted) {
      await context.read<AppState>().completePairing(bundle);
    }
    _handlingScan = false;
  }
}

/// The six digits, big enough to read off one phone while holding another.
class _VerificationDialog extends StatelessWidget {
  const _VerificationDialog({required this.bundle});

  final PairingBundle bundle;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final code = bundle.verificationCode;

    return AlertDialog(
      backgroundColor: colors.panel,
      title: Text(
        'Pair with ${bundle.hostName}?',
        style: TrioType.title(color: colors.ink, size: 17),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Compare this code with the one on the Trio host. Only continue if '
            'they match.',
            style: TrioType.body(color: colors.inkMuted, size: 13.5),
          ),
          const SizedBox(height: 16),
          Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                '${code.substring(0, 3)} ${code.substring(3)}',
                style: TrioType.numeral(
                  size: 34,
                  weight: FontWeight.w600,
                  color: colors.ink,
                  tracking: 0.08,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'This device will be able to send bolus, meal, temp target and '
            'override commands to ${bundle.hostName}, and will receive '
            'encrypted status directly from it.',
            style: TrioType.body(color: colors.inkMuted, size: 12.5),
          ),
          if (Platform.isAndroid && !bundle.fcmAvailable) ...[
            const SizedBox(height: 12),
            Text(
              'The host has no FCM credential configured, so this Android device '
              'will not receive live status. Commands still work. Add a Firebase '
              'service account on the host under Settings → Remote Control to '
              'enable status pushes.',
              style: TrioType.body(color: colors.danger, size: 12.5),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Codes match — pair'),
        ),
      ],
    );
  }
}
