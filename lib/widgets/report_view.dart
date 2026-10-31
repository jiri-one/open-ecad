import 'package:ecad_core/ecad_core.dart';
import 'package:flutter/material.dart';
import '../app/controller.dart';
import '../services/report_layout.dart';
import 'inventory.dart';
import 'diagnostic_text.dart';
import 'sheet_settings.dart';

class ReportView extends StatefulWidget {
  const ReportView({super.key, required this.app});
  final EditorController app;
  @override
  State<ReportView> createState() => _ReportViewState();
}

class _ReportViewState extends State<ReportView> {
  EcadProject? snapshot;
  String? sheetId;
  late ReportLayout layout;
  int index = 0;
  final transformation = TransformationController();
  @override
  void initState() {
    super.initState();
    _bindNavigation();
  }

  @override
  void dispose() {
    widget.app.viewport.unbindNavigation(this);
    transformation.removeListener(_zoomChanged);
    transformation.dispose();
    super.dispose();
  }

  void _bindNavigation() {
    transformation.addListener(_zoomChanged);
    widget.app.viewport.bindNavigation(
      this,
      fit: () => transformation.value = Matrix4.identity(),
      zoom: (factor) {
        final current = transformation.value.getMaxScaleOnAxis();
        final next = (current * factor).clamp(.5, 8.0);
        transformation.value =
            transformation.value.clone()
              ..scaleByDouble(next / current, next / current, 1, 1);
      },
    );
  }

  void _zoomChanged() =>
      widget.app.viewport.reportZoom(transformation.value.getMaxScaleOnAxis());
  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    if (!identical(snapshot, app.project) || sheetId != app.sheet.id) {
      snapshot = app.project;
      sheetId = app.sheet.id;
      layout = layoutReport(app.project, app.sheet);
      index = index.clamp(0, layout.pages.length - 1);
    }
    final page = layout.pages[index];
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 42, 8, 0),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                tooltip: 'Předchozí strana reportu',
                onPressed: index == 0 ? null : () => setState(() => index--),
                icon: const Icon(Icons.chevron_left),
              ),
              Text('${page.number} · ${index + 1}/${layout.pages.length}'),
              IconButton(
                tooltip: 'Další strana reportu',
                onPressed:
                    index + 1 == layout.pages.length
                        ? null
                        : () => setState(() => index++),
                icon: const Icon(Icons.chevron_right),
              ),
              TextButton(
                onPressed: () => editSheetSettings(context, app),
                child: const Text('Vlastnosti reportu'),
              ),
            ],
          ),
        ),
        Expanded(
          child: InteractiveViewer(
            transformationController: transformation,
            minScale: .5,
            maxScale: 8,
            child: Center(
              child: AspectRatio(
                aspectRatio: page.sizeMm.width / page.sizeMm.height,
                child: CustomPaint(painter: _ReportPainter(page)),
              ),
            ),
          ),
        ),
        if (layout.data.diagnostics.isNotEmpty)
          SizedBox(
            height: 95,
            child: ListView(
              children: [
                for (final issue in layout.data.diagnostics)
                  ListTile(
                    dense: true,
                    title: Text(diagnosticText(app.project, issue)),
                    onTap: () {
                      if (issue.componentId case final id?) {
                        editComponent(
                          context,
                          app,
                          component: app.project.componentById(id),
                        );
                      } else if (issue.articleId case final id?) {
                        editArticle(
                          context,
                          app,
                          article: app.project.articleById(id),
                        );
                      }
                    },
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ReportPainter extends CustomPainter {
  const _ReportPainter(this.page);
  final ReportPage page;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / page.sizeMm.width);
    paintReportPage(canvas, page);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _ReportPainter oldDelegate) =>
      !identical(page, oldDelegate.page);
}
