package com.example.talk_assist

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.pm.PackageManager
import android.provider.CalendarContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    private data class PendingReminderCall(
        val title: String,
        val startMillis: Long,
        val allDay: Boolean,
        val result: MethodChannel.Result
    )

    private var pendingReminderCall: PendingReminderCall? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "talk_assist/reminders"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "createReminder" -> createReminder(call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun createReminder(call: MethodCall, result: MethodChannel.Result) {
        val title = call.argument<String>("title")?.trim().orEmpty()
        if (title.isEmpty()) {
            result.error("invalid_title", "Reminder title is required.", null)
            return
        }

        val startMillis = call.argument<Long>("startMillis")
        if (startMillis == null) {
            result.error(
                "invalid_start_time",
                "A reminder date and time are required for automatic saving.",
                null
            )
            return
        }

        val allDay = call.argument<Boolean>("allDay") ?: false

        if (hasCalendarPermissions()) {
            saveReminder(title, startMillis, allDay, result)
            return
        }

        if (pendingReminderCall != null) {
            result.error(
                "request_in_progress",
                "Another reminder permission request is already in progress.",
                null
            )
            return
        }

        pendingReminderCall = PendingReminderCall(title, startMillis, allDay, result)

        requestPermissions(
            arrayOf(
                Manifest.permission.READ_CALENDAR,
                Manifest.permission.WRITE_CALENDAR
            ),
            2001
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode != 2001) {
            return
        }

        val pending = pendingReminderCall ?: return
        pendingReminderCall = null

        var granted = grantResults.isNotEmpty()
        for (status in grantResults) {
            if (status != PackageManager.PERMISSION_GRANTED) {
                granted = false
                break
            }
        }

        if (!granted) {
            pending.result.error(
                "permission_denied",
                "Calendar permission is required to save reminders automatically.",
                null
            )
            return
        }

        saveReminder(
            pending.title,
            pending.startMillis,
            pending.allDay,
            pending.result
        )
    }

    private fun hasCalendarPermissions(): Boolean {
        val readGranted = checkSelfPermission(Manifest.permission.READ_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED
        val writeGranted = checkSelfPermission(Manifest.permission.WRITE_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED
        return readGranted && writeGranted
    }

    private fun saveReminder(
        title: String,
        startMillis: Long,
        allDay: Boolean,
        result: MethodChannel.Result
    ) {
        val calendarId = resolveCalendarId()
        if (calendarId == null) {
            result.error(
                "calendar_unavailable",
                "No writable calendar was found on this device.",
                null
            )
            return
        }

        try {
            val endMillis = if (allDay) {
                startMillis + 24L * 60L * 60L * 1000L
            } else {
                startMillis + 10L * 60L * 1000L
            }

            val eventValues = ContentValues().apply {
                put(CalendarContract.Events.CALENDAR_ID, calendarId)
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.DTSTART, startMillis)
                put(CalendarContract.Events.DTEND, endMillis)
                put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
                put(CalendarContract.Events.HAS_ALARM, 1)
                if (allDay) {
                    put(CalendarContract.Events.ALL_DAY, 1)
                }
            }

            val eventUri = contentResolver.insert(
                CalendarContract.Events.CONTENT_URI,
                eventValues
            )

            if (eventUri == null) {
                result.error(
                    "save_failed",
                    "The reminder could not be written to the calendar.",
                    null
                )
                return
            }

            val eventId = ContentUris.parseId(eventUri)
            val reminderValues = ContentValues().apply {
                put(CalendarContract.Reminders.EVENT_ID, eventId)
                put(CalendarContract.Reminders.MINUTES, 0)
                put(
                    CalendarContract.Reminders.METHOD,
                    CalendarContract.Reminders.METHOD_ALERT
                )
            }

            contentResolver.insert(
                CalendarContract.Reminders.CONTENT_URI,
                reminderValues
            )

            result.success(null)
        } catch (error: SecurityException) {
            result.error(
                "permission_denied",
                error.message ?: "Calendar permission was denied.",
                null
            )
        } catch (error: Exception) {
            result.error(
                "save_failed",
                error.message ?: "The reminder could not be saved.",
                null
            )
        }
    }

    private fun resolveCalendarId(): Long? {
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.IS_PRIMARY
        )
        val selection =
            "${CalendarContract.Calendars.VISIBLE} = 1 AND " +
                "${CalendarContract.Calendars.SYNC_EVENTS} = 1"
        val sortOrder =
            "${CalendarContract.Calendars.IS_PRIMARY} DESC, " +
                "${CalendarContract.Calendars._ID} ASC"

        contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            selection,
            null,
            sortOrder
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                return cursor.getLong(0)
            }
        }

        return null
    }
}
