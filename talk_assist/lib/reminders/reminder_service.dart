import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'reminder_command.dart';

class ReminderLaunchResult {
  const ReminderLaunchResult({
    required this.opened,
    required this.message,
  });

  final bool opened;
  final String message;
}

class ReminderService {
  static const MethodChannel _channel = MethodChannel(
    'talk_assist/reminders',
  );

  Future<ReminderLaunchResult> createReminder(ReminderRequest request) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return const ReminderLaunchResult(
        opened: false,
        message: 'Automatic reminders are only available on Android.',
      );
    }

    try {
      await _channel.invokeMethod<void>('createReminder', <String, dynamic>{
        'title': request.title,
        if (request.startAt != null)
          'startMillis': request.startAt!.millisecondsSinceEpoch,
        'allDay': request.allDay,
      });

      return const ReminderLaunchResult(
        opened: true,
        message: 'Created the Android calendar reminder.',
      );
    } on PlatformException catch (error) {
      return ReminderLaunchResult(
        opened: false,
        message:
            error.message ?? 'Could not create the Android calendar reminder.',
      );
    } on MissingPluginException {
      return const ReminderLaunchResult(
        opened: false,
        message: 'Automatic reminders are not available on this build.',
      );
    }
  }
}