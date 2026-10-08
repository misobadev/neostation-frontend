import 'dart:convert';

/// Persisted rule vocabulary. Enum names are stable serialization identifiers.
enum SmartField {
  system,
  title,
  genre,
  developer,
  publisher,
  year,
  rating,
  favorite,
  played,
  playTime,
  lastPlayed,
}

enum SmartOperator {
  isEqual,
  isNot,
  contains,
  notContains,
  before,
  after,
  atLeast,
  atMost,
  between,
  withinDays,
  notWithinDays,
}

List<SmartOperator> operatorsFor(SmartField field) => switch (field) {
  SmartField.system => [SmartOperator.isEqual, SmartOperator.isNot],
  SmartField.title => [
    SmartOperator.contains,
    SmartOperator.notContains,
    SmartOperator.isEqual,
  ],
  SmartField.genre || SmartField.developer || SmartField.publisher => [
    SmartOperator.isEqual,
    SmartOperator.isNot,
    SmartOperator.contains,
  ],
  SmartField.year => [
    SmartOperator.isEqual,
    SmartOperator.before,
    SmartOperator.after,
    SmartOperator.between,
  ],
  SmartField.rating => [
    SmartOperator.atLeast,
    SmartOperator.atMost,
    SmartOperator.between,
  ],
  SmartField.playTime => [SmartOperator.atLeast, SmartOperator.atMost],
  SmartField.favorite || SmartField.played => [SmartOperator.isEqual],
  SmartField.lastPlayed => [
    SmartOperator.withinDays,
    SmartOperator.notWithinDays,
  ],
};

class SmartRule {
  final SmartField field;
  final SmartOperator operator;
  final Object value;
  final num? upper;

  SmartRule({
    required this.field,
    required this.operator,
    required Object value,
    this.upper,
  }) : value = value is List<String>
           ? List<String>.unmodifiable(value)
           : value {
    if (!isValid) throw const FormatException('Invalid smart collection rule');
  }

  bool get isValid {
    if (!operatorsFor(field).contains(operator)) return false;
    if (field == SmartField.system) {
      return upper == null &&
          value is List<String> &&
          (value as List<String>).isNotEmpty &&
          (value as List<String>).every((v) => v.trim().isNotEmpty);
    }
    if (field == SmartField.favorite || field == SmartField.played) {
      return value is bool && upper == null;
    }
    if ([
      SmartField.title,
      SmartField.genre,
      SmartField.developer,
      SmartField.publisher,
    ].contains(field)) {
      return value is String &&
          (value as String).trim().isNotEmpty &&
          upper == null;
    }
    if (value is! num || !(value as num).isFinite) return false;
    final number = value as num;
    final max = field == SmartField.rating
        ? 10
        : field == SmartField.year
        ? 9999
        : double.infinity;
    final min = field == SmartField.year || field == SmartField.lastPlayed
        ? 1
        : 0;
    if (number < min || number > max) return false;
    if ((field == SmartField.year || field == SmartField.lastPlayed) &&
        number != number.roundToDouble()) {
      return false;
    }
    if (operator == SmartOperator.between) {
      return upper != null &&
          upper!.isFinite &&
          upper! >= number &&
          upper! <= max &&
          (field != SmartField.year || upper == upper!.round());
    }
    return upper == null;
  }

  Map<String, Object?> toJson() => {
    'field': field.name,
    'operator': operator.name,
    'value': value,
    if (upper != null) 'upper': upper,
  };

  factory SmartRule.fromJson(Map<String, dynamic> json) {
    final field = SmartField.values.byName(json['field'] as String);
    final raw = json['value'];
    return SmartRule(
      field: field,
      operator: SmartOperator.values.byName(json['operator'] as String),
      value: field == SmartField.system
          ? List<String>.from(raw as List)
          : raw as Object,
      upper: json['upper'] as num?,
    );
  }
}

class SmartCollectionRules {
  final bool matchAll;
  final List<SmartRule> rules;

  SmartCollectionRules({this.matchAll = true, required List<SmartRule> rules})
    : rules = List.unmodifiable(rules) {
    if (rules.isEmpty || rules.any((r) => !r.isValid)) {
      throw const FormatException('A smart collection needs valid rules');
    }
  }

  String encode() => jsonEncode({
    'version': 1,
    'mode': matchAll ? 'all' : 'any',
    'rules': rules.map((r) => r.toJson()).toList(),
  });

  factory SmartCollectionRules.decode(String source) {
    final json = jsonDecode(source) as Map<String, dynamic>;
    if (json['version'] != 1 || !['all', 'any'].contains(json['mode'])) {
      throw const FormatException('Unsupported smart collection definition');
    }
    return SmartCollectionRules(
      matchAll: json['mode'] == 'all',
      rules: (json['rules'] as List)
          .map((r) => SmartRule.fromJson(Map<String, dynamic>.from(r as Map)))
          .toList(),
    );
  }
}
