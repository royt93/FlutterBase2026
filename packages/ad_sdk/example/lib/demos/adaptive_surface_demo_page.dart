// T124 — AdaptiveAdSurface demo. Drag the slider to change the surface's
// own width and watch it flip between banner and MREC at the 600pt
// breakpoint (after the resize debounce settles).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';

class AdaptiveSurfaceDemoPage extends StatefulWidget {
  const AdaptiveSurfaceDemoPage({super.key});

  @override
  State<AdaptiveSurfaceDemoPage> createState() =>
      _AdaptiveSurfaceDemoPageState();
}

class _AdaptiveSurfaceDemoPageState extends State<AdaptiveSurfaceDemoPage> {
  double _width = 320;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Adaptive surface demo')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Width: ${_width.round()}pt — banner below 600pt, MREC at/above.',
            ),
          ),
          Slider(
            min: 300,
            max: 800,
            value: _width,
            onChanged: (v) => setState(() => _width = v),
          ),
          Center(
            child: SizedBox(
              width: _width,
              child: const AdaptiveAdSurface(
                placement: AdPlacement.home,
                resizeDebounce: Duration(milliseconds: 200),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
