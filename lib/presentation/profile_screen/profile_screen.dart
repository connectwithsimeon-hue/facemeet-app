import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../routes/app_routes.dart';
import '../../services/content_filter_service.dart';
import '../../services/presence_service.dart';
import '../../services/realtime_notification_service.dart';
import '../../services/revenuecat_service.dart';
import '../../services/supabase_service.dart';
import '../../services/referral_service.dart';
import '../../services/web_push_notification_service.dart';
import '../../theme/app_theme.dart';
import './widgets/profile_edit_bio_widget.dart';
import './widgets/profile_interests_widget.dart';
import './widgets/profile_stats_widget.dart';
import './widgets/profile_video_hero_widget.dart';
import '../../../main.dart' show manualLogout;

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => ProfileScreenState();
}

class ProfileScreenState extends State<ProfileScreen> {
  bool _isEditing = false;
  bool _isSaving = false;

  String _editBio = '';
  List<String> _editInterests = [];
  String _editConnectionIntent = SupabaseService.defaultConnectionIntent;
  final FocusNode _bioFocusNode = FocusNode();
  final GlobalKey _aboutMeSectionKey = GlobalKey();

  late Future<Map<String, dynamic>?> _profileFuture;

  int? _sparkCount;
  int? _sessionCount;
  int? _matchCount;
  bool _statsLoading = true;

  // Referral stats
  int _friendsCount = 0;
  int _sparksEarned = 0;
  String _referralLink = '';
  bool _referralLoading = true;
  bool _notificationActionInProgress = false;
  WebPushSetupResult? _notificationState;
  bool _publicProfileActionInProgress = false;

  RealtimeChannel? _matchesRealtimeChannel;

  @override
  void initState() {
    super.initState();
    _profileFuture = _fetchProfile();
    _loadStats();
    _loadReferralData();
    _subscribeToMatchesRealtime();
    if (kIsWeb) _loadNotificationState();
  }

  @override
  void dispose() {
    _bioFocusNode.dispose();
    _matchesRealtimeChannel?.unsubscribe();
    super.dispose();
  }

  Future<Map<String, dynamic>?> _fetchProfile() async {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) return null;
    final data = await SupabaseService.instance.getUserProfile(uid);
    if (data != null) {
      _editBio = data['bio'] ?? '';
      _editInterests = _parseInterests(data['interests']);
      _editConnectionIntent = SupabaseService.normalizeConnectionIntent(
        data['connection_intent'] as String?,
      );
    }
    return data;
  }

  Future<void> _loadStats() async {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) {
      if (mounted) setState(() => _statsLoading = false);
      return;
    }

    try {
      final sparksResult = await SupabaseService.instance.client
          .from('interactions')
          .select('id')
          .eq('from_user_id', uid)
          .eq('action_type', 'spark');
      final sparksCount = (sparksResult as List).length;

      final matchesForSessions = await SupabaseService.instance.client
          .from('matches')
          .select('id')
          .or('user_1_id.eq.$uid,user_2_id.eq.$uid');
      final matchIds = (matchesForSessions as List)
          .map((m) => m['id'] as String)
          .toList();

      int sessionsCount = 0;
      if (matchIds.isNotEmpty) {
        final sessionsResult = await SupabaseService.instance.client
            .from('spark_sessions')
            .select('id')
            .inFilter('match_id', matchIds);
        sessionsCount = (sessionsResult as List).length;
      }

      final matchesResult = await SupabaseService.instance.client
          .from('matches')
          .select('id')
          .or('user_1_id.eq.$uid,user_2_id.eq.$uid')
          .eq('status', 'chat_unlocked');
      final matchesCount = (matchesResult as List).length;

      if (mounted) {
        setState(() {
          _sparkCount = sparksCount;
          _sessionCount = sessionsCount;
          _matchCount = matchesCount;
          _statsLoading = false;
        });
      }
    } catch (e) {
      debugPrint('PROFILE STATS: Error loading stats: $e');
      if (mounted) setState(() => _statsLoading = false);
    }
  }

  Future<void> _loadNotificationState() async {
    final state = await WebPushNotificationService.instance.currentSetupState();
    if (mounted) {
      setState(() => _notificationState = state);
    }
  }

  Future<void> _enableWebNotifications() async {
    debugPrint('WEB PUSH: settings enable tapped');
    setState(() {
      _notificationActionInProgress = true;
      _notificationState = const WebPushSetupResult(
        success: false,
        status: 'Enabling notifications…',
        message: 'Enabling notifications…',
      );
    });
    final result = await WebPushNotificationService.instance
        .enableNotifications();
    if (mounted) {
      setState(() {
        _notificationState = result;
        _notificationActionInProgress = false;
      });
    }
  }

  Future<void> _sendWebTestNotification() async {
    setState(() {
      _notificationActionInProgress = true;
      _notificationState = const WebPushSetupResult(
        success: false,
        status: 'Sending test notification…',
        message: 'Sending test notification…',
      );
    });
    final result = await WebPushNotificationService.instance
        .sendTestNotification();
    if (mounted) {
      setState(() {
        _notificationState = result;
        _notificationActionInProgress = false;
      });
    }
  }

  Future<void> _loadReferralData() async {
    try {
      final link = await ReferralService.instance.getReferralLink();
      final stats = await ReferralService.instance.getReferralStats();
      if (mounted) {
        setState(() {
          _referralLink = link;
          _friendsCount = stats['friendsCount'] ?? 0;
          _sparksEarned = stats['sparksEarned'] ?? 0;
          _referralLoading = false;
        });
      }
    } catch (e) {
      debugPrint('REFERRAL: loadReferralData error: $e');
      if (mounted) setState(() => _referralLoading = false);
    }
  }

  void _subscribeToMatchesRealtime() {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) return;

    _matchesRealtimeChannel = SupabaseService.instance.client
        .channel('profile_stats_matches:$uid')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'matches',
          callback: (_) {
            _loadStats();
          },
        )
        .subscribe();
  }

  List<String> _parseInterests(dynamic raw) {
    if (raw == null) return [];
    if (raw is List) return raw.map((e) => e.toString()).toList();
    return [];
  }

  void _toggleEdit(Map<String, dynamic> profile) {
    if (_isEditing) {
      _saveProfile(profile);
    } else {
      setState(() => _isEditing = true);
    }
  }

  void openAboutMeEditor() {
    setState(() => _isEditing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final sectionContext = _aboutMeSectionKey.currentContext;
      if (sectionContext != null) {
        Scrollable.ensureVisible(
          sectionContext,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOutCubic,
          alignment: 0.18,
        );
      }
      _bioFocusNode.requestFocus();
    });
  }

  Future<void> _saveProfile(Map<String, dynamic> profile) async {
    setState(() => _isSaving = true);
    try {
      final uid = SupabaseService.instance.currentUserId;
      if (uid != null) {
        await SupabaseService.instance.updateUserProfile({
          'bio': _editBio,
          'interests': _editInterests,
          'connection_intent': SupabaseService.normalizeConnectionIntent(
            _editConnectionIntent,
          ),
        });
      }
      if (mounted) {
        setState(() {
          profile['bio'] = _editBio;
          profile['interests'] = List<String>.from(_editInterests);
          profile['connection_intent'] =
              SupabaseService.normalizeConnectionIntent(_editConnectionIntent);
          _isEditing = false;
          _isSaving = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Profile updated', style: GoogleFonts.dmSans()),
            backgroundColor: AppTheme.sparkGreen,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        final errorText = e.toString().replaceFirst('Exception: ', '');
        final message = errorText == ContentFilterService.violationMessage
            ? ContentFilterService.violationMessage
            : 'Save failed: $errorText';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message, style: GoogleFonts.dmSans()),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  void _cancelEdit(Map<String, dynamic> profile) {
    setState(() {
      _editBio = profile['bio'] ?? '';
      _editInterests = _parseInterests(profile['interests']);
      _editConnectionIntent = SupabaseService.normalizeConnectionIntent(
        profile['connection_intent'] as String?,
      );
      _isEditing = false;
    });
  }

  void _refreshProfile() {
    setState(() {
      _profileFuture = _fetchProfile();
    });
    _loadStats();
  }

  Future<void> _openSettings(Map<String, dynamic> profile) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _SettingsScreen(
          profile: profile,
          notificationState: _notificationState,
          notificationActionInProgress: _notificationActionInProgress,
          onEnableWebNotifications: _enableWebNotifications,
          onSendWebTestNotification: _sendWebTestNotification,
          onOpenSupportEmail: _openSupportEmail,
          onResetDiscovery: _handleResetDiscovery,
          onDeleteAccount: _showDeleteAccountFlow,
          onLogout: _handleLogout,
          onSocialLinksSaved: _refreshProfile,
        ),
      ),
    );
    if (mounted) _refreshProfile();
  }

  void _handleLogout() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'You\'ll need to sign back in to access your Spark Sessions and chats.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              'Cancel',
              style: GoogleFonts.dmSans(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              manualLogout = true;
              await SupabaseService.instance.signOut();
              if (mounted) {
                Navigator.pushNamedAndRemoveUntil(
                  context,
                  AppRoutes.authScreen,
                  (route) => false,
                );
              }
            },
            child: Text(
              'Sign out',
              style: GoogleFonts.dmSans(color: AppTheme.error),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showDeleteAccountFlow() async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Delete account?',
          style: GoogleFonts.dmSans(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This permanently removes or anonymizes your FaceMeet account data where legally and technically possible, including:',
                style: GoogleFonts.dmSans(
                  color: AppTheme.textSecondary,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 12),
              ...const [
                'profile',
                'profile video',
                'matches',
                'chats/messages',
                'device tokens',
                'reports/block relationships where appropriate',
                'subscription/customer references where appropriate',
              ].map(
                (item) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.check_rounded,
                        color: AppTheme.primary,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          item,
                          style: GoogleFonts.dmSans(
                            color: AppTheme.textMuted,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _subscriptionManagementCopy,
                style: GoogleFonts.dmSans(
                  color: AppTheme.textSecondary,
                  height: 1.45,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: GoogleFonts.dmSans(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Continue',
              style: GoogleFonts.dmSans(
                color: AppTheme.error,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    if (proceed != true || !mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          _DeleteAccountConfirmationSheet(onConfirmed: _performAccountDeletion),
    );
  }

  Future<void> _performAccountDeletion() async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);

    debugPrint('ACCOUNT DELETE: user confirmed deletion');
    await PresenceService.instance.setOffline();
    RealtimeNotificationService.instance.dispose();
    await SupabaseService.instance.deleteAccount(confirmation: 'DELETE');
    await RevenueCatService.instance.logOutCurrentUser();

    manualLogout = true;
    await SupabaseService.instance.signOut();

    if (!mounted) return;
    navigator.pushNamedAndRemoveUntil(AppRoutes.authScreen, (route) => false);
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          'Your FaceMeet account has been deleted.',
          style: GoogleFonts.dmSans(),
        ),
        backgroundColor: AppTheme.sparkGreen,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  Future<void> _handleResetDiscovery() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Reset all your swipes?',
          style: GoogleFonts.dmSans(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          'This will let you see every profile again.',
          style: GoogleFonts.dmSans(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: GoogleFonts.dmSans(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Reset',
              style: GoogleFonts.dmSans(
                color: AppTheme.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final uid = SupabaseService.instance.currentUserId;
      if (uid != null) {
        await Supabase.instance.client
            .from('interactions')
            .delete()
            .eq('from_user_id', uid);
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Discovery feed reset — all profiles are now discoverable again',
              style: GoogleFonts.dmSans(),
            ),
            backgroundColor: AppTheme.sparkGreen,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Reset failed: $e', style: GoogleFonts.dmSans()),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    }
  }

  // ─── Username Edit ────────────────────────────────────────────────────────

  void _showUsernameEditSheet(String currentUsername) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _UsernameEditSheet(
        currentUsername: currentUsername,
        onSaved: (newUsername) {
          setState(() {
            _profileFuture = _fetchProfile();
          });
          _loadReferralData();
        },
      ),
    );
  }

  // ─── Share helpers ────────────────────────────────────────────────────────

  String get _subscriptionManagementCopy {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      return 'Active subscriptions are not cancelled in FaceMeet. Manage subscriptions through the App Store.';
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'Active subscriptions are not cancelled in FaceMeet. Manage subscriptions through Google Play.';
    }
    return 'Active subscriptions are not cancelled in FaceMeet. Manage subscriptions through your app store account.';
  }

  String get _inviteShareUrl {
    final link = _referralLink.trim();
    return link.isNotEmpty ? link : ReferralService.playStoreUrl;
  }

  String _referralShareMessage(String inviteUrl) =>
      'Join me on FaceMeet — a video-first way to meet people through Sparks, Live Topics, and real conversations.\n\n'
      'Use my invite link:\n$inviteUrl\n\n'
      'When you join, we both may earn Sparks.';

  Future<String> _ensureReferralShareUrl() async {
    final existing = _referralLink.trim();
    if (existing.isNotEmpty) return existing;

    final link = await ReferralService.instance.getReferralLink();
    final normalized = link.trim();
    if (mounted && normalized.isNotEmpty) {
      setState(() => _referralLink = normalized);
    }
    return normalized.isNotEmpty ? normalized : ReferralService.playStoreUrl;
  }

  Future<void> _shareWhatsApp() async {
    final inviteUrl = await _ensureReferralShareUrl();
    final encoded = Uri.encodeComponent(_referralShareMessage(inviteUrl));
    final uri = Uri.parse('https://wa.me/?text=$encoded');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('WhatsApp not installed')));
      }
    }
  }

  Future<void> _shareSms() async {
    final inviteUrl = await _ensureReferralShareUrl();
    final encoded = Uri.encodeComponent(_referralShareMessage(inviteUrl));
    final uri = Uri.parse('sms:?body=$encoded');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SMS not available on this device')),
        );
      }
    }
  }

  Future<void> _shareMore() async {
    final inviteUrl = await _ensureReferralShareUrl();
    final shared = await _shareText(
      text: _referralShareMessage(inviteUrl),
      subject: 'Join me on FaceMeet',
    );
    if (!shared) {
      await Clipboard.setData(ClipboardData(text: inviteUrl));
      if (mounted) _showProfileSnack('Referral link copied');
    }
  }

  Rect? _sharePositionOrigin() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    return renderObject.localToGlobal(Offset.zero) & renderObject.size;
  }

  Future<bool> _shareText({
    required String text,
    required String subject,
  }) async {
    try {
      final result = await Share.share(
        text,
        subject: subject,
        sharePositionOrigin: _sharePositionOrigin(),
      );
      return result.status != ShareResultStatus.unavailable;
    } catch (e) {
      debugPrint('SHARE: native share unavailable — $e');
      return false;
    }
  }

  String _publicProfileUrlFromSlug(String slug) =>
      'https://facemeet.app/p/$slug';

  Future<String> _ensurePublicProfileUrl(Map<String, dynamic> profile) async {
    final enabled = profile['public_profile_enabled'] == true;
    final existingSlug =
        profile['public_profile_slug']?.toString().trim() ?? '';
    if (enabled && existingSlug.isNotEmpty) {
      return _publicProfileUrlFromSlug(existingSlug);
    }

    setState(() => _publicProfileActionInProgress = true);
    try {
      final publicProfile = await SupabaseService.instance
          .enableMyPublicProfile();
      final slug = publicProfile['slug']?.toString().trim() ?? '';
      final url =
          publicProfile['public_url']?.toString().trim() ??
          _publicProfileUrlFromSlug(slug);
      if (slug.isEmpty || url.isEmpty) {
        throw Exception('Could not create your public profile link.');
      }
      profile['public_profile_slug'] = slug;
      profile['public_profile_enabled'] =
          publicProfile['public_profile_enabled'] == true;
      return url;
    } finally {
      if (mounted) {
        setState(() => _publicProfileActionInProgress = false);
      }
    }
  }

  String _publicProfileShareCopy(Map<String, dynamic> profile, String url) {
    final displayName =
        [
              profile['first_name'],
              profile['display_name'],
              profile['full_name'],
              profile['username'],
            ]
            .map((value) => value?.toString().trim() ?? '')
            .firstWhere((value) => value.isNotEmpty, orElse: () => '');

    if (displayName.isNotEmpty) {
      return 'Connect with $displayName on FaceMeet.\n\n$url\n\n'
          'FaceMeet is a video-first way to meet people through Sparks, Live Topics, and real conversations.';
    }

    return 'Connect with me on FaceMeet.\n\n'
        'FaceMeet is a video-first way to meet people through Sparks, Live Topics, and real conversations.\n\n'
        'My profile:\n$url';
  }

  Future<void> _sharePublicProfile(Map<String, dynamic> profile) async {
    if (_publicProfileActionInProgress) return;
    try {
      final publicUrl = await _ensurePublicProfileUrl(profile);
      final copy = _publicProfileShareCopy(profile, publicUrl);
      final shared = await _shareText(
        text: copy,
        subject: 'My FaceMeet profile',
      );
      if (!shared) {
        await Clipboard.setData(ClipboardData(text: publicUrl));
        if (mounted) {
          _showProfileSnack(
            'Share sheet unavailable. Public profile link copied.',
          );
        }
      }
    } catch (e) {
      final slug = profile['public_profile_slug']?.toString().trim() ?? '';
      var copiedFallback = false;
      if (slug.isNotEmpty) {
        await Clipboard.setData(
          ClipboardData(text: _publicProfileUrlFromSlug(slug)),
        );
        copiedFallback = true;
      }
      if (mounted) {
        _showProfileSnack(
          copiedFallback
              ? 'Share sheet unavailable. Public profile link copied.'
              : 'Could not create your public profile link.',
        );
      }
    }
  }

  Future<void> _copyPublicProfileLink(Map<String, dynamic> profile) async {
    if (_publicProfileActionInProgress) return;
    try {
      final publicUrl = await _ensurePublicProfileUrl(profile);
      await Clipboard.setData(ClipboardData(text: publicUrl));
      if (mounted) _showProfileSnack('Public profile link copied');
    } catch (e) {
      if (mounted) {
        _showProfileSnack(
          'Could not copy public profile link: ${e.toString().replaceFirst('Exception: ', '')}',
          isError: true,
        );
      }
    }
  }

  Future<void> _disablePublicProfile(Map<String, dynamic> profile) async {
    if (_publicProfileActionInProgress) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Disable public link?',
          style: GoogleFonts.dmSans(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          'Your public profile page will stop showing useful profile details. You can make it shareable again later.',
          style: GoogleFonts.dmSans(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              'Cancel',
              style: GoogleFonts.dmSans(color: AppTheme.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              'Disable',
              style: GoogleFonts.dmSans(
                color: AppTheme.error,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _publicProfileActionInProgress = true);
    try {
      await SupabaseService.instance.disableMyPublicProfile();
      profile['public_profile_enabled'] = false;
      if (mounted) {
        setState(() => _publicProfileActionInProgress = false);
        _showProfileSnack('Public profile link disabled');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _publicProfileActionInProgress = false);
        _showProfileSnack(
          'Could not disable public link: ${e.toString().replaceFirst('Exception: ', '')}',
          isError: true,
        );
      }
    }
  }

  void _showProfileSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, style: GoogleFonts.dmSans()),
        backgroundColor: isError ? AppTheme.error : AppTheme.sparkGreen,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _inviteContacts() async {
    final status = await Permission.contacts.request();
    if (!status.isGranted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Contacts permission is required to invite friends'),
          ),
        );
      }
      return;
    }

    try {
      final inviteUrl = await _ensureReferralShareUrl();
      final contacts = await FlutterContacts.getContacts(withProperties: true);
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => _ContactsInviteSheet(
          contacts: contacts,
          shareMessage: _referralShareMessage(inviteUrl),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not load contacts: $e')));
      }
    }
  }

  Future<void> _openSupportEmail() async {
    final uid = SupabaseService.instance.currentUserId;
    PackageInfo? packageInfo;
    try {
      packageInfo = await PackageInfo.fromPlatform();
    } catch (e) {
      debugPrint('SUPPORT EMAIL: package info unavailable: $e');
    }

    final platform = switch (defaultTargetPlatform) {
      TargetPlatform.iOS => 'iOS',
      TargetPlatform.android => 'Android',
      _ => kIsWeb ? 'Web' : defaultTargetPlatform.name,
    };

    final details = <String>[
      '',
      '',
      '---',
      if (uid != null && uid.isNotEmpty) 'User ID: $uid',
      if (packageInfo != null)
        'App version/build: ${packageInfo.version}+${packageInfo.buildNumber}',
      'Platform: $platform',
    ];

    final uri = Uri(
      scheme: 'mailto',
      path: 'support@facemeet.app',
      queryParameters: {
        'subject': 'FaceMeet Support Request',
        'body': details.join('\n'),
      },
    );

    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not open email app.',
              style: GoogleFonts.dmSans(),
            ),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } catch (e) {
      debugPrint('SUPPORT EMAIL: launch failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not open email app.',
              style: GoogleFonts.dmSans(),
            ),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      body: FutureBuilder<Map<String, dynamic>?>(
        future: _profileFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: AppTheme.primary),
            );
          }

          final profile = snapshot.data;
          if (profile == null) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: AppTheme.primary),
                  const SizedBox(height: 16),
                  Text(
                    'Loading profile…',
                    style: GoogleFonts.dmSans(color: AppTheme.textSecondary),
                  ),
                ],
              ),
            );
          }

          return _buildProfileContent(
            MediaQuery.of(context).size.width >= 600,
            profile,
          );
        },
      ),
    );
  }

  Widget _buildProfileContent(bool isTablet, Map<String, dynamic> profile) {
    final firstName = profile['first_name'] ?? '';
    final age = (profile['age'] as num?)?.toInt() ?? 0;
    final city = profile['city'] ?? '';
    final videoUrl = profile['profile_video_url'] ?? '';
    final isVerified = profile['verification_status'] == 'verified';
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    if (isTablet) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 360,
            child: ProfileVideoHeroWidget(
              videoUrl: videoUrl,
              name: firstName,
              age: age,
              city: city,
              isVerified: isVerified,
              onVideoUpdated: _refreshProfile,
              onSettingsTap: () => _openSettings(profile),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(24, 32, 24, 120 + keyboardInset),
              child: _buildInfoSection(profile),
            ),
          ),
        ],
      );
    }

    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ProfileVideoHeroWidget(
            videoUrl: videoUrl,
            name: firstName,
            age: age,
            city: city,
            isVerified: isVerified,
            onVideoUpdated: _refreshProfile,
            onSettingsTap: () => _openSettings(profile),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: _buildInfoSection(profile),
          ),
          const SizedBox(height: 140),
        ],
      ),
    );
  }

  Widget _buildInfoSection(Map<String, dynamic> profile) {
    final username = profile['username'] as String? ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 12),
          child: Row(
            children: [
              Expanded(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        username.isNotEmpty ? '@$username' : 'Set username',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.outfit(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    GestureDetector(
                      onTap: () => _showUsernameEditSheet(username),
                      child: const Icon(
                        Icons.edit_rounded,
                        color: Color(0xFFE8503A),
                        size: 14,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Tooltip(
                message: 'Settings',
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => _openSettings(profile),
                    borderRadius: BorderRadius.circular(18),
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: AppTheme.surfaceGlass,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: AppTheme.borderGlass),
                      ),
                      child: const Icon(
                        Icons.settings_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),

        // Stats row
        _statsLoading
            ? _buildStatsShimmer()
            : ProfileStatsWidget(
                sparkCount: _sparkCount ?? 0,
                sessionCount: _sessionCount ?? 0,
                matchCount: _matchCount ?? 0,
              ),
        const SizedBox(height: 20),

        // Invite Friends card
        _buildInviteFriendsCard(),
        const SizedBox(height: 20),

        _buildPublicProfileCard(profile),
        const SizedBox(height: 20),

        KeyedSubtree(
          key: _aboutMeSectionKey,
          child: _SectionCard(
            title: 'About me',
            trailing: _isEditing
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      GestureDetector(
                        onTap: () => _cancelEdit(profile),
                        child: Text(
                          'Cancel',
                          style: GoogleFonts.dmSans(
                            fontSize: 13,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: _isSaving ? null : () => _toggleEdit(profile),
                        child: _isSaving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  color: AppTheme.primary,
                                  strokeWidth: 2,
                                ),
                              )
                            : Text(
                                'Save',
                                style: GoogleFonts.dmSans(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.primary,
                                ),
                              ),
                      ),
                    ],
                  )
                : GestureDetector(
                    onTap: () => _toggleEdit(profile),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.edit_rounded,
                          color: AppTheme.textMuted,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Edit',
                          style: GoogleFonts.dmSans(
                            fontSize: 13,
                            color: AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
            child: ProfileEditBioWidget(
              bio: _editBio,
              isEditing: _isEditing,
              focusNode: _bioFocusNode,
              onChanged: (v) => _editBio = v,
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'Interests',
          child: ProfileInterestsWidget(
            interests: _editInterests,
            isEditing: _isEditing,
            onChanged: (interests) =>
                setState(() => _editInterests = interests),
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: 'What are you open to?',
          child: _ConnectionIntentEditor(
            value: _editConnectionIntent,
            isEditing: _isEditing,
            onChanged: (value) {
              setState(() => _editConnectionIntent = value);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPublicProfileCard(Map<String, dynamic> profile) {
    final enabled = profile['public_profile_enabled'] == true;
    final slug = profile['public_profile_slug']?.toString().trim() ?? '';
    final hasLink = enabled && slug.isNotEmpty;

    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppTheme.surfaceGlass,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.borderGlass, width: 1),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withAlpha(30),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.ios_share_rounded,
                      color: AppTheme.primary,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Public Profile',
                          style: GoogleFonts.dmSans(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          hasLink
                              ? 'Share your public video page so people can watch your intro and Spark you.'
                              : 'Create a public video page so people can watch your intro and Spark you.',
                          style: GoogleFonts.dmSans(
                            fontSize: 12,
                            color: Colors.white70,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (hasLink) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1E),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _publicProfileUrlFromSlug(slug),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.dmSans(
                      fontSize: 12,
                      color: Colors.white70,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton.icon(
                  onPressed: _publicProfileActionInProgress
                      ? null
                      : () => _sharePublicProfile(profile),
                  icon: _publicProfileActionInProgress
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.ios_share_rounded, size: 18),
                  label: Text(
                    'Share My Profile',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.dmSans(
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: AppTheme.surfaceGlass,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                ),
              ),
              if (hasLink) ...[
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _publicProfileActionInProgress
                            ? null
                            : () => _copyPublicProfileLink(profile),
                        icon: const Icon(Icons.copy_rounded, size: 16),
                        label: Text(
                          'Copy Link',
                          style: GoogleFonts.dmSans(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: BorderSide(color: AppTheme.borderGlass),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextButton(
                        onPressed: _publicProfileActionInProgress
                            ? null
                            : () => _disablePublicProfile(profile),
                        child: Text(
                          'Disable Link',
                          style: GoogleFonts.dmSans(
                            color: AppTheme.error,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ─── Invite Friends Card ──────────────────────────────────────────────────

  Widget _buildInviteFriendsCard() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceGlass,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.borderGlass, width: 1),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  const Icon(
                    Icons.bolt_rounded,
                    color: Color(0xFFE8503A),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Invite Friends — Earn Free Sparks',
                    style: GoogleFonts.dmSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.textMuted,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // Referral link pill
              _referralLoading
                  ? Container(
                      height: 44,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1E),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    )
                  : Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1E),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _inviteShareUrl,
                              style: GoogleFonts.dmSans(
                                fontSize: 12,
                                color: Colors.white70,
                              ),
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                            ),
                          ),
                          const SizedBox(width: 8),
                          GestureDetector(
                            onTap: () async {
                              final inviteUrl = await _ensureReferralShareUrl();
                              await Clipboard.setData(
                                ClipboardData(text: inviteUrl),
                              );
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(
                                    'Link copied',
                                    style: GoogleFonts.dmSans(),
                                  ),
                                  backgroundColor: AppTheme.sparkGreen,
                                  duration: const Duration(seconds: 2),
                                ),
                              );
                            },
                            child: const Icon(
                              Icons.copy_rounded,
                              color: Color(0xFFE8503A),
                              size: 18,
                            ),
                          ),
                        ],
                      ),
                    ),
              const SizedBox(height: 14),

              // Share buttons row
              Row(
                children: [
                  Expanded(
                    child: _ShareButton(
                      label: 'WhatsApp',
                      color: const Color(0xFF25D366),
                      icon: Icons.chat_rounded,
                      onTap: _shareWhatsApp,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ShareButton(
                      label: 'SMS',
                      color: const Color(0xFF555555),
                      icon: Icons.sms_rounded,
                      onTap: _shareSms,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ShareButton(
                      label: 'More',
                      color: const Color(0xFF333338),
                      icon: Icons.ios_share_rounded,
                      onTap: _shareMore,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Invite Contacts button
              GestureDetector(
                onTap: _inviteContacts,
                child: Container(
                  width: double.infinity,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0x1AE8503A),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(0x33E8503A),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.people_rounded,
                        color: Color(0xFFE8503A),
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Invite Contacts',
                        style: GoogleFonts.dmSans(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: const Color(0xFFE8503A),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),

              // Stats line
              _referralLoading
                  ? const SizedBox.shrink()
                  : Text(
                      'Friends invited: $_friendsCount · Sparks earned: $_sparksEarned',
                      style: GoogleFonts.dmSans(
                        fontSize: 12,
                        color: AppTheme.textMuted,
                      ),
                    ),
              const SizedBox(height: 6),

              // Earn info line
              Text(
                'Earn 1 Spark per friend who joins. Earn 3 bonus Sparks when they upgrade.',
                style: GoogleFonts.dmSans(
                  fontSize: 12,
                  color: const Color(0xFFE8503A),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatsShimmer() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceGlass,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.borderGlass, width: 1),
          ),
          padding: const EdgeInsets.symmetric(vertical: 20),
          child: Row(
            children: [
              Expanded(child: _ShimmerStatItem()),
              Container(width: 1, height: 40, color: AppTheme.borderGlass),
              Expanded(child: _ShimmerStatItem()),
              Container(width: 1, height: 40, color: AppTheme.borderGlass),
              Expanded(child: _ShimmerStatItem()),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsScreen extends StatefulWidget {
  final Map<String, dynamic> profile;
  final WebPushSetupResult? notificationState;
  final bool notificationActionInProgress;
  final Future<void> Function() onEnableWebNotifications;
  final Future<void> Function() onSendWebTestNotification;
  final Future<void> Function() onOpenSupportEmail;
  final Future<void> Function() onResetDiscovery;
  final Future<void> Function() onDeleteAccount;
  final VoidCallback onLogout;
  final VoidCallback onSocialLinksSaved;

  const _SettingsScreen({
    required this.profile,
    required this.notificationState,
    required this.notificationActionInProgress,
    required this.onEnableWebNotifications,
    required this.onSendWebTestNotification,
    required this.onOpenSupportEmail,
    required this.onResetDiscovery,
    required this.onDeleteAccount,
    required this.onLogout,
    required this.onSocialLinksSaved,
  });

  @override
  State<_SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<_SettingsScreen> {
  late final TextEditingController _xController;
  late final TextEditingController _instagramController;
  late final TextEditingController _tiktokController;
  late final TextEditingController _facebookController;
  late final TextEditingController _linkedinController;
  late final TextEditingController _websiteController;
  bool _isSavingSocialLinks = false;

  @override
  void initState() {
    super.initState();
    final links = _parseSocialLinks(widget.profile['social_links']);
    _xController = TextEditingController(text: links['x'] ?? '');
    _instagramController = TextEditingController(
      text: links['instagram'] ?? '',
    );
    _tiktokController = TextEditingController(text: links['tiktok'] ?? '');
    _facebookController = TextEditingController(text: links['facebook'] ?? '');
    _linkedinController = TextEditingController(text: links['linkedin'] ?? '');
    _websiteController = TextEditingController(text: links['website'] ?? '');
  }

  @override
  void dispose() {
    _xController.dispose();
    _instagramController.dispose();
    _tiktokController.dispose();
    _facebookController.dispose();
    _linkedinController.dispose();
    _websiteController.dispose();
    super.dispose();
  }

  Map<String, String> _parseSocialLinks(dynamic raw) {
    if (raw is Map) {
      return raw.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    }
    return const {};
  }

  String _cleanSocialValue(String value, {bool website = false}) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return '';
    if (website &&
        !trimmed.startsWith('https://') &&
        !trimmed.startsWith('http://')) {
      return 'https://$trimmed';
    }
    return trimmed;
  }

  Future<void> _saveSocialLinks() async {
    setState(() => _isSavingSocialLinks = true);
    final links = <String, String>{
      'x': _cleanSocialValue(_xController.text),
      'instagram': _cleanSocialValue(_instagramController.text),
      'tiktok': _cleanSocialValue(_tiktokController.text),
      'facebook': _cleanSocialValue(_facebookController.text),
      'linkedin': _cleanSocialValue(_linkedinController.text),
      'website': _cleanSocialValue(_websiteController.text, website: true),
    }..removeWhere((_, value) => value.trim().isEmpty);

    try {
      await SupabaseService.instance.updateUserProfile({'social_links': links});
      widget.profile['social_links'] = links;
      widget.onSocialLinksSaved();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Social Links saved', style: GoogleFonts.dmSans()),
          backgroundColor: AppTheme.sparkGreen,
        ),
      );
    } catch (error) {
      debugPrint('SOCIAL LINKS: save failed — $error');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Social Links are not ready to save yet.',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSavingSocialLinks = false);
    }
  }

  String get _email => widget.profile['email']?.toString().trim() ?? '';

  @override
  Widget build(BuildContext context) {
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundDark,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          'Settings',
          style: GoogleFonts.dmSans(fontWeight: FontWeight.w800),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(20, 12, 20, 120 + keyboardInset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _SectionCard(
                title: 'Account',
                child: _SettingsRow(
                  icon: Icons.account_circle_outlined,
                  label: _email.isEmpty ? 'FaceMeet account' : _email,
                  subtitleBuilder: (_) => Text(
                    'Your signed-in FaceMeet account.',
                    style: GoogleFonts.dmSans(
                      fontSize: 12,
                      color: AppTheme.textMuted,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: 'Notifications',
                child: Column(
                  children: [
                    _SettingsRow(
                      icon: Icons.notifications_outlined,
                      label: 'Spark Session alerts',
                      subtitleBuilder: (_) => Text(
                        'Alerts for Sparks, sessions, chats, and Live Topics.',
                        style: GoogleFonts.dmSans(
                          fontSize: 12,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                    if (kIsWeb) ...[
                      Divider(color: AppTheme.borderGlass, height: 1),
                      _SettingsRow(
                        icon: Icons.notifications_active_outlined,
                        label: 'Web notifications',
                        subtitleBuilder: (_) => Text(
                          widget.notificationState?.status ??
                              'Enable alerts in this browser.',
                          style: GoogleFonts.dmSans(
                            fontSize: 12,
                            color: AppTheme.textMuted,
                          ),
                        ),
                        trailing: widget.notificationActionInProgress
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  color: AppTheme.primary,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                Icons.chevron_right_rounded,
                                color: AppTheme.textMuted,
                              ),
                        onTap: widget.notificationActionInProgress
                            ? null
                            : widget.onEnableWebNotifications,
                      ),
                      Divider(color: AppTheme.borderGlass, height: 1),
                      _SettingsRow(
                        icon: Icons.send_rounded,
                        label: 'Send test notification',
                        onTap: widget.notificationActionInProgress
                            ? null
                            : widget.onSendWebTestNotification,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: 'Privacy & Safety',
                child: Column(
                  children: [
                    _SettingsRow(
                      icon: Icons.visibility_outlined,
                      label: 'Online status',
                      subtitleBuilder: (_) => Text(
                        'Your activity state helps conversations feel current.',
                        style: GoogleFonts.dmSans(
                          fontSize: 12,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                    Divider(color: AppTheme.borderGlass, height: 1),
                    _SettingsRow(
                      icon: Icons.health_and_safety_outlined,
                      label: 'Community Guidelines',
                      subtitleBuilder: (_) => Text(
                        'No harassment, exploitation, fake profiles, or unsafe behavior.',
                        style: GoogleFonts.dmSans(
                          fontSize: 12,
                          color: AppTheme.textMuted,
                        ),
                      ),
                    ),
                    Divider(color: AppTheme.borderGlass, height: 1),
                    _SettingsRow(
                      icon: Icons.refresh_rounded,
                      label: 'Reset Discovery Feed',
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        color: AppTheme.textMuted,
                        size: 20,
                      ),
                      onTap: widget.onResetDiscovery,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: 'Social Links',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Add your public social links so people can find you outside FaceMeet.',
                      style: GoogleFonts.dmSans(
                        color: AppTheme.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 14),
                    _SocialLinkField(
                      controller: _xController,
                      label: 'X / Twitter',
                      hint: '@username or https://x.com/username',
                    ),
                    _SocialLinkField(
                      controller: _instagramController,
                      label: 'Instagram',
                      hint: '@username or Instagram URL',
                    ),
                    _SocialLinkField(
                      controller: _tiktokController,
                      label: 'TikTok',
                      hint: '@username or TikTok URL',
                    ),
                    _SocialLinkField(
                      controller: _facebookController,
                      label: 'Facebook',
                      hint: 'Facebook profile/page URL',
                    ),
                    _SocialLinkField(
                      controller: _linkedinController,
                      label: 'LinkedIn',
                      hint: 'LinkedIn profile URL',
                    ),
                    _SocialLinkField(
                      controller: _websiteController,
                      label: 'Website',
                      hint: 'https://your-site.com',
                      keyboardType: TextInputType.url,
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed: _isSavingSocialLinks ? null : _saveSocialLinks,
                      icon: _isSavingSocialLinks
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.save_rounded),
                      label: Text(
                        _isSavingSocialLinks
                            ? 'Saving...'
                            : 'Save Social Links',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(50),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        textStyle: GoogleFonts.dmSans(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: 'Subscription / Sparks',
                child: _SettingsRow(
                  icon: Icons.workspace_premium_rounded,
                  label: 'Buy Sparks / Subscriptions',
                  subtitleBuilder: (_) => Text(
                    'Manage FaceMeet Sparks and membership options.',
                    style: GoogleFonts.dmSans(
                      fontSize: 12,
                      color: AppTheme.textMuted,
                    ),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: AppTheme.textMuted,
                    size: 20,
                  ),
                  onTap: () =>
                      Navigator.pushNamed(context, AppRoutes.pricingScreen),
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: 'Support',
                child: Column(
                  children: [
                    _SettingsRow(
                      icon: Icons.event_available_rounded,
                      label: 'FaceMeet Events',
                      subtitleBuilder: (_) => Text(
                        'Request invite-only access to curated FaceMeet events.',
                        style: GoogleFonts.dmSans(
                          fontSize: 12,
                          color: AppTheme.textMuted,
                        ),
                      ),
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        color: AppTheme.textMuted,
                        size: 20,
                      ),
                      onTap: () =>
                          Navigator.pushNamed(context, AppRoutes.eventsScreen),
                    ),
                    Divider(color: AppTheme.borderGlass, height: 1),
                    _SettingsRow(
                      icon: Icons.help_outline_rounded,
                      label: 'Help & Support',
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        color: AppTheme.textMuted,
                        size: 20,
                      ),
                      onTap: widget.onOpenSupportEmail,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: 'Session',
                child: _SettingsRow(
                  icon: Icons.logout_rounded,
                  label: 'Sign out',
                  foregroundColor: AppTheme.primary,
                  onTap: widget.onLogout,
                ),
              ),
              const SizedBox(height: 16),
              _SectionCard(
                title: 'Danger Zone',
                child: _SettingsRow(
                  icon: Icons.delete_forever_outlined,
                  label: 'Delete Account',
                  foregroundColor: AppTheme.error,
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: AppTheme.error,
                    size: 20,
                  ),
                  onTap: widget.onDeleteAccount,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SocialLinkField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final TextInputType? keyboardType;

  const _SocialLinkField({
    required this.controller,
    required this.label,
    required this.hint,
    this.keyboardType,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        textInputAction: TextInputAction.next,
        style: GoogleFonts.dmSans(color: Colors.white),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          labelStyle: GoogleFonts.dmSans(color: AppTheme.textSecondary),
          hintStyle: GoogleFonts.dmSans(color: AppTheme.textMuted),
          filled: true,
          fillColor: Colors.white.withAlpha(15),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppTheme.borderGlass),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppTheme.borderGlass),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: AppTheme.primary, width: 1.4),
          ),
        ),
      ),
    );
  }
}

// ─── Delete Account Confirmation Sheet ───────────────────────────────────────

class _DeleteAccountConfirmationSheet extends StatefulWidget {
  final Future<void> Function() onConfirmed;

  const _DeleteAccountConfirmationSheet({required this.onConfirmed});

  @override
  State<_DeleteAccountConfirmationSheet> createState() =>
      _DeleteAccountConfirmationSheetState();
}

class _DeleteAccountConfirmationSheetState
    extends State<_DeleteAccountConfirmationSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _isDeleting = false;

  bool get _canDelete => _controller.text.trim().toUpperCase() == 'DELETE';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (!_canDelete || _isDeleting) return;
    setState(() => _isDeleting = true);
    try {
      await widget.onConfirmed();
    } catch (e) {
      debugPrint('ACCOUNT DELETE: UI deletion failed — $e');
      if (!mounted) return;
      setState(() => _isDeleting = false);
      final message = e.toString().replaceFirst('Exception: ', '');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Account deletion failed: $message',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.error,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.borderGlass,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: AppTheme.error,
                  size: 22,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Final confirmation',
                    style: GoogleFonts.dmSans(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Type DELETE to permanently delete your account. You will be signed out and returned to the login screen.',
              style: GoogleFonts.dmSans(
                fontSize: 13,
                color: AppTheme.textSecondary,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              enabled: !_isDeleting,
              textCapitalization: TextCapitalization.characters,
              style: GoogleFonts.dmSans(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
              decoration: InputDecoration(
                hintText: 'DELETE',
                hintStyle: GoogleFonts.dmSans(color: AppTheme.textMuted),
                filled: true,
                fillColor: const Color(0xFF0D0D0F),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _canDelete && !_isDeleting ? _delete : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.error,
                  disabledBackgroundColor: const Color(0xFF333338),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isDeleting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Text(
                        'Delete My Account',
                        style: GoogleFonts.dmSans(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: TextButton(
                onPressed: _isDeleting ? null : () => Navigator.pop(context),
                child: Text(
                  'Cancel',
                  style: GoogleFonts.dmSans(
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Username Edit Bottom Sheet ───────────────────────────────────────────────

class _UsernameEditSheet extends StatefulWidget {
  final String currentUsername;
  final void Function(String) onSaved;

  const _UsernameEditSheet({
    required this.currentUsername,
    required this.onSaved,
  });

  @override
  State<_UsernameEditSheet> createState() => _UsernameEditSheetState();
}

class _UsernameEditSheetState extends State<_UsernameEditSheet> {
  late TextEditingController _ctrl;
  bool? _isAvailable;
  bool _checking = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.currentUsername);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _checkAvailability(String value) async {
    if (value.trim().isEmpty) {
      setState(() => _isAvailable = null);
      return;
    }
    setState(() => _checking = true);
    final available = await ReferralService.instance.isUsernameAvailable(value);
    if (mounted) {
      setState(() {
        _isAvailable = available;
        _checking = false;
      });
    }
  }

  Future<void> _save() async {
    final username = _ctrl.text.trim();
    if (username.isEmpty || _isAvailable == false) return;
    setState(() => _saving = true);
    try {
      await ReferralService.instance.updateUsername(username);
      if (mounted) {
        Navigator.pop(context);
        widget.onSaved(username);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Username updated', style: GoogleFonts.dmSans()),
            backgroundColor: AppTheme.sparkGreen,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to save: $e', style: GoogleFonts.dmSans()),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.borderGlass,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'Edit Username',
              style: GoogleFonts.dmSans(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _ctrl,
              autofocus: true,
              style: GoogleFonts.dmSans(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Enter username',
                hintStyle: GoogleFonts.dmSans(color: AppTheme.textMuted),
                filled: true,
                fillColor: const Color(0xFF0D0D0F),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: _checking
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppTheme.primary,
                          ),
                        ),
                      )
                    : _isAvailable == null
                    ? null
                    : Icon(
                        _isAvailable!
                            ? Icons.check_circle_rounded
                            : Icons.cancel_rounded,
                        color: _isAvailable!
                            ? AppTheme.sparkGreen
                            : AppTheme.error,
                      ),
              ),
              onChanged: (v) {
                setState(() => _isAvailable = null);
                Future.delayed(const Duration(milliseconds: 500), () {
                  if (_ctrl.text == v) _checkAvailability(v);
                });
              },
            ),
            if (_isAvailable == false) ...[
              const SizedBox(height: 6),
              Text(
                'Already taken',
                style: GoogleFonts.dmSans(fontSize: 12, color: AppTheme.error),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: (_saving || _isAvailable == false) ? null : _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE8503A),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Text(
                        'Save',
                        style: GoogleFonts.dmSans(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Contacts Invite Sheet ────────────────────────────────────────────────────

class _ContactsInviteSheet extends StatefulWidget {
  final List<Contact> contacts;
  final String shareMessage;

  const _ContactsInviteSheet({
    required this.contacts,
    required this.shareMessage,
  });

  @override
  State<_ContactsInviteSheet> createState() => _ContactsInviteSheetState();
}

class _ContactsInviteSheetState extends State<_ContactsInviteSheet> {
  final Set<int> _selected = {};
  String _search = '';

  List<Contact> get _filtered {
    if (_search.isEmpty) return widget.contacts;
    final q = _search.toLowerCase();
    return widget.contacts
        .where((c) => c.displayName.toLowerCase().contains(q))
        .toList();
  }

  Future<void> _sendInvites() async {
    Navigator.pop(context);
    await Share.share(widget.shareMessage, subject: 'Join me on FaceMeet');
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      minChildSize: 0.5,
      expand: false,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.borderGlass,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
              child: Column(
                children: [
                  Text(
                    'Invite Contacts',
                    style: GoogleFonts.dmSans(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    style: GoogleFonts.dmSans(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Search contacts…',
                      hintStyle: GoogleFonts.dmSans(color: AppTheme.textMuted),
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        color: AppTheme.textMuted,
                      ),
                      filled: true,
                      fillColor: const Color(0xFF0D0D0F),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onChanged: (v) => setState(() => _search = v),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                controller: scrollCtrl,
                itemCount: _filtered.length,
                itemBuilder: (_, i) {
                  final contact = _filtered[i];
                  final isSelected = _selected.contains(i);
                  return CheckboxListTile(
                    value: isSelected,
                    onChanged: (v) {
                      setState(() {
                        if (v == true) {
                          _selected.add(i);
                        } else {
                          _selected.remove(i);
                        }
                      });
                    },
                    title: Text(
                      contact.displayName,
                      style: GoogleFonts.dmSans(color: Colors.white),
                    ),
                    activeColor: const Color(0xFFE8503A),
                    checkColor: Colors.white,
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: _selected.isEmpty ? null : _sendInvites,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE8503A),
                    disabledBackgroundColor: const Color(0xFF333338),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Text(
                    _selected.isEmpty
                        ? 'Send Invites'
                        : 'Send Invites (${_selected.length})',
                    style: GoogleFonts.dmSans(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Share Button ─────────────────────────────────────────────────────────────

class _ShareButton extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  final VoidCallback onTap;

  const _ShareButton({
    required this.label,
    required this.color,
    required this.icon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(height: 2),
            Text(
              label,
              style: GoogleFonts.dmSans(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Shimmer / Section helpers (unchanged) ────────────────────────────────────

class _ShimmerStatItem extends StatefulWidget {
  @override
  State<_ShimmerStatItem> createState() => _ShimmerStatItemState();
}

class _ShimmerStatItemState extends State<_ShimmerStatItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 0.7).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => Column(
        children: [
          Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: _anim.value * 0.3),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 6),
          Container(
            width: 32,
            height: 20,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: _anim.value * 0.4),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: 4),
          Container(
            width: 56,
            height: 10,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: _anim.value * 0.2),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  final Widget? trailing;

  const _SectionCard({required this.title, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(20),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceGlass,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: AppTheme.borderGlass, width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
                child: Row(
                  children: [
                    Text(
                      title,
                      style: GoogleFonts.dmSans(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textMuted,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const Spacer(),
                    if (trailing != null) trailing!,
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: child,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectionIntentEditor extends StatelessWidget {
  final String value;
  final bool isEditing;
  final ValueChanged<String> onChanged;

  const _ConnectionIntentEditor({
    required this.value,
    required this.isEditing,
    required this.onChanged,
  });

  static const _options = [
    _ConnectionIntentOption(value: 'dating', label: 'Social Connections'),
    _ConnectionIntentOption(value: 'friendship', label: 'Friendship'),
    _ConnectionIntentOption(
      value: 'professional',
      label: 'Professional Connections',
    ),
    _ConnectionIntentOption(value: 'open_to_all', label: 'Open to All'),
  ];

  @override
  Widget build(BuildContext context) {
    final normalized = SupabaseService.normalizeConnectionIntent(value);

    if (!isEditing) {
      return Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: 0.3),
              ),
            ),
            child: Text(
              SupabaseService.connectionIntentLabel(normalized),
              style: GoogleFonts.dmSans(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            ),
          ),
        ],
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _options
          .map((option) {
            final isSelected = option.value == normalized;
            return GestureDetector(
              onTap: () => onChanged(option.value),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  color: isSelected ? AppTheme.primary : AppTheme.surfaceGlass,
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: isSelected ? AppTheme.primary : AppTheme.borderGlass,
                  ),
                ),
                child: Text(
                  option.label,
                  style: GoogleFonts.dmSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: isSelected ? Colors.white : AppTheme.textSecondary,
                  ),
                ),
              ),
            );
          })
          .toList(growable: false),
    );
  }
}

class _ConnectionIntentOption {
  final String value;
  final String label;

  const _ConnectionIntentOption({required this.value, required this.label});
}

class _SettingsRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? foregroundColor;
  final WidgetBuilder? subtitleBuilder;

  const _SettingsRow({
    required this.icon,
    required this.label,
    this.trailing,
    this.onTap,
    this.foregroundColor,
    this.subtitleBuilder,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Icon(
              icon,
              color: foregroundColor ?? AppTheme.textSecondary,
              size: 20,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: GoogleFonts.dmSans(
                      fontSize: 14,
                      color: foregroundColor ?? Colors.white,
                    ),
                  ),
                  if (subtitleBuilder != null) ...[
                    const SizedBox(height: 4),
                    subtitleBuilder!(context),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}
