import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:webview_master_app/config/app_config.dart';

/// Background message handler for Firebase Cloud Messaging
/// This must be a top-level function
/// Handles notifications when app is in background or terminated state
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('📨 Background message received: ${message.messageId}');
  debugPrint('📨 Message data: ${message.data}');

  // Initialize notification plugin for background messages
  final FlutterLocalNotificationsPlugin notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // Use AppConfig for consistency
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings(AppConfig.notificationIcon);

  const DarwinInitializationSettings iosSettings = DarwinInitializationSettings(
    requestAlertPermission: true,
    requestBadgePermission: true,
    requestSoundPermission: true,
  );

  const InitializationSettings initSettings = InitializationSettings(
    android: androidSettings,
    iOS: iosSettings,
  );

  await notificationsPlugin.initialize(initSettings);

  // Create notification channel for Android using AppConfig
  final AndroidNotificationChannel channel = AndroidNotificationChannel(
    AppConfig.notificationChannelId,
    AppConfig.notificationChannelName,
    description: AppConfig.notificationChannelDescription,
    importance: Importance.high,
    playSound: true,
    enableVibration: true,
    showBadge: true,
    enableLights: true,
    ledColor: AppConfig.notificationColor,
  );

  await notificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  RemoteNotification? notification = message.notification;
  Map<String, dynamic>? data = message.data;

  // Create unique ID for this notification
  final String notificationId = message.messageId ??
      '${message.sentTime?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch}';

  debugPrint('📨 Background notification ID: $notificationId');

  // Handle notification payload (when app is in background/terminated)
  if (notification != null) {
    // When a notification payload is present, the OS (Android/iOS) automatically
    // displays a system notification while the app is in the background.
    // Manually showing a local notification here would cause a duplicate.
    debugPrint('✅ Background notification received: ${notification.title}');
    debugPrint('⚠️ Not displaying manual notification to prevent duplicates.');
  } else if (data.isNotEmpty) {
    // Handle data-only messages (messages without notification payload)
    debugPrint('📨 Data-only message received in background');
    final title = data['title']?.toString() ?? 'Notification';
    final body = data['body']?.toString() ?? data['message']?.toString() ?? '';

    // Android notification details using AppConfig
    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      AppConfig.notificationChannelId,
      AppConfig.notificationChannelName,
      channelDescription: AppConfig.notificationChannelDescription,
      importance: Importance.high,
      priority: Priority.high,
      playSound: true,
      enableVibration: true,
      icon: AppConfig.notificationIcon,
      showWhen: true,
      styleInformation: const BigTextStyleInformation(''),
      color: AppConfig.notificationColor,
    );

    // iOS notification details
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    final NotificationDetails notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    // Generate notification ID from data
    final int localNotificationId = notificationId.hashCode.abs() % 2147483647;

    await notificationsPlugin.show(
      localNotificationId,
      title,
      body,
      notificationDetails,
      payload: data.toString(),
    );

    debugPrint(
        '✅ Background data-only notification shown: $title (ID: $localNotificationId)');
  }
}
