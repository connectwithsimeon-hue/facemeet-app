class ContentFilterException implements Exception {
  final String message;

  const ContentFilterException([
    this.message = ContentFilterService.violationMessage,
  ]);

  @override
  String toString() => message;
}

class ContentFilterService {
  static const String violationMessage =
      'This content may violate FaceMeet’s community standards.';

  static final List<RegExp> _blockedPatterns = [
    RegExp(r'\bkill\s+yourself\b', caseSensitive: false),
    RegExp(r'\bkys\b', caseSensitive: false),
    RegExp(r'\brape\b', caseSensitive: false),
    RegExp(r'\bcsam\b', caseSensitive: false),
    RegExp(r'\bchild\s+porn\b', caseSensitive: false),
    RegExp(r'\bunderage\b', caseSensitive: false),
    RegExp(r'\bnudes?\b', caseSensitive: false),
    RegExp(r'\bsex\s+work\b', caseSensitive: false),
    RegExp(r'\bescort\b', caseSensitive: false),
    RegExp(r'\bonlyfans\b', caseSensitive: false),
    RegExp(r'\bscam\b', caseSensitive: false),
    RegExp(r'\bcash\s?app\b', caseSensitive: false),
    RegExp(r'\bvenmo\b', caseSensitive: false),
    RegExp(r'\bfuck\s+you\b', caseSensitive: false),
    RegExp(r'\bwhore\b', caseSensitive: false),
    RegExp(r'\bbitch\b', caseSensitive: false),
  ];

  static bool containsObjectionableText(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return false;
    return _blockedPatterns.any((pattern) => pattern.hasMatch(text));
  }

  static void ensureAllowed(String? value) {
    if (containsObjectionableText(value)) {
      throw const ContentFilterException();
    }
  }

  static void ensureProfileFieldsAllowed(Map<String, dynamic> data) {
    ensureAllowed(data['bio'] as String?);

    final interests = data['interests'];
    if (interests is Iterable) {
      for (final interest in interests) {
        ensureAllowed(interest.toString());
      }
    }
  }
}
