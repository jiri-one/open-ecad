// SPDX-License-Identifier: GPL-3.0-or-later

/// Positions are valid only for the captured engine and revision.
final class EditHistoryEntry {
  const EditHistoryEntry({required this.label, required this.steps})
    : assert(steps > 0);

  final String label;
  final int steps;
}
