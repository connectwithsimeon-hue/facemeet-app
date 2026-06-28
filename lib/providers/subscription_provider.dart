import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class SubscriptionProvider extends ChangeNotifier {
  String _subscriptionTier = 'free';
  int _sparkBalance = 3;

  String get subscriptionTier => _subscriptionTier;
  int get sparkBalance => _sparkBalance;
  bool get isSparkPlus =>
      _subscriptionTier == 'spark_plus' || _subscriptionTier == 'gold';
  bool get isGold => _subscriptionTier == 'gold';

  /// Maximum spark balance from tier replenishment only.
  /// Bundles always add regardless of this cap.
  static const int replenishmentCap = 50;

  Future<void> refreshSubscription() async {
    try {
      final uid = Supabase.instance.client.auth.currentUser?.id;
      if (uid == null) return;

      final data = await Supabase.instance.client
          .from('users')
          .select('subscription_tier, spark_balance, spark_last_replenished_at')
          .eq('id', uid)
          .maybeSingle();

      if (data != null) {
        _subscriptionTier = data['subscription_tier'] as String? ?? 'free';
        _sparkBalance = (data['spark_balance'] as num?)?.toInt() ?? 3;
        notifyListeners();
        debugPrint(
          'SUBSCRIPTION: refreshed — tier=$_subscriptionTier, balance=$_sparkBalance',
        );

        // Attempt replenishment after refreshing
        await _replenishSparksIfDue(uid, data);
      }
    } catch (e) {
      debugPrint('SUBSCRIPTION: refresh error — $e');
    }
  }

  /// Replenish sparks based on tier and time since last replenishment.
  /// - Free: no recurring replenishment; starter Sparks are granted once only.
  /// - Spark+: +2 every day at midnight
  /// - Gold: +5 every day at midnight
  /// Cap: tier replenishment only adds up to 50. Bundles are uncapped.
  Future<void> _replenishSparksIfDue(
    String uid,
    Map<String, dynamic> userData,
  ) async {
    try {
      final tier = userData['subscription_tier'] as String? ?? 'free';
      final currentBalance = (userData['spark_balance'] as num?)?.toInt() ?? 0;
      final lastReplenishedStr =
          userData['spark_last_replenished_at'] as String?;

      final now = DateTime.now();
      final todayDate = DateTime(now.year, now.month, now.day);

      DateTime? lastReplenished;
      if (lastReplenishedStr != null && lastReplenishedStr.isNotEmpty) {
        lastReplenished = DateTime.tryParse(lastReplenishedStr);
      }

      if (tier == 'free') {
        if (lastReplenished == null) {
          debugPrint(
            'REPLENISH: Free user has no last_replenished timestamp — marking initialized without adding recurring Sparks',
          );
          await Supabase.instance.client
              .from('users')
              .update({'spark_last_replenished_at': now.toIso8601String()})
              .eq('id', uid);
        }
        debugPrint(
          'REPLENISH: Free users do not receive recurring Sparks; starter Sparks are once-only',
        );
        return;
      }

      int sparksToAdd = 0;
      bool shouldReplenish = false;

      if (tier == 'gold') {
        // Gold: +5 per day
        final lastReplenishedDate = lastReplenished != null
            ? DateTime(
                lastReplenished.year,
                lastReplenished.month,
                lastReplenished.day,
              )
            : null;
        shouldReplenish =
            lastReplenishedDate == null ||
            lastReplenishedDate.isBefore(todayDate);
        sparksToAdd = 5;
        debugPrint(
          'REPLENISH: Gold — lastReplenished=$lastReplenishedDate, today=$todayDate, shouldReplenish=$shouldReplenish',
        );
      } else if (tier == 'spark_plus') {
        // Spark+: +2 per day
        final lastReplenishedDate = lastReplenished != null
            ? DateTime(
                lastReplenished.year,
                lastReplenished.month,
                lastReplenished.day,
              )
            : null;
        shouldReplenish =
            lastReplenishedDate == null ||
            lastReplenishedDate.isBefore(todayDate);
        sparksToAdd = 2;
        debugPrint(
          'REPLENISH: Spark+ — lastReplenished=$lastReplenishedDate, today=$todayDate, shouldReplenish=$shouldReplenish',
        );
      }

      if (!shouldReplenish || sparksToAdd <= 0) {
        debugPrint('REPLENISH: No replenishment due for uid=$uid (tier=$tier)');
        return;
      }

      // Apply 50-cap for tier replenishment
      if (currentBalance >= replenishmentCap) {
        debugPrint(
          'REPLENISH: Balance=$currentBalance already at cap=$replenishmentCap — skipping replenishment for uid=$uid',
        );
        // Still update last_replenished_at so we don't check again today
        await Supabase.instance.client
            .from('users')
            .update({'spark_last_replenished_at': now.toIso8601String()})
            .eq('id', uid);
        return;
      }

      // Only add up to the cap
      final room = replenishmentCap - currentBalance;
      final actualAdd = sparksToAdd < room ? sparksToAdd : room;
      final newBalance = currentBalance + actualAdd;

      debugPrint(
        'REPLENISH: ✅ Adding $actualAdd sparks (of $sparksToAdd) to uid=$uid (tier=$tier). '
        'Balance: $currentBalance → $newBalance (cap=$replenishmentCap)',
      );

      await Supabase.instance.client
          .from('users')
          .update({
            'spark_balance': newBalance,
            'spark_last_replenished_at': now.toIso8601String(),
          })
          .eq('id', uid);

      _sparkBalance = newBalance;
      notifyListeners();
    } catch (e) {
      debugPrint('REPLENISH: Error during replenishment — $e');
    }
  }
}
