// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;
import 'package:flutter/material.dart';

class FrameDialog extends StatelessWidget {
  const FrameDialog({
    super.key,
    required this.title,
    required this.child,
    required this.onSave,
    this.error,
    this.busy = false,
    this.width = 1000,
    this.saveLabel = 'Uložit',
  });

  final String title, saveLabel;
  final Widget child;
  final VoidCallback onSave;
  final String? error;
  final bool busy;
  final double width;

  @override
  Widget build(BuildContext context) => Dialog(
    insetPadding: const EdgeInsets.all(16),
    child: SizedBox(
      width: width,
      height: math.min(820, MediaQuery.sizeOf(context).height - 32),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Expanded(child: child),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 80),
                  child: SingleChildScrollView(
                    child: Text(
                      error!,
                      key: const ValueKey('frame-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ),
              ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Zrušit'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  key: const ValueKey('frame-save'),
                  onPressed: busy ? null : onSave,
                  child: Text(saveLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
