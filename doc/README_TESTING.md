# 🧪 TESTING GUIDE - WiFi Stressor App

> ⚠️ **OUTDATED / ASPIRATIONAL.** The `test/unit`, `test/widget`, `test/integration`
> layout, `make coverage` and Codecov steps described below **do not exist** in
> this repo. The host app has no `test/` directory. The real automated tests
> (201 unit/widget/integration tests across 21 files) live in
> **`packages/ad_sdk/test/`** — run them with `cd packages/ad_sdk && flutter test`.
> CI (`.github/workflows/test.yml`) runs exactly that. This file is kept only as a
> future plan for host-app tests.
>
> The newest file, `ad_manager_core_test.dart`, drives the orchestrator through
> its `@visibleForTesting` seams (`debugSetAdapter` / `debugVipManager` /
> `debugEmit` / `releaseFootgunWarnings`) so VIP gating, the release footgun
> guards, and the `RevenuePanel` event consumer are covered without the native
> AppLovin/AdMob plugins.

## 📋 Tổng quan

Comprehensive testing suite cho WiFi Stressor App bao gồm:
- **Unit Tests**: Test logic và business rules
- **Widget Tests**: Test UI components và interactions
- **Integration Tests**: Test toàn bộ user flows
- **Performance Tests**: Test hiệu suất và memory usage

## 🗂️ Cấu trúc Test

```
test/
├── unit/                          # Unit tests
│   ├── stressor_controller_test.dart    # Test StressorController
│   └── admob_manager_test.dart          # Test AdMob functionality
├── widget/                        # Widget tests
│   └── wifi_stressor_screen_test.dart   # Test UI components
├── integration/                   # Integration tests
│   └── app_integration_test.dart        # Test complete flows
├── test_utils.dart               # Test utilities và helpers
└── test_driver/                  # Integration test driver
    └── integration_test.dart
```

## 🚀 Chạy Tests

### Prerequisites
```bash
# Install dependencies
flutter pub get

# Generate mocks
flutter packages pub run build_runner build --delete-conflicting-outputs
```

### Unit Tests
```bash
# Chạy tất cả unit tests
flutter test test/unit/

# Chạy specific test file
flutter test test/unit/stressor_controller_test.dart

# Chạy với coverage
flutter test test/unit/ --coverage
```

### Widget Tests
```bash
# Chạy tất cả widget tests
flutter test test/widget/

# Chạy với verbose output
flutter test test/widget/ --reporter=expanded
```

### Integration Tests
```bash
# Chạy integration tests
flutter test test/integration/

# Chạy trên device/emulator
flutter drive \
  --driver=test_driver/integration_test.dart \
  --target=test/integration/app_integration_test.dart
```

### Test Coverage
```bash
# Generate coverage report
flutter test --coverage
genhtml coverage/lcov.info -o coverage/html

# View coverage report
open coverage/html/index.html
```

## 🛠️ Makefile Commands

```bash
# Install dependencies và setup
make install-deps

# Chạy tất cả tests
make test

# Chạy specific test types
make test-unit
make test-widget
make test-integration

# Generate coverage
make coverage

# Quality checks
make quality-check

# Quick development tests
make quick-test
```

## 📊 Test Coverage Targets

| Component | Target Coverage | Current |
|-----------|----------------|---------|
| StressorController | 90%+ | ✅ |
| UI Components | 85%+ | ✅ |
| AdMob Integration | 80%+ | ✅ |
| Overall Project | 80%+ | ✅ |

## 🧪 Test Categories

### 1. Unit Tests

#### StressorController Tests
- ✅ Initialization và default values
- ✅ Start/stop stress test functionality
- ✅ Speed history management
- ✅ Total speed calculations
- ✅ Throttling mechanism
- ✅ Memory management

#### AdMob Manager Tests
- ✅ Singleton pattern
- ✅ Ad Unit ID handling
- ✅ Timing controls (15-minute cooldown)
- ✅ Event Bus functionality
- ✅ Connection checking
- ✅ Error handling

### 2. Widget Tests

#### WiFiStressorApp Tests
- ✅ Widget rendering
- ✅ AppBar display
- ✅ State transitions (idle ↔ running)
- ✅ Button interactions
- ✅ Dropdown functionality
- ✅ Info dialog
- ✅ Metrics display
- ✅ Chart rendering
- ✅ Responsive design

#### SpeedChart Tests
- ✅ Data visualization
- ✅ Empty state handling
- ✅ Max speed calculations
- ✅ Performance optimizations

### 3. Integration Tests

#### Complete User Flows
- ✅ App launch và navigation
- ✅ Stress test lifecycle
- ✅ Settings configuration
- ✅ AdMob integration
- ✅ Performance under load
- ✅ Back navigation
- ✅ App lifecycle management

#### Edge Cases
- ✅ No internet connection
- ✅ Memory pressure
- ✅ Background/foreground transitions

## 🔧 Test Utilities

### TestUtils Class
```dart
// Setup GetX cho testing
TestUtils.setupGetX();

// Tạo test app wrapper
Widget testApp = TestUtils.createTestApp(child: MyWidget());

// Wait for condition với timeout
await TestUtils.waitForCondition(tester, () => condition);

// Generate test data
List<double> speeds = TestUtils.generateSpeedData(count: 10);
```

### Custom Matchers
```dart
// Validate speed values
expect(speedValue, CustomMatchers.isValidSpeed);

// Validate download counts
expect(downloadCount, CustomMatchers.isValidDownloadCount);
```

## 🏗️ CI/CD Integration

### GitHub Actions Workflow
- ✅ **Test Job**: Unit và Widget tests với coverage
- ✅ **Quality Job**: Static analysis và formatting
- ✅ **Integration Job**: Android emulator tests
- ✅ **Build Job**: APK và Web builds
- ✅ **Performance Job**: Memory và size analysis

### Coverage Reporting
- **Codecov integration** cho coverage tracking
- **HTML reports** cho local development
- **LCOV format** cho CI/CD tools

## 📈 Performance Testing

### Memory Usage Tests
```bash
# Check memory leaks
flutter test test/unit/ --reporter=github

# Analyze build size
flutter build apk --analyze-size
```

### Load Testing
- Test với 500 parallel connections
- Monitor memory usage during stress tests
- Verify UI responsiveness under load

## 🐛 Debugging Tests

### Test Failures
```bash
# Run với verbose output
flutter test --reporter=expanded

# Debug specific test
flutter test test/unit/stressor_controller_test.dart --plain-name="specific test name"
```

### Mock Debugging
```dart
// Verify mock calls
verify(mockController.startStressTest()).called(1);

// Check mock state
when(mockController.isRunning).thenReturn(true.obs);
```

## 📋 Test Checklist

### Before Release
- [ ] Tất cả unit tests pass
- [ ] Widget tests cover UI flows
- [ ] Integration tests pass trên devices
- [ ] Coverage ≥ 80%
- [ ] No memory leaks
- [ ] Performance tests pass
- [ ] Static analysis clean
- [ ] Code formatted

### Continuous Monitoring
- [ ] CI/CD pipeline green
- [ ] Coverage reports updated
- [ ] Performance metrics stable
- [ ] No flaky tests

## 🚨 Common Issues & Solutions

### Test Timeout Issues
```dart
// Increase timeout cho slow operations
await tester.pumpAndSettle(Duration(seconds: 10));
```

### GetX State Issues
```dart
// Proper cleanup
setUp(() => Get.testMode = true);
tearDown(() => Get.reset());
```

### Mock Generation Issues
```bash
# Regenerate mocks
flutter packages pub run build_runner build --delete-conflicting-outputs
```

## 📚 Best Practices

1. **Test Organization**: Group related tests together
2. **Descriptive Names**: Test names should explain what they verify
3. **Setup/Teardown**: Proper initialization và cleanup
4. **Mock Strategy**: Mock external dependencies only
5. **Performance**: Avoid slow tests in unit test suite
6. **Maintainability**: Keep tests simple và focused
7. **Coverage**: Aim for meaningful coverage, not just numbers

## 🔄 Maintenance

### Weekly Tasks
- Review test coverage reports
- Update deprecated test methods
- Check for flaky tests

### Monthly Tasks
- Update test dependencies
- Review test performance
- Analyze coverage trends
- Update CI/CD pipeline if needed

---

**⚡ Happy Testing! Chất lượng code = Chất lượng app** 🚀