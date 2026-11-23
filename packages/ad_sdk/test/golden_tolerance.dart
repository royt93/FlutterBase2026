import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Text/shadow anti-aliasing differs between macOS and the Linux CI runner
/// (measured 0.04%-4.5% on these goldens). A real layout, colour or size
/// regression moves far more pixels than this.
void useTolerantGoldens({double tolerance = 0.06}) {
  final base = goldenFileComparator;
  if (base is! LocalFileComparator) return;
  goldenFileComparator = _TolerantComparator(
    base.basedir.resolve('x_test.dart'),
    tolerance,
  );
}

class _TolerantComparator extends LocalFileComparator {
  _TolerantComparator(super.testFile, this.tolerance);

  final double tolerance;

  @override
  Future<bool> compare(Uint8List imageBytes, Uri golden) async {
    final result = await GoldenFileComparator.compareLists(
      imageBytes,
      await getGoldenBytes(golden),
    );
    if (result.passed || result.diffPercent <= tolerance) return true;
    throw FlutterError(await generateFailureOutput(result, golden, basedir));
  }
}
