// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';

import 'package:ecad_core/ecad_core.dart';
import 'package:http/http.dart' as http;

import 'provider_settings.dart';

class OllamaActionResult {
  const OllamaActionResult({required this.actions, this.label, this.message});
  final Object? actions;
  final String? label;
  final String? message;
}

/// No request occurs until [propose] is invoked by an explicit user action.
/// The endpoint may be a local Ollama server or an explicitly configured host.
class OllamaProvider {
  OllamaProvider({http.Client? client}) : _client = client;
  final http.Client? _client;
  static const timeout = Duration(seconds: 45);
  static const maxResponseBytes = 64 * 1024;

  Future<OllamaActionResult> propose({
    required String prompt,
    required AiProviderSettings settings,
    required Sheet sheet,
    required Set<String> selectedDeviceIds,
  }) async {
    settings.validate();
    if (selectedDeviceIds.length > 200) {
      throw const FormatException(
        'Pro model vyberte nejvýše 200 přístrojů najednou.',
      );
    }
    final client = _client ?? http.Client();
    try {
      final contextDevices =
          sheet.devices
              .where((device) => selectedDeviceIds.contains(device.id))
              .toList();
      for (final device in sheet.devices) {
        if (contextDevices.length >= 200) break;
        if (!selectedDeviceIds.contains(device.id)) contextDevices.add(device);
      }
      final request =
          http.Request('POST', settings.chatUri)
            ..headers['Content-Type'] = 'application/json'
            ..body = jsonEncode({
              'model': settings.model,
              'stream': false,
              'format': _schema,
              'options': {'temperature': 0.1},
              'messages': [
                {
                  'role': 'system',
                  'content':
                      'You assist with an electrical CAD prototype. Return only JSON matching the schema. '
                      'Plan only changes explicitly requested by the user. Use only the listed operations. '
                      'Selection operations refer to the supplied selected IDs. Never invent a selection. '
                      'Use motor_branch for a single-line supply, breaker, contactor, motor and protective earth branch. '
                      'Device coordinates are optional; omit them for automatic placement. '
                      'No engineering calculations, code, shell commands, external tools or file operations are available. '
                      'If unsupported or ambiguous, return actions: [] and explain in Czech. '
                      'Write a concise Czech label and message describing the actual proposal.',
                },
                {
                  'role': 'user',
                  'content': jsonEncode({
                    'request': prompt,
                    'sheet': {'id': sheet.id, 'name': sheet.name},
                    'selection': selectedDeviceIds.toList(),
                    'devices':
                        contextDevices
                            .map((device) => device.toJson())
                            .toList(),
                    'deviceContextTruncated':
                        contextDevices.length < sheet.devices.length,
                  }),
                },
              ],
            });
      final response = await _send(client, request).timeout(timeout);
      final json = jsonDecode(response);
      if (json is! Map<String, dynamic> ||
          json['message'] is! Map<String, dynamic>) {
        throw const FormatException('Ollama vrátila neplatnou odpověď.');
      }
      final content = (json['message'] as Map<String, dynamic>)['content'];
      if (content is! String) {
        throw const FormatException('V odpovědi modelu chybí návrh.');
      }
      final proposal = jsonDecode(content);
      if (proposal is! Map<String, dynamic> ||
          proposal.keys.any(
            (key) => !{'label', 'message', 'actions'}.contains(key),
          )) {
        throw const FormatException('Návrh neodpovídá povolenému schématu.');
      }
      final label = _boundedText(proposal['label'], 80);
      final message = _boundedText(proposal['message'], 500);
      if (proposal['actions'] is List &&
          (proposal['actions'] as List).isEmpty) {
        throw FormatException(
          message ??
              'Model pro tento požadavek nenavrhl žádnou podporovanou změnu.',
        );
      }
      return OllamaActionResult(
        actions: proposal['actions'],
        label: label,
        message: message,
      );
    } on TimeoutException {
      throw const FormatException('Ollama neodpověděla do 45 sekund.');
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<String> _send(http.Client client, http.Request request) async {
    final response = await client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.listen((_) {}).cancel();
      throw FormatException(
        'Ollama HTTP ${response.statusCode}. Zkontrolujte adresu serveru a název modelu.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.stream) {
      if (bytes.length + chunk.length > maxResponseBytes) {
        throw const FormatException('Odpověď modelu překročila limit 64 kB.');
      }
      bytes.addAll(chunk);
    }
    return utf8.decode(bytes);
  }

  static String? _boundedText(Object? value, int maxLength) {
    if (value == null) return null;
    if (value is! String ||
        value.length > maxLength ||
        value.contains(RegExp(r'[\x00-\x08\x0b\x0c\x0e-\x1f]'))) {
      throw const FormatException('Model vrátil neplatný text návrhu.');
    }
    return value;
  }

  static Map<String, Object> _operation(
    String name,
    Map<String, Object> properties, [
    List<String> required = const [],
  ]) => {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'op': {'const': name},
      ...properties,
    },
    'required': ['op', ...required],
  };

  static final _schema = {
    'type': 'object',
    'additionalProperties': false,
    'properties': {
      'label': {'type': 'string', 'maxLength': 80},
      'message': {'type': 'string', 'maxLength': 500},
      'actions': {
        'type': 'array',
        'maxItems': 20,
        'items': {
          'anyOf': [
            _operation(
              'insert_device',
              {
                'kind': {
                  'enum': DeviceKind.values.map((kind) => kind.name).toList(),
                },
                'designation': {
                  'type': 'string',
                  'minLength': 1,
                  'maxLength': 32,
                },
                'x': {'type': 'number', 'minimum': -10000, 'maximum': 10000},
                'y': {'type': 'number', 'minimum': -10000, 'maximum': 10000},
                'rating': {'type': 'string', 'maxLength': 80},
                'description': {'type': 'string', 'maxLength': 500},
              },
              ['kind'],
            ),
            _operation('motor_branch', {
              'rating': {'type': 'string', 'maxLength': 80},
            }),
            _operation(
              'rename_selected',
              {
                'designation': {
                  'type': 'string',
                  'minLength': 1,
                  'maxLength': 32,
                },
              },
              ['designation'],
            ),
            _operation(
              'duplicate_selected',
              {
                'count': {'type': 'integer', 'minimum': 1, 'maximum': 20},
              },
              ['count'],
            ),
            _operation('delete_selected', {}),
            _operation('undo', {}),
            _operation('redo', {}),
            _operation('validate', {}),
          ],
        },
      },
    },
    'required': ['label', 'message', 'actions'],
  };
}
