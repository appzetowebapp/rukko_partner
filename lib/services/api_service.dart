import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:webview_master_app/config/app_config.dart';
import 'package:webview_master_app/utils/prefs_util.dart';
import 'dart:io' show Platform;

/// API Service - Handles all API calls to the backend
class ApiService {
  static final ApiService _instance = ApiService._internal();
  factory ApiService() => _instance;
  ApiService._internal();

  /// Get the full API URL for an endpoint
  String _getApiUrl(String endpoint) {
    // Remove leading slash if present to avoid double slashes
    final cleanEndpoint =
        endpoint.startsWith('/') ? endpoint.substring(1) : endpoint;
    return '${AppConfig.apiBaseUrl}/$cleanEndpoint';
  }

  /// Save FCM token to backend
  ///
  /// [token] - The FCM token to save
  /// [phone] - Phone number (10-digit without +91)
  /// [platform] - Platform identifier (defaults to "android" for Android)
  ///
  /// Returns true if successful, false otherwise
  Future<bool> saveFCMToken({
    required String token,
    String? platform,
  }) async {
    try {
      // Determine platform if not provided
      final platformValue =
          platform ?? (Platform.isAndroid ? 'app' : 'app'); // Default to 'app' as per requirement

      // Validate token
      if (token.isEmpty) {
        debugPrint('❌ FCM token is empty');
        return false;
      }

      final url = _getApiUrl('partners/fcm-token');

      // Get access token (optional)
      String? accessToken = PrefsUtil.getAccessToken();
      
      debugPrint('📤 Saving FCM token to: $url');
     
      final requestBody = {
        'fcmToken': token,
        'platform': platformValue,
      };

      final Map<String, String> headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

      if (accessToken != null && accessToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer $accessToken';
      }

      final response = await http
          .put(
        Uri.parse(url),
        headers: headers,
        body: jsonEncode(requestBody),
      )
          .timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          debugPrint('❌ Request timeout while saving FCM token');
          throw Exception('Request timeout');
        },
      );

      debugPrint('📥 requestBody: ${requestBody}');
      debugPrint('=headers====>>${headers}');
    

      if (response.statusCode >= 200 && response.statusCode < 300) {
        debugPrint('✅ FCM token saved successfully');
        return true;
      } else {
        debugPrint(
            '❌ Failed to save FCM token. Status: ${response.statusCode}');
        debugPrint('❌ Error: ${response.body}');
        return false;
      }
    } catch (e, stackTrace) {
      debugPrint('❌ Error saving FCM token: $e');
      debugPrint('❌ Stack trace: $stackTrace');
      return false;
    }
  }

  
  /// Upload Base64 Image to Backend
  ///
  /// [base64Image] - The full base64 string including data:image/jpeg;base64,...
  /// [mimeType] - MIME type of the image (e.g., image/jpeg)
  /// [fileName] - Name of the file
  /// [endpoint] - API endpoint to upload to (defaults to auth document upload)
  Future<Map<String, dynamic>> uploadBase64Image({
    required String base64Image,
    required String mimeType, 
    required String fileName,
    String endpoint = 'auth/partner/upload-docs-base64',
  }) async {
    try {
      final url = _getApiUrl(endpoint);
      
      // Get access token
      String? accessToken = PrefsUtil.getAccessToken();
      
      debugPrint('📤 Uploading image to: $url');
      
      final requestBody = {
        'images': [
          {
            'base64': base64Image,
            'mimeType': mimeType,
            'fileName': fileName
          }
        ]
      };

      final Map<String, String> headers = {
        'Content-Type': 'application/json',
        'Accept': 'application/json',
      };

      if (accessToken != null && accessToken.isNotEmpty) {
        headers['Authorization'] = 'Bearer $accessToken';
      }

      final response = await http
          .post(
        Uri.parse(url),
        headers: headers,
        body: jsonEncode(requestBody),
      )
          .timeout(
        const Duration(seconds: 60),
        onTimeout: () {
          throw Exception('Upload timeout');
        },
      );

      debugPrint('📥 Upload Response Status: ${response.statusCode}');
      
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final responseData = jsonDecode(response.body);
        return {'success': true, 'data': responseData};
      } else {
        debugPrint('❌ Upload Failed: ${response.body}');
        return {'success': false, 'error': response.body};
      }
    } catch (e) {
      debugPrint('❌ Error uploading image: $e');
      return {'success': false, 'error': e.toString()};
    }
  }
}

