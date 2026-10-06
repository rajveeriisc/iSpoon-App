/// Restore policy for meal bite payloads.
///
/// `GET /api/meals?include_bites=true` embeds at most 500 bites. An empty or
/// truncated JSON array is still a [List], so the client must not treat every
/// list as the complete history.
const int kEmbeddedBiteCap = 500;

bool mealNeedsDedicatedBiteFetch(
  Object? embeddedBites, {
  int? totalBites,
}) {
  if (embeddedBites is! List) return true;
  if (embeddedBites.length >= kEmbeddedBiteCap) return true;
  if (totalBites != null && embeddedBites.length < totalBites) return true;
  return false;
}

int? jsonInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}
