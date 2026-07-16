import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_master_app/config/app_config.dart';
import 'package:webview_master_app/utils/permission_handler_util.dart';

import 'package:webview_master_app/screens/webview_screen.dart';

/// Splash Screen - Shows full screen splash GIF for configured duration
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    _navigateAfterDelay();
  }

  Future<void> _navigateAfterDelay() async {
    // Total duration for show the splash GIF
    await Future.delayed(
      const Duration(seconds: AppConfig.splashDurationSeconds),
    );

    if (!mounted) return;

    // Request permissions early for better UX
    await _requestInitialPermissions();

    // Navigate directly to WebViewScreen
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) =>
            const WebViewScreen(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
        transitionDuration: const Duration(milliseconds: 800),
      ),
    );
  }

  /// Request initial permissions during splash
  Future<void> _requestInitialPermissions() async {
    if (!mounted) return;
    try {
      await PermissionHandlerUtil.requestAllPermissions();
    } catch (e) {
      debugPrint('Initial permission request: $e');
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Set system UI to immersive/transparent with light content
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light, // Light icons for dark bg
        statusBarBrightness: Brightness.dark, // for iOS
        systemNavigationBarColor: Color(0xFF1A1F4D), // Dark nav bar
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    return Scaffold(
      backgroundColor: Colors.white, // Background color while GIF loads
      body: SizedBox.expand(
        child: Image.asset(
          AppConfig.splashGifPath,
          fit: BoxFit.cover,
        ),
      ),

      
    );
  }
}
