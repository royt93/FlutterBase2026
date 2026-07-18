# WiFi Stressor - Statistics & History UI/UX Design

## 🎨 Overall Structure

```
AppBar (với tab navigation)
├── "Test Now" Tab
└── "History" Tab (NEW)
    ├── Summary Stats Card
    ├── Chart Filter Bar
    ├── Visual Charts
    └── History Timeline List
```

---

## 📱 Screen 1: Enhanced Home Screen

### Changes to Current Screen:
- Add "View History" button ở top-right AppBar
- Hoặc thêm Bottom Navigation với 2 tabs: "Test" | "History"

---

## 📊 Screen 2: Statistics & History Screen

### Layout Structure:

```
┌─────────────────────────────────────┐
│  ← Statistics & History             │
│                          [Filter] 🔍│
├─────────────────────────────────────┤
│                                     │
│  📊 SUMMARY STATISTICS CARD         │
│  ┌─────────────────────────────┐   │
│  │  Total Tests: 24            │   │
│  │  ───────────────────────     │   │
│  │  🏆 Best Speed              │   │
│  │     125.3 Mbps              │   │
│  │     Dec 28, 2025 14:32      │   │
│  │                              │   │
│  │  📈 Avg Speed: 98.5 Mbps    │   │
│  │  📉 Min Speed: 45.2 Mbps    │   │
│  │  ⏱️  Avg Duration: 2m 15s    │   │
│  │  ✅ Success Rate: 95.8%     │   │
│  └─────────────────────────────┘   │
│                                     │
│  📈 CHART SECTION                   │
│  ┌─────────────────────────────┐   │
│  │ [Day][Week][Month][All] <── │   │
│  │                              │   │
│  │    📊 Line Chart             │   │
│  │    Speeds over time          │   │
│  │         130 ╱╲               │   │
│  │         100 ╱  ╲╱╲           │   │
│  │          70 ╱      ╲         │   │
│  │             Mon  Tue  Wed    │   │
│  └─────────────────────────────┘   │
│                                     │
│  📜 HISTORY TIMELINE                │
│  ┌─────────────────────────────┐   │
│  │ Today                        │   │
│  ├─────────────────────────────┤   │
│  │ 🟢 Test #24                 ↗│   │
│  │ 98.5 Mbps • 2m 30s          │   │
│  │ 14:32 PM                    │   │
│  ├─────────────────────────────┤   │
│  │ 🟢 Test #23                 ↗│   │
│  │ 105.2 Mbps • 1m 45s         │   │
│  │ 10:15 AM                    │   │
│  ├─────────────────────────────┤   │
│  │ Yesterday                    │   │
│  ├─────────────────────────────┤   │
│  │ 🟡 Test #22                 ↗│   │
│  │ 67.3 Mbps • 3m 12s          │   │
│  │ 18:45 PM                    │   │
│  ├─────────────────────────────┤   │
│  │ 🔴 Test #21 (Failed)        ↗│   │
│  │ Connection Lost • 0m 45s    │   │
│  │ 14:20 PM                    │   │
│  └─────────────────────────────┘   │
│                                     │
│  [Export Data] [Clear History]     │
└─────────────────────────────────────┘
```

---

## 📊 Screen 3: Test Detail Screen

Khi tap vào một test item:

```
┌─────────────────────────────────────┐
│  ← Test #24 Details                 │
├─────────────────────────────────────┤
│                                     │
│  📊 PERFORMANCE CARD                │
│  ┌─────────────────────────────┐   │
│  │  Average Speed              │   │
│  │  98.5 Mbps                  │   │
│  │  ──────────────────         │   │
│  │  Peak: 125.3 Mbps           │   │
│  │  Min:  45.7 Mbps            │   │
│  │  Median: 92.1 Mbps          │   │
│  └─────────────────────────────┘   │
│                                     │
│  ⏱️  TEST INFO                      │
│  ┌─────────────────────────────┐   │
│  │  Started: 14:32:15          │   │
│  │  Ended:   14:34:45          │   │
│  │  Duration: 2m 30s           │   │
│  │  Status: ✅ Completed       │   │
│  └─────────────────────────────┘   │
│                                     │
│  📡 NETWORK INFO                    │
│  ┌─────────────────────────────┐   │
│  │  SSID: HomeWiFi_5G          │   │
│  │  Signal: -45 dBm (Excellent)│   │
│  │  Frequency: 5 GHz           │   │
│  │  Channel: 44                │   │
│  │  IP: 192.168.1.105          │   │
│  └─────────────────────────────┘   │
│                                     │
│  📈 SPEED OVER TIME CHART           │
│  ┌─────────────────────────────┐   │
│  │  [Full chart from test]     │   │
│  │                              │   │
│  │  125╱╲                       │   │
│  │  100╱  ╲╱╲                   │   │
│  │   75╱      ╲                 │   │
│  │   50                         │   │
│  │     0s  30s  60s  90s 120s  │   │
│  └─────────────────────────────┘   │
│                                     │
│  [Share] [Delete] [Retest]         │
└─────────────────────────────────────┘
```

---

## 🎨 UI Components Breakdown

### 1. **Summary Stats Card**
```dart
Container(
  decoration: BoxDecoration(
    gradient: LinearGradient(
      colors: [Color(0xFF1E3A8A), Color(0xFF3B82F6)],
    ),
    borderRadius: BorderRadius.circular(16),
    boxShadow: [...],
  ),
  child: Column(
    children: [
      // Trophy icon + Best Speed
      // Grid của các metrics (2x2)
      GridView(
        children: [
          StatMetric(label: "Avg Speed", value: "98.5 Mbps"),
          StatMetric(label: "Min Speed", value: "45.2 Mbps"),
          StatMetric(label: "Avg Duration", value: "2m 15s"),
          StatMetric(label: "Success Rate", value: "95.8%"),
        ],
      ),
    ],
  ),
)
```

### 2. **Chart Section**
```dart
Column(
  children: [
    // Time Range Selector
    SegmentedButton(
      segments: [
        ButtonSegment(value: 'day', label: Text('Day')),
        ButtonSegment(value: 'week', label: Text('Week')),
        ButtonSegment(value: 'month', label: Text('Month')),
        ButtonSegment(value: 'all', label: Text('All')),
      ],
    ),
    // Line Chart (fl_chart package)
    LineChart(
      LineChartData(
        // Speed data points over time
      ),
    ),
  ],
)
```

### 3. **Timeline List Item**
```dart
Card(
  child: ListTile(
    leading: CircleAvatar(
      backgroundColor: _getStatusColor(), // 🟢🟡🔴
      child: Text('#24'),
    ),
    title: Text('98.5 Mbps'),
    subtitle: Text('2m 30s • 14:32 PM'),
    trailing: Icon(Icons.arrow_forward_ios),
    onTap: () => navigateToDetail(),
  ),
)
```

### 4. **Status Color Coding**
- 🟢 Green: > 80 Mbps (Excellent)
- 🟡 Yellow: 40-80 Mbps (Good)
- 🔴 Red: < 40 Mbps or Failed

---

## 📦 Data Model

```dart
class TestResult {
  final String id;
  final DateTime startTime;
  final DateTime endTime;
  final double avgSpeed;
  final double peakSpeed;
  final double minSpeed;
  final double medianSpeed;
  final List<double> speedHistory;
  final String status; // 'completed', 'failed'
  final NetworkInfo networkInfo;

  Duration get duration => endTime.difference(startTime);
}

class NetworkInfo {
  final String ssid;
  final int signalStrength; // dBm
  final String frequency; // '2.4 GHz' or '5 GHz'
  final String ipAddress;
  final int channel;
}

class TestStatistics {
  final int totalTests;
  final TestResult bestTest;
  final double avgSpeed;
  final double minSpeed;
  final Duration avgDuration;
  final double successRate;
}
```

---

## 🔄 User Flow

```
Home Screen
    │
    ├─→ Run Test
    │       │
    │       └─→ Auto save to History
    │
    └─→ Tap "History" Icon
            │
            ├─→ View Summary Stats
            ├─→ View Charts (Day/Week/Month)
            ├─→ Scroll Timeline
            │       │
            │       └─→ Tap Item → Detail Screen
            │                   │
            │                   ├─→ View Full Stats
            │                   ├─→ Share
            │                   ├─→ Delete
            │                   └─→ Retest
            │
            └─→ Export/Clear Data
```

---

## 🎯 Filter Options

### Filter Dialog:
```
┌─────────────────────────┐
│  Filter Tests           │
├─────────────────────────┤
│  Date Range             │
│  [Start] ─→ [End]       │
│                         │
│  Speed Range            │
│  [0] ════●═══ [200] Mbps│
│                         │
│  Status                 │
│  ☑ Completed            │
│  ☑ Failed               │
│                         │
│  Network                │
│  ☑ HomeWiFi_5G          │
│  ☑ Office_WiFi          │
│                         │
│  [Reset]  [Apply]       │
└─────────────────────────┘
```

---

## 🎨 Color Scheme

### Dark Theme:
- Background: `#0F172A` (slate-900)
- Cards: `#1E293B` (slate-800)
- Primary: `#3B82F6` (blue-500)
- Success: `#10B981` (green-500)
- Warning: `#F59E0B` (amber-500)
- Error: `#EF4444` (red-500)
- Text: `#F1F5F9` (slate-100)

### Gradients:
- Stats Card: `[#1E3A8A → #3B82F6]`
- Chart Background: `[#0F172A → #1E293B]`

---

## 📊 Charts & Visualizations

### Chart Types to Implement:
1. **Line Chart** - Speed over time (main)
2. **Bar Chart** - Comparison between tests
3. **Gauge Chart** - Current speed indicator
4. **Pie Chart** - Success vs Failed ratio

### Package Recommendation:
- `fl_chart` - Best performance for Flutter charts
- `syncfusion_flutter_charts` - More professional (có license)

---

## ⚡ Performance Optimizations

1. **Lazy Loading**: Load 20 items at a time trong timeline
2. **Pagination**: Infinite scroll với lazy load
3. **Chart Data Sampling**: Nếu > 1000 data points, sample xuống
4. **Image Caching**: Cache charts as images
5. **Database Indexing**: Index by date, speed for faster queries

---

## 🚀 Implementation Priority

### Phase 1 (MVP):
- [ ] Data model & Hive storage
- [ ] Basic history list
- [ ] Summary statistics card
- [ ] Simple line chart

### Phase 2:
- [ ] Detail screen
- [ ] Time range filters
- [ ] Export functionality
- [ ] Delete/Clear options

### Phase 3:
- [ ] Advanced charts
- [ ] Comparison features
- [ ] Search & advanced filters
- [ ] Share functionality

---

## 📝 Notes

- Sử dụng `Hive` thay vì `SharedPreferences` vì có thể lưu complex objects
- Implement pagination để avoid memory issues với large datasets
- Add confirmation dialog trước khi clear history
- Auto-cleanup old data (keep last 100 tests hoặc 30 days)
- Consider background sync nếu user có multi-device

---

Bạn muốn tôi bắt đầu implement từ Phase nào? Hoặc cần mockup chi tiết hơn cho screen nào?
