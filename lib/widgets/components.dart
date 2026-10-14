import 'package:flutter/material.dart';
import '../app/theme.dart';

class EcadIconButton extends StatelessWidget {
  const EcadIconButton({
    super.key,
    required this.icon,
    required this.label,
    this.onPressed,
    this.selected = false,
    this.size = 34,
    this.iconSize = 18,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final double size, iconSize;
  @override
  Widget build(BuildContext context) {
    final c = EcadColors.of(context);
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: label,
        enabled: onPressed != null,
        selected: selected,
        onTap: onPressed,
        child: ExcludeSemantics(
          child: Material(
            color: selected ? c.accent : Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(4),
              side: selected ? BorderSide(color: c.accent) : BorderSide.none,
            ),
            child: InkWell(
              onTap: onPressed,
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                width: size,
                height: size,
                child: Icon(
                  icon,
                  size: iconSize,
                  color: selected ? c.onAccent : c.foreground,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SectionCaption extends StatelessWidget {
  const SectionCaption(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.25,
              fontWeight: FontWeight.w600,
              color: EcadColors.of(context).muted,
            ),
          ),
        ),
        if (trailing != null) trailing!,
      ],
    ),
  );
}

class Keycap extends StatelessWidget {
  const Keycap(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) {
    final c = EcadColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: c.border),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 9, color: c.muted, height: 1.2),
      ),
    );
  }
}

class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 27});
  final double size;
  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _BrandPainter(EcadColors.of(context).foreground),
  );
}

class _BrandPainter extends CustomPainter {
  _BrandPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final p =
        Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.square;
    final s = size.width / 28;
    canvas.save();
    canvas.scale(s);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(1, 1, 26, 26),
        const Radius.circular(5),
      ),
      p,
    );
    canvas.drawLine(const Offset(1, 14), const Offset(8, 14), p);
    canvas.drawLine(const Offset(8, 14), const Offset(15, 7), p);
    canvas.drawLine(const Offset(16, 14), const Offset(27, 14), p);
    canvas.drawCircle(const Offset(8, 14), 1.5, Paint()..color = color);
    canvas.drawCircle(const Offset(17, 14), 1.5, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BrandPainter oldDelegate) =>
      color != oldDelegate.color;
}

class PanelTab extends StatelessWidget {
  const PanelTab({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    this.count,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final int? count;
  @override
  Widget build(BuildContext context) {
    final c = EcadColors.of(context);
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 46,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: selected ? c.foreground : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 15),
                const SizedBox(width: 7),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                if (count != null && count! > 0) ...[
                  const SizedBox(width: 5),
                  Text('$count', style: const TextStyle(fontSize: 10)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
