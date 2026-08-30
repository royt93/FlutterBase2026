// Round-25 sweep (post-QC-22) — the invariant that ends the whack-a-mole.
//
// Rounds 12 through 22 were all one bug: a guard read before an `await`, an act
// performed after it. Each round patched the one branch the reviewer probed, so
// the next unswept branch was always one round away. The fix was to give the
// three facts that can move under an await a single home
// (`AdManager._presentBlockedReason`) and to call it immediately before every
// fullscreen presentation.
//
// A convention nobody can check is a convention that rots, so this test checks
// it mechanically: it reads `ad_manager.dart` as text and fails if any
// `await ad.showX(...)` is not preceded by the guard. A fifth ad type added in
// two years' time inherits the rule by failing this test on day one.
//
// It is a source-shape test on purpose. The behavioural proofs live in
// `qc22_rewarded_consent_withdrawn_midload_test.dart` and the per-round files;
// what those cannot do is fail when someone adds a NEW show path.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// How far back from a show call the guard may sit. Generous enough for the
/// logging block that precedes most of them, tight enough that a guard at the
/// top of a 200-line method does not count.
const int _lookbackLines = 30;

int _indentOf(String s) => s.length - s.trimLeft().length;

/// The line of the guard that actually protects the show call at [showLine],
/// or -1.
///
/// "Actually protects" is stricter than "appears above it". A guard nested in
/// a sibling branch — `if (bypassVipGuard) { ...guard... }` — sits above the
/// show textually while covering none of the other path through the method.
/// The first version of this test accepted exactly that and would have passed
/// with the non-bypass rewarded path unguarded. So: the guard must be at an
/// indent no deeper than the show's, and nothing between them may dedent past
/// it (which would mean the enclosing block closed in between).
int _guardLineFor(List<String> lines, int showLine) {
  final showIndent = _indentOf(lines[showLine]);
  final stop = showLine - _lookbackLines < 0 ? 0 : showLine - _lookbackLines;
  for (var j = showLine - 1; j >= stop; j--) {
    final l = lines[j];
    if (l.trim().isEmpty) continue;
    if (!l.contains('_presentBlockedReason(ad)')) continue;
    final guardIndent = _indentOf(l);
    if (guardIndent > showIndent) continue;
    var ok = true;
    for (var k = j + 1; k < showLine; k++) {
      final b = lines[k];
      if (b.trim().isEmpty) continue;
      if (_indentOf(b) < guardIndent) {
        ok = false;
        break;
      }
    }
    if (ok) return j;
  }
  return -1;
}

void main() {
  late List<String> lines;

  setUpAll(() {
    final f = File('lib/src/core/ad_manager.dart');
    expect(f.existsSync(), isTrue,
        reason: 'run this from packages/ad_sdk — the test reads the source');
    lines = f.readAsLinesSync();
  });

  test('the guard helper exists and asks exactly the three volatile facts', () {
    final src = lines.join('\n');
    final start = src.indexOf('String? _presentBlockedReason(');
    expect(start, greaterThan(-1),
        reason: 'the single home of the post-await checks is gone — every show '
            'path below is now guarded by nothing');
    final body = src.substring(start, start + 400);
    expect(body, contains('_destroyInFlight'),
        reason: 'teardown: showing on a session being dismantled');
    expect(body, contains('identical(_adapter, ad)'),
        reason: 'adapter swap: showing on a disposed native channel');
    expect(body, contains('canRequestAds'),
        reason: 'consent: an impression after the user said no');
  });

  test('every fullscreen show call is guarded immediately before the act', () {
    final unguarded = <String>[];
    var found = 0;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (!RegExp(r'await ad\.show[A-Z]').hasMatch(line)) continue;
      found++;
      if (_guardLineFor(lines, i) < 0) {
        unguarded.add('L${i + 1}: ${line.trim()}');
      }
    }

    expect(found, greaterThanOrEqualTo(4),
        reason: 'the four fullscreen types (app open, interstitial, rewarded, '
            'rewarded interstitial) should all be found — if this drops, the '
            'regex stopped matching and the test below is vacuous');
    expect(unguarded, isEmpty,
        reason: 'a fullscreen ad is presented without asking '
            '_presentBlockedReason first. That is exactly the shape of every '
            'bug rounds 12-22 found: the world moves while an await is in '
            'flight, and the act goes ahead on a stale answer');
  });

  // The helper is only worth anything if it is asked LATE. A call at the top of
  // the method is the bug, not the fix.
  test('the guard is not hoisted to the top of a show method', () {
    for (var i = 0; i < lines.length; i++) {
      if (!RegExp(r'await ad\.show[A-Z]').hasMatch(lines[i])) continue;
      final guardLine = _guardLineFor(lines, i);
      expect(guardLine, greaterThan(-1),
          reason: 'covered by the test above; here for a clear failure');
      // Nothing between the guard and the show may await — that would reopen
      // the very window the guard closes.
      final between = lines.sublist(guardLine, i).join('\n');
      expect(between.contains('await '), isFalse,
          reason: 'L${i + 1}: an await sits between the guard and the show, so '
              'the guard is answering about a moment that has already passed');
    }
  });
}
