import 'dart:io';

import 'package:flutter/services.dart';

/// An action the user took on a notification while the app was closed.
class NotificationAction {
  final String pane;

  /// 'key' for a keypress to send, 'text' for a typed reply.
  final String kind;
  final String value;

  const NotificationAction(this.pane, this.kind, this.value);
}

class Native {
  static const _channel = MethodChannel('herd/native');

  static bool get available => Platform.isAndroid;

  /// Called when a queued notification action is waiting.
  static void Function()? onWake;

  static void listen() {
    if (!available) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'wake') onWake?.call();
    });
  }

  static Future<void> _call(String method, [Map<String, Object?>? args]) async {
    if (!available) return;
    try {
      await _channel.invokeMethod(method, args);
    } on MissingPluginException {
      // Tests and desktop runs have no host side.
    }
  }

  /// Holds the process at foreground importance. Android freezes a backgrounded
  /// app within seconds, which stops forwards and status polling alike.
  static Future<void> startService(String text) =>
      _call('service.start', {'text': text});

  static Future<void> stopService() => _call('service.stop');

  static Future<void> notify({
    required String pane,
    required String title,
    required String text,
    List<String> keys = const [],
    bool reply = false,
  }) =>
      _call('notify', {
        'pane': pane,
        'title': title,
        'text': text,
        'keys': keys,
        'reply': reply,
      });

  static Future<void> cancel(String pane) => _call('cancel', {'pane': pane});

  /// Drains rather than receives: a tap can land before Dart is listening, so
  /// the host queues and this collects whatever accumulated.
  static Future<List<NotificationAction>> takeActions() async {
    if (!available) return const [];
    try {
      final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'takeActions',
      );
      return (raw ?? [])
          .map((m) => NotificationAction(
                m['pane'] as String,
                m['kind'] as String,
                m['value'] as String,
              ))
          .toList();
    } on MissingPluginException {
      return const [];
    }
  }
}
