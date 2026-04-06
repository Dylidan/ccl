class ReminderCommandParseResult {
  const ReminderCommandParseResult._({
    required this.isReminderCommand,
    this.request,
    this.errorMessage,
  });

  const ReminderCommandParseResult.notReminder()
    : this._(isReminderCommand: false);

  const ReminderCommandParseResult.success(ReminderRequest request)
    : this._(isReminderCommand: true, request: request);

  const ReminderCommandParseResult.error(String message)
    : this._(isReminderCommand: true, errorMessage: message);

  final bool isReminderCommand;
  final ReminderRequest? request;
  final String? errorMessage;
}

class ReminderRequest {
  const ReminderRequest({
    required this.title,
    this.startAt,
    this.allDay = false,
  });

  final String title;
  final DateTime? startAt;
  final bool allDay;

  static ReminderCommandParseResult parse(String rawInput) {
    final trimmed = rawInput.trim();
    if (!trimmed.toLowerCase().startsWith("/reminder")) {
      return const ReminderCommandParseResult.notReminder();
    }

    final body = trimmed.substring("/reminder".length).trim();
    if (body.isEmpty) {
      return const ReminderCommandParseResult.error(
        "Use /reminder Title | YYYY-MM-DD HH:MM",
      );
    }

    final separatorIndex = body.indexOf("|");
    if (separatorIndex == -1) {
      return const ReminderCommandParseResult.error(
        "Automatic reminders need a date/time. Use /reminder Title | YYYY-MM-DD HH:MM",
      );
    }

    final title = body.substring(0, separatorIndex).trim();
    final whenText = body.substring(separatorIndex + 1).trim();

    if (title.isEmpty) {
      return const ReminderCommandParseResult.error(
        "Reminder title is missing. Use /reminder Title | YYYY-MM-DD HH:MM",
      );
    }

    if (whenText.isEmpty) {
      return const ReminderCommandParseResult.error(
        "Reminder time is missing. Use /reminder Title | YYYY-MM-DD HH:MM",
      );
    }

    final parsedDate = _parseDateTime(whenText);
    if (parsedDate == null) {
      return const ReminderCommandParseResult.error(
        "I could not parse that time. Use YYYY-MM-DD or YYYY-MM-DD HH:MM",
      );
    }

    return ReminderCommandParseResult.success(
      ReminderRequest(
        title: title,
        startAt: parsedDate.dateTime,
        allDay: parsedDate.allDay,
      ),
    );
  }
}

class _ParsedReminderDate {
  const _ParsedReminderDate({
    required this.dateTime,
    required this.allDay,
  });

  final DateTime dateTime;
  final bool allDay;
}

_ParsedReminderDate? _parseDateTime(String input) {
  final normalized = input.trim();

  final dateOnlyPattern = RegExp(r"^\d{4}-\d{2}-\d{2}$");
  if (dateOnlyPattern.hasMatch(normalized)) {
    final parsed = DateTime.tryParse("${normalized}T09:00:00");
    if (parsed == null) {
      return null;
    }
    return _ParsedReminderDate(dateTime: parsed, allDay: false);
  }

  final dateTimePattern = RegExp(r"^\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}$");
  if (dateTimePattern.hasMatch(normalized)) {
    final parsed = DateTime.tryParse(normalized.replaceFirst(" ", "T"));
    if (parsed == null) {
      return null;
    }
    return _ParsedReminderDate(dateTime: parsed, allDay: false);
  }

  final parsed = DateTime.tryParse(normalized);
  if (parsed == null) {
    return null;
  }
  return _ParsedReminderDate(dateTime: parsed, allDay: false);
}