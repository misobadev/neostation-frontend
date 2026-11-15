Map<String, dynamic> convertMapToJson(Map<Object?, Object?> raw) {
  return raw.map((key, value) {
    if (value is Map) {
      return MapEntry(key.toString(), convertMapToJson(value));
    } else if (value is List) {
      return MapEntry(
        key.toString(),
        value.map((e) {
          if (e is Map) {
            return convertMapToJson(e);
          }
          return e;
        }).toList(),
      );
    }
    return MapEntry(key.toString(), value);
  });
}
