import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import './supabase_service.dart';
import 'stripe_checkout_launcher_stub.dart'
    if (dart.library.html) 'stripe_checkout_launcher_web.dart';

class StripeCheckoutResult {
  final bool success;
  final String productType;
  final int? httpStatus;
  final bool checkoutRequestStarted;
  final bool urlReturned;
  final bool launchAttempted;
  final bool launchSucceeded;
  final String userMessage;
  final String? sanitizedBackendError;
  final String? stripeCode;

  const StripeCheckoutResult({
    required this.success,
    required this.productType,
    this.httpStatus,
    this.checkoutRequestStarted = false,
    this.urlReturned = false,
    this.launchAttempted = false,
    this.launchSucceeded = false,
    required this.userMessage,
    this.sanitizedBackendError,
    this.stripeCode,
  });

  factory StripeCheckoutResult.failed({
    required String productType,
    int? httpStatus,
    bool checkoutRequestStarted = false,
    bool urlReturned = false,
    bool launchAttempted = false,
    bool launchSucceeded = false,
    String userMessage = 'Checkout could not start. Please try again.',
    String? sanitizedBackendError,
    String? stripeCode,
  }) {
    return StripeCheckoutResult(
      success: false,
      productType: productType,
      httpStatus: httpStatus,
      checkoutRequestStarted: checkoutRequestStarted,
      urlReturned: urlReturned,
      launchAttempted: launchAttempted,
      launchSucceeded: launchSucceeded,
      userMessage: userMessage,
      sanitizedBackendError: sanitizedBackendError,
      stripeCode: stripeCode,
    );
  }
}

class _CheckoutSessionResult {
  final String productType;
  final int? httpStatus;
  final String? url;
  final bool urlReturned;
  final String? userMessage;
  final String? sanitizedBackendError;
  final String? stripeCode;

  const _CheckoutSessionResult({
    required this.productType,
    this.httpStatus,
    this.url,
    required this.urlReturned,
    this.userMessage,
    this.sanitizedBackendError,
    this.stripeCode,
  });
}

class StripeService {
  static StripeService? _instance;
  static StripeService get instance => _instance ??= StripeService._();
  StripeService._();

  static const String _edgeFunctionUrl =
      'https://vbaiivsvjdntzaffboue.supabase.co/functions/v1/create_checkout_session';

  final Dio _dio = Dio();

  BuildContext? _context;
  String? _lastCheckoutError;

  String? get lastCheckoutError => _lastCheckoutError;

  void setContext(BuildContext context) {
    _context = context;
  }

  void _setCheckoutError(String message) {
    _lastCheckoutError = message;
    debugPrint('STRIPE WEB: sanitized error message: $message');
  }

  String _readErrorMessage(Map<String, dynamic> responseData) {
    final message = responseData['message'] as String?;
    final error = responseData['error'] as String?;
    if (message != null && message.trim().isNotEmpty) return message;
    if (error == 'checkout_session_failed') {
      return 'Checkout could not start for this product.';
    }
    if (error == 'Unsupported product type') {
      return 'This product is not available yet.';
    }
    return 'Checkout could not start. Please try again.';
  }

  Future<_CheckoutSessionResult> _createCheckoutSession({
    required String productType,
    BuildContext? context,
  }) async {
    _lastCheckoutError = null;
    debugPrint('STRIPE WEB: checkout request started');
    debugPrint('STRIPE WEB: product_type=$productType');

    final userId = SupabaseService.instance.currentUserId;
    final accessToken =
        SupabaseService.instance.client.auth.currentSession?.accessToken;
    if (userId == null || accessToken == null || accessToken.isEmpty) {
      debugPrint('STRIPE WEB: no authenticated user found');
      _setCheckoutError('Please sign in again before starting checkout.');
      return _CheckoutSessionResult(
        productType: productType,
        urlReturned: false,
        userMessage: _lastCheckoutError,
      );
    }

    final requestBody = {'product_type': productType};

    debugPrint('STRIPE WEB: sending request to create_checkout_session');

    try {
      final response = await _dio.post(
        _edgeFunctionUrl,
        data: jsonEncode(requestBody),
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $accessToken',
            'apikey': SupabaseService.supabaseAnonKey,
          },
          validateStatus: (status) => true,
        ),
      );

      debugPrint('STRIPE WEB: response status=${response.statusCode}');

      final responseData = response.data is String
          ? jsonDecode(response.data as String) as Map<String, dynamic>
          : response.data as Map<String, dynamic>;

      if ((response.statusCode ?? 500) >= 400) {
        final errorMsg = _readErrorMessage(responseData);
        final stripeCode = responseData['stripe_code'] as String?;
        debugPrint(
          'STRIPE WEB: checkout creation failed; '
          'product_type=$productType; stripe_code=${stripeCode ?? 'none'}',
        );
        _setCheckoutError(errorMsg);
        return _CheckoutSessionResult(
          productType: productType,
          httpStatus: response.statusCode,
          urlReturned: false,
          userMessage: errorMsg,
          sanitizedBackendError: responseData['error'] as String?,
          stripeCode: stripeCode,
        );
      }

      final url = responseData['url'] as String?;
      final stripeCustomerId = responseData['stripe_customer_id'] as String?;

      debugPrint(
        'STRIPE WEB: checkout URL returned=${url != null && url.isNotEmpty}',
      );
      debugPrint(
        'STRIPE WEB: stripe_customer_id returned=${stripeCustomerId != null && stripeCustomerId.isNotEmpty}',
      );

      if (url == null || url.isEmpty) {
        final errorMsg = _readErrorMessage(responseData);
        debugPrint('STRIPE WEB: checkout URL missing');
        _setCheckoutError(errorMsg);
        return _CheckoutSessionResult(
          productType: productType,
          httpStatus: response.statusCode,
          urlReturned: false,
          userMessage: errorMsg,
          sanitizedBackendError: responseData['error'] as String?,
          stripeCode: responseData['stripe_code'] as String?,
        );
      }

      return _CheckoutSessionResult(
        productType: productType,
        httpStatus: response.statusCode,
        url: url,
        urlReturned: true,
        userMessage: 'Opening Stripe Checkout...',
      );
    } catch (e) {
      debugPrint('STRIPE WEB: checkout request exception: ${e.runtimeType}');
      _setCheckoutError('Checkout could not start. Please try again.');
      return _CheckoutSessionResult(
        productType: productType,
        urlReturned: false,
        userMessage: _lastCheckoutError,
        sanitizedBackendError: 'frontend_request_exception',
      );
    }
  }

  Future<StripeCheckoutResult> _launchCheckout(
    _CheckoutSessionResult session,
  ) async {
    final url = session.url;
    if (url == null || url.isEmpty) {
      debugPrint('STRIPE WEB: launchUrl skipped; URL missing');
      return StripeCheckoutResult.failed(
        productType: session.productType,
        httpStatus: session.httpStatus,
        checkoutRequestStarted: true,
        urlReturned: false,
        userMessage: session.userMessage ?? 'Checkout URL missing',
        sanitizedBackendError: session.sanitizedBackendError,
        stripeCode: session.stripeCode,
      );
    }
    try {
      debugPrint('STRIPE WEB: checkout navigation attempted');
      final launched = await openStripeCheckoutUrl(url);
      debugPrint('STRIPE WEB: checkout navigation started=$launched');
      if (!launched) {
        _setCheckoutError('Checkout could not start. Please try again.');
      }
      if (launched) {
        return StripeCheckoutResult(
          success: true,
          productType: session.productType,
          httpStatus: session.httpStatus,
          checkoutRequestStarted: true,
          urlReturned: true,
          launchAttempted: true,
          launchSucceeded: true,
          userMessage: 'Redirecting to Stripe Checkout...',
        );
      }
      return StripeCheckoutResult.failed(
        productType: session.productType,
        httpStatus: session.httpStatus,
        checkoutRequestStarted: true,
        urlReturned: true,
        launchAttempted: true,
        launchSucceeded: false,
        userMessage: 'Could not open Stripe Checkout. Please try again.',
        sanitizedBackendError: session.sanitizedBackendError,
        stripeCode: session.stripeCode,
      );
    } catch (e) {
      debugPrint('STRIPE WEB: checkout navigation failure: ${e.runtimeType}');
      _setCheckoutError('Checkout could not start. Please try again.');
      return StripeCheckoutResult.failed(
        productType: session.productType,
        httpStatus: session.httpStatus,
        checkoutRequestStarted: true,
        urlReturned: true,
        launchAttempted: true,
        launchSucceeded: false,
        userMessage: 'Could not open Stripe Checkout. Please try again.',
        sanitizedBackendError: 'launch_url_exception',
        stripeCode: session.stripeCode,
      );
    }
  }

  /// Launch Stripe checkout for Spark+ subscription ($14.99/month)
  Future<StripeCheckoutResult> subscribeSparkPlus({
    BuildContext? context,
  }) async {
    debugPrint('STRIPE WEB: product tapped; product_type=spark_plus');
    final result = await _createCheckoutSession(
      productType: 'spark_plus',
      context: context,
    );
    return _launchCheckout(result);
  }

  /// Launch Stripe checkout for Gold subscription ($29.99/month)
  Future<StripeCheckoutResult> subscribeGold({BuildContext? context}) async {
    debugPrint('STRIPE WEB: product tapped; product_type=gold');
    final result = await _createCheckoutSession(
      productType: 'gold',
      context: context,
    );
    return _launchCheckout(result);
  }

  /// Launch Stripe checkout for a Spark bundle (3, 10, or 25 sparks)
  Future<StripeCheckoutResult> purchaseBundle(
    int bundleSize, {
    BuildContext? context,
  }) async {
    String productType;

    switch (bundleSize) {
      case 3:
        productType = 'bundle_3';
        break;
      case 10:
        productType = 'bundle_10';
        break;
      case 25:
        productType = 'bundle_25';
        break;
      default:
        debugPrint('STRIPE WEB: invalid bundle size=$bundleSize');
        _setCheckoutError('This product is not available yet.');
        return StripeCheckoutResult.failed(
          productType: 'bundle_$bundleSize',
          userMessage: _lastCheckoutError!,
          sanitizedBackendError: 'invalid_bundle_size',
        );
    }

    debugPrint('STRIPE WEB: product tapped; product_type=$productType');
    final result = await _createCheckoutSession(
      productType: productType,
      context: context,
    );
    return _launchCheckout(result);
  }
}
