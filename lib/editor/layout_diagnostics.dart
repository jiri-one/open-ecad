import 'package:flutter/material.dart';

class LayoutDiagnostics extends StatelessWidget {
  const LayoutDiagnostics(this.messages, {super.key});
  final List<String> messages;

  @override
  Widget build(BuildContext context) =>
      messages.isEmpty
          ? const SizedBox.shrink()
          : Tooltip(
            message: messages.join('\n'),
            child: IconButton(
              tooltip: null,
              icon: const Icon(Icons.warning_amber_rounded),
              onPressed:
                  () => showDialog<void>(
                    context: context,
                    builder:
                        (context) => AlertDialog(
                          title: const Text('Upozornění rozložení'),
                          content: Text(messages.join('\n\n')),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Zavřít'),
                            ),
                          ],
                        ),
                  ),
            ),
          );
}
