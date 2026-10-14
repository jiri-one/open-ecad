import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import '../app/theme.dart';

IconData sheetTypeIcon(SheetType type) => switch (type) {
  SheetType.multiLine => Icons.view_headline,
  SheetType.singleLine => Icons.horizontal_rule,
  SheetType.cabinetLayout => Icons.dashboard_outlined,
  SheetType.form => Icons.table_chart_outlined,
};

String sheetTypeHint(SheetType type) => switch (type) {
  SheetType.multiLine => 'Obvody se všemi vodiči a vývody přístrojů',
  SheetType.singleLine => '1P · jedna čára zastupuje více vodičů',
  SheetType.cabinetLayout => 'Ruční výkres skříně a montážní desky',
  SheetType.form => 'Tabulky a seznamy vyplňované ručně',
};

/// Lowercase text without Czech diacritics, so searches work with any keyboard.
String foldForSearch(String value) {
  const accents = {
    'á': 'a',
    'č': 'c',
    'ď': 'd',
    'é': 'e',
    'ě': 'e',
    'í': 'i',
    'ň': 'n',
    'ó': 'o',
    'ř': 'r',
    'š': 's',
    'ť': 't',
    'ú': 'u',
    'ů': 'u',
    'ý': 'y',
    'ž': 'z',
  };
  var result = value.toLowerCase();
  accents.forEach((key, value) => result = result.replaceAll(key, value));
  return result;
}

bool sheetMatchesSearch(Sheet sheet, String query) {
  final needle = foldForSearch(query.trim());
  return needle.isEmpty ||
      foldForSearch(
        // 1P is the customary short name of single-line pages.
        '${sheet.number} ${sheet.name} ${sheet.type.label}'
        '${sheet.type == SheetType.singleLine ? ' 1P' : ''}',
      ).contains(needle);
}

class SheetTypeSelector extends StatelessWidget {
  const SheetTypeSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });
  final SheetType value;
  final ValueChanged<SheetType>? onChanged;

  @override
  Widget build(BuildContext context) {
    final c = EcadColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final type in SheetType.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Semantics(
              button: true,
              selected: type == value,
              inMutuallyExclusiveGroup: true,
              child: InkWell(
                onTap: onChanged == null ? null : () => onChanged!(type),
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: type == value ? c.accent : Colors.transparent,
                    border: Border.all(
                      color: type == value ? c.accent : c.border,
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        sheetTypeIcon(type),
                        size: 18,
                        color: type == value ? c.onAccent : c.foreground,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              type.label,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color:
                                    type == value ? c.onAccent : c.foreground,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              sheetTypeHint(type),
                              style: TextStyle(
                                fontSize: 10,
                                color: type == value ? c.onAccent : c.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (type == value)
                        Icon(Icons.check, size: 16, color: c.onAccent),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
