import 'package:integration_test/integration_test.dart';

import '../../test/admob_late_load_midshow_widget_test.dart' as cases;

// Device rendering and the real AdManager mutex, with injected bridge callbacks;
// this does not reproduce late delivery by the native Google Ads SDK.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  cases.main();
}
