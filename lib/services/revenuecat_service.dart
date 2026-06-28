import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// RevenueCat product identifiers — platform-specific.
/// iOS uses reverse-domain prefixed IDs; Android uses short IDs.
class RCProductIds {
  static String get sparkBundle3 => (!kIsWeb && Platform.isIOS)
      ? 'com.ononobi.facemeet.spark_bundle_3'
      : 'spark_bundle_3';
  static String get sparkBundle10 => (!kIsWeb && Platform.isIOS)
      ? 'com.ononobi.facemeet.spark_bundle_10'
      : 'spark_bundle_10';
  static String get sparkBundle25 => (!kIsWeb && Platform.isIOS)
      ? 'com.ononobi.facemeet.spark_bundle_25'
      : 'spark_bundle_25';
  static String get sparkPlusMonthly => (!kIsWeb && Platform.isIOS)
      ? 'com.ononobi.facemeet.spark_plus_monthly'
      : 'spark_plus_monthly';
  static String get goldMonthly => (!kIsWeb && Platform.isIOS)
      ? 'com.ononobi.facemeet.gold'
      : 'gold_monthly';
}

/// Spark credits granted per product (mirrors stripe_webhook logic).
Map<String, int> get _bundleSparkMap => {
  RCProductIds.sparkBundle3: 3,
  RCProductIds.sparkBundle10: 10,
  RCProductIds.sparkBundle25: 25,
};

/// Subscription tier mapped per product.
Map<String, String> get _subscriptionTierMap => {
  RCProductIds.sparkPlusMonthly: 'spark_plus',
  RCProductIds.goldMonthly: 'gold',
};

/// Spark allowance on first subscription purchase (mirrors stripe_webhook).
const Map<String, int> _subscriptionSparkAllowance = {
  'spark_plus': 2,
  'gold': 5,
};

const int _sparkReplenishmentCap = 50;

enum RCPurchaseStatus { success, cancelled, failed }

class RevenueCatService {
  static RevenueCatService? _instance;
  static RevenueCatService get instance => _instance ??= RevenueCatService._();
  RevenueCatService._();

  static final String _apiKey = (!kIsWeb && Platform.isIOS)
      ? 'appl_hdFbUWphqwpiFRPYWGkTOPKHggA'
      : 'goog_VOLhwFfDVeQCGsneCoZkbkTcfWK';

  /// Initialize RevenueCat — call once on app start (mobile only).
  static Future<void> initialize() async {
    if (kIsWeb) return;
    try {
      await Purchases.configure(PurchasesConfiguration(_apiKey));
      debugPrint('REVENUECAT: initialized');
    } catch (e) {
      debugPrint('REVENUECAT: initialization error — $e');
    }
  }

  /// Set the RevenueCat user ID to match the Supabase user ID.
  Future<void> identifyUser(String userId) async {
    if (kIsWeb) return;
    try {
      await Purchases.logIn(userId);
      debugPrint('REVENUECAT: identified user $userId');
    } catch (e) {
      debugPrint('REVENUECAT: identify error — $e');
    }
  }

  /// Clear the local RevenueCat app user association after account deletion.
  /// This does not cancel or alter App Store / Google Play subscriptions.
  Future<void> logOutCurrentUser() async {
    if (kIsWeb) return;
    try {
      await Purchases.logOut();
      debugPrint('REVENUECAT: logged out local app user');
    } catch (e) {
      debugPrint('REVENUECAT: local logout error — $e');
    }
  }

  /// Fetch available products from RevenueCat.
  Future<List<StoreProduct>> getProducts(List<String> productIds) async {
    if (kIsWeb) return [];
    try {
      return await Purchases.getProducts(productIds);
    } catch (e) {
      debugPrint('REVENUECAT: getProducts error — $e');
      return [];
    }
  }

  /// Purchase a product from the active RevenueCat offering.
  /// Using the Offering Package is required for Google Play one-time products.
  Future<RCPurchaseStatus> purchaseProduct(
    String productId, {
    void Function()? onCancelled,
  }) async {
    if (kIsWeb) return RCPurchaseStatus.failed;
    try {
      debugPrint(
        'REVENUECAT: platform detected — ${_platformLabel()}, requestedProductId=$productId',
      );
      final package = await _findPackageForProduct(productId);
      if (package == null) {
        debugPrint(
          'REVENUECAT: purchase failed — no active offering package for productId=$productId',
        );
        return RCPurchaseStatus.failed;
      }

      debugPrint(
        'REVENUECAT: purchase started — packageId=${package.identifier}, productId=${package.storeProduct.identifier}',
      );
      final result = await Purchases.purchase(PurchaseParams.package(package));
      debugPrint(
        'REVENUECAT: purchase succeeded — activeSubscriptions=${result.customerInfo.activeSubscriptions}',
      );
      await _handlePurchaseSuccess(productId, result);
      return RCPurchaseStatus.success;
    } on PlatformException catch (e) {
      final code = PurchasesErrorHelper.getErrorCode(e);
      if (code == PurchasesErrorCode.purchaseCancelledError) {
        debugPrint('REVENUECAT: purchase cancelled — productId=$productId');
        onCancelled?.call();
        return RCPurchaseStatus.cancelled;
      }
      debugPrint(
        'REVENUECAT: purchase failed — code=$code, message=${e.message}',
      );
      return RCPurchaseStatus.failed;
    } on PurchasesError catch (e) {
      if (e.code == PurchasesErrorCode.purchaseCancelledError) {
        debugPrint('REVENUECAT: purchase cancelled — productId=$productId');
        onCancelled?.call();
        return RCPurchaseStatus.cancelled;
      }
      debugPrint(
        'REVENUECAT: purchase failed — code=${e.code}, message=${e.message}',
      );
      return RCPurchaseStatus.failed;
    } catch (e) {
      debugPrint('REVENUECAT: purchase failed — unexpected error=$e');
      return RCPurchaseStatus.failed;
    }
  }

  Future<RCPurchaseStatus> purchaseSparkBundle(int size) async {
    final productId = switch (size) {
      3 => RCProductIds.sparkBundle3,
      10 => RCProductIds.sparkBundle10,
      25 => RCProductIds.sparkBundle25,
      _ => null,
    };
    if (productId == null) {
      debugPrint('REVENUECAT: purchase failed — unknown bundle size=$size');
      return RCPurchaseStatus.failed;
    }
    debugPrint(
      'REVENUECAT: selected Spark bundle — size=$size, productId=$productId',
    );
    return purchaseProduct(productId);
  }

  Future<Package?> _findPackageForProduct(String productId) async {
    try {
      final offerings = await Purchases.getOfferings();
      final current = offerings.current;
      debugPrint('REVENUECAT: offering loaded — exists=${current != null}');
      if (current == null) return null;

      final packages = current.availablePackages;
      debugPrint(
        'REVENUECAT: packages found — ${packages.map((p) => p.identifier).join(', ')}',
      );
      debugPrint(
        'REVENUECAT: product IDs found — ${packages.map((p) => p.storeProduct.identifier).join(', ')}',
      );

      final aliases = _productAliases(productId);
      for (final package in packages) {
        final packageId = package.identifier;
        final storeProductId = package.storeProduct.identifier;
        if (aliases.contains(storeProductId) || aliases.contains(packageId)) {
          debugPrint(
            'REVENUECAT: selected package identifier=$packageId, '
            'selected product identifier=$storeProductId',
          );
          return package;
        }
      }

      final inferredPackage = _findAndroidSubscriptionPackageByName(
        packages,
        productId,
      );
      if (inferredPackage != null) {
        debugPrint(
          'REVENUECAT: selected package identifier=${inferredPackage.identifier}, '
          'selected product identifier=${inferredPackage.storeProduct.identifier}',
        );
        return inferredPackage;
      }

      return null;
    } catch (e) {
      debugPrint('REVENUECAT: offering lookup failed — $e');
      return null;
    }
  }

  Set<String> _productAliases(String productId) {
    final aliases = <String>{productId};
    if (!kIsWeb && Platform.isAndroid) {
      if (productId == RCProductIds.sparkPlusMonthly) {
        aliases.addAll({'spark_plus', 'spark_plus_monthly'});
      } else if (productId == RCProductIds.goldMonthly) {
        aliases.addAll({'gold', 'gold_monthly'});
      }
    }
    return aliases;
  }

  Package? _findAndroidSubscriptionPackageByName(
    List<Package> packages,
    String productId,
  ) {
    if (kIsWeb || !Platform.isAndroid) return null;
    final isSparkPlus = productId == RCProductIds.sparkPlusMonthly;
    final isGold = productId == RCProductIds.goldMonthly;
    if (!isSparkPlus && !isGold) return null;

    final needle = isSparkPlus ? 'spark_plus' : 'gold';
    for (final package in packages) {
      final packageId = package.identifier.toLowerCase();
      final storeProductId = package.storeProduct.identifier.toLowerCase();
      if (packageId.contains(needle) || storeProductId.contains(needle)) {
        return package;
      }
    }
    return null;
  }

  String _platformLabel() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    return Platform.operatingSystem;
  }

  /// Restore previous purchases (required by App Store guidelines).
  Future<bool> restorePurchases() async {
    if (kIsWeb) return false;
    try {
      final customerInfo = await Purchases.restorePurchases();
      debugPrint(
        'REVENUECAT: restore completed — activeSubscriptions=${customerInfo.activeSubscriptions}',
      );
      // Sync the latest entitlements to Supabase
      await _syncCustomerInfoToSupabase(customerInfo);
      return true;
    } catch (e) {
      debugPrint('REVENUECAT: restore error — $e');
      return false;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // PRIVATE — Supabase sync (mirrors stripe_webhook logic exactly)
  // ─────────────────────────────────────────────────────────────

  Future<void> _handlePurchaseSuccess(
    String productId,
    PurchaseResult result,
  ) async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) {
      debugPrint('REVENUECAT: no authenticated user — skipping Supabase sync');
      return;
    }

    if (!kIsWeb && Platform.isAndroid) {
      await _recordGooglePlayPurchase(productId, result.storeTransaction);
      return;
    }

    // Bundle purchase
    if (_bundleSparkMap.containsKey(productId)) {
      await _creditBundleSparks(uid, productId);
      return;
    }

    // Subscription purchase
    if (_subscriptionTierMap.containsKey(productId)) {
      final tier = _subscriptionTierMap[productId]!;
      await _activateSubscription(uid, tier);
      return;
    }

    debugPrint('REVENUECAT: unknown productId=$productId — no Supabase update');
  }

  Future<void> _recordGooglePlayPurchase(
    String productId,
    StoreTransaction transaction,
  ) async {
    final providerOrderId = transaction.transactionIdentifier.trim();
    final storeProductId = transaction.productIdentifier.trim();
    final purchasedAt = transaction.purchaseDate.trim();

    if (providerOrderId.isEmpty) {
      throw Exception('Google Play purchase is missing a transaction id.');
    }

    final response = await Supabase.instance.client.rpc(
      'record_google_play_purchase',
      params: {
        'p_product_id': productId,
        'p_provider_order_id': providerOrderId,
        'p_provider_purchase_token': null,
        'p_store_product_id': storeProductId.isEmpty ? null : storeProductId,
        'p_purchased_at': purchasedAt.isEmpty ? null : purchasedAt,
        'p_metadata': {
          'revenuecat_store_product_id': storeProductId,
          'client_platform': 'android',
        },
      },
    );

    final responseMap = response is Map
        ? Map<String, dynamic>.from(response)
        : <String, dynamic>{};
    final success = responseMap['success'] == true;
    if (!success) {
      throw Exception('Google Play purchase could not be recorded.');
    }

    debugPrint(
      'REVENUECAT: Google Play purchase recorded — '
      'product=$productId, duplicate=${responseMap['duplicate'] == true}',
    );
  }

  /// Credit spark bundle — always adds, no cap (mirrors stripe_webhook).
  Future<void> _creditBundleSparks(String uid, String productId) async {
    final sparksToAdd = _bundleSparkMap[productId]!;
    try {
      final data = await Supabase.instance.client
          .from('users')
          .select('spark_balance')
          .eq('id', uid)
          .single();

      final currentBalance = (data['spark_balance'] as num?)?.toInt() ?? 0;
      final newBalance = currentBalance + sparksToAdd;

      await Supabase.instance.client
          .from('users')
          .update({'spark_balance': newBalance})
          .eq('id', uid);

      debugPrint(
        'REVENUECAT: credits added — product=$productId, added=$sparksToAdd, '
        'balance: $currentBalance → $newBalance',
      );
    } catch (e) {
      debugPrint('REVENUECAT: _creditBundleSparks error — $e');
    }
  }

  /// Activate subscription tier and credit initial sparks (mirrors stripe_webhook).
  Future<void> _activateSubscription(String uid, String tier) async {
    final allowance = _subscriptionSparkAllowance[tier] ?? 0;
    try {
      final data = await Supabase.instance.client
          .from('users')
          .select('spark_balance')
          .eq('id', uid)
          .single();

      final currentBalance = (data['spark_balance'] as num?)?.toInt() ?? 0;
      final newBalance = _calculateReplenishedBalance(
        currentBalance,
        allowance,
      );

      await Supabase.instance.client
          .from('users')
          .update({
            'subscription_tier': tier,
            'subscription_expires_at': DateTime.now()
                .add(const Duration(days: 30))
                .toIso8601String(),
            'spark_balance': newBalance,
            'spark_last_replenished_at': DateTime.now().toIso8601String(),
          })
          .eq('id', uid);

      debugPrint(
        'REVENUECAT: subscription activated — tier=$tier, '
        'balance: $currentBalance → $newBalance',
      );
    } catch (e) {
      debugPrint('REVENUECAT: _activateSubscription error — $e');
    }
  }

  /// Sync CustomerInfo entitlements to Supabase (used after restore).
  Future<void> _syncCustomerInfoToSupabase(CustomerInfo customerInfo) async {
    final uid = Supabase.instance.client.auth.currentUser?.id;
    if (uid == null) return;

    try {
      String tier = 'free';
      if (customerInfo.activeSubscriptions.contains(RCProductIds.goldMonthly)) {
        tier = 'gold';
      } else if (customerInfo.activeSubscriptions.contains(
        RCProductIds.sparkPlusMonthly,
      )) {
        tier = 'spark_plus';
      }

      if (tier != 'free') {
        await Supabase.instance.client
            .from('users')
            .update({
              'subscription_tier': tier,
              'subscription_expires_at': DateTime.now()
                  .add(const Duration(days: 30))
                  .toIso8601String(),
            })
            .eq('id', uid);
        debugPrint('REVENUECAT: restore synced tier=$tier for uid=$uid');
      }
    } catch (e) {
      debugPrint('REVENUECAT: _syncCustomerInfoToSupabase error — $e');
    }
  }

  /// Mirrors calculateReplenishedBalance from stripe_webhook/index.ts.
  int _calculateReplenishedBalance(int currentBalance, int allowance) {
    if (currentBalance >= _sparkReplenishmentCap) {
      return currentBalance;
    }
    final room = _sparkReplenishmentCap - currentBalance;
    final toAdd = allowance < room ? allowance : room;
    return currentBalance + toAdd;
  }
}
