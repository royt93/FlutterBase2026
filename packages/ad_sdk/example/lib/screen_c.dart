import 'package:flutter/material.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';

/// Demo Screen C — final screen in the demo flow, shows a banner.
class ScreenC extends AdScreen {
  const ScreenC({super.key});

  @override
  State<ScreenC> createState() => _ScreenCState();
}

class _ScreenCState extends AdScreenState<ScreenC> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Screen C — Final'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            const Expanded(
              child: Center(
                child: Text(
                  '🎉 End of demo flow',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            buildBanner(),
          ],
        ),
      ),
    );
  }
}
