// T217 — computes this package's public API surface (every symbol visible
// through `package:applovin_admob_sdk/applovin_admob_sdk.dart`, plus every
// public member declared directly on each exported class/enum/mixin) as one
// deterministic, sorted text blob.
//
// Used two ways:
//   - `test/api_golden_test.dart` calls [computePublicApiSurface] and
//     compares the result against the checked-in golden file, failing (and
//     printing a diff) on any unintentional change to the public API.
//   - Run directly (`dart run tool/api_surface.dart`) to print the current
//     surface — pipe it to `test/goldens/public_api_surface.txt` to
//     deliberately accept a change:
//       dart run tool/api_surface.dart > test/goldens/public_api_surface.txt
//
// Deliberately walks the resolved EXPORT NAMESPACE (`LibraryElement2.
// exportNamespace`), not the export directives' text — this is what a
// `import 'package:applovin_admob_sdk/applovin_admob_sdk.dart'` consumer
// actually sees, independent of which file a symbol is physically declared
// in or whether an export directive uses a `show` clause.
//
// Deliberately only walks members DECLARED on each class/enum/mixin
// (`fields2`/`getters2`/`methods2`/`setters2`/`constructors2`), never
// inherited ones — inheriting from Flutter's own `StatefulWidget`/`State`/
// etc. would otherwise flood this with framework noise this package does
// not own and cannot break.
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element2.dart';
import 'package:path/path.dart' as p;

Future<String> computePublicApiSurface({
  required String packageRoot,
  String entryLibraryRelativePath = 'lib/applovin_admob_sdk.dart',
}) async {
  final absoluteRoot = p.normalize(p.absolute(packageRoot));
  final entryPath = p.join(absoluteRoot, entryLibraryRelativePath);

  // Run via plain `dart run`, `Platform.resolvedExecutable` already points
  // at a real Dart SDK install and auto-detection (the default, sdkPath:
  // null) works. Run via `flutter test`, it points at the flutter_tester
  // engine binary instead — a different directory layout analyzer's
  // auto-detection can't parse — so resolve the real dart-sdk explicitly
  // from FLUTTER_ROOT (set by the `flutter` launcher) whenever present.
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final sdkPath =
      flutterRoot == null ? null : p.join(flutterRoot, 'bin', 'cache', 'dart-sdk');

  final collection = AnalysisContextCollection(
      includedPaths: [absoluteRoot], sdkPath: sdkPath);
  try {
    final context = collection.contextFor(entryPath);
    final result = await context.currentSession.getResolvedLibrary(entryPath);
    if (result is! ResolvedLibraryResult) {
      throw StateError(
          'Could not resolve $entryLibraryRelativePath: $result');
    }

    // analyzer's `Element2` model is its own in-progress replacement for
    // the deprecated `Element` API — there is no non-experimental way to
    // walk a resolved library's export namespace right now. Dev-tool-only,
    // never shipped; re-check on the next analyzer major bump.
    // ignore: experimental_member_use
    final library = result.element2;
    final exported = library.exportNamespace.definedNames2;

    final lines = <String>[];
    for (final name in exported.keys.toList()..sort()) {
      final element = exported[name]!;
      lines.add(_describeTopLevel(name, element));
      if (element is InterfaceElement2) {
        lines.addAll(_describeMembers(name, element));
      }
    }
    lines.sort();
    return lines.join('\n');
  } finally {
    await collection.dispose();
  }
}

String _describeTopLevel(String name, Element2 element) {
  final kind = element.kind.displayName;
  return '$name  [$kind]  ${element.displayString2()}';
}

// T217 — @internal/@visibleForTesting mark a member as public Dart syntax
// requires but NOT part of this package's actual API promise to a host —
// excluded here so their churn (renames, signature tweaks) never forces an
// unrelated golden-file update.
bool _isExcludedFromApiSurface(Annotatable a) =>
    a.metadata2.hasInternal || a.metadata2.hasVisibleForTesting;

List<String> _describeMembers(String ownerName, InterfaceElement2 element) {
  final lines = <String>[];

  for (final c in element.constructors2) {
    if (c.isPrivate || _isExcludedFromApiSurface(c)) continue;
    lines.add('$ownerName.${c.name3 ?? "new"}  [constructor]  '
        '${c.displayString2()}');
  }
  for (final f in element.fields2) {
    if (f.isPrivate || f.isSynthetic || _isExcludedFromApiSurface(f)) {
      continue;
    }
    lines.add(
        '$ownerName.${f.name3}  [field]  ${f.displayString2()}');
  }
  for (final m in element.methods2) {
    if (m.isPrivate || _isExcludedFromApiSurface(m)) continue;
    lines.add(
        '$ownerName.${m.name3}  [method]  ${m.displayString2()}');
  }
  for (final g in element.getters2) {
    if (g.isPrivate || g.isSynthetic || _isExcludedFromApiSurface(g)) {
      continue;
    }
    lines.add(
        '$ownerName.${g.name3}  [getter]  ${g.displayString2()}');
  }
  for (final s in element.setters2) {
    if (s.isPrivate || s.isSynthetic || _isExcludedFromApiSurface(s)) {
      continue;
    }
    lines.add(
        '$ownerName.${s.name3}  [setter]  ${s.displayString2()}');
  }
  return lines;
}

Future<void> main(List<String> args) async {
  final surface = await computePublicApiSurface(packageRoot: Directory.current.path);
  stdout.writeln(surface);
}
