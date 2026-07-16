import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'package:webview_master_app/config/app_config.dart';
import 'package:mime/mime.dart';
import 'package:webview_master_app/utils/permission_handler_util.dart';
import 'package:webview_master_app/utils/connectivity_util.dart';
import 'package:webview_master_app/utils/status_bar_util.dart';
import 'package:webview_master_app/utils/notification_service.dart';
import 'package:webview_master_app/utils/prefs_util.dart';
import 'package:webview_master_app/utils/download_service.dart';
import 'package:webview_master_app/widgets/offline_screen.dart';
import 'package:webview_master_app/widgets/exit_dialog.dart';
import 'package:webview_master_app/services/api_service.dart';

/// WebView Screen - Main screen that loads the configured web URL
class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  InAppWebViewController? _webViewController;
  bool _isLoading = true;
  double _loadingProgress = 0.0;

  bool _isOnline = true;
  bool _phoneListenerInjected = false;
  bool _linkInterceptorInjected = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  // Track pending download requests from API calls
  final Map<String, Map<String, dynamic>> _pendingDownloadRequests = {};

  // Track API request bodies captured from JavaScript
  final Map<String, String> _apiRequestBodies = {};

  final ImagePicker _picker = ImagePicker();

  // Pull to refresh controller
  late final PullToRefreshController _pullToRefreshController;

  @override
  void initState() {
    super.initState();
    // Initialize pull-to-refresh controller
    _pullToRefreshController = PullToRefreshController(
      settings: PullToRefreshSettings(color: AppConfig.primaryColor),
      onRefresh: () async {
        if (_webViewController != null) {
          await _webViewController!.loadUrl(
            urlRequest: URLRequest(url: WebUri(AppConfig.webUrl)),
          );
        }
      },
    );
    _checkConnectivity();
    _initializeNotifications();
    _listenToConnectivityChanges();
  }

  Future<void> _handleBackNavigation() async {
    if (_webViewController != null) {
      final canGoBack = await _webViewController!.canGoBack();
      if (canGoBack) {
        _webViewController!.goBack();
        return;
      }
    }

    // Show exit confirmation dialog using centralized widget
    if (!mounted) return;

    final shouldExit = await ExitDialog.show(context);
    if (shouldExit == true) {
      SystemNavigator.pop();
    }
  }

  /// Initialize notification service
  Future<void> _initializeNotifications() async {
    try {
      await NotificationService().initialize();
      await NotificationService().requestPermission();
      debugPrint('✅ Notification service ready');
      await _saveFCMToken();
    } catch (e) {
      debugPrint('❌ Error initializing notifications: $e');
    }
  }

  /// Save FCM token to backend
  Future<void> _saveFCMToken() async {
    try {
      debugPrint('Saving FCM token to backend...');
      final success = await NotificationService().saveFCMTokenToBackend();
      if (success) {
        debugPrint('✅ FCM token saved successfully');
      } else {
        debugPrint('⚠️ Failed to save FCM token');
      }
    } catch (e) {
      debugPrint('❌ Error saving FCM token: $e');
    }
  }

  /// Handle blob URL download by extracting blob data via JavaScript
  Future<void> _handleBlobDownload({
    required InAppWebViewController controller,
    required String blobUrl,
    String? suggestedFilename,
    String? mimeType,
    bool isReceiptDownload = false,
  }) async {
    if (!mounted) return;

    final downloadService = DownloadService();

    try {
      debugPrint('🔵 Extracting blob data from: $blobUrl');

      // Create a completer to wait for JavaScript callback
      final completer = Completer<Map<String, dynamic>>();
      final handlerName =
          'blobDownloadHandler_${DateTime.now().millisecondsSinceEpoch}';

      // Add JavaScript handler to receive blob data
      controller.addJavaScriptHandler(
        handlerName: handlerName,
        callback: (args) {
          if (args.isNotEmpty) {
            try {
              final result =
                  jsonDecode(args[0].toString()) as Map<String, dynamic>;
              if (!completer.isCompleted) {
                completer.complete(result);
              }
            } catch (e) {
              debugPrint('❌ Error parsing blob data: $e');
              if (!completer.isCompleted) {
                completer.completeError(e);
              }
            }
          } else {
            if (!completer.isCompleted) {
              completer
                  .completeError(Exception('No data received from JavaScript'));
            }
          }
        },
      );

      // Execute JavaScript to extract blob
      final blobDataScript = '''
        (function() {
          try {
            var handlerName = '$handlerName';
            var blobUrl = '$blobUrl';
            var mimeType = '${mimeType ?? 'application/pdf'}';

            function sendResult(success, data, error, mime, size) {
              try {
                if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                  window.flutter_inappwebview.callHandler(handlerName, JSON.stringify({
                    success: success,
                    data: data || null,
                    error: error || null,
                    mimeType: mime || mimeType,
                    size: size || 0
                  }));
                } else {
                  console.error('Flutter handler not available');
                }
              } catch (e) {
                console.error('Error sending result:', e);
              }
            }

            function extractBlob() {
              try {
                var xhr = new XMLHttpRequest();
                xhr.open('GET', blobUrl, true);
                xhr.responseType = 'blob';

                xhr.onload = function() {
                  try {
                    if (xhr.status === 200 || xhr.status === 0) {
                      var blob = xhr.response;
                      if (!blob || blob.size === 0) {
                        sendResult(false, null, 'Blob is empty or null', mimeType, 0);
                        return;
                      }
                      var reader = new FileReader();
                      reader.onloadend = function() {
                        try {
                          sendResult(true, reader.result, null, blob.type || mimeType, blob.size);
                        } catch (e) {
                          sendResult(false, null, 'Error in onloadend: ' + (e.message || e.toString()), mimeType, 0);
                        }
                      };
                      reader.onerror = function() {
                        sendResult(false, null, 'Failed to read blob data', mimeType, 0);
                      };
                      reader.readAsDataURL(blob);
                    } else {
                      sendResult(false, null, 'HTTP error: ' + xhr.status, mimeType, 0);
                    }
                  } catch (e) {
                    sendResult(false, null, 'Error in onload: ' + (e.message || e.toString()), mimeType, 0);
                  }
                };

                xhr.onerror = function() {
                  sendResult(false, null, 'Network error loading blob', mimeType, 0);
                };

                xhr.ontimeout = function() {
                  sendResult(false, null, 'Timeout loading blob', mimeType, 0);
                };

                xhr.timeout = 30000;
                xhr.send();
              } catch (error) {
                sendResult(false, null, error.message || 'Unknown error', mimeType, 0);
              }
            }

            extractBlob();
          } catch (e) {
            console.error('Error in blob extraction script:', e);
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('$handlerName', JSON.stringify({
                success: false,
                error: 'Script error: ' + (e.message || e.toString())
              }));
            }
          }
        })();
      ''';

      await controller.evaluateJavascript(source: blobDataScript);

      // Wait for JavaScript callback (with timeout)
      final resultMap = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw Exception('Timeout waiting for blob data');
        },
      );

      if (resultMap['success'] != true) {
        throw Exception(resultMap['error'] ?? 'Failed to extract blob data');
      }

      final base64Data = resultMap['data'] as String;
      final blobMimeType =
          resultMap['mimeType'] as String? ?? mimeType ?? 'application/pdf';

      // Extract base64 data (remove data URL prefix)
      final base64Content =
          base64Data.contains(',') ? base64Data.split(',')[1] : base64Data;

      // Determine filename
      String filename = suggestedFilename ?? 'receipt.pdf';
      if (!filename.contains('.')) {
        // Add extension based on MIME type
        if (blobMimeType.contains('pdf')) {
          filename = '$filename.pdf';
        } else if (blobMimeType.contains('image')) {
          filename = '$filename.png';
        }
      }

      // Get download directory (try public Downloads for receipts, fallback to app-specific)
      bool hasPermission = false;
      if (isReceiptDownload) {
        hasPermission = await PermissionHandlerUtil.checkStoragePermission();
        if (!hasPermission) {
          hasPermission =
              await PermissionHandlerUtil.requestStoragePermission();
        }
      }

      Directory downloadDir;
      if (isReceiptDownload && hasPermission) {
        downloadDir = await downloadService.getDownloadDirectory(
            usePublicDownloads: true);
      } else {
        downloadDir = await downloadService.getDownloadDirectory(
            usePublicDownloads: false);
      }

      final filePath = '${downloadDir.path}/$filename';
      debugPrint('💾 Saving blob to: $filePath');

      // Decode base64 and save to file
      final bytes = base64Decode(base64Content);
      final file = File(filePath);
      await file.writeAsBytes(bytes);

      // For Android, try to add file to MediaStore to make it visible in Downloads
      if (Platform.isAndroid && isReceiptDownload) {
        try {
          final downloadService = DownloadService();
          await downloadService.addFileToMediaStore(
              filePath, filename, blobMimeType);
        } catch (e) {
          debugPrint('⚠️ Could not add file to MediaStore: $e');
        }
      }

      if (!mounted) return;

      // Show success message
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.check_circle, color: Colors.white),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isReceiptDownload
                          ? 'Receipt saved to Downloads'
                          : 'File saved to Downloads',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                filename,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'OPEN',
            textColor: Colors.white,
            onPressed: () async {
              await downloadService.openFile(filePath);
            },
          ),
        ),
      );
      debugPrint('✅ Blob download successful: $filePath');
    } catch (e) {
      debugPrint('❌ Error downloading blob: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Download failed: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _injectPhoneCaptureScript(
      InAppWebViewController controller) async {
    if (_phoneListenerInjected) {
      return;
    }
    try {
      const script = r"""
        (function() {
          if (window.__phoneCaptureInstalled) {
            return;
          }
          window.__phoneCaptureInstalled = true;

          function callFlutter(phoneValue) {
            if (!phoneValue) {
              return;
            }
            var phone = String(phoneValue).trim();
            if (!phone) {
              return;
            }

            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler('savePhoneNumber', phone);
            } else if (window.webkit
              && window.webkit.messageHandlers
              && window.webkit.messageHandlers.savePhoneNumber
              && window.webkit.messageHandlers.savePhoneNumber.postMessage) {
              window.webkit.messageHandlers.savePhoneNumber.postMessage(phone);
            }
          }

          function attachToInput(input) {
            if (!input || input.__phoneListenerAttached) {
              return;
            }
            input.__phoneListenerAttached = true;

            var notify = function() {
              callFlutter(input.value);
            };

            input.addEventListener('change', notify);
            input.addEventListener('blur', notify);
            input.addEventListener('keyup', function() {
              var digits = (input.value || '').replace(/\D/g, '');
              if (digits.length >= 10) {
                callFlutter(input.value);
              }
            });
          }

          function attachToForms() {
            document.querySelectorAll('form').forEach(function(form) {
              if (form.__phoneSubmitAttached) {
                return;
              }
              form.__phoneSubmitAttached = true;
              form.addEventListener('submit', function() {
                var formData = new FormData(form);
                var phone = formData.get('phone')
                  || formData.get('mobile')
                  || formData.get('phone_number')
                  || '';
                if (!phone) {
                  var input = form.querySelector(
                    'input[type="tel"], input[name*="phone"], input[name*="mobile"], input[id*="phone"], input[id*="mobile"]'
                  );
                  if (input) {
                    phone = input.value;
                  }
                }
                callFlutter(phone);
              });
            });
          }

          function scanAndAttach() {
            var selectors = [
              'input[type="tel"]',
              'input[name*="phone"]',
              'input[name*="mobile"]',
              'input[id*="phone"]',
              'input[id*="mobile"]'
            ];
            selectors.forEach(function(selector) {
              document.querySelectorAll(selector).forEach(attachToInput);
            });
            attachToForms();
          }

          var observer = new MutationObserver(function() {
            scanAndAttach();
          });

          observer.observe(document.documentElement || document.body, {
            childList: true,
            subtree: true
          });

          if (document.readyState === 'loading') {
            document.addEventListener('DOMContentLoaded', scanAndAttach);
          } else {
            scanAndAttach();
          }
        })();
      """;

      await controller.evaluateJavascript(source: script);
      _phoneListenerInjected = true;
    } catch (e) {
      debugPrint('❌ Failed to inject phone capture script: $e');
      _phoneListenerInjected = false;
    }
  }

  /// Inject JavaScript to intercept API requests and capture POST bodies and RESPONSES
  Future<void> _injectApiInterceptorScript(
      InAppWebViewController controller) async {
    try {
      const script = r"""
        (function() {
          if (window.__apiInterceptorInstalled) {
            return;
          }
          window.__apiInterceptorInstalled = true;

          function callFlutterHandler(handlerName, data) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              return window.flutter_inappwebview.callHandler(handlerName, data);
            } else {
              return Promise.reject('Flutter handler not available');
            }
          }

          // Intercept fetch API
          var originalFetch = window.fetch;
          window.fetch = async function(url, options) {
            var urlString = typeof url === 'string' ? url : url.url || url.toString();
            var method = (options && options.method) ? options.method.toUpperCase() : 'GET';
            
            // 1. Intercept Uploads that might fail or are known to need native handling
            var isUpload = (urlString.includes('upload') || urlString.includes('profile-image')) && 
                           (method === 'POST' || method === 'PUT');
            
            // Check if body contains base64
            var hasBase64 = false;
            var bodyObj = null;
            if (options && options.body && typeof options.body === 'string') {
               try {
                 bodyObj = JSON.parse(options.body);
                 if (bodyObj.base64 || (bodyObj.images && bodyObj.images[0] && bodyObj.images[0].base64)) {
                   hasBase64 = true;
                 }
               } catch(e) {}
            }

            // If it's an upload with base64, Try delegation to Flutter FIRST if we suspect failure, 
            // OR try network and fallback on 405.
            // Given the user issue (405), let's try network first, and catch 405.
            
            try {
              var response = await originalFetch.apply(this, arguments);
              
              // IF Status is 405 (Method Not Allowed) AND we have payload to upload
              if (response.status === 405 && hasBase64 && bodyObj) {
                  console.log("⚠️ Intercepted 405 on " + urlString + ". Delegating to Flutter...");
                  
                  // Prepare data for Flutter
                  var uploadData = {};
                  if (bodyObj.base64) {
                     uploadData = bodyObj; // Already flat
                  } else if (bodyObj.images && bodyObj.images[0]) {
                     uploadData = bodyObj.images[0]; // Extract first image
                  }
                  
                  // Add endpoint context
                  uploadData.endpoint = 'auth/partner/upload-docs-base64'; // Force use known working endpoint
                  
                  try {
                    var flutterResult = await callFlutterHandler('uploadBase64', uploadData);
                    
                    if (flutterResult && flutterResult.success) {
                       // Create a fake success response
                       var mockResponse = new Response(JSON.stringify(flutterResult.data), {
                         status: 200,
                         statusText: 'OK',
                         headers: {'Content-Type': 'application/json'}
                       });
                       // define url property
                       Object.defineProperty(mockResponse, 'url', { value: urlString });
                       return mockResponse;
                    }
                  } catch(err) {
                     console.error("Flutter upload fallback failed:", err);
                  }
              }

              // Login Capture Logic (Existing)
              var isLogin = urlString.includes('/auth/login') || 
                            urlString.includes('/users/login') ||
                            urlString.includes('/auth/verify-otp') ||
                            urlString.includes('/auth/signup-verify');
              
              if (isLogin) {
                  var clone = response.clone();
                  clone.json().then(data => {
                     callFlutterHandler('captureLoginResponse', JSON.stringify({
                       url: urlString,
                       body: data
                     }));
                  }).catch(err => {});
              }

              return response;
            } catch (e) {
              throw e;
            }
          };

          // Intercept XMLHttpRequest
          var originalXHROpen = XMLHttpRequest.prototype.open;
          var originalXHRSend = XMLHttpRequest.prototype.send;
          
          XMLHttpRequest.prototype.open = function(method, url, async, user, password) {
            this._method = method;
            this._url = url;
            return originalXHROpen.apply(this, arguments);
          };
          
          XMLHttpRequest.prototype.send = function(data) {
            var self = this;
            var url = this._url;
            
            // Login Capture Logic
            if (url && (url.includes('/auth/login') || 
                        url.includes('/users/login') ||
                        url.includes('/auth/verify-otp') ||
                        url.includes('/auth/signup-verify'))) {
               this.addEventListener('load', function() {
                  try {
                    var responseBody = self.responseText;
                    try {
                       var json = JSON.parse(responseBody);
                       // Use fire-and-forget for login capture
                       if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
                          window.flutter_inappwebview.callHandler('captureLoginResponse', JSON.stringify({
                              url: url,
                              body: json
                           }));
                       }
                    } catch(e) {}
                  } catch(e) {}
               });
            }
            
            return originalXHRSend.apply(this, arguments);
          };
        })();
      """;

      await controller.evaluateJavascript(source: script);

      // Add JavaScript handler to receive captured API requests
      controller.addJavaScriptHandler(
        handlerName: 'captureApiRequest',
        callback: (args) {
          // Existing existing handler logic...
        },
      );

      // Add Handler for Login Response
      controller.addJavaScriptHandler(
        handlerName: 'captureLoginResponse',
        callback: (args) async {
          if (args.isNotEmpty) {
            try {
              final data = jsonDecode(args[0].toString());
              final body = data['body'];
              
              // Handle common token keys (token, accessToken, data.token, etc.)
              String? token;
              if (body != null) {
                if (body['token'] != null) {
                  token = body['token'].toString();
                } else if (body['accessToken'] != null) {
                  token = body['accessToken'].toString();
                } else if (body['data'] != null && body['data']['token'] != null) {
                  token = body['data']['token'].toString();
                }
              }

              if (token != null) {
                await PrefsUtil.setAccessToken(token);
                debugPrint('✅ Access token captured and saved from login');
                // After saving token, save FCM token to backend
                await _saveFCMToken();
              }
            } catch (e) {
              debugPrint('❌ Error parsing login response: $e');
            }
          }
        },
      );

      await _saveFCMToken();

      debugPrint('✅ API interceptor script injected successfully');
    } catch (e) {
      debugPrint('❌ Failed to inject API interceptor script: $e');
    }
  }

  /// Inject JavaScript to intercept phone, email, and WhatsApp button clicks
  Future<void> _injectLinkInterceptorScript(
      InAppWebViewController controller) async {
    if (_linkInterceptorInjected) {
      return;
    }
    try {
      const script = r"""
        (function() {
          if (window.__linkInterceptorInstalled) {
            return;
          }
          window.__linkInterceptorInstalled = true;

          function callFlutterHandler(handlerName, data) {
            if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
              window.flutter_inappwebview.callHandler(handlerName, data);
            } else if (window.webkit
              && window.webkit.messageHandlers
              && window.webkit.messageHandlers[handlerName]
              && window.webkit.messageHandlers[handlerName].postMessage) {
              window.webkit.messageHandlers[handlerName].postMessage(data);
            }
          }
          
          // Intercept clicks on links
          document.addEventListener('click', function(e) {
            var target = e.target;
            while (target && target.tagName !== 'A') {
              target = target.parentElement;
            }
            
            if (target && target.tagName === 'A') {
              var href = target.getAttribute('href');
              if (href) {
                 if (href.startsWith('tel:') || 
                     href.startsWith('mailto:') || 
                     href.includes('wa.me') || 
                     href.includes('whatsapp.com')) {
                   // Let default handling or other interceptors work
                 }
              }
            }
          }, true);
        })();
      """;

       await controller.evaluateJavascript(source: script);
       _linkInterceptorInjected = true;
    } catch (e) {
      debugPrint('❌ Failed to inject link interceptor script: $e');
      _linkInterceptorInjected = false;
    }
  }

  @override
  void dispose() {
    _connectivitySubscription?.cancel();
    super.dispose();
  }

  /// Check initial connectivity status
  Future<void> _checkConnectivity() async {
    final isConnected = await ConnectivityUtil.isConnected();
    if (mounted) {
      setState(() {
        _isOnline = isConnected;
      });
    }
  }

  /// Listen to connectivity changes
  void _listenToConnectivityChanges() {
    _connectivitySubscription = ConnectivityUtil.onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      final isConnected = ConnectivityUtil.isConnectivityResultConnected(
        results,
      );

      if (mounted) {
        setState(() {
          _isOnline = isConnected;
        });
      }
    });
  }

  /// Retry loading the page
  Future<void> _retryLoad() async {
    await _checkConnectivity();
    if (_isOnline) {
      _webViewController?.reload();
    }
  }

  /// Check if URL should be launched externally (phone, email, WhatsApp, social media)
  bool _shouldLaunchExternally(Uri uri) {
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host.toLowerCase();

    // Phone calls, Email, SMS
    if (scheme == 'tel' ||
        scheme == 'callto' ||
        scheme == 'mailto' ||
        scheme == 'sms') {
      return true;
    }

    // WhatsApp
    if (scheme == 'whatsapp' ||
        scheme == 'whatsapp-api' ||
        host.contains('whatsapp.com') ||
        host.contains('wa.me')) {
      return true;
    }

    // Social media platforms
    final socialMediaDomains = [
      'facebook.com',
      'fb.com',
      'twitter.com',
      'x.com',
      'instagram.com',
      'linkedin.com',
      'youtube.com',
      'tiktok.com',
      'snapchat.com',
      'pinterest.com',
      'telegram.org',
      't.me',
      'messenger.com',
      'viber.com',
      'line.me',
      'wechat.com',
      'skype.com',
    ];

    for (var domain in socialMediaDomains) {
      if (host.contains(domain)) {
        return true;
      }
    }

    // Messaging apps
    if (['tg', 'telegram', 'viber', 'skype'].contains(scheme)) {
      return true;
    }

    // Payment & Stores
    if (['market', 'itms-apps', 'itms-appss'].contains(scheme) ||
        host.contains('play.google.com') ||
        host.contains('apps.apple.com')) {
      return true;
    }

    // UPI Payment Schemes
    if ([
      'upi',
      'tez',
      'phonepe',
      'paytm',
      'bhim',
      'cred',
      'mobikwik',
      'amazonpay'
    ].contains(scheme)) {
      return true;
    }

    // Check for UPI deep links in URL
    final urlString = uri.toString().toLowerCase();
    if (urlString.contains('upi://') || urlString.contains('upi:pay')) {
      return true;
    }

    return false;
  }

  /// Handle Razorpay UPI app SVG URL clicks
  /// Detects URLs like https://cdn.razorpay.com/app/paytm.svg and converts to UPI deep links
  Future<Uri?> _handleRazorpayUPIAppClick(Uri uri) async {
    try {
      final urlString = uri.toString().toLowerCase();
      final host = uri.host.toLowerCase();

      // Check if it's a Razorpay CDN URL for UPI apps
      // FIX: Use path.endsWith or contains check to handle query parameters
      if (host.contains('razorpay.com') &&
          urlString.contains('/app/') &&
          (uri.path.endsWith('.svg') || urlString.contains('.svg'))) {
        debugPrint('💳 Detected Razorpay UPI app SVG URL: $urlString');

        // Extract app name from URL (e.g., "paytm" from "https://cdn.razorpay.com/app/paytm.svg")
        final pathSegments = uri.pathSegments;
        String? appName;

        for (var segment in pathSegments) {
          if (segment.endsWith('.svg')) {
            appName = segment.replaceAll('.svg', '').toLowerCase();
            break;
          }
        }

        if (appName != null && appName.isNotEmpty) {
          debugPrint('💳 Extracted UPI app name: $appName');

          final normalizedAppName = appName
              .replaceAll('-', '')
              .replaceAll('_', '')
              .replaceAll(' ', '')
              .toLowerCase();

          final upiAppMap = {
            'paytm': 'paytm',
            'phonepe': 'phonepe',
            'googlepay': 'tez',
            'gpay': 'tez',
            'tez': 'tez',
            'bhim': 'bhim',
            'cred': 'cred',
            'mobikwik': 'mobikwik',
            'amazonpay': 'amazonpay',
            'amazon': 'amazonpay',
            'pop': 'pop',
            'moneyview': 'moneyview',
            'popupi': 'pop',
          };

          var upiScheme = upiAppMap[appName] ?? upiAppMap[normalizedAppName];

          if (upiScheme != null) {
            // Try to extract UPI payment parameters from JavaScript context
            try {
              if (_webViewController != null) {
                final upiParamsScript = '''
                  (function() {
                    try {
                      // Look for Razorpay payment data
                      var razorpayData = window.Razorpay || window.razorpay || {};
                      var paymentData = razorpayData.paymentData || {};
                      var upiParams = {};
                      
                      // Check URL parameters
                      var urlParams = new URLSearchParams(window.location.search);
                      if (urlParams.get('pa')) upiParams.pa = urlParams.get('pa');
                      if (urlParams.get('pn')) upiParams.pn = urlParams.get('pn');
                      
                      // Check in payment data
                      if (paymentData.upi && paymentData.upi.vpa) upiParams.pa = paymentData.upi.vpa;
                      
                      // Also scan page text for VPA if needed
                      // Return parameters as JSON string
                      return Object.keys(upiParams).length > 0 ? JSON.stringify(upiParams) : null;
                    } catch(e) { return null; }
                  })();
                ''';

                final upiParamsResult = await _webViewController!
                    .evaluateJavascript(source: upiParamsScript);

                if (upiParamsResult != null &&
                    upiParamsResult.toString() != 'null') {
                  try {
                    final paramsJson = jsonDecode(upiParamsResult.toString())
                        as Map<String, dynamic>;
                    if (paramsJson.isNotEmpty) {
                      final upiUri = Uri(
                        scheme: 'upi',
                        host: 'pay',
                        queryParameters: paramsJson.map(
                            (key, value) => MapEntry(key, value.toString())),
                      );
                      debugPrint('💳 Using UPI parameters from page: $upiUri');
                      return upiUri;
                    }
                  } catch (e) {
                    debugPrint('⚠️ Error parsing UPI params: $e');
                  }
                }
              }
            } catch (e) {
              debugPrint('⚠️ Could not get page context: $e');
            }

            // Fallback: If we can't find params, try to launch the app directly
            // Note: Launching 'paytm://' usually opens the app home screen.
            final upiUri = Uri(scheme: 'upi', host: 'pay');
            debugPrint('💳 Launching UPI Payment (generic): $upiUri');
            return upiUri;
          }
        }
      }
      return null;
    } catch (e) {
      debugPrint('❌ Error handling Razorpay UPI app click: $e');
      return null;
    }
  }

  /// Handle UPI app launches
  Future<bool> _handleUPIAppLaunch(Uri uri) async {
    try {
      final scheme = uri.scheme.toLowerCase();

      // List of known UPI schemes
      final knownUpiSchemes = [
        'upi',
        'tez',
        'phonepe',
        'paytm',
        'bhim',
        'cred',
        'mobikwik',
        'amazonpay',
        'gpay'
      ];

      if (knownUpiSchemes.contains(scheme) ||
          uri.toString().startsWith('upi://')) {
        debugPrint('💳 Detected UPI/Payment link: $uri');

        // Try launching external application mode
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
          debugPrint('✅ UPI app launched');
          return true;
        } else {
          // Fallback attempt without checking canLaunchUrl (sometimes works on legacy Android or specific config)
          try {
            debugPrint(
                '⚠️ canLaunchUrl returned false, attempting launch anyway...');
            await launchUrl(uri, mode: LaunchMode.externalApplication);
            return true;
          } catch (e) {
            debugPrint('❌ Failed to launch UPI app: $e');
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                    content:
                        Text('Could not open payment app. Is it installed?')),
              );
            }
          }
        }
      }
      return false;
    } catch (e) {
      debugPrint('❌ Error handling UPI app launch: $e');
      return false;
    }
  }

  /// Handle Android Intent URLs specifically
  Future<void> _handleIntentUrl(Uri uri) async {
    try {
      debugPrint('🤖 Attempting to launch intent: $uri');
      // On Android, launchUrl with externalApplication mode handles intents if the app is installed
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        return;
      }
    } catch (e) {
      debugPrint('❌ Failed to launch intent directly: $e');
    }

    // Fallback handling if launch failed
    try {
      final intentString = uri.toString();
      String? fallbackUrl;

      // Try different patterns for browser_fallback_url
      final patterns = [
        'browser_fallback_url=',
        'S.browser_fallback_url='
      ];

      for (var pattern in patterns) {
        if (intentString.contains(pattern)) {
          final fallbackBlock = intentString.substring(
              intentString.indexOf(pattern) + pattern.length);
          final endIndex = fallbackBlock.indexOf(';');
          
          if (endIndex != -1) {
            final fallbackUrlEncoded = fallbackBlock.substring(0, endIndex);
            fallbackUrl = Uri.decodeFull(fallbackUrlEncoded);
            break;
          }
        }
      }

      if (fallbackUrl != null && fallbackUrl.isNotEmpty) {
        debugPrint('🔄 Intent failed, using fallback: $fallbackUrl');
        final fallbackUri = Uri.parse(fallbackUrl);
          
        // Launch fallback URL externally (e.g. Chrome) to avoid WebView redirect loops
        // and provide better UX for things like Maps directions.
        await _launchExternalUrl(fallbackUri);
      } else {
        debugPrint('⚠️ No fallback URL found in intent');
        if (mounted) {
           ScaffoldMessenger.of(context).showSnackBar(
             const SnackBar(content: Text('Could not open map application.')),
           );
        }
      }
    } catch (e) {
      debugPrint('❌ Failed to handle intent fallback: $e');
    }
  }

  /// Launch URL externally using url_launcher
  Future<void> _launchExternalUrl(Uri uri) async {
    try {
      if (await _handleUPIAppLaunch(uri)) return;

      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
        debugPrint('✅ External URL launched successfully: $uri');
      } else {
        // Try launching anyway for intent schemes or special cases
        try {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (e) {
          debugPrint('❌ Cannot launch URL: $uri');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Cannot open: ${uri.scheme}://...'),
                backgroundColor: Colors.orange,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('❌ Error launching external URL: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    StatusBarUtil.updateStatusBar(context);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        _handleBackNavigation();
      },
      child: Scaffold(
        body: SafeArea(
          child: _isOnline
              ? Stack(
                  children: [
                    InAppWebView(
                      initialUrlRequest: URLRequest(
                        url: WebUri(AppConfig.webUrl),
                      ),
                      initialSettings: InAppWebViewSettings(
                        javaScriptEnabled: true,
                        javaScriptCanOpenWindowsAutomatically: true,
                        domStorageEnabled: true,
                        databaseEnabled: true,
                        mediaPlaybackRequiresUserGesture: false,
                        allowsInlineMediaPlayback: true,
                        useOnDownloadStart: true,
                        geolocationEnabled: true,
                        supportZoom: true,
                        builtInZoomControls: true,
                        displayZoomControls: false,
                        safeBrowsingEnabled: true,
                        mixedContentMode:
                            MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
                        allowFileAccess: true,
                        allowFileAccessFromFileURLs: true,
                        allowUniversalAccessFromFileURLs: true,
                        useOnLoadResource: true,
                        useShouldOverrideUrlLoading: true,
                      ),
                      pullToRefreshController: _pullToRefreshController,
                      onCreateWindow: (controller, createWindowRequest) async {
                        final urlRequest = createWindowRequest.request;
                        var url = urlRequest.url;
                        debugPrint('🪟 onCreateWindow: url=$url');

                        if (url == null) return false;

                        // Check for Razorpay UPI app SVG URLs FIRST
                        // Use stricter check that handles query params
                        if (url.host.contains('razorpay.com') &&
                            url.toString().contains('/app/') &&
                            (url.path.endsWith('.svg') ||
                                url.toString().contains('.svg'))) {
                          debugPrint(
                              '💳 onCreateWindow: Detected Razorpay UPI app SVG, intercepting...');
                          final upiAppUri =
                              await _handleRazorpayUPIAppClick(url);
                          if (upiAppUri != null) {
                            await _launchExternalUrl(upiAppUri);
                            return false;
                          }
                        }

                        // Handle non-HTTP schemes
                        final allowedSchemes = [
                          'http',
                          'https',
                          'file',
                          'chrome',
                          'data',
                          'javascript'
                        ];
                        if (!allowedSchemes
                            .contains(url.scheme.toLowerCase())) {
                          if (await canLaunchUrl(url)) {
                            await launchUrl(url,
                                mode: LaunchMode.externalApplication);
                            return false;
                          }
                        }

                        if (_shouldLaunchExternally(url)) {
                          await _launchExternalUrl(url);
                          return false;
                        }

                        controller.loadUrl(urlRequest: urlRequest);
                        return true;
                      },
                      shouldOverrideUrlLoading:
                          (controller, navigationAction) async {
                        final urlRequest = navigationAction.request;
                        final uri = urlRequest.url;

                        if (uri == null) return NavigationActionPolicy.ALLOW;

                        debugPrint('➡️ Navigating: $uri');

                        // 1. Check for Intent Scheme (Android)
                        if (uri.scheme.toLowerCase() == 'intent') {
                          await _handleIntentUrl(uri);
                          return NavigationActionPolicy.CANCEL;
                        }

                        // 2. Check for Phone/Tel Scheme
                        if (uri.scheme.toLowerCase() == 'tel') {
                          debugPrint('🤖 Detected Intent scheme, launching...');
                          try {
                            await launchUrl(uri,
                                mode: LaunchMode.externalApplication);
                            return NavigationActionPolicy.CANCEL;
                          } catch (e) {
                            debugPrint('❌ Failed to launch intent: $e');
                            // Continue to allow fallback URL processing if handled by webview?
                            // Usually fallback urls are inside the intent string, complex to parse here.
                          }
                        }

                        // 2. Check for UPI deep links
                        if (uri.scheme.toLowerCase() == 'upi') {
                          debugPrint('💳 Detected UPI URL: $uri');
                          await _launchExternalUrl(uri);
                          return NavigationActionPolicy.CANCEL;
                        }

                        // 3. Check for Razorpay UPI SVG
                        final upiAppUri = await _handleRazorpayUPIAppClick(uri);
                        if (upiAppUri != null) {
                          await _launchExternalUrl(upiAppUri);
                          return NavigationActionPolicy.CANCEL;
                        }

                        // 4. Handle other non-HTTP schemes
                        final allowedSchemes = [
                          'http',
                          'https',
                          'file',
                          'chrome',
                          'data',
                          'javascript',
                          'about'
                        ];
                        if (!allowedSchemes
                            .contains(uri.scheme.toLowerCase())) {
                          await _launchExternalUrl(uri);
                          return NavigationActionPolicy.CANCEL;
                        }

                        // 5. External launch check
                        if (_shouldLaunchExternally(uri)) {
                          await _launchExternalUrl(uri);
                          return NavigationActionPolicy.CANCEL;
                        }

                        return NavigationActionPolicy.ALLOW;
                      },
                      onWebViewCreated: (controller) async {
                        _webViewController = controller;
                         debugPrint('Add camera handler---------->>>>>>');
                        // Add camera handler
                        controller.addJavaScriptHandler(
                          handlerName: 'openCamera',
                          callback: (args) async {
                            debugPrint('📷 openCamera handler called with args: $args'); 
                            return await _openCamera();
                          },
                        );

                        // Add generic upload handler
                        controller.addJavaScriptHandler(
                          handlerName: 'uploadBase64',
                          callback: (args) async {
                            debugPrint('📤 uploadBase64 handler called from JavaScript: $args');
                            if (args.isNotEmpty) {
                              try {
                                dynamic data = args[0];
                                if (data is String) {
                                  try {
                                    data = jsonDecode(data);
                                  } catch (e) {
                                    debugPrint('⚠️ Argument is string but not JSON, treating as raw? No, expecting Map.');
                                  }
                                }
                                
                                if (data is Map<String, dynamic>) {
                                  return await _uploadBase64(data);
                                } else {
                                  return {'success': false, 'error': 'Invalid argument format. Expected Map.'};
                                }
                              } catch (e) {
                                debugPrint('❌ Error in uploadBase64 handler: $e');
                                return {'success': false, 'error': e.toString()};
                              }
                            }
                            return {'success': false, 'error': 'No arguments provided'};
                          },
                        );

                        debugPrint('✅ WebView created');
                        
                        await _saveFCMToken();
                      },
                      onLoadStart: (controller, url) {
                        setState(() {
                          _isLoading = true;
                          _phoneListenerInjected = false;
                          _linkInterceptorInjected = false;
                        });
                        debugPrint('🌐 Loading started: $url');
                      },
                      onLoadStop: (controller, url) async {
                        _pullToRefreshController.endRefreshing();
                        setState(() {
                          _isLoading = false;
                          _loadingProgress = 1.0;
                        });
                        debugPrint('✅ Loading finished: $url');
                        await _injectPhoneCaptureScript(controller);
                        await _injectLinkInterceptorScript(controller);
                        await _injectApiInterceptorScript(controller);
                      },
                      onProgressChanged: (controller, progress) {
                        setState(() {
                          _loadingProgress = progress / 100;
                          // Hide loader when progress reaches 100%
                          if (progress >= 100) {
                            _isLoading = false;
                            _pullToRefreshController.endRefreshing();
                          }
                        });
                        debugPrint('📊 Loading progress: $progress%');
                      },
                      onLoadError: (controller, url, code, message) {
                        _pullToRefreshController.endRefreshing();
                        setState(() {
                          _isLoading = false;
                        });
                        debugPrint('❌ Load error: $message (code: $code)');
                      },
                      onGeolocationPermissionsShowPrompt:
                          (controller, origin) async {
                        return GeolocationPermissionShowPromptResponse(
                            origin: origin, allow: true, retain: true);
                      },
                      onDownloadStartRequest:
                          (controller, downloadStartRequest) async {
                        try {
                          final url = downloadStartRequest.url.toString();
                          final suggestedFilename =
                              downloadStartRequest.suggestedFilename;
                          final mimeType = downloadStartRequest.mimeType;
                          final contentDisposition =
                              downloadStartRequest.contentDisposition;

                          debugPrint('📥 Download requested: $url');
                          debugPrint(
                              '📄 Suggested filename: $suggestedFilename');
                          debugPrint('📋 MIME type: $mimeType');
                          debugPrint(
                              '📋 Content-Disposition: $contentDisposition');

                          // Handle blob URLs - they need to be extracted via JavaScript
                          if (url.startsWith('blob:')) {
                            debugPrint(
                                '🔵 Blob URL detected, extracting blob data...');
                            await _handleBlobDownload(
                              controller: controller,
                              blobUrl: url,
                              suggestedFilename:
                                  suggestedFilename ?? 'receipt.pdf',
                              mimeType: mimeType ?? 'application/pdf',
                              isReceiptDownload: true,
                            );
                            return;
                          }

                          // Check if it's a receipt download
                          final isReceiptDownload = url.contains('receipt') ||
                              url.contains('download-receipt') ||
                              url.contains('invoice') ||
                              (suggestedFilename != null &&
                                  (suggestedFilename
                                          .toLowerCase()
                                          .contains('receipt') ||
                                      suggestedFilename
                                          .toLowerCase()
                                          .contains('invoice')));

                          if (!mounted) return;

                          // For Android 10+, app-specific directories don't require permission
                          // Only request permission if we need public Downloads folder
                          // But we'll try public Downloads first, fallback to app-specific if needed
                          bool hasPermission = false;
                          bool canDownload = true;

                          if (isReceiptDownload) {
                            // For receipts, try to get permission for public Downloads
                            hasPermission = await PermissionHandlerUtil
                                .checkStoragePermission();
                            if (!hasPermission) {
                              final granted = await PermissionHandlerUtil
                                  .requestStoragePermission();
                              if (!granted) {
                                // Permission denied, but we can still download to app-specific folder
                                debugPrint(
                                    '⚠️ Permission denied, will use app-specific Downloads folder');
                                hasPermission = false;
                                canDownload =
                                    true; // Still allow download to app folder
                              } else {
                                hasPermission = true;
                              }
                            } else {
                              hasPermission = true;
                            }
                          } else {
                            // For other files, app-specific directory doesn't need permission
                            canDownload = true;
                          }

                          if (!canDownload) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                      'Cannot download file. Please check storage permissions in app settings.'),
                                  backgroundColor: Colors.orange,
                                  duration: Duration(seconds: 3),
                                ),
                              );
                            }
                            return;
                          }

                          // Show download progress
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Row(
                                  children: [
                                    const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                                Colors.white),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        isReceiptDownload
                                            ? 'Downloading receipt...'
                                            : 'Downloading file...',
                                        style: const TextStyle(
                                            color: Colors.white),
                                      ),
                                    ),
                                  ],
                                ),
                                backgroundColor: Colors.blue,
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }

                          // Download the file
                          // For Android 10+, app-specific directories don't require permission
                          // Try public Downloads for receipts if permission granted, otherwise use app-specific
                          final downloadService = DownloadService();
                          DownloadResult result;

                          if (isReceiptDownload && hasPermission) {
                            // Try public Downloads folder first
                            debugPrint(
                                '📥 Attempting to download receipt to public Downloads folder...');
                            result = await downloadService.downloadFile(
                              url: url,
                              contentDisposition: contentDisposition,
                              context: context,
                              usePublicDownloads: true, // Try public Downloads
                              onProgress: (received, total) {
                                if (total > 0) {
                                  final progress = (received / total * 100)
                                      .toStringAsFixed(1);
                                  debugPrint(
                                      '📥 Download progress: $progress%');
                                }
                              },
                            );

                            // If public Downloads failed, fallback to app-specific folder
                            if (!result.success) {
                              debugPrint(
                                  '⚠️ Public Downloads failed, using app-specific folder...');
                              result = await downloadService.downloadFile(
                                url: url,
                                contentDisposition: contentDisposition,
                                context: context,
                                usePublicDownloads:
                                    false, // Use app-specific folder (no permission needed)
                                onProgress: (received, total) {
                                  if (total > 0) {
                                    final progress = (received / total * 100)
                                        .toStringAsFixed(1);
                                    debugPrint(
                                        '📥 Download progress: $progress%');
                                  }
                                },
                              );
                            }
                          } else {
                            // Use app-specific folder (no permission needed for Android 10+)
                            debugPrint(
                                '📥 Downloading to app-specific Downloads folder (no permission needed)...');
                            result = await downloadService.downloadFile(
                              url: url,
                              contentDisposition: contentDisposition,
                              context: context,
                              usePublicDownloads:
                                  false, // Use app-specific folder
                              onProgress: (received, total) {
                                if (total > 0) {
                                  final progress = (received / total * 100)
                                      .toStringAsFixed(1);
                                  debugPrint(
                                      '📥 Download progress: $progress%');
                                }
                              },
                            );
                          }

                          if (!mounted) return;

                          if (result.success && result.filePath != null) {
                            // Show success message
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        const Icon(Icons.check_circle,
                                            color: Colors.white),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            isReceiptDownload
                                                ? 'Receipt saved to Downloads'
                                                : 'File saved to Downloads',
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (result.filename != null) ...[
                                      const SizedBox(height: 4),
                                      Text(
                                        result.filename!,
                                        style: const TextStyle(
                                          color: Colors.white70,
                                          fontSize: 12,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ],
                                  ],
                                ),
                                backgroundColor: Colors.green,
                                duration: const Duration(seconds: 4),
                                behavior: SnackBarBehavior.floating,
                                action: SnackBarAction(
                                  label: 'OPEN',
                                  textColor: Colors.white,
                                  onPressed: () async {
                                    if (result.filePath != null) {
                                      await downloadService
                                          .openFile(result.filePath!);
                                    }
                                  },
                                ),
                              ),
                            );
                            debugPrint(
                                '✅ Download successful: ${result.filePath}');
                          } else {
                            // Show error message
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  result.error ?? 'Download failed',
                                  style: const TextStyle(color: Colors.white),
                                ),
                                backgroundColor: Colors.red,
                                duration: const Duration(seconds: 3),
                              ),
                            );
                            debugPrint('❌ Download failed: ${result.error}');
                          }
                        } catch (e) {
                          debugPrint('❌ Error handling download: $e');
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Download failed: $e'),
                                backgroundColor: Colors.red,
                                duration: const Duration(seconds: 3),
                              ),
                            );
                          }
                        }
                      },
                    ),
                    // Loading indicator overlay - only show when loading
                    if (_isLoading)
                      Container(
                        color: Colors.white.withOpacity(0.9),
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              CircularProgressIndicator(
                                value: _loadingProgress < 1.0 &&
                                        _loadingProgress > 0
                                    ? _loadingProgress
                                    : null,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                    AppConfig.primaryColor),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Loading...',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: AppConfig.primaryColor,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                )
              : OfflineScreen(
                  onRetry: _retryLoad), // Use your existing OfflineScreen
        ),
      ),
    );
  }

  /// Handle base64 upload request from JavaScript
  Future<Map<String, dynamic>> _uploadBase64(Map<String, dynamic> data) async {
    try {
      final base64Image = data['base64'] as String?;
      final mimeType = data['mimeType'] as String? ?? 'image/jpeg';
      final fileName = data['fileName'] as String? ?? 'upload_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final endpoint = data['endpoint'] as String?; // Allow overriding endpoint if needed

      if (base64Image == null) {
        return {'success': false, 'error': 'Missing base64 data'};
      }

      debugPrint('🚀 _uploadBase64: Uploading $fileName ($mimeType) to ${endpoint ?? "default"}');

      final result = await ApiService().uploadBase64Image(
        base64Image: base64Image,
        mimeType: mimeType,
        fileName: fileName,
        endpoint: endpoint ?? 'auth/partner/upload-docs-base64',
      );

      return result;
    } catch (e) {
      debugPrint('❌ _uploadBase64 Error: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  Future<Map<String, dynamic>> _openCamera() async {
    debugPrint('📷 openCamera called from JavaScript');
    try {
      if (!mounted) return {'success': false, 'message': 'Context not mounted'};

      // Show bottom sheet to choose camera or gallery
      final source = await showModalBottomSheet<ImageSource>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (context) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24.0)),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag Handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2.0),
                  ),
                ),
              ),

              // Title
              const Text(
                'Select Image Source',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF1F2937),
                  fontFamily: 'Roboto', // Or system default
                ),
              ),
              const SizedBox(height: 30),

              // Options Row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildImageSourceOption(
                    context: context,
                    icon: Icons.camera_alt_rounded,
                    label: 'Camera',
                    onTap: () => Navigator.pop(context, ImageSource.camera),
                    color: const Color(0xFF0D9488), // Teal-600
                  ),
                  _buildImageSourceOption(
                    context: context,
                    icon: Icons.photo_library_rounded,
                    label: 'Gallery',
                    onTap: () => Navigator.pop(context, ImageSource.gallery),
                    color: const Color(0xFF0D9488), // Teal-600
                  ),
                ],
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      );

      if (source == null) {
        return {'success': false, 'message': 'Cancelled'};
      }

      // Pick image
      final XFile? image = await _picker.pickImage(
        source: source,
        imageQuality: 70, // Reduced quality to keep size small
        maxWidth: 1024, // Reduced max width
        maxHeight: 1024, // Reduced max height
      );

      if (image == null) {
        return {'success': false, 'message': 'No image selected'};
      }

      // Read file as bytes
      final bytes = await image.readAsBytes();
      
      // Convert to base64
      final base64String = base64Encode(bytes);

      final String mimeType = lookupMimeType(image.path) ?? 'image/jpeg';
      final String fileName = image.name;
      final int fileSize = bytes.length;
      final String dataUrl = 'data:$mimeType;base64,$base64String';

      debugPrint('✅ Image captured: $fileName, Size: $fileSize bytes, Mime: $mimeType');

      // Return richer object to JavaScript to support various upload implementations
      return {
        'success': true,
        'base64': base64String, // Raw base64 (Hotel Partner likely uses this)
        'dataUrl': dataUrl, // Base64 with prefix (Partner Profile might need this)
        'mimeType': mimeType,
        'type': mimeType, // Alias
        'fileName': fileName,
        'name': fileName, // Alias
        'size': fileSize,
        'path': image.path,
      };
    } catch (e) {
      debugPrint('❌ Camera error: $e');
      return {
        'success': false,
        'message': e.toString(),
      };
    }
  }

  Widget _buildImageSourceOption({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required Color color,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: color.withOpacity(0.2),
                width: 1,
              ),
            ),
            child: Icon(
              icon,
              size: 32,
              color: color,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            label,
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: Color(0xFF4B5563),
            ),
          ),
        ],
      ),
    );
  }
}
