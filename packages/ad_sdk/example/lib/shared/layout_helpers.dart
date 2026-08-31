// T117 — edge-to-edge layout helper shared by every demo page. Split out of
// main.dart (used to be private to that one file; now needs to be public
// since it's called from many files).
import 'package:flutter/material.dart';

/// Adds the system nav-bar inset to the bottom of [base] so the last item in
/// a scrollable isn't hidden behind the (transparent) Android nav bar in
/// edge-to-edge mode.
EdgeInsets bottomSafe(BuildContext context, EdgeInsets base) {
  final inset = MediaQuery.paddingOf(context).bottom;
  return EdgeInsets.fromLTRB(
      base.left, base.top, base.right, base.bottom + inset);
}
