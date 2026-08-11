import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../models/pairing_bundle.dart';
import '../state/app_state.dart';

/// Pairing flow: scan the QR code shown in Trio → Settings → Remote Control →
/// Pair New Follower, verify the six-digit code against the host screen, and
/// store the bundle.
class PairScreen extends StatefulWidget {
  const PairScreen({super.key});

  @override
  State<PairScreen> createState() => _PairScreenState();
}

class _PairScreenState extends State<PairScreen> {
  bool _scanning = false;
  bool _handlingScan = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Trio Follower')),
      body: _scanning ? _buildScanner() : _buildIntro(theme),
    );
  }

  Widget _buildIntro(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Spacer(),
          Icon(Icons.qr_code_scanner, size: 96, color: theme.colorScheme.primary),
          const SizedBox(height: 24),
          Text(
            'Pair with a Trio host',
            style: theme.textTheme.headlineSmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            'On the Trio phone, open Settings → Remote Control, enable remote '
            'control and tap "Pair New Follower". Then scan the QR code shown '
            'there.',
            style: theme.textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
              textAlign: TextAlign.center,
            ),
          ],
          const Spacer(),
          FilledButton.icon(
            onPressed: () => setState(() {
              _scanning = true;
              _error = null;
            }),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan pairing code'),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _buildScanner() {
    return Stack(
      children: [
        MobileScanner(
          onDetect: (capture) {
            final value = capture.barcodes.firstOrNull?.rawValue;
            if (value != null) _handleScan(value);
          },
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 32,
          child: Center(
            child: FilledButton.tonal(
              onPressed: () => setState(() => _scanning = false),
              child: const Text('Cancel'),
            ),
          ),
        ),
      ],
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

class _VerificationDialog extends StatelessWidget {
  const _VerificationDialog({required this.bundle});

  final PairingBundle bundle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Pair with ${bundle.hostName}?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Compare this verification code with the one shown on the Trio '
            'host. Only continue if they match.',
          ),
          const SizedBox(height: 16),
          Text(
            bundle.verificationCode,
            style: theme.textTheme.headlineMedium?.copyWith(
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
              letterSpacing: 6,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'This device will be able to send bolus, meal, temp target and '
            'override commands to ${bundle.hostName}.',
            style: theme.textTheme.bodySmall,
          ),
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
