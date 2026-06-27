import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../models/location_models.dart';
import 'content_filter_service.dart';

class SparkSessionEntryEligibility {
  final bool canEnter;
  final String reason;
  final String? sessionStatus;
  final bool endedAtExists;
  final bool chatUnlocked;
  final bool feedbackComplete;

  const SparkSessionEntryEligibility({
    required this.canEnter,
    required this.reason,
    this.sessionStatus,
    this.endedAtExists = false,
    this.chatUnlocked = false,
    this.feedbackComplete = false,
  });
}

class SupabaseService {
  static SupabaseService? _instance;
  static SupabaseService get instance => _instance ??= SupabaseService._();

  SupabaseService._();

  static const String supabaseUrl = 'https://vbaiivsvjdntzaffboue.supabase.co';
  static const String webAuthCallbackUrl =
      'https://app.facemeet.app/auth-callback.html';
  static const String webPasswordResetUrl =
      'https://app.facemeet.app/reset-password.html';
  static const String supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZiYWlpdnN2amRudHphZmZib3VlIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzYxODk2NjQsImV4cCI6MjA5MTc2NTY2NH0.ZNzIdnuQXf69nLmo7FafLASNOG6_2m36JZQKCIQzK-w';

  // Initialize Supabase - call this in main()
  static Future<void> initialize() async {
    await Supabase.initialize(
      url: supabaseUrl,
      anonKey: supabaseAnonKey,
      authOptions: FlutterAuthClientOptions(
        authFlowType: AuthFlowType.pkce,
        autoRefreshToken: true,
        detectSessionInUri: false,
      ),
    );
  }

  // Get Supabase client
  SupabaseClient get client => Supabase.instance.client;

  // Current authenticated user
  User? get currentUser => client.auth.currentUser;
  String? get currentUserId => client.auth.currentUser?.id;

  // ============================================================
  // AUTH
  // ============================================================

  /// Sign up with email and password
  Future<AuthResponse> signUp({
    required String email,
    required String password,
    String? firstName,
  }) async {
    final redirectTo = kIsWeb
        ? webAuthCallbackUrl
        : 'facemeet://login-callback';
    debugPrint(
      'AUTH SIGNUP: email verification redirect configured for ${kIsWeb ? 'web' : 'native'}',
    );
    return await client.auth.signUp(
      email: email,
      password: password,
      emailRedirectTo: redirectTo,
      data: firstName != null ? {'first_name': firstName} : null,
    );
  }

  /// Sign in with email and password
  Future<AuthResponse> signIn({
    required String email,
    required String password,
  }) async {
    return await client.auth.signInWithPassword(
      email: email,
      password: password,
    );
  }

  /// Sign out
  Future<void> signOut() async {
    if (!kIsWeb) {
      try {
        final googleSignIn = GoogleSignIn();
        if (await googleSignIn.isSignedIn()) {
          await googleSignIn.signOut();
        }
      } catch (_) {}
    }
    await client.auth.signOut();
  }

  /// Permanently delete the current user's FaceMeet account via a Supabase
  /// Edge Function. The function owns all service-role work; the app only
  /// sends the user's authenticated session and explicit confirmation.
  Future<void> deleteAccount({required String confirmation}) async {
    final uid = currentUserId;
    if (uid == null) {
      throw Exception('You must be signed in to delete your account.');
    }
    if (confirmation.trim().toUpperCase() != 'DELETE') {
      throw Exception('Type DELETE to confirm account deletion.');
    }

    try {
      debugPrint('ACCOUNT DELETE: invoking delete_account for current user');
      final response = await client.functions.invoke(
        'delete_account',
        body: {'confirmation': 'DELETE'},
      );

      final data = response.data;
      if (data is Map && data['error'] != null) {
        throw Exception(data['error'].toString());
      }
      debugPrint('ACCOUNT DELETE: delete_account completed');
    } catch (e) {
      debugPrint('ACCOUNT DELETE: delete_account failed — $e');
      rethrow;
    }
  }

  /// Google Sign-In
  Future<bool> signInWithGoogle() async {
    if (kIsWeb) {
      await client.auth.signInWithOAuth(OAuthProvider.google);
      return true;
    } else {
      const webClientId = String.fromEnvironment(
        'GOOGLE_WEB_CLIENT_ID',
        defaultValue: '',
      );
      final googleSignIn = GoogleSignIn(serverClientId: webClientId);
      GoogleSignInAccount? googleUser = await googleSignIn.signInSilently();
      googleUser ??= await googleSignIn.signIn();
      if (googleUser == null) return false;
      final googleAuth = await googleUser.authentication;
      final idToken = googleAuth.idToken;
      if (idToken == null) throw AuthException('No ID Token found.');
      final response = await client.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: googleAuth.accessToken,
      );
      return response.user != null;
    }
  }

  /// Reset password
  Future<void> resetPassword(String email) async {
    if (kIsWeb) {
      await client.auth.resetPasswordForEmail(
        email,
        redirectTo: webPasswordResetUrl,
      );
      return;
    }
    await client.auth.resetPasswordForEmail(email);
  }

  /// Auth state stream
  Stream<AuthState> get authStateChanges => client.auth.onAuthStateChange;

  // ============================================================
  // USERS (PROFILES)
  // ============================================================

  static const String defaultConnectionIntent = 'dating';

  static const Set<String> connectionIntentValues = {
    'dating',
    'friendship',
    'professional',
    // Kept for compatibility with older deployed clients. New app UI treats
    // this as friendship and no longer creates it.
    'events',
    'open_to_all',
  };

  static String normalizeConnectionIntent(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == 'events') return 'friendship';
    if (normalized != null && connectionIntentValues.contains(normalized)) {
      return normalized;
    }
    return defaultConnectionIntent;
  }

  static String connectionIntentLabel(String? value) {
    switch (normalizeConnectionIntent(value)) {
      case 'friendship':
        return 'Friendship';
      case 'professional':
        return 'Professional Connections';
      case 'open_to_all':
        return 'Open to All';
      case 'dating':
      default:
        return 'Dating';
    }
  }

  static String connectionIntentCardLabel(String? value) {
    final normalized = normalizeConnectionIntent(value);
    if (normalized == 'open_to_all') return 'Open to All';
    return 'Open to ${connectionIntentLabel(normalized)}';
  }

  static const Set<String> sparkTypeValues = {
    'dating',
    'friendship',
    'professional',
    // Kept for compatibility with older deployed clients. New app UI treats
    // this as friendship and no longer creates it.
    'event',
  };

  static String normalizeSparkType(String? value) {
    final normalized = value?.trim().toLowerCase();
    if (normalized == 'event') return 'friendship';
    if (normalized != null && sparkTypeValues.contains(normalized)) {
      return normalized;
    }
    return 'dating';
  }

  static String sparkTypeForConnectionIntent(String? value) {
    switch (normalizeConnectionIntent(value)) {
      case 'friendship':
        return 'friendship';
      case 'professional':
        return 'professional';
      case 'open_to_all':
      case 'dating':
      default:
        return 'dating';
    }
  }

  static String sparkTypeLabel(String? value) {
    switch (normalizeSparkType(value)) {
      case 'friendship':
        return 'Friendship Spark';
      case 'professional':
        return 'Professional Connection Spark';
      case 'dating':
      default:
        return 'Dating Spark';
    }
  }

  /// Get current user's profile
  Future<Map<String, dynamic>?> getCurrentUserProfile() async {
    final uid = currentUserId;
    if (uid == null) return null;
    final response = await client
        .from('users')
        .select()
        .eq('id', uid)
        .maybeSingle();
    return response;
  }

  /// Ensure the authenticated user has exactly one initialized public.users row.
  /// The welcome Spark grant is idempotent: existing rows are never incremented.
  Future<void> ensureCurrentUserInitialized() async {
    final uid = currentUserId;
    final email = currentUser?.email;
    if (uid == null) return;

    final now = DateTime.now().toIso8601String();

    try {
      final existing = await client
          .from('users')
          .select('id, email, spark_balance, spark_last_replenished_at')
          .eq('id', uid)
          .maybeSingle();

      if (existing == null) {
        if (email == null || email.isEmpty) {
          debugPrint(
            'WELCOME SPARKS: new user initialized skipped — missing auth email',
          );
          return;
        }
        await client.from('users').insert({
          'id': uid,
          'email': email,
          'spark_balance': 3,
          'spark_last_replenished_at': now,
        });
        debugPrint('WELCOME SPARKS: new user initialized — uid=$uid');
        debugPrint('WELCOME SPARKS: welcome sparks granted — amount=3');
        return;
      }

      final updates = <String, dynamic>{};
      final balance = (existing['spark_balance'] as num?)?.toInt();
      final lastReplenished = existing['spark_last_replenished_at'] as String?;

      debugPrint(
        'WELCOME SPARKS: existing spark balance found — uid=$uid, balance=${balance ?? 'null'}',
      );

      if (balance == null) {
        updates['spark_balance'] = 3;
        debugPrint('WELCOME SPARKS: welcome sparks granted — amount=3');
      } else {
        debugPrint(
          'WELCOME SPARKS: welcome sparks skipped because already granted',
        );
      }

      if (lastReplenished == null || lastReplenished.isEmpty) {
        updates['spark_last_replenished_at'] = now;
      }

      if (updates.isNotEmpty) {
        await client.from('users').update(updates).eq('id', uid);
      }
    } catch (e) {
      debugPrint('WELCOME SPARKS: initialization error — $e');
    }
  }

  /// Get a user profile by ID
  Future<Map<String, dynamic>?> getUserProfile(String userId) async {
    final response = await client
        .from('users')
        .select()
        .eq('id', userId)
        .maybeSingle();
    return response;
  }

  bool isUserFacingProfileAvailable(Map<String, dynamic>? profile) {
    if (profile == null) return false;
    final accountStatus =
        profile['account_status']?.toString().trim().toLowerCase() ?? 'active';
    final visibilityStatus =
        profile['profile_visibility_status']?.toString().trim().toLowerCase() ??
        'visible';
    final moderationStatus =
        profile['moderation_status']?.toString().trim().toLowerCase() ?? '';

    return accountStatus == 'active' &&
        visibilityStatus == 'visible' &&
        moderationStatus == 'approved';
  }

  Future<bool> isUserFacingProfileAvailableById(String userId) async {
    final profile = await getUserProfile(userId);
    return isUserFacingProfileAvailable(profile);
  }

  /// Update current user's profile
  Future<void> updateUserProfile(Map<String, dynamic> data) async {
    final uid = currentUserId;
    if (uid == null) return;
    ContentFilterService.ensureProfileFieldsAllowed(data);
    await client.from('users').update(data).eq('id', uid);
  }

  Future<Map<String, dynamic>> enableMyPublicProfile() async {
    final uid = currentUserId;
    if (uid == null) {
      throw Exception('You must be signed in to share your profile.');
    }

    final response = await client.rpc('enable_my_public_profile');
    final row = _firstRpcRow(response);
    final slug = row['slug']?.toString().trim();
    if (slug == null || slug.isEmpty) {
      throw Exception('Could not create your public profile link.');
    }

    return {
      'slug': slug,
      'public_url': 'https://facemeet.app/p/$slug',
      'public_path': row['public_path']?.toString() ?? '/p/$slug',
      'public_profile_enabled': row['public_profile_enabled'] == true,
    };
  }

  Future<void> disableMyPublicProfile() async {
    final uid = currentUserId;
    if (uid == null) {
      throw Exception('You must be signed in to manage your public profile.');
    }

    await client.rpc('disable_my_public_profile');
  }

  Map<String, dynamic> _firstRpcRow(dynamic response) {
    if (response is List && response.isNotEmpty && response.first is Map) {
      return Map<String, dynamic>.from(response.first as Map);
    }
    if (response is Map) {
      return Map<String, dynamic>.from(response);
    }
    return <String, dynamic>{};
  }

  /// Update onboarding step data and optionally mark complete
  Future<void> saveOnboardingStep(
    Map<String, dynamic> data, {
    bool markComplete = false,
  }) async {
    final uid = currentUserId;
    if (uid == null) return;
    ContentFilterService.ensureProfileFieldsAllowed(data);
    await ensureCurrentUserInitialized();

    if (markComplete) {
      data['onboarding_complete'] = true;
    }

    // Log the exact payload being sent
    debugPrint('ONBOARDING SAVE PAYLOAD — uid: $uid, data: $data');

    Map<String, dynamic>? existingProfile;
    try {
      existingProfile = await client
          .from('users')
          .select('id')
          .eq('id', uid)
          .maybeSingle();
    } catch (e) {
      final errMsg = _extractErrorMessage(e);
      debugPrint(
        'ONBOARDING SAVE ERROR [select check] — uid: $uid, data: $data, error: $e${_postgrestDetails(e)}',
      );
      throw Exception('Save failed: $errMsg');
    }

    if (existingProfile != null) {
      try {
        await client.from('users').update(data).eq('id', uid);
      } catch (e) {
        final errMsg = _extractErrorMessage(e);
        debugPrint(
          'ONBOARDING SAVE ERROR [update] — uid: $uid, data: $data, error: $e${_postgrestDetails(e)}',
        );
        throw Exception('Save failed: $errMsg');
      }
      return;
    }

    final email = currentUser?.email;
    if (email == null || email.isEmpty) {
      throw Exception(
        'Unable to save onboarding: authenticated user email is missing.',
      );
    }

    try {
      await client.from('users').insert({
        'id': uid,
        'email': email,
        'spark_balance': 3,
        'spark_last_replenished_at': DateTime.now().toIso8601String(),
        ...data,
      });
      debugPrint('WELCOME SPARKS: new user initialized — uid=$uid');
      debugPrint('WELCOME SPARKS: welcome sparks granted — amount=3');
    } catch (e) {
      final errMsg = _extractErrorMessage(e);
      debugPrint(
        'ONBOARDING SAVE ERROR [insert] — uid: $uid, email: $email, data: $data, error: $e${_postgrestDetails(e)}',
      );
      throw Exception('Save failed: $errMsg');
    }
  }

  /// Extract a human-readable error message from any exception type
  String _extractErrorMessage(Object e) {
    if (e is PostgrestException) {
      return e.message;
    }
    return e.toString();
  }

  /// Build a detailed string of PostgrestException fields for logging
  String _postgrestDetails(Object e) {
    if (e is PostgrestException) {
      return ' | PostgrestException — code: ${e.code}, message: ${e.message}, hint: ${e.hint}, details: ${e.details}';
    }
    return '';
  }

  /// Test basic Supabase connectivity by selecting 1 row from users table.
  /// Call this on app open to confirm the app can reach Supabase.
  Future<void> testSupabaseConnection() async {
    try {
      await client.from('users').select('id').limit(1);
      debugPrint(
        'SUPABASE CONNECTION TEST — OK: successfully queried users table',
      );
    } catch (e) {
      debugPrint(
        'SUPABASE CONNECTION TEST FAILED — error: $e${_postgrestDetails(e)}',
      );
    }
  }

  /// Check if current user has completed onboarding
  Future<bool> isOnboardingComplete() async {
    final profile = await getCurrentUserProfile();
    return profile?['onboarding_complete'] == true;
  }

  /// Get discovery feed ranked and filtered server-side.
  Future<List<Map<String, dynamic>>> getDiscoveryFeed({
    String connectionIntentFilter = 'all',
  }) async {
    final uid = currentUserId;
    if (uid == null) return [];
    await ensureCurrentUserInitialized();

    final response = await client.rpc(
      'get_discovery_feed',
      params: {
        'p_limit': 20,
        'p_connection_intent_filter': connectionIntentFilter,
      },
    );
    final profiles = List<Map<String, dynamic>>.from(
      response as List? ?? const [],
    );

    debugPrint(
      'DISCOVERY_FEED: server-ranked profiles found = ${profiles.length}',
    );

    return profiles;
  }

  Future<List<LocationCountry>> getLocationCountries() async {
    final rows = await client
        .from('location_countries')
        .select('code, name')
        .eq('enabled', true)
        .order('sort_order')
        .order('name');
    return List<Map<String, dynamic>>.from(
      rows as List? ?? const [],
    ).map(LocationCountry.fromMap).where((country) {
      return country.code.isNotEmpty && country.name.isNotEmpty;
    }).toList();
  }

  Future<List<LocationRegion>> getLocationRegions(String countryCode) async {
    if (countryCode.trim().isEmpty) return const [];
    final rows = await client
        .from('location_regions')
        .select('id, country_code, region_code, name')
        .eq('enabled', true)
        .eq('country_code', countryCode.toUpperCase())
        .order('sort_order')
        .order('name');
    return List<Map<String, dynamic>>.from(
      rows as List? ?? const [],
    ).map(LocationRegion.fromMap).where((region) {
      return region.id.isNotEmpty && region.name.isNotEmpty;
    }).toList();
  }

  Future<List<LocationPlace>> searchLocations({
    required String query,
    String? countryCode,
    String? regionId,
    int limit = 20,
  }) async {
    final response = await client.rpc(
      'search_locations',
      params: {
        'p_query': query,
        'p_country_code': countryCode,
        'p_region_id': regionId,
        'p_limit': limit,
      },
    );
    return List<Map<String, dynamic>>.from(
      response as List? ?? const [],
    ).map(LocationPlace.fromMap).where((place) {
      return place.id.isNotEmpty && place.displayName.isNotEmpty;
    }).toList();
  }

  /// Update last_active timestamp
  Future<void> updateLastActive() async {
    final uid = currentUserId;
    if (uid == null) return;
    await client
        .from('users')
        .update({'last_active': DateTime.now().toIso8601String()})
        .eq('id', uid);
  }

  // ============================================================
  // EVENTS
  // ============================================================

  Future<List<Map<String, dynamic>>> getPublishedEvents() async {
    final response = await client.rpc('get_published_events');
    return List<Map<String, dynamic>>.from(response as List? ?? const []);
  }

  Future<List<Map<String, dynamic>>> getMyAccessibleEvents() async {
    final response = await client.rpc('get_my_accessible_events');
    return List<Map<String, dynamic>>.from(response as List? ?? const []);
  }

  Future<List<Map<String, dynamic>>> getFeaturedEvents() async {
    final response = await client.rpc('get_featured_events');
    return List<Map<String, dynamic>>.from(response as List? ?? const []);
  }

  Future<List<Map<String, dynamic>>> getEventsByCity(String city) async {
    final response = await client.rpc(
      'get_events_by_city',
      params: {'p_city': city},
    );
    return List<Map<String, dynamic>>.from(response as List? ?? const []);
  }

  Future<Map<String, String>> getCurrentUserEventStatuses() async {
    final uid = currentUserId;
    if (uid == null) return {};

    final rows = await client
        .from('event_rsvps')
        .select('event_id,status')
        .eq('user_id', uid);

    final statuses = <String, String>{};
    for (final row in List<Map<String, dynamic>>.from(rows)) {
      final eventId = row['event_id']?.toString();
      final status = row['status']?.toString();
      if (eventId != null && status != null) {
        statuses[eventId] = status;
      }
    }
    return statuses;
  }

  Future<List<Map<String, dynamic>>> getMyEventAccessDetails() async {
    try {
      final response = await client.rpc('get_my_event_access_details');
      return List<Map<String, dynamic>>.from(response as List? ?? const []);
    } catch (e) {
      debugPrint(
        'SUPABASE getMyEventAccessDetails: failed to load event access details — $e',
      );
      return const [];
    }
  }

  Future<Map<String, dynamic>?> getEventTicketForUser(String eventId) async {
    try {
      final response = await client.rpc(
        'get_event_ticket_for_user',
        params: {'p_event_id': eventId},
      );
      final rows = List<Map<String, dynamic>>.from(
        response as List? ?? const [],
      );
      if (rows.isEmpty) return null;
      return rows.first;
    } catch (e) {
      debugPrint('SUPABASE getEventTicketForUser: failed to load ticket — $e');
      return null;
    }
  }

  Future<Map<String, dynamic>?> getMyEventPairingPreferences(
    String eventId,
  ) async {
    final response = await client.rpc(
      'get_my_event_pairing_preferences',
      params: {'p_event_id': eventId},
    );
    if (response == null) return null;
    if (response is List) {
      if (response.isEmpty) return null;
      return Map<String, dynamic>.from(response.first as Map);
    }
    return Map<String, dynamic>.from(response as Map);
  }

  Future<List<Map<String, dynamic>>> getMyEligibleEventMatches(
    String eventId,
  ) async {
    final response = await client.rpc(
      'get_my_eligible_event_matches',
      params: {'p_event_id': eventId},
    );
    return List<Map<String, dynamic>>.from(response as List? ?? const []);
  }

  Future<Map<String, dynamic>> saveMyEventPairingPreferences({
    required String eventId,
    required bool openToNewIntro,
    required bool attendWithOpenSocialAccess,
    required List<String> selectedMatchIds,
  }) async {
    final response = await client.rpc(
      'save_my_event_pairing_preferences',
      params: {
        'p_event_id': eventId,
        'p_open_to_new_intro': openToNewIntro,
        'p_attend_with_open_social_access': attendWithOpenSocialAccess,
        'p_selected_match_ids': selectedMatchIds,
      },
    );
    if (response is List) {
      if (response.isEmpty) return const {};
      return Map<String, dynamic>.from(response.first as Map);
    }
    return Map<String, dynamic>.from(response as Map? ?? const {});
  }

  Future<String?> getUserEventStatus(String userId, String eventId) async {
    final response = await client.rpc(
      'get_user_event_status',
      params: {'p_user_id': userId, 'p_event_id': eventId},
    );
    return response?.toString();
  }

  Future<Map<String, dynamic>> requestEventInvite(
    String eventId,
    String userId,
  ) async {
    final response = await client.rpc(
      'request_event_invite',
      params: {'p_event_id': eventId, 'p_user_id': userId},
    );
    return Map<String, dynamic>.from(response as Map? ?? const {});
  }

  Future<Map<String, dynamic>> withdrawEventRequest(String eventId) async {
    final response = await client.rpc(
      'withdraw_event_request',
      params: {'p_event_id': eventId},
    );
    return Map<String, dynamic>.from(response as Map? ?? const {});
  }

  Future<bool> hasChatUnlockedMatch() async {
    final uid = currentUserId;
    if (uid == null) return false;

    try {
      final row = await client
          .from('matches')
          .select('id')
          .or('user_1_id.eq.$uid,user_2_id.eq.$uid')
          .eq('status', 'chat_unlocked')
          .limit(1)
          .maybeSingle();
      return row != null;
    } catch (e) {
      debugPrint(
        'SUPABASE hasChatUnlockedMatch: failed to check eligibility — $e',
      );
      return false;
    }
  }

  // ============================================================
  // SAFETY / MODERATION
  // ============================================================

  Future<void> submitUserReport({
    required String reportedUserId,
    required String reason,
    String? details,
    required String source,
    String? matchId,
  }) async {
    final uid = currentUserId;
    if (uid == null || reportedUserId.isEmpty || reportedUserId == uid) {
      return;
    }

    final detailsFlagged = ContentFilterService.containsObjectionableText(
      details,
    );

    final report = await client
        .from('user_reports')
        .insert({
          'reporter_user_id': uid,
          'reported_user_id': reportedUserId,
          'reason': reason,
          'details': details,
          'source': source,
          'match_id': matchId,
          'status': 'pending',
          'details_flagged': detailsFlagged,
        })
        .select('id')
        .single();

    await _createModerationEvent(
      eventType: 'user_report',
      priority: 'high',
      targetUserId: reportedUserId,
      reportId: report['id'] as String?,
      source: source,
      matchId: matchId,
      details: {'reason': reason, 'details_flagged': detailsFlagged},
    );
  }

  Future<void> blockUser({
    required String blockedUserId,
    required String source,
    String? matchId,
  }) async {
    final uid = currentUserId;
    if (uid == null || blockedUserId.isEmpty || blockedUserId == uid) return;

    final existing = await client
        .from('blocked_users')
        .select('id')
        .eq('blocker_user_id', uid)
        .eq('blocked_user_id', blockedUserId)
        .maybeSingle();

    String? blockRowId = existing?['id'] as String?;
    if (blockRowId == null) {
      final inserted = await client
          .from('blocked_users')
          .insert({
            'blocker_user_id': uid,
            'blocked_user_id': blockedUserId,
            'source': source,
            'match_id': matchId,
          })
          .select('id')
          .single();
      blockRowId = inserted['id'] as String?;
    }

    await _createModerationEvent(
      eventType: 'user_block',
      priority: 'high',
      targetUserId: blockedUserId,
      blockedUserRowId: blockRowId,
      source: source,
      matchId: matchId,
      details: {'action': 'block'},
    );
  }

  Future<Set<String>> getBlockedUserIdsForCurrentUser() async {
    final uid = currentUserId;
    if (uid == null) return <String>{};

    final rows = await client
        .from('blocked_users')
        .select('blocker_user_id, blocked_user_id')
        .or('blocker_user_id.eq.$uid,blocked_user_id.eq.$uid');

    final blockedIds = <String>{};
    for (final row in rows as List) {
      final blockerId = row['blocker_user_id'] as String?;
      final blockedId = row['blocked_user_id'] as String?;
      if (blockerId == uid && blockedId != null) blockedIds.add(blockedId);
      if (blockedId == uid && blockerId != null) blockedIds.add(blockerId);
    }
    return blockedIds;
  }

  Future<bool> hasBlockBetween(String otherUserId) async {
    final uid = currentUserId;
    if (uid == null || otherUserId.isEmpty) return false;

    final rows = await client
        .from('blocked_users')
        .select('id')
        .or(
          'and(blocker_user_id.eq.$uid,blocked_user_id.eq.$otherUserId),and(blocker_user_id.eq.$otherUserId,blocked_user_id.eq.$uid)',
        )
        .limit(1);

    return (rows as List).isNotEmpty;
  }

  Future<void> _createModerationEvent({
    required String eventType,
    required String priority,
    required String targetUserId,
    String? reportId,
    String? blockedUserRowId,
    required String source,
    String? matchId,
    Map<String, dynamic>? details,
  }) async {
    final uid = currentUserId;
    if (uid == null) return;

    try {
      await client.from('moderation_events').insert({
        'event_type': eventType,
        'priority': priority,
        'actor_user_id': uid,
        'target_user_id': targetUserId,
        'report_id': reportId,
        'blocked_user_id': blockedUserRowId,
        'source': source,
        'match_id': matchId,
        'details': details ?? <String, dynamic>{},
        'status': 'pending',
        'admin_email': 'support@facemeet.app',
      });
      debugPrint('MODERATION: queued $eventType for source=$source');
    } catch (e) {
      debugPrint('MODERATION: failed to queue $eventType — $e');
    }
  }

  // ============================================================
  // INTERACTIONS
  // ============================================================

  /// Save a spark or skip interaction
  Future<Map<String, dynamic>?> saveInteraction({
    required String toUserId,
    required String actionType, // 'spark' or 'skip'
    String? sparkType,
  }) async {
    final uid = currentUserId;
    if (uid == null) return null;
    await ensureCurrentUserInitialized();

    if (await hasBlockBetween(toUserId)) {
      throw Exception('This user is blocked.');
    }

    final target = await client
        .from('users')
        .select('id')
        .eq('id', toUserId)
        .maybeSingle();
    if (target == null) {
      debugPrint(
        'DISCOVERY_SPARK: stale profile skipped — target user missing from public.users',
      );
      return null;
    }

    final payload = {
      'from_user_id': uid,
      'to_user_id': toUserId,
      'action_type': actionType,
      if (actionType == 'spark') 'spark_type': normalizeSparkType(sparkType),
    };

    final response = await client
        .from('interactions')
        .insert(payload)
        .select()
        .single();

    return response;
  }

  /// Check if there is a mutual spark between current user and another
  Future<bool> checkMutualSpark(String otherUserId) async {
    final uid = currentUserId;
    if (uid == null) return false;

    // Check if other user has sparked current user
    final response = await client
        .from('interactions')
        .select('id')
        .eq('from_user_id', otherUserId)
        .eq('to_user_id', uid)
        .eq('action_type', 'spark')
        .maybeSingle();

    return response != null;
  }

  /// Check if a match already exists between two users (to avoid duplicates)
  Future<Map<String, dynamic>?> getExistingMatch({
    required String user1Id,
    required String user2Id,
  }) async {
    // Check both orderings
    final r1 = await client
        .from('matches')
        .select()
        .eq('user_1_id', user1Id)
        .eq('user_2_id', user2Id)
        .maybeSingle();
    if (r1 != null) return r1;

    final r2 = await client
        .from('matches')
        .select()
        .eq('user_1_id', user2Id)
        .eq('user_2_id', user1Id)
        .maybeSingle();
    return r2;
  }

  // ============================================================
  // MATCHES
  // ============================================================

  /// Create a match record
  Future<Map<String, dynamic>?> createMatch({
    required String user1Id,
    required String user2Id,
  }) async {
    final uid = currentUserId;
    final otherUserId = user1Id == uid ? user2Id : user1Id;
    if (uid != null && await hasBlockBetween(otherUserId)) {
      return null;
    }

    final response = await client
        .from('matches')
        .insert({
          'user_1_id': user1Id,
          'user_2_id': user2Id,
          'status': 'matched_pending_session',
        })
        .select()
        .single();
    return response;
  }

  /// Get all matches for current user
  Future<List<Map<String, dynamic>>> getMyMatches() async {
    final uid = currentUserId;
    if (uid == null) return [];

    final response = await client
        .from('matches')
        .select()
        .or('user_1_id.eq.$uid,user_2_id.eq.$uid')
        .order('created_at', ascending: false);

    final visibleMatches = _excludeBlockedMatches(
      List<Map<String, dynamic>>.from(response as List),
      uid,
      await getBlockedUserIdsForCurrentUser(),
    );
    return _excludeUnavailableMatches(visibleMatches, uid);
  }

  /// Get pending mutual matches (matched_pending_session or session_expired) for current user.
  /// session_expired matches are included so users can retry after a timeout.
  /// Bug 1 fix: explicitly excludes chat_unlocked matches so they never appear
  /// in the "Ready to Spark" section after a session completes.
  Future<List<Map<String, dynamic>>> getPendingMatches() async {
    final uid = currentUserId;
    if (uid == null) return [];

    final response = await client
        .from('matches')
        .select()
        .or('user_1_id.eq.$uid,user_2_id.eq.$uid')
        .inFilter('status', ['matched_pending_session', 'session_expired'])
        .neq('status', 'chat_unlocked')
        .order('created_at', ascending: false);

    final visibleMatches = _excludeBlockedMatches(
      List<Map<String, dynamic>>.from(response as List),
      uid,
      await getBlockedUserIdsForCurrentUser(),
    );
    return _excludeUnavailableMatches(visibleMatches, uid);
  }

  /// Get chat-unlocked matches for current user
  Future<List<Map<String, dynamic>>> getChatUnlockedMatches() async {
    final uid = currentUserId;
    if (uid == null) return [];

    final response = await client
        .from('matches')
        .select()
        .or('user_1_id.eq.$uid,user_2_id.eq.$uid')
        .eq('status', 'chat_unlocked')
        .order('created_at', ascending: false);

    final visibleMatches = _excludeBlockedMatches(
      List<Map<String, dynamic>>.from(response as List),
      uid,
      await getBlockedUserIdsForCurrentUser(),
    );
    return _excludeUnavailableMatches(visibleMatches, uid);
  }

  List<Map<String, dynamic>> _excludeBlockedMatches(
    List<Map<String, dynamic>> matches,
    String uid,
    Set<String> blockedUserIds,
  ) {
    if (blockedUserIds.isEmpty) return matches;
    return matches.where((match) {
      final user1 = match['user_1_id'] as String?;
      final user2 = match['user_2_id'] as String?;
      final otherUserId = user1 == uid ? user2 : user1;
      return otherUserId == null || !blockedUserIds.contains(otherUserId);
    }).toList();
  }

  Future<List<Map<String, dynamic>>> _excludeUnavailableMatches(
    List<Map<String, dynamic>> matches,
    String uid,
  ) async {
    final visibleMatches = <Map<String, dynamic>>[];
    for (final match in matches) {
      final user1 = match['user_1_id'] as String?;
      final user2 = match['user_2_id'] as String?;
      final otherUserId = user1 == uid ? user2 : user1;
      if (otherUserId == null) continue;

      if (await isUserFacingProfileAvailableById(otherUserId)) {
        visibleMatches.add(match);
      }
    }
    return visibleMatches;
  }

  /// Update match status
  Future<void> updateMatchStatus({
    required String matchId,
    required String status,
  }) async {
    await client.from('matches').update({'status': status}).eq('id', matchId);
  }

  /// Get a single match by ID
  Future<Map<String, dynamic>?> getMatch(String matchId) async {
    final response = await client
        .from('matches')
        .select()
        .eq('id', matchId)
        .maybeSingle();
    return response;
  }

  // ============================================================
  // SCHEDULED SPARK SESSIONS
  // ============================================================

  Future<List<Map<String, dynamic>>> getMyScheduledSparkSessions() async {
    final response = await client.rpc('get_my_scheduled_spark_sessions');
    return List<Map<String, dynamic>>.from(response as List? ?? const []);
  }

  Future<Map<String, dynamic>> createSparkSessionSchedule({
    required String matchId,
    required String recipientUserId,
    required List<DateTime> proposedTimes,
  }) async {
    final response = await client.rpc(
      'create_spark_session_schedule',
      params: {
        'p_match_id': matchId,
        'p_proposed_times': _scheduleTimesPayload(proposedTimes),
      },
    );
    final schedule = Map<String, dynamic>.from(response as Map);
    unawaited(
      _sendSparkSchedulePush(
        userId: recipientUserId,
        type: 'spark_schedule_proposed',
        schedule: schedule,
      ),
    );
    return schedule;
  }

  Future<Map<String, dynamic>> acceptSparkSessionSchedule({
    required String scheduleId,
    required String notifyUserId,
    required DateTime acceptedTime,
  }) async {
    final response = await client.rpc(
      'accept_spark_session_schedule',
      params: {
        'p_schedule_id': scheduleId,
        'p_accepted_time': acceptedTime.toUtc().toIso8601String(),
      },
    );
    final schedule = Map<String, dynamic>.from(response as Map);
    unawaited(
      _sendSparkSchedulePush(
        userId: notifyUserId,
        type: 'spark_schedule_accepted',
        schedule: schedule,
      ),
    );
    return schedule;
  }

  Future<Map<String, dynamic>> counterSparkSessionSchedule({
    required String scheduleId,
    required String notifyUserId,
    required List<DateTime> proposedTimes,
  }) async {
    final response = await client.rpc(
      'counter_spark_session_schedule',
      params: {
        'p_schedule_id': scheduleId,
        'p_proposed_times': _scheduleTimesPayload(proposedTimes),
      },
    );
    final schedule = Map<String, dynamic>.from(response as Map);
    unawaited(
      _sendSparkSchedulePush(
        userId: notifyUserId,
        type: 'spark_schedule_proposed',
        schedule: schedule,
      ),
    );
    return schedule;
  }

  Future<Map<String, dynamic>> cancelSparkSessionSchedule({
    required String scheduleId,
  }) async {
    final response = await client.rpc(
      'cancel_spark_session_schedule',
      params: {'p_schedule_id': scheduleId},
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<int> completeSparkSessionScheduleForMatch(String matchId) async {
    final response = await client.rpc(
      'complete_spark_session_schedule_for_match',
      params: {'p_match_id': matchId},
    );
    return (response as num?)?.toInt() ?? 0;
  }

  List<String> _scheduleTimesPayload(List<DateTime> proposedTimes) {
    final sorted = proposedTimes.map((time) => time.toUtc()).toSet().toList()
      ..sort();
    return sorted.take(3).map((time) => time.toIso8601String()).toList();
  }

  Future<void> _sendSparkSchedulePush({
    required String userId,
    required String type,
    required Map<String, dynamic> schedule,
  }) async {
    final sparkType = normalizeSparkType(schedule['spark_type'] as String?);
    final professional = sparkType == 'professional';
    final title = switch (type) {
      'spark_schedule_accepted' =>
        professional
            ? 'Professional Connection intro scheduled'
            : 'Your Spark intro is scheduled',
      _ =>
        professional
            ? 'Schedule your Professional Connection intro'
            : 'Schedule your Spark intro',
    };
    final body = switch (type) {
      'spark_schedule_accepted' =>
        professional
            ? 'Your Professional Connection intro time is confirmed.'
            : 'Your 3-minute intro time is confirmed.',
      _ =>
        professional
            ? 'Choose a time for your Professional Connection intro.'
            : 'Choose a time for your 3-minute intro.',
    };

    try {
      await client.functions.invoke(
        'send_push_notification',
        body: {
          'user_id': userId,
          'target_user_id': userId,
          if (currentUserId != null) 'sender_user_id': currentUserId,
          'type': type,
          'title': title,
          'body': body,
          'data': {
            'type': type,
            'match_id': schedule['match_id'],
            'schedule_id': schedule['id'],
            'spark_type': sparkType,
            'url': '/',
          },
        },
      );
    } catch (e) {
      debugPrint('SCHEDULED SPARK PUSH: failed type=$type — $e');
    }
  }

  // ============================================================
  // SPARK SESSIONS
  // ============================================================

  /// Create a spark session
  Future<Map<String, dynamic>?> createSparkSession({
    required String matchId,
    String? dailyRoomUrl,
  }) async {
    final response = await client
        .from('spark_sessions')
        .insert({
          'match_id': matchId,
          'daily_room_url': dailyRoomUrl,
          'started_at': DateTime.now().toIso8601String(),
        })
        .select()
        .single();
    return response;
  }

  /// Mark current user as present in the spark session waiting room
  Future<void> markUserPresent(String matchId) async {
    final uid = currentUserId;
    if (uid == null) return;

    // Determine if current user is user_1 or user_2
    final match = await getMatch(matchId);
    if (match == null) return;

    final isUser1 = match['user_1_id'] == uid;
    final presenceField = isUser1 ? 'user_1_present' : 'user_2_present';

    await client
        .from('spark_sessions')
        .update({presenceField: true})
        .eq('match_id', matchId);
  }

  /// Mark current user as ready in the spark session (user_1_ready / user_2_ready).
  /// This is the synchronisation signal — when both are true the call launches.
  Future<void> markUserReady({
    required String matchId,
    required bool isUser1,
  }) async {
    final readyField = isUser1 ? 'user_1_ready' : 'user_2_ready';
    debugPrint(
      'SUPABASE markUserReady: setting $readyField=true for matchId=$matchId',
    );
    await client
        .from('spark_sessions')
        .update({readyField: true})
        .eq('match_id', matchId);
    debugPrint(
      'SUPABASE markUserReady: ✅ $readyField set to true for matchId=$matchId',
    );
  }

  /// Subscribe to spark_session changes for a match using Supabase Realtime.
  /// Listens for both INSERT and UPDATE events so the waiting room catches
  /// the row being created by the other user as well as ready-flag updates.
  RealtimeChannel subscribeToSparkSession({
    required String matchId,
    required void Function(Map<String, dynamic> record) onUpdate,
  }) {
    debugPrint(
      'SUPABASE subscribeToSparkSession: subscribing to spark_sessions for matchId=$matchId',
    );
    return client
        .channel('spark_session:$matchId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'spark_sessions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'match_id',
            value: matchId,
          ),
          callback: (payload) {
            debugPrint(
              'SUPABASE subscribeToSparkSession: UPDATE event received for matchId=$matchId — ${payload.newRecord}',
            );
            onUpdate(payload.newRecord);
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'spark_sessions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'match_id',
            value: matchId,
          ),
          callback: (payload) {
            debugPrint(
              'SUPABASE subscribeToSparkSession: INSERT event received for matchId=$matchId — ${payload.newRecord}',
            );
            onUpdate(payload.newRecord);
          },
        )
        .subscribe();
  }

  /// Subscribe to new matches for current user using Supabase Realtime
  RealtimeChannel subscribeToNewMatches({
    required void Function(Map<String, dynamic> match) onNewMatch,
  }) {
    final uid = currentUserId;
    if (uid == null) {
      return client.channel(
        'matches_noop_${DateTime.now().millisecondsSinceEpoch}',
      );
    }
    return client
        .channel('new_matches:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'matches',
          callback: (payload) {
            final record = payload.newRecord;
            // Only notify if current user is involved
            if (record['user_1_id'] == uid || record['user_2_id'] == uid) {
              onNewMatch(record);
            }
          },
        )
        .subscribe();
  }

  /// Save a user's decision in a spark session
  Future<void> saveSparkDecision({
    required String sessionId,
    required String matchId,
    required String decision, // 'spark' or 'skip'
  }) async {
    final uid = currentUserId;
    if (uid == null) return;

    // Determine if current user is user_1 or user_2
    final match = await getMatch(matchId);
    if (match == null) return;

    final isUser1 = match['user_1_id'] == uid;
    final decisionField = isUser1 ? 'decision_user_1' : 'decision_user_2';

    await client
        .from('spark_sessions')
        .update({decisionField: decision})
        .eq('id', sessionId);

    // Check if both decisions are in and determine outcome
    final session = await client
        .from('spark_sessions')
        .select()
        .eq('id', sessionId)
        .single();

    final d1 = session['decision_user_1'];
    final d2 = session['decision_user_2'];

    if (d1 != null && d2 != null) {
      final outcome = (d1 == 'spark' && d2 == 'spark')
          ? 'mutual_spark'
          : 'no_spark';
      final matchStatus = outcome == 'mutual_spark'
          ? 'chat_unlocked'
          : 'session_ended';

      await client
          .from('spark_sessions')
          .update({
            'outcome': outcome,
            'status': 'ended',
            'ended_at': DateTime.now().toIso8601String(),
          })
          .eq('id', sessionId);

      await client
          .from('matches')
          .update({'status': matchStatus, 'current_session_key': null})
          .eq('id', matchId);

      await completeSparkSessionScheduleForMatch(matchId);
    }
  }

  /// Get spark session for a match
  Future<Map<String, dynamic>?> getSparkSession(String matchId) async {
    final response = await client
        .from('spark_sessions')
        .select()
        .eq('match_id', matchId)
        .order('created_at', ascending: false)
        .limit(1)
        .maybeSingle();
    return response;
  }

  /// Read-only guard used before automatic Spark Session popups/navigation.
  /// Manual starts still go through the normal Spark Session screen and secure
  /// Daily access flow; this only suppresses stale completed attempts.
  Future<SparkSessionEntryEligibility> checkSparkSessionEntryEligibility({
    required String matchId,
    String? sessionId,
  }) async {
    final cleanMatchId = matchId.trim();
    if (cleanMatchId.isEmpty) {
      return const SparkSessionEntryEligibility(
        canEnter: false,
        reason: 'invalid_match',
      );
    }

    try {
      final match = await client
          .from('matches')
          .select('status, current_session_key')
          .eq('id', cleanMatchId)
          .maybeSingle();

      if (match == null) {
        return const SparkSessionEntryEligibility(
          canEnter: false,
          reason: 'match_not_found',
        );
      }

      final matchStatus = (match['status'] as String? ?? '').toLowerCase();
      final currentSessionKey = (match['current_session_key'] as String? ?? '')
          .trim();

      var query = client
          .from('spark_sessions')
          .select(
            'id, status, ended_at, session_key, decision_user_1, decision_user_2, outcome, created_at',
          )
          .eq('match_id', cleanMatchId);

      final cleanSessionId = sessionId?.trim();
      if (cleanSessionId != null && cleanSessionId.isNotEmpty) {
        query = query.eq('id', cleanSessionId);
      } else if (currentSessionKey.isNotEmpty) {
        query = query.eq('session_key', currentSessionKey);
      }

      final rows = await query.order('created_at', ascending: false).limit(1);
      final session = rows.isNotEmpty
          ? Map<String, dynamic>.from(rows.first as Map)
          : null;

      if (session == null) {
        return SparkSessionEntryEligibility(
          canEnter: false,
          reason: matchStatus == 'chat_unlocked'
              ? 'chat_unlocked_no_active_session'
              : 'no_active_session',
          chatUnlocked: matchStatus == 'chat_unlocked',
        );
      }

      final sessionStatus = (session['status'] as String? ?? '').toLowerCase();
      final endedAt = session['ended_at'] as String?;
      final endedAtExists = endedAt != null && endedAt.isNotEmpty;
      final outcome = session['outcome'];
      final d1 = session['decision_user_1'];
      final d2 = session['decision_user_2'];
      final feedbackComplete = d1 != null && d2 != null;
      final sessionKey = (session['session_key'] as String? ?? '').trim();

      if (sessionStatus == 'ended' || endedAtExists) {
        return SparkSessionEntryEligibility(
          canEnter: false,
          reason: 'session_ended',
          sessionStatus: sessionStatus,
          endedAtExists: endedAtExists,
          chatUnlocked: matchStatus == 'chat_unlocked',
          feedbackComplete: feedbackComplete,
        );
      }

      if (outcome != null || feedbackComplete) {
        return SparkSessionEntryEligibility(
          canEnter: false,
          reason: 'feedback_complete',
          sessionStatus: sessionStatus,
          endedAtExists: endedAtExists,
          chatUnlocked: matchStatus == 'chat_unlocked',
          feedbackComplete: true,
        );
      }

      if (currentSessionKey.isEmpty || sessionKey != currentSessionKey) {
        return SparkSessionEntryEligibility(
          canEnter: false,
          reason: 'stale_session_key',
          sessionStatus: sessionStatus,
          endedAtExists: endedAtExists,
          chatUnlocked: matchStatus == 'chat_unlocked',
          feedbackComplete: feedbackComplete,
        );
      }

      final createdAt = DateTime.tryParse(
        session['created_at'] as String? ?? '',
      );
      if (createdAt == null ||
          DateTime.now().toUtc().difference(createdAt.toUtc()) >
              const Duration(minutes: 12)) {
        return SparkSessionEntryEligibility(
          canEnter: false,
          reason: 'session_expired',
          sessionStatus: sessionStatus,
          endedAtExists: endedAtExists,
          chatUnlocked: matchStatus == 'chat_unlocked',
          feedbackComplete: feedbackComplete,
        );
      }

      return SparkSessionEntryEligibility(
        canEnter: true,
        reason: 'active_session',
        sessionStatus: sessionStatus,
        endedAtExists: false,
        chatUnlocked: matchStatus == 'chat_unlocked',
        feedbackComplete: false,
      );
    } catch (e) {
      debugPrint('SPARK ENTRY GUARD: eligibility check failed — $e');
      return const SparkSessionEntryEligibility(
        canEnter: false,
        reason: 'eligibility_check_failed',
      );
    }
  }

  // ============================================================
  // MESSAGES
  // ============================================================

  /// Send a message
  Future<Map<String, dynamic>?> sendMessage({
    required String matchId,
    required String content,
  }) async {
    final uid = currentUserId;
    if (uid == null) return null;
    ContentFilterService.ensureAllowed(content);

    final match = await getMatch(matchId);
    final matchUser1Id = match == null ? null : match['user_1_id'] as String?;
    final matchUser2Id = match == null ? null : match['user_2_id'] as String?;
    final otherUserId = matchUser1Id == uid ? matchUser2Id : matchUser1Id;
    if (otherUserId != null && await hasBlockBetween(otherUserId)) {
      throw Exception('You cannot message this user.');
    }

    final response = await client
        .from('messages')
        .insert({'match_id': matchId, 'sender_id': uid, 'content': content})
        .select()
        .single();
    return response;
  }

  /// Get messages for a match
  Future<List<Map<String, dynamic>>> getMessages(String matchId) async {
    final uid = currentUserId;
    final match = await getMatch(matchId);
    final matchUser1Id = match == null ? null : match['user_1_id'] as String?;
    final matchUser2Id = match == null ? null : match['user_2_id'] as String?;
    final otherUserId = matchUser1Id == uid ? matchUser2Id : matchUser1Id;
    if (otherUserId != null && await hasBlockBetween(otherUserId)) {
      return [];
    }

    final response = await client
        .from('messages')
        .select()
        .eq('match_id', matchId)
        .order('created_at', ascending: true);
    return List<Map<String, dynamic>>.from(response as List);
  }

  /// Mark messages as read
  Future<void> markMessagesRead(String matchId) async {
    final uid = currentUserId;
    if (uid == null) return;
    await client
        .from('messages')
        .update({'is_read': true})
        .eq('match_id', matchId)
        .neq('sender_id', uid)
        .eq('is_read', false);
  }

  /// Subscribe to real-time messages for a match
  RealtimeChannel subscribeToMessages({
    required String matchId,
    required void Function(Map<String, dynamic> message) onNewMessage,
  }) {
    return client
        .channel('messages:$matchId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'messages',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'match_id',
            value: matchId,
          ),
          callback: (payload) {
            onNewMessage(payload.newRecord);
          },
        )
        .subscribe();
  }

  /// Subscribe to new spark_sessions for a match (for incoming spark requests from chat)
  RealtimeChannel subscribeToNewSparkSessions({
    required String matchId,
    required void Function(Map<String, dynamic> record) onNewSession,
  }) {
    return client
        .channel('new_spark_session:$matchId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'spark_sessions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'match_id',
            value: matchId,
          ),
          callback: (payload) {
            onNewSession(payload.newRecord);
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'spark_sessions',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'match_id',
            value: matchId,
          ),
          callback: (payload) {
            onNewSession(payload.newRecord);
          },
        )
        .subscribe();
  }

  // ============================================================
  // STORAGE - Profile Videos
  // ============================================================

  /// Upload profile video and return public URL
  Future<String?> uploadProfileVideo(String filePath) async {
    final uid = currentUserId;
    if (uid == null) return null;

    final file = File(filePath);
    final storagePath = '$uid/profile.mp4';

    await client.storage
        .from('profile-videos')
        .upload(
          storagePath,
          file,
          fileOptions: const FileOptions(upsert: true),
        );

    final url = client.storage.from('profile-videos').getPublicUrl(storagePath);
    return url;
  }

  /// Upload a sampled video frame used only for backend profile video moderation.
  Future<String?> uploadProfileModerationFrame(
    String frameFilePath,
    int frameIndex,
  ) async {
    final uid = currentUserId;
    if (uid == null) return null;

    try {
      final file = File(frameFilePath);
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final storagePath = '$uid/moderation/frame_${frameIndex}_$timestamp.jpg';

      await client.storage
          .from('profile-thumbnails')
          .upload(
            storagePath,
            file,
            fileOptions: const FileOptions(
              upsert: true,
              contentType: 'image/jpeg',
            ),
          );

      final url = client.storage
          .from('profile-thumbnails')
          .getPublicUrl(storagePath);
      debugPrint('PROFILE VIDEO MODERATION: uploaded frame ${frameIndex + 1}');
      return url;
    } catch (e) {
      debugPrint(
        'PROFILE VIDEO MODERATION: frame upload failed index=$frameIndex — $e',
      );
      return null;
    }
  }

  Future<String?> uploadProfileModerationFrameBytes(
    Uint8List bytes,
    int frameIndex,
  ) async {
    final uid = currentUserId;
    if (uid == null) return null;

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final storagePath = '$uid/moderation/frame_${frameIndex}_$timestamp.jpg';

      await client.storage
          .from('profile-thumbnails')
          .uploadBinary(
            storagePath,
            bytes,
            fileOptions: const FileOptions(
              upsert: true,
              contentType: 'image/jpeg',
            ),
          );

      final url = client.storage
          .from('profile-thumbnails')
          .getPublicUrl(storagePath);
      debugPrint(
        'PROFILE VIDEO MODERATION: uploaded web frame ${frameIndex + 1} bytes=${bytes.length}',
      );
      return url;
    } catch (e) {
      debugPrint(
        'PROFILE VIDEO MODERATION: web frame upload failed index=$frameIndex — $e',
      );
      return null;
    }
  }

  Future<Map<String, dynamic>> moderateProfileVideo({
    required String videoUrl,
    required List<String> frameUrls,
  }) async {
    final uid = currentUserId;
    if (uid == null) {
      return {
        'moderation_status': 'needs_review',
        'moderation_reason': 'User is not authenticated.',
      };
    }

    debugPrint(
      'PROFILE VIDEO MODERATION: starting — frames=${frameUrls.length}',
    );

    try {
      final response = await client.functions
          .invoke(
            'moderate_profile_video',
            body: {'video_url': videoUrl, 'frame_urls': frameUrls},
          )
          .timeout(const Duration(seconds: 30));

      final data = response.data;
      if (data is Map<String, dynamic>) {
        debugPrint(
          'PROFILE VIDEO MODERATION: completed — status=${data['moderation_status']}',
        );
        return data;
      }
      if (data is Map) {
        final mapped = Map<String, dynamic>.from(data);
        debugPrint(
          'PROFILE VIDEO MODERATION: completed — status=${mapped['moderation_status']}',
        );
        return mapped;
      }
    } catch (e) {
      debugPrint('PROFILE VIDEO MODERATION: function failed — $e');
    }

    await client
        .from('users')
        .update({
          'profile_video_url': videoUrl,
          'moderation_status': 'needs_review',
          'moderation_reason': 'Automated moderation timed out.',
          'moderated_at': DateTime.now().toIso8601String(),
        })
        .eq('id', uid);

    return {
      'moderation_status': 'needs_review',
      'moderation_reason': 'Automated moderation timed out.',
    };
  }

  /// Upload profile video from file path and update users table (for re-upload flow)
  Future<String?> reUploadProfileVideo(String filePath) async {
    final uid = currentUserId;
    if (uid == null) return null;

    final file = File(filePath);
    final storagePath = '$uid/profile.mp4';

    await client.storage
        .from('profile-videos')
        .upload(
          storagePath,
          file,
          fileOptions: const FileOptions(upsert: true),
        );

    final url = client.storage.from('profile-videos').getPublicUrl(storagePath);
    if (url.isNotEmpty) {
      // Increment video_upload_count and update video_url
      await client.rpc(
        'increment_video_upload_count',
        params: {'user_id': uid},
      );
      await client
          .from('users')
          .update({
            'profile_video_url': url,
            'moderation_status': 'pending',
            'moderation_reason': 'New profile video uploaded.',
            'moderated_at': null,
          })
          .eq('id', uid);
    }
    return url;
  }

  /// Increment video_upload_count for current user
  Future<void> incrementVideoUploadCount() async {
    final uid = currentUserId;
    if (uid == null) return;
    final profile = await getUserProfile(uid);
    final current = (profile?['video_upload_count'] as num?)?.toInt() ?? 0;
    await client
        .from('users')
        .update({'video_upload_count': current + 1})
        .eq('id', uid);
  }

  /// Update profile video URL and increment upload count
  Future<void> updateProfileVideoUrl(String url) async {
    final uid = currentUserId;
    if (uid == null) return;
    final profile = await getUserProfile(uid);
    final current = (profile?['video_upload_count'] as num?)?.toInt() ?? 0;
    await client
        .from('users')
        .update({
          'profile_video_url': url,
          'video_upload_count': current + 1,
          'moderation_status': 'pending',
          'moderation_reason': 'New profile video uploaded.',
          'moderated_at': null,
        })
        .eq('id', uid);
  }

  /// Upload profile video bytes (for web)
  Future<String?> uploadProfileVideoBytes(
    Uint8List bytes,
    String fileName, {
    String? mimeType,
  }) async {
    final uid = currentUserId;
    if (uid == null) return null;

    final lowerName = fileName.toLowerCase();
    final lowerMime = (mimeType ?? '').toLowerCase();
    final extension = lowerName.endsWith('.webm') || lowerMime.contains('webm')
        ? 'webm'
        : lowerName.endsWith('.mov') || lowerMime.contains('quicktime')
        ? 'mov'
        : lowerName.endsWith('.m4v') || lowerMime.contains('x-m4v')
        ? 'm4v'
        : 'mp4';
    final contentType = switch (extension) {
      'webm' => 'video/webm',
      'mov' => 'video/quicktime',
      'm4v' => 'video/x-m4v',
      _ => 'video/mp4',
    };
    final storagePath = '$uid/profile.$extension';

    debugPrint(
      'PROFILE VIDEO WEB: upload started extension=$extension contentType=$contentType bytes=${bytes.length}',
    );
    await client.storage
        .from('profile-videos')
        .uploadBinary(
          storagePath,
          bytes,
          fileOptions: FileOptions(upsert: true, contentType: contentType),
        );

    final url = client.storage.from('profile-videos').getPublicUrl(storagePath);
    debugPrint(
      'PROFILE VIDEO WEB: upload succeeded urlExists=${url.isNotEmpty}',
    );
    return url;
  }

  /// Upload a thumbnail JPEG file to the profile-thumbnails bucket and save
  /// the public URL to the thumbnail_url column on the users table.
  /// Returns the public URL or null on failure.
  Future<String?> uploadProfileThumbnail(String thumbnailFilePath) async {
    final uid = currentUserId;
    if (uid == null) return null;

    try {
      final file = File(thumbnailFilePath);
      final storagePath = '$uid/thumbnail.jpg';

      await client.storage
          .from('profile-thumbnails')
          .upload(
            storagePath,
            file,
            fileOptions: const FileOptions(
              upsert: true,
              contentType: 'image/jpeg',
            ),
          );

      final url = client.storage
          .from('profile-thumbnails')
          .getPublicUrl(storagePath);

      if (url.isNotEmpty) {
        await client.from('users').update({'thumbnail_url': url}).eq('id', uid);
        debugPrint('THUMBNAIL UPLOAD: ✅ uploaded and saved thumbnail_url=$url');
      }
      return url;
    } catch (e) {
      debugPrint('THUMBNAIL UPLOAD: ❌ failed — $e');
      return null;
    }
  }

  /// Upload thumbnail JPEG bytes from web/PWA and save a durable public URL.
  Future<String?> uploadProfileThumbnailBytes(Uint8List bytes) async {
    final uid = currentUserId;
    if (uid == null || bytes.isEmpty) return null;

    try {
      final storagePath = '$uid/thumbnail.jpg';

      await client.storage
          .from('profile-thumbnails')
          .uploadBinary(
            storagePath,
            bytes,
            fileOptions: const FileOptions(
              upsert: true,
              contentType: 'image/jpeg',
            ),
          );

      final url = client.storage
          .from('profile-thumbnails')
          .getPublicUrl(storagePath);

      if (url.isNotEmpty) {
        await client.from('users').update({'thumbnail_url': url}).eq('id', uid);
        debugPrint(
          'THUMBNAIL WEB UPLOAD: uploaded and saved thumbnail_url exists=yes',
        );
      }
      return url;
    } catch (e) {
      debugPrint('THUMBNAIL WEB UPLOAD: failed — $e');
      return null;
    }
  }

  /// Get the total number of interactions sent by the current user (for debug logging)
  Future<int> getInteractionCount() async {
    final uid = currentUserId;
    if (uid == null) return 0;
    final response = await client
        .from('interactions')
        .select('id')
        .eq('from_user_id', uid);
    return (response as List).length;
  }
}
