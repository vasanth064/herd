import 'dart:io';

import 'package:flutter/services.dart';

const _channel = MethodChannel('herd/forwards');

/// Keeps the process at foreground importance while ports are forwarded.
/// Without it Android freezes the app on the way to the browser and the
/// tunnel it was opened for stops answering.
Future<void> setForwardService(List<int> ports) async {
  if (!Platform.isAndroid) return;
  try {
    if (ports.isEmpty) {
      await _channel.invokeMethod('stop');
    } else {
      await _channel.invokeMethod('start', {
        'text': ports.length == 1
            ? 'Forwarding port ${ports.single}'
            : 'Forwarding ports ${ports.join(', ')}',
      });
    }
  } on MissingPluginException {
    // Tests and desktop runs have no host side.
  }
}
