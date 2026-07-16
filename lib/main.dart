import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:webview_master_app/config/app_config.dart';
import 'package:webview_master_app/config/theme_config.dart';
import 'package:webview_master_app/screens/splash_screen.dart';
import 'package:webview_master_app/utils/prefs_util.dart';
import 'package:webview_master_app/utils/fcm_background_handler.dart';
import 'package:webview_master_app/utils/notification_service.dart';

/// Main entry point of the application
void main() async {
  // Ensure Flutter bindings are initialized
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize Firebase
  try {
    if (Platform.isIOS) {
      // On iOS, we attempt initialization with manual options as a robust fallback
      // if GoogleService-Info.plist is missing from the Xcode project targets.
      await Firebase.initializeApp(
        options: const FirebaseOptions(
          apiKey: 'AIzaSyDrv_P03d6qXlX-cWv0elS0rkH6jnR-bx4',
          appId: '1:463389493822:ios:b743566d43fc840a965f6f',
          messagingSenderId: '463389493822',
          projectId: 'rukkooin-39480',
          iosBundleId: 'com.rukkoin.partner',
        ),
      );
    } else {
      await Firebase.initializeApp();
    }
    debugPrint('✅ Firebase initialized');

    // Register background message handler
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    debugPrint('✅ Background message handler registered');
  } catch (e) {
    debugPrint('❌ Error initializing Firebase: $e');
    if (Platform.isIOS) {
      debugPrint('⚠️ Please ensure ios/Runner/GoogleService-Info.plist exists AND is added to the Xcode project targets.');
    } else {
      debugPrint('⚠️ Please ensure android/app/google-services.json is added.');
    }
  }

  // Initialize SharedPreferences
  await PrefsUtil.init();

  // Initialize Notification Service early
  // This sets up foreground notification handler (FirebaseMessaging.onMessage)
  // and handles all notification display logic
  try {
    await NotificationService().initialize();
    debugPrint('✅ Notification service initialized in main');
    debugPrint('📱 Foreground notifications: Enabled via NotificationService');
  } catch (e) {
    debugPrint('❌ Error initializing notification service in main: $e');
  }

  // Initial system UI overlay style (will be updated based on theme in each screen)
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: AppConfig.statusBarColorLight,
      statusBarIconBrightness: AppConfig.statusBarIconBrightnessLight,
      systemNavigationBarColor: AppConfig.navigationBarColorLight,
      systemNavigationBarIconBrightness:
          AppConfig.navigationBarIconBrightnessLight,
    ),
  );

  runApp(const MyApp());
}

/// Root widget of the application
class MyApp extends StatefulWidget {
  const MyApp({super.key});

    // Global navigator key for navigation without context
  static final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // Default to system theme mode
  ThemeMode _themeMode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _loadThemeMode();
  }

  /// Load saved theme mode from preferences
  void _loadThemeMode() {
    final themeModeInt = PrefsUtil.getThemeMode();
    setState(() {
      _themeMode = ThemeMode.values[themeModeInt];
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: MyApp.navigatorKey,
      debugShowCheckedModeBanner: false,
      title: AppConfig.appName,

      // Theme configuration
      theme: ThemeConfig.lightTheme,
      darkTheme: ThemeConfig.darkTheme,
      themeMode: _themeMode,

      // Home screen
      home: const SplashScreen(),

      // Builder for additional configuration
      builder: (context, child) {
        return child ?? const SizedBox.shrink();
      },
    );
  }
}
