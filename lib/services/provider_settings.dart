// SPDX-License-Identifier: GPL-3.0-or-later
/// Explicit settings for the optional Ollama HTTP integration.
/// Merely constructing or saving these settings makes no network requests.
class AiProviderSettings {
  const AiProviderSettings({
    this.baseUrl = 'http://localhost:11434',
    this.model = 'qwen2.5:7b',
  });

  final String baseUrl;
  final String model;

  factory AiProviderSettings.fromJson(Map<String, dynamic> json) =>
      AiProviderSettings(
        baseUrl: json['baseUrl'] as String? ?? 'http://localhost:11434',
        model: json['model'] as String? ?? 'qwen2.5:7b',
      );

  Map<String, String> toJson() => {'baseUrl': baseUrl, 'model': model};

  void validate() {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        'Adresa Ollama musí být HTTP(S) URL bez hesla, dotazu a fragmentu.',
      );
    }
    if (model.trim().isEmpty || model.length > 120) {
      throw const FormatException('Vyplňte platný název modelu Ollama.');
    }
  }

  Uri get chatUri {
    validate();
    final base = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$base/api/chat');
  }
}
