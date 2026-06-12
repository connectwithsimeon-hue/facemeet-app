import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// ReferralService — handles all referral logic:
/// - Generating/fetching referral codes
/// - Awarding sparks on join and upgrade
/// - Username availability checks and updates
/// - Referral stats queries
class ReferralService {
  static ReferralService? _instance;
  static ReferralService get instance => _instance ??= ReferralService._();
  ReferralService._();

  SupabaseClient get _client => Supabase.instance.client;
  String? get _uid => _client.auth.currentUser?.id;

  // ─── Referral Code ───────────────────────────────────────────────────────

  /// Returns the current user's referral code, generating one if missing.
  Future<String?> getOrCreateReferralCode() async {
    final uid = _uid;
    if (uid == null) return null;

    final row = await _client
        .from('users')
        .select('referral_code, username')
        .eq('id', uid)
        .maybeSingle();

    if (row == null) return null;

    String? code = row['referral_code'] as String?;
    if (code != null && code.isNotEmpty) return code;

    // Generate a new code server-side
    try {
      final result = await _client.rpc(
        'generate_referral_code',
        params: {'user_id': uid},
      );
      code = result as String?;
      if (code != null) {
        await _client
            .from('users')
            .update({'referral_code': code})
            .eq('id', uid);
      }
    } catch (e) {
      debugPrint('REFERRAL: generate_referral_code error: $e');
    }
    return code;
  }

  /// Returns the referral link for the current user.
  Future<String> getReferralLink() async {
    final uid = _uid;
    if (uid == null) return 'https://app.facemeet.app/';

    final code = await getOrCreateReferralCode();
    if (code == null || code.isEmpty) return 'https://app.facemeet.app/';
    return 'https://app.facemeet.app/?ref=${Uri.encodeComponent(code)}';
  }

  // ─── Username ────────────────────────────────────────────────────────────

  /// Checks if a username is available (not taken by another user).
  Future<bool> isUsernameAvailable(String username) async {
    final uid = _uid;
    if (username.isEmpty) return false;
    try {
      final rows = await _client
          .from('users')
          .select('id')
          .eq('username', username.toLowerCase().trim());
      final list = rows as List;
      if (list.isEmpty) return true;
      // Available if the only match is the current user
      if (list.length == 1 && list[0]['id'] == uid) return true;
      return false;
    } catch (e) {
      debugPrint('REFERRAL: isUsernameAvailable error: $e');
      return false;
    }
  }

  /// Updates username and referral_code for the current user.
  Future<void> updateUsername(String username) async {
    final uid = _uid;
    if (uid == null) return;
    final normalized = username.toLowerCase().trim();
    await _client
        .from('users')
        .update({'username': normalized, 'referral_code': normalized})
        .eq('id', uid);
  }

  // ─── Referral Stats ──────────────────────────────────────────────────────

  /// Returns {friendsCount, sparksEarned} for the current user.
  Future<Map<String, int>> getReferralStats() async {
    final uid = _uid;
    if (uid == null) return {'friendsCount': 0, 'sparksEarned': 0};

    try {
      final row = await _client
          .from('users')
          .select('referral_code, spark_balance')
          .eq('id', uid)
          .maybeSingle();

      final code = row?['referral_code'] as String?;
      final sparkBalance = (row?['spark_balance'] as num?)?.toInt() ?? 0;

      int friendsCount = 0;
      if (code != null && code.isNotEmpty) {
        final referred = await _client
            .from('users')
            .select('id')
            .eq('referred_by', code);
        friendsCount = (referred as List).length;
      }

      return {'friendsCount': friendsCount, 'sparksEarned': sparkBalance};
    } catch (e) {
      debugPrint('REFERRAL: getReferralStats error: $e');
      return {'friendsCount': 0, 'sparksEarned': 0};
    }
  }

  // ─── Referral Tracking ───────────────────────────────────────────────────

  /// Called after onboarding completes — attributes the referral and awards
  /// 1 Spark to the referrer through an idempotent Edge Function.
  Future<bool> applyReferralOnJoin(String referralCode) async {
    final uid = _uid;
    if (uid == null || referralCode.trim().isEmpty) return false;

    try {
      final response = await _client.functions.invoke(
        'apply_referral',
        body: {'referral_code': referralCode.trim()},
      );
      final data = response.data;
      debugPrint('REFERRAL: apply result=$data');
      if (data is Map && data['success'] == true) {
        debugPrint('REFERRAL: Applied pending referral yes');
        return true;
      }
      debugPrint('REFERRAL: applyReferralOnJoin returned no success');
      return false;
    } catch (e) {
      debugPrint('REFERRAL: applyReferralOnJoin error: $e');
      return false;
    }
  }

  /// Called when a referred user upgrades to Spark+ — awards 3 sparks to referrer.
  Future<void> applyReferralOnUpgrade() async {
    final uid = _uid;
    if (uid == null) return;
    try {
      await _client.rpc(
        'award_referral_spark_on_upgrade',
        params: {'p_upgraded_user_id': uid},
      );
      debugPrint('REFERRAL: Awarded upgrade bonus for user $uid');
    } catch (e) {
      debugPrint('REFERRAL: applyReferralOnUpgrade error: $e');
    }
  }

  // ─── Notification helper ─────────────────────────────────────────────────

  /// Checks if the current user has a pending referral notification to show.
  /// Returns the referrer's first_name if a new referral was just processed.
  Future<String?> checkPendingReferralNotification() async {
    // This is handled via Realtime in the main shell — placeholder for future use.
    return null;
  }
}
