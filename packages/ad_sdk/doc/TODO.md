> ⚠️ **STALE / WRONG REPO SCOPE (checked 2026-08-19).** These are feature
> ideas for the old WiFi Stressor host app (network speedometer, ping
> monitoring, WiFi comparison, etc.), not for `applovin_admob_sdk`. That app
> no longer lives in this repo — per `CLAUDE.md` it now lives in its own
> separate repo — so none of these items are actionable here. None of them
> appear in `packages/ad_sdk/CHANGELOG.md`. Kept only as historical reference;
> not a pending-work list for this package.

Dựa trên code hiện tại của WiFi Stressor, đây là các ý tưởng mở rộng:

không dùng print/debugPrint, hãy dùng class Logger
hãy dùng UIUtils.showToast, không dùng Get.snack
không dùng late, hãy dùng nullable
không dùng setState, hãy dùng GetX
không dùng force null
không bug, không memory leak
lưu ý cần có multi language đầy đủ

🔬 Advanced Testing Features

- Ping/Latency monitoring - đo độ trễ thời gian thực
- Packet loss tracking - theo dõi mất gói tin
- Upload vs Download - phân biệt tốc độ up/down
- Network Quality Score - chấm điểm A-F cho chất lượng mạng
- DNS Resolution Test - kiểm tra DNS response time
- Test Presets - 30s/1min/5min/custom duration
- Multiple Connections - test với nhiều kết nối đồng thời

📈 Visualization Enhancements

- Speedometer gauge - đồng hồ tốc độ thời gian thực
- Heatmap - bản đồ nhiệt hiệu suất theo thời gian
- Chart types - line/bar/area charts
- Comparison charts - so sánh nhiều lần test

🔔 Notifications & Alerts

- Cảnh báo khi tốc độ drop dưới ngưỡng
- Thông báo hoàn thành test
- Push notification cho connection failures

⚙️ Settings & Configuration

- Custom test parameters (packet size, interval, timeout)
- Dark/light theme
- Test server selection (multiple servers)
- Auto-test scheduling (daily/weekly)
- Data usage limits

📤 Export & Sharing

- Export CSV/JSON/PDF reports
- Share qua social media
- Generate beautiful test reports
- Compare & share with friends

📡 Network Information Dashboard

- SSID, signal strength, frequency (2.4/5GHz)
- IP address (local/public)
- Gateway/DNS info
- Connected devices count
- Router manufacturer/model

🏆 Comparison & Benchmarking

- So sánh nhiều WiFi networks
- Before/after comparisons
- Benchmark với chuẩn ISP speeds
- Leaderboard (fastest networks)
