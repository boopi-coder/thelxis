/// Builds the four plural entries of a group. English: [enOne]/[enOther];
/// Russian: one (1, 21...), few (2-4, 22-24...), many (0, 5-20, 25...).
Map<String, (String, String)> plural(
  String base, {
  required String enOne,
  required String enOther,
  required String ruOne,
  required String ruFew,
  required String ruMany,
}) =>
    {
      '$base.one': (enOne, ruOne),
      '$base.few': (enOther, ruFew),
      '$base.many': (enOther, ruMany),
      '$base.other': (enOther, ruMany),
    };
