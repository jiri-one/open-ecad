import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  timeout: const Duration(seconds: 60),
  writeResponseOnFailure: true,
  responseDataCallback: (data) async {
    final output = Directory('artifacts/performance');
    await output.create(recursive: true);
    final path = '${output.path}/canvas_profile.json';
    await File(
      path,
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    stdout.writeln('Actual native frame timings saved to $path');
    final report = data?['canvas_profile'] as Map<String, dynamic>?;
    if (report == null) return;
    stdout.writeln('Environment: ${report['environment']}');
    for (final key in ['working_view', 'overview']) {
      final phase = report[key] as Map<String, dynamic>;
      final sum = phase['buildPlusRasterMs'] as Map<String, dynamic>;
      final total = phase['totalSpanMs'] as Map<String, dynamic>;
      final missed = phase['overBudgetFrames'] as Map<String, dynamic>;
      stdout.writeln(
        '$key: ${phase['frameCount']} frames; '
        'build+raster p50 ${sum['p50']} ms, p95 ${sum['p95']} ms, worst ${sum['worst']} ms; '
        'total p95 ${total['p95']} ms; ${missed['totalSpan']} total spans over 16.7 ms.',
      );
    }
  },
);
