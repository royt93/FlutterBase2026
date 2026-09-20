/// Redacts identifiers and credentials before data crosses a host boundary.
///
/// Round 62 audit fix: each pattern's `["']?` right after the key name
/// (before `\s*[:=]`) matches a JSON-quoted key's closing quote (e.g.
/// `"gaid": "abc-123-def"`), which the original `\s*[:=]` alone did not —
/// that quote character isn't whitespace/`:`/`=`, so the whole match failed
/// to even start and the value passed through unredacted. Handwritten
/// `key: value`/`key=value` shapes (no quote before the colon) still match
/// the same as before.
String redactSensitiveData(String message) {
  var result = message;
  result = result.replaceAllMapped(
    RegExp(
        r'\b(gaid|idfa|devicegaid|advertising[_ -]?id)["\x27]?\s*[:=]\s*[^\s,;)]+',
        caseSensitive: false),
    (m) => '${m.group(1)}=<redacted>',
  );
  result = result.replaceAllMapped(
    RegExp(
        r'\b(test[_ -]?device(?:[_ -]?id|[_ -]?hash)?)["\x27]?\s*[:=]\s*[^\s,;)]+',
        caseSensitive: false),
    (m) => '${m.group(1)}=<redacted>',
  );
  return result.replaceAllMapped(
    RegExp(
        r'\b(vip[_ -]?(?:key|code|token)|private[_ -]?key)["\x27]?\s*[:=]\s*[^\s,;)]+',
        caseSensitive: false),
    (m) => '${m.group(1)}=<redacted>',
  );
}
