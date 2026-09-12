/// Redacts identifiers and credentials before data crosses a host boundary.
String redactSensitiveData(String message) {
  var result = message;
  result = result.replaceAllMapped(
    RegExp(r'\b(gaid|idfa|devicegaid|advertising[_ -]?id)\s*[:=]\s*[^\s,;)]+',
        caseSensitive: false),
    (m) => '${m.group(1)}=<redacted>',
  );
  result = result.replaceAllMapped(
    RegExp(r'\b(test[_ -]?device(?:[_ -]?id|[_ -]?hash)?)\s*[:=]\s*[^\s,;)]+',
        caseSensitive: false),
    (m) => '${m.group(1)}=<redacted>',
  );
  return result.replaceAllMapped(
    RegExp(
        r'\b(vip[_ -]?(?:key|code|token)|private[_ -]?key)\s*[:=]\s*[^\s,;)]+',
        caseSensitive: false),
    (m) => '${m.group(1)}=<redacted>',
  );
}
