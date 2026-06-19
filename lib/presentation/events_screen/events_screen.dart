import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';

class EventsScreen extends StatefulWidget {
  const EventsScreen({super.key});

  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  bool _loading = true;
  bool _requesting = false;
  String? _requestingEventId;
  bool _withdrawing = false;
  String? _withdrawingEventId;
  String? _error;
  Map<String, dynamic>? _profile;
  List<Map<String, dynamic>> _events = const [];
  Map<String, String> _statuses = const {};
  Map<String, Map<String, dynamic>> _eventAccessDetailsByEventId = const {};
  Map<String, Map<String, dynamic>> _eventPairingPreferencesByEventId =
      const {};
  bool _hasChatUnlockedMatch = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final results = await Future.wait([
        SupabaseService.instance.getCurrentUserProfile(),
        SupabaseService.instance.getMyAccessibleEvents(),
        SupabaseService.instance.getCurrentUserEventStatuses(),
        SupabaseService.instance.hasChatUnlockedMatch(),
        SupabaseService.instance.getMyEventAccessDetails(),
      ]);

      final profile = results[0] as Map<String, dynamic>?;
      final events = List<Map<String, dynamic>>.from(results[1] as List);
      final statuses = Map<String, String>.from(results[2] as Map);
      final hasChatUnlockedMatch = results[3] as bool;
      final accessDetailsRows = List<Map<String, dynamic>>.from(
        results[4] as List,
      );
      final eventAccessDetailsByEventId = <String, Map<String, dynamic>>{};
      for (final row in accessDetailsRows) {
        final eventId = row['event_id']?.toString();
        if (eventId == null || eventId.isEmpty) continue;
        eventAccessDetailsByEventId[eventId] = Map<String, dynamic>.from(row);
      }
      final pairingPreferenceResponses = await Future.wait(
        events.map((event) async {
          final eventId = event['id']?.toString();
          if (eventId == null || eventId.isEmpty) return null;
          try {
            return await SupabaseService.instance.getMyEventPairingPreferences(
              eventId,
            );
          } catch (_) {
            return null;
          }
        }),
      );
      final eventPairingPreferencesByEventId = <String, Map<String, dynamic>>{};
      for (final row in pairingPreferenceResponses) {
        final eventId = row?['event_id']?.toString();
        if (eventId == null || eventId.isEmpty) continue;
        eventPairingPreferencesByEventId[eventId] = Map<String, dynamic>.from(
          row!,
        );
      }

      events.sort((a, b) {
        final aRank = (a['location_relevance_rank'] as num?)?.toInt() ?? 5;
        final bRank = (b['location_relevance_rank'] as num?)?.toInt() ?? 5;
        if (aRank != bRank) return aRank.compareTo(bRank);
        final aFeatured =
            a['featured'] == true ||
            (a['visibility']?.toString() ?? '') == 'featured';
        final bFeatured =
            b['featured'] == true ||
            (b['visibility']?.toString() ?? '') == 'featured';
        if (aFeatured != bFeatured) return aFeatured ? -1 : 1;
        final aStarts = DateTime.tryParse(a['starts_at']?.toString() ?? '');
        final bStarts = DateTime.tryParse(b['starts_at']?.toString() ?? '');
        if (aStarts == null && bStarts == null) return 0;
        if (aStarts == null) return 1;
        if (bStarts == null) return -1;
        return aStarts.compareTo(bStarts);
      });

      if (!mounted) return;
      setState(() {
        _profile = profile;
        _events = events;
        _statuses = statuses;
        _eventAccessDetailsByEventId = eventAccessDetailsByEventId;
        _eventPairingPreferencesByEventId = eventPairingPreferencesByEventId;
        _hasChatUnlockedMatch = hasChatUnlockedMatch;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _requestInvite(String eventId) async {
    final userId = SupabaseService.instance.currentUserId;
    if (userId == null) return;

    setState(() {
      _requesting = true;
      _requestingEventId = eventId;
    });

    try {
      final row = await SupabaseService.instance.requestEventInvite(
        eventId,
        userId,
      );
      final status = row['status']?.toString() ?? 'requested';
      if (!mounted) return;
      setState(() {
        _statuses = {..._statuses, eventId: status};
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status == 'requested'
                ? 'Invite request sent.'
                : 'Your event status is $status.',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.sparkGreen,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final errorText = e.toString();
      final message = errorText.contains('match_required')
          ? 'Unlock a mutual Match first to request access to this event.'
          : 'Could not request your invite yet. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message, style: GoogleFonts.dmSans()),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _requesting = false;
          _requestingEventId = null;
        });
      }
    }
  }

  Future<void> _withdrawRequest(String eventId) async {
    setState(() {
      _withdrawing = true;
      _withdrawingEventId = eventId;
    });

    try {
      final row = await SupabaseService.instance.withdrawEventRequest(eventId);
      final status = row['status']?.toString() ?? 'cancelled';
      if (!mounted) return;
      setState(() {
        _statuses = {..._statuses, eventId: status};
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Event request withdrawn.',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.sparkGreen,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Could not withdraw this request yet. Please try again.',
            style: GoogleFonts.dmSans(),
          ),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _withdrawing = false;
          _withdrawingEventId = null;
        });
      }
    }
  }

  bool get _hasVideoProfile {
    final videoUrl = _profile?['profile_video_url']?.toString().trim() ?? '';
    return videoUrl.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          'FaceMeet Events',
          style: GoogleFonts.outfit(fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: AppTheme.primary),
              )
            : RefreshIndicator(
                color: AppTheme.primary,
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
                  children: [
                    _buildHeroCard(),
                    if (!_hasVideoProfile) ...[
                      const SizedBox(height: 16),
                      _buildQualificationCard(),
                    ],
                    const SizedBox(height: 20),
                    if (_error != null)
                      _buildErrorCard()
                    else if (_events.isEmpty)
                      _buildEmptyCard()
                    else
                      ..._events.map(_buildEventCard),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildHeroCard() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF24110F), Color(0xFF100D0D)],
        ),
        border: Border.all(color: const Color(0x33E8503A)),
      ),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0x22E8503A),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              'Dallas preview',
              style: GoogleFonts.dmSans(
                color: AppTheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Curated in-person experiences for members who are ready to turn real video chemistry into real moments.',
            style: GoogleFonts.cormorantGaramond(
              fontSize: 30,
              height: 1.08,
              fontWeight: FontWeight.w700,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Limited guest lists. Approval-required event drops. Real-world access for members ready to meet beyond the screen, starting in Dallas.',
            style: GoogleFonts.dmSans(
              fontSize: 14,
              height: 1.65,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQualificationCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x141B84FF),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x334CC9F0)),
      ),
      padding: const EdgeInsets.all(18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.videocam_rounded, color: Color(0xFF4CC9F0)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Complete your video profile to improve your invite priority.',
              style: GoogleFonts.dmSans(
                color: Colors.white,
                fontSize: 13,
                height: 1.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0x14E8503A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x33E8503A)),
      ),
      padding: const EdgeInsets.all(18),
      child: Text(
        'We could not load FaceMeet Events right now. Pull to try again.',
        style: GoogleFonts.dmSans(color: Colors.white, height: 1.5),
      ),
    );
  }

  Widget _buildEmptyCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceGlass,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Dallas Event Access Opens Soon',
            style: GoogleFonts.dmSans(
              fontWeight: FontWeight.w700,
              color: Colors.white,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'We are preparing the first curated FaceMeet event drop for Dallas members. Complete your video profile now to improve your invite priority when access opens.',
            style: GoogleFonts.dmSans(
              color: AppTheme.textSecondary,
              fontSize: 13,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'Approved members will see future drops here first.',
            style: GoogleFonts.dmSans(
              color: AppTheme.textMuted,
              fontSize: 12,
              height: 1.55,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEventCard(Map<String, dynamic> event) {
    final eventId = event['id']?.toString() ?? '';
    final status = _statuses[eventId];
    final requestBusy = _requesting && _requestingEventId == eventId;
    final withdrawBusy = _withdrawing && _withdrawingEventId == eventId;
    final guestListStatus = _normalizedGuestListStatus(
      event['guest_list_status']?.toString(),
    );
    final accessNote = event['access_note']?.toString().trim() ?? '';
    final accessMode = _normalizedAccessMode(event['access_mode']?.toString());
    final accessDetails = _eventAccessDetailsByEventId[eventId];
    final ticketState = accessDetails?['ticket_state']?.toString();
    final pairingPreferences =
        _eventPairingPreferencesByEventId[eventId] ??
        <String, dynamic>{
          'event_id': eventId,
          'pairing_preferences_status': 'closed',
          'open_to_new_intro': false,
          'attend_with_open_social_access': false,
          'selected_match_ids': const [],
        };

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceGlass,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.borderGlass),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  event['title']?.toString() ?? 'Untitled event',
                  style: GoogleFonts.dmSans(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (event['featured'] == true ||
                  event['visibility']?.toString() == 'featured')
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0x22D4A847),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'Featured Drop',
                    style: GoogleFonts.dmSans(
                      color: const Color(0xFFD4A847),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _guestListPill(guestListStatus),
              _accessModePill(accessMode),
              _pill(event['event_type']?.toString() ?? 'Event'),
              _pill(event['city_name']?.toString() ?? 'Dallas'),
              _pill(_formatDateRange(event['starts_at'], event['ends_at'])),
              _pill(
                _inviteRequirementLabel(
                  event['invite_requirement']?.toString(),
                ),
              ),
              if ((event['capacity'] as num?) != null &&
                  (event['capacity'] as num).toInt() > 0)
                _pill(
                  'Limited Guest List · ${(event['capacity'] as num).toInt()}',
                ),
              if ((event['venue_name']?.toString().trim() ?? '').isNotEmpty)
                _pill(event['venue_name'].toString()),
              if (event['video_required'] == true)
                _pill(
                  'Video Profile Required',
                  backgroundColor: const Color(0x22E8503A),
                  borderColor: const Color(0x44E8503A),
                  textColor: AppTheme.primary,
                ),
              if (event['verification_required'] == true)
                _pill(
                  'Verified Members Only',
                  backgroundColor: const Color(0x223A241D),
                  borderColor: const Color(0x55E8503A),
                  textColor: const Color(0xFFFFC1B8),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            event['short_description']?.toString().trim().isNotEmpty == true
                ? event['short_description'].toString()
                : 'Curated FaceMeet experience for verified members.',
            style: GoogleFonts.dmSans(
              color: AppTheme.textSecondary,
              fontSize: 13,
              height: 1.65,
            ),
          ),
          if (accessNote.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0x1A2A1714),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0x33E8503A)),
              ),
              padding: const EdgeInsets.all(14),
              child: Text(
                accessNote,
                style: GoogleFonts.dmSans(
                  color: const Color(0xFFF3D3CD),
                  fontSize: 12,
                  height: 1.6,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            _accessModeHelperCopy(accessMode),
            style: GoogleFonts.dmSans(
              color: AppTheme.textMuted,
              fontSize: 12,
              height: 1.55,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _guestListHelperCopy(guestListStatus),
            style: GoogleFonts.dmSans(
              color: AppTheme.textMuted,
              fontSize: 12,
              height: 1.55,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (_statusExplanation(status, ticketState).isNotEmpty) ...[
            const SizedBox(height: 12),
            _statusExplanationBlock(_statusExplanation(status, ticketState)),
          ],
          ...switch (_capacityHint(event)) {
            final String hint => [
              const SizedBox(height: 10),
              _statusExplanationBlock(hint, subtle: true),
            ],
            null => const <Widget>[],
          },
          const SizedBox(height: 18),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _requestButton(
                eventId: eventId,
                status: status,
                busy: requestBusy,
                guestListStatus: guestListStatus,
                accessMode: accessMode,
              ),
              if (_canWithdraw(status)) ...[
                const SizedBox(height: 10),
                _withdrawButton(eventId: eventId, busy: withdrawBusy),
              ],
            ],
          ),
          ...switch (_buildEventAccessTicketBlock(
            ticketState: ticketState,
            accessDetails: accessDetails,
          )) {
            final Widget block => [const SizedBox(height: 14), block],
            null => const <Widget>[],
          },
          ...switch (_buildPairingPreferencesEntryBlock(
            event: event,
            eventId: eventId,
            status: status,
            ticketState: ticketState,
            pairingPreferences: pairingPreferences,
          )) {
            final Widget block => [const SizedBox(height: 14), block],
            null => const <Widget>[],
          },
        ],
      ),
    );
  }

  Widget? _buildPairingPreferencesEntryBlock({
    required Map<String, dynamic> event,
    required String eventId,
    required String? status,
    required String? ticketState,
    required Map<String, dynamic> pairingPreferences,
  }) {
    if (status != 'approved') return null;
    if (ticketState == 'released_anchor_pair' ||
        ticketState == 'released_open_social_access') {
      return null;
    }

    final lifecycleStatus =
        pairingPreferences['pairing_preferences_status']?.toString() ??
        'closed';
    final hasSavedPreferences = _pairingPreferencesExist(pairingPreferences);
    final isOpen = lifecycleStatus == 'open';
    final isReadOnly =
        lifecycleStatus == 'closed' || lifecycleStatus == 'locked';

    if (isOpen) {
      final buttonLabel = hasSavedPreferences
          ? 'Update Pairing Preferences'
          : 'Set Pairing Preferences';
      return _pairingPreferencesStatusBlock(
        title: 'Pairing Preferences',
        description: hasSavedPreferences
            ? 'You can update your event preferences while submissions are open.'
            : 'Tell us how you would like to attend. Your selections help us prepare your event experience.',
        buttonLabel: buttonLabel,
        onPressed: () => _openPairingPreferencesSheet(
          event: event,
          eventId: eventId,
          pairingPreferences: pairingPreferences,
          readOnly: false,
        ),
      );
    }

    if (hasSavedPreferences && isReadOnly) {
      return _pairingPreferencesStatusBlock(
        title: 'Pairing Preferences Submitted',
        description: 'Your submitted preferences are saved for this event.',
        buttonLabel: 'Pairing Preferences Submitted',
        onPressed: () => _openPairingPreferencesSheet(
          event: event,
          eventId: eventId,
          pairingPreferences: pairingPreferences,
          readOnly: true,
        ),
      );
    }

    return _pairingPreferencesStatusBlock(
      title: 'Pairing Preferences',
      description: 'Pairing Preferences are not currently open.',
      showChevron: false,
    );
  }

  Widget? _buildEventAccessTicketBlock({
    required String? ticketState,
    required Map<String, dynamic>? accessDetails,
  }) {
    switch (ticketState) {
      case 'approved_unreleased':
        return _eventAccessMessageBlock(
          eyebrow: 'GUEST LIST APPROVED',
          title: 'Anchor Pair details will be released before the event.',
        );
      case 'approved_unassigned':
        return _eventAccessMessageBlock(
          eyebrow: 'GUEST LIST APPROVED',
          title: 'Your event-access details are still being finalized.',
        );
      case 'released_anchor_pair':
        final pairName =
            accessDetails?['anchor_pair_first_name']?.toString().trim() ?? '';
        final pairNumber = accessDetails?['pair_number'];
        if (pairName.isEmpty || pairNumber == null) return null;
        return _eventAccessMessageBlock(
          eyebrow: 'YOUR FACEMEET PAIR TICKET',
          title: 'Your Anchor Pair is:',
          featuredText: pairName,
          pairLabel: _formatPairNumber(pairNumber),
          body:
              'Meet your Anchor Pair at the FaceMeet Pair Check-In area.\nYour first introduction is waiting.',
          highlighted: true,
        );
      case 'released_open_social_access':
        return _eventAccessMessageBlock(
          eyebrow: 'OPEN SOCIAL ACCESS',
          title: 'You are on the guest list.',
          body: 'Meet verified FaceMeet members throughout the evening.',
          highlighted: true,
        );
      default:
        return null;
    }
  }

  bool _canWithdraw(String? status) {
    return status == 'requested' || status == 'waitlisted';
  }

  String _statusExplanation(String? status, String? ticketState) {
    if (ticketState == 'released_anchor_pair' ||
        ticketState == 'released_open_social_access') {
      return 'Your FaceMeet Pair Ticket is ready.';
    }

    switch (status) {
      case 'requested':
        return 'Access requested. We’ll notify you if you’re approved.';
      case 'waitlisted':
        return 'You’re on the waitlist. We’ll notify you if a spot opens.';
      case 'rejected':
        return 'Not selected for this round. You can request access to future FaceMeet events.';
      case 'approved':
        return 'You’re approved for this event. Watch this card for your event details and Pair Ticket updates.';
      default:
        return '';
    }
  }

  String? _capacityHint(Map<String, dynamic> event) {
    final capacity = (event['capacity'] as num?)?.toInt();
    if (capacity == null || capacity <= 0) return null;
    final guestListStatus = _normalizedGuestListStatus(
      event['guest_list_status']?.toString(),
    );
    if (guestListStatus == 'full' || guestListStatus == 'finalizing') {
      return 'Few spots left';
    }
    return 'Limited spots available';
  }

  Widget _statusExplanationBlock(String message, {bool subtle = false}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: subtle ? const Color(0x141B8F5A) : const Color(0x1A2A1714),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: subtle ? const Color(0x331B8F5A) : const Color(0x33E8503A),
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Text(
        message,
        style: GoogleFonts.dmSans(
          color: subtle ? const Color(0xFFC9F4DF) : const Color(0xFFF3D3CD),
          fontSize: 12,
          height: 1.55,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _eventAccessMessageBlock({
    required String eyebrow,
    required String title,
    String? featuredText,
    String? pairLabel,
    String? body,
    bool highlighted = false,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: highlighted ? const Color(0xFF18110F) : const Color(0xFF141111),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: highlighted
              ? const Color(0x44E8503A)
              : const Color(0x22FFFFFF),
        ),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            eyebrow,
            style: GoogleFonts.dmSans(
              color: highlighted ? AppTheme.primary : AppTheme.textMuted,
              fontSize: 11,
              height: 1.3,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            title,
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontSize: 14,
              height: 1.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          if ((featuredText ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              featuredText!,
              style: GoogleFonts.cormorantGaramond(
                color: Colors.white,
                fontSize: 30,
                height: 1.0,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
          if ((pairLabel ?? '').isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0x22E8503A),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: const Color(0x44E8503A)),
              ),
              child: Text(
                pairLabel!,
                style: GoogleFonts.dmSans(
                  color: AppTheme.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
          if ((body ?? '').isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              body!,
              style: GoogleFonts.dmSans(
                color: const Color(0xFFF3D3CD),
                fontSize: 12,
                height: 1.6,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _pairingPreferencesStatusBlock({
    required String title,
    required String description,
    String? buttonLabel,
    VoidCallback? onPressed,
    bool showChevron = true,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF141111),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0x22FFFFFF)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.dmSans(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: GoogleFonts.dmSans(
              color: const Color(0xFFF3D3CD),
              fontSize: 12,
              height: 1.55,
              fontWeight: FontWeight.w500,
            ),
          ),
          if ((buttonLabel ?? '').isNotEmpty && onPressed != null) ...[
            const SizedBox(height: 14),
            OutlinedButton(
              onPressed: onPressed,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Color(0x44E8503A)),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    buttonLabel!,
                    style: GoogleFonts.dmSans(fontWeight: FontWeight.w700),
                  ),
                  if (showChevron) ...[
                    const SizedBox(width: 8),
                    const Icon(Icons.keyboard_arrow_up_rounded, size: 18),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  bool _pairingPreferencesExist(Map<String, dynamic>? pairingPreferences) {
    if (pairingPreferences == null) return false;
    final openToNewIntro = pairingPreferences['open_to_new_intro'] == true;
    final openSocial =
        pairingPreferences['attend_with_open_social_access'] == true;
    final selectedMatchIds = List<dynamic>.from(
      pairingPreferences['selected_match_ids'] as List? ?? const [],
    );
    final submittedAt = pairingPreferences['submitted_at'];
    return openToNewIntro ||
        openSocial ||
        selectedMatchIds.isNotEmpty ||
        submittedAt != null;
  }

  Future<void> _openPairingPreferencesSheet({
    required Map<String, dynamic> event,
    required String eventId,
    required Map<String, dynamic> pairingPreferences,
    required bool readOnly,
  }) async {
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _PairingPreferencesSheet(
        eventTitle: event['title']?.toString() ?? 'FaceMeet Event',
        eventId: eventId,
        initialPreferences: pairingPreferences,
        readOnly: readOnly,
      ),
    );

    if (result == null || !mounted) return;

    if (result['updatedPreferences']
        case Map<String, dynamic> updatedPreferences) {
      setState(() {
        _eventPairingPreferencesByEventId = {
          ..._eventPairingPreferencesByEventId,
          eventId: updatedPreferences,
        };
      });
    }

    final message = result['message']?.toString();
    if (message != null && message.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message, style: GoogleFonts.dmSans()),
          backgroundColor: AppTheme.sparkGreen,
        ),
      );
    }
  }

  String _formatPairNumber(dynamic value) {
    final pairNumber = int.tryParse(value?.toString() ?? '');
    if (pairNumber == null || pairNumber <= 0) return 'PAIR --';
    return 'PAIR ${pairNumber.toString().padLeft(2, '0')}';
  }

  Widget _requestButton({
    required String eventId,
    required String? status,
    required bool busy,
    required String guestListStatus,
    required String accessMode,
  }) {
    final matchUnlockedEligible =
        accessMode == 'match_unlocked' && _hasChatUnlockedMatch;
    final buttonLabel = status != null
        ? switch (status) {
            'requested' => 'Access Requested',
            'waitlisted' => 'Waitlist Open',
            'approved' => 'Guest List Approved',
            'rejected' => 'Not Selected This Round',
            'cancelled' => 'Event Cancelled',
            _ => 'Request Invite',
          }
        : guestListStatus == 'closed'
        ? 'Access Closed'
        : switch (accessMode) {
            'match_unlocked' =>
              matchUnlockedEligible ? 'Request Invite' : 'Unlock Match First',
            'invite_only' => 'Invite Only',
            'pair_priority' => 'Request Invite',
            _ => switch (guestListStatus) {
              'finalizing' => 'Join Waitlist',
              'full' => 'Join Waitlist',
              _ => 'Request Invite',
            },
          };

    final enabled =
        status == null &&
        !busy &&
        guestListStatus != 'closed' &&
        accessMode != 'invite_only' &&
        (accessMode != 'match_unlocked' || matchUnlockedEligible);
    final background = status != null
        ? switch (status) {
            'approved' => AppTheme.sparkGreen,
            'waitlisted' => const Color(0xFFD4A847),
            'rejected' || 'cancelled' => const Color(0xFF3A312E),
            'requested' => const Color(0xFF1E3026),
            _ => AppTheme.primary,
          }
        : !enabled
        ? const Color(0xFF3A312E)
        : switch (guestListStatus) {
            'finalizing' => const Color(0xFFD4A847),
            'full' => const Color(0xFF6B4A20),
            _ => AppTheme.primary,
          };

    return ElevatedButton(
      onPressed: enabled ? () => _requestInvite(eventId) : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: background,
        disabledBackgroundColor: background,
        disabledForegroundColor: Colors.white70,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: busy
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
              ),
            )
          : Text(
              buttonLabel,
              style: GoogleFonts.dmSans(fontWeight: FontWeight.w700),
            ),
    );
  }

  Widget _withdrawButton({required String eventId, required bool busy}) {
    return OutlinedButton(
      onPressed: busy ? null : () => _withdrawRequest(eventId),
      style: OutlinedButton.styleFrom(
        foregroundColor: const Color(0xFFF3D3CD),
        side: const BorderSide(color: Color(0x55E8503A)),
        padding: const EdgeInsets.symmetric(vertical: 13),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      child: busy
          ? const SizedBox(
              height: 18,
              width: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFF3D3CD)),
              ),
            )
          : Text(
              'Withdraw Request',
              style: GoogleFonts.dmSans(fontWeight: FontWeight.w700),
            ),
    );
  }

  String _normalizedAccessMode(String? value) {
    switch (value) {
      case 'pair_priority':
      case 'match_unlocked':
      case 'invite_only':
        return value!;
      default:
        return 'individual_request';
    }
  }

  String _accessModeLabel(String mode) {
    switch (mode) {
      case 'pair_priority':
        return 'Pair Priority';
      case 'match_unlocked':
        return 'Match-Unlocked Access';
      case 'invite_only':
        return 'Invite Only';
      default:
        return 'Individual Access';
    }
  }

  String _accessModeHelperCopy(String mode) {
    switch (mode) {
      case 'pair_priority':
        return 'Matched pairs may receive priority guest-list consideration.';
      case 'match_unlocked':
        return 'Unlock a mutual Match in FaceMeet to qualify for this event.';
      case 'invite_only':
        return 'Access is reserved for selected FaceMeet members.';
      default:
        return 'Request access for individual guest-list consideration.';
    }
  }

  Widget _accessModePill(String mode) {
    switch (mode) {
      case 'pair_priority':
        return _pill(
          _accessModeLabel(mode),
          backgroundColor: const Color(0x22D4A847),
          borderColor: const Color(0x44D4A847),
          textColor: const Color(0xFFD4A847),
        );
      case 'match_unlocked':
        return _pill(
          _accessModeLabel(mode),
          backgroundColor: const Color(0x22E8503A),
          borderColor: const Color(0x44E8503A),
          textColor: AppTheme.primary,
        );
      case 'invite_only':
        return _pill(
          _accessModeLabel(mode),
          backgroundColor: const Color(0x223A241D),
          borderColor: const Color(0x553A241D),
          textColor: const Color(0xFFFFC1B8),
        );
      default:
        return _pill(
          _accessModeLabel(mode),
          backgroundColor: const Color(0x141B84FF),
          borderColor: const Color(0x22FFFFFF),
          textColor: Colors.white70,
        );
    }
  }

  String _normalizedGuestListStatus(String? value) {
    switch (value) {
      case 'limited':
      case 'finalizing':
      case 'full':
      case 'closed':
        return value!;
      default:
        return 'open';
    }
  }

  String _guestListLabel(String status) {
    switch (status) {
      case 'limited':
        return 'Limited Guest List';
      case 'finalizing':
        return 'Guest List Finalizing';
      case 'full':
        return 'Guest List Full';
      case 'closed':
        return 'Access Closed';
      default:
        return 'Access Open';
    }
  }

  String _guestListHelperCopy(String status) {
    switch (status) {
      case 'limited':
        return 'Limited spots remain. Invite requests are reviewed individually.';
      case 'finalizing':
        return 'The guest list is being finalized. Waitlist requests are still open.';
      case 'full':
        return 'The guest list is full. Join the waitlist for possible access.';
      case 'closed':
        return 'Invite requests are now closed.';
      default:
        return 'Invite requests are reviewed individually.';
    }
  }

  Widget _guestListPill(String status) {
    switch (status) {
      case 'limited':
        return _pill(
          _guestListLabel(status),
          backgroundColor: const Color(0x22E8503A),
          borderColor: const Color(0x44E8503A),
          textColor: AppTheme.primary,
        );
      case 'finalizing':
        return _pill(
          _guestListLabel(status),
          backgroundColor: const Color(0x22D4A847),
          borderColor: const Color(0x44D4A847),
          textColor: const Color(0xFFD4A847),
        );
      case 'full':
        return _pill(
          _guestListLabel(status),
          backgroundColor: const Color(0x223A241D),
          borderColor: const Color(0x553A241D),
          textColor: const Color(0xFFFFC1B8),
        );
      case 'closed':
        return _pill(
          _guestListLabel(status),
          backgroundColor: const Color(0x22322A29),
          borderColor: const Color(0x55322A29),
          textColor: AppTheme.textMuted,
        );
      default:
        return _pill(
          _guestListLabel(status),
          backgroundColor: const Color(0x1A6C2C22),
          borderColor: const Color(0x446C2C22),
          textColor: const Color(0xFFFFC1B8),
        );
    }
  }

  String _inviteRequirementLabel(String? value) {
    switch (value) {
      case 'approval_required':
        return 'Approval Required';
      case 'invite_only':
        return 'Invite Only';
      default:
        return 'Open Access';
    }
  }

  Widget _pill(
    String label, {
    Color backgroundColor = const Color(0x141B84FF),
    Color borderColor = const Color(0x22FFFFFF),
    Color textColor = Colors.white70,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        label,
        style: GoogleFonts.dmSans(
          color: textColor,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _formatDateRange(dynamic startsAtRaw, dynamic endsAtRaw) {
    final startsAt = DateTime.tryParse(startsAtRaw?.toString() ?? '');
    final endsAt = DateTime.tryParse(endsAtRaw?.toString() ?? '');
    if (startsAt == null) return 'Date coming soon';

    final localStart = startsAt.toLocal();
    final localEnd = endsAt?.toLocal();
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];

    String timeOfDay(DateTime dt) {
      final hour = dt.hour == 0
          ? 12
          : dt.hour > 12
          ? dt.hour - 12
          : dt.hour;
      final minute = dt.minute.toString().padLeft(2, '0');
      final suffix = dt.hour >= 12 ? 'PM' : 'AM';
      return '$hour:$minute $suffix';
    }

    final dateLabel =
        '${months[localStart.month - 1]} ${localStart.day}, ${localStart.year}';
    if (localEnd == null) return '$dateLabel · ${timeOfDay(localStart)}';
    return '$dateLabel · ${timeOfDay(localStart)} – ${timeOfDay(localEnd)}';
  }
}

class _PairingPreferencesSheet extends StatefulWidget {
  const _PairingPreferencesSheet({
    required this.eventTitle,
    required this.eventId,
    required this.initialPreferences,
    required this.readOnly,
  });

  final String eventTitle;
  final String eventId;
  final Map<String, dynamic> initialPreferences;
  final bool readOnly;

  @override
  State<_PairingPreferencesSheet> createState() =>
      _PairingPreferencesSheetState();
}

class _PairingPreferencesSheetState extends State<_PairingPreferencesSheet> {
  bool _loading = true;
  bool _saving = false;
  String? _errorMessage;
  String? _infoMessage;
  late String _pairingPreferencesStatus;
  bool _openToNewIntro = false;
  bool _attendWithOpenSocialAccess = false;
  List<String> _selectedMatchIds = const [];
  DateTime? _submittedAt;
  List<Map<String, dynamic>> _eligibleMatches = const [];

  bool get _isReadOnly =>
      widget.readOnly || _pairingPreferencesStatus != 'open';

  @override
  void initState() {
    super.initState();
    _pairingPreferencesStatus =
        widget.initialPreferences['pairing_preferences_status']?.toString() ??
        'closed';
    _primeState(widget.initialPreferences);
    _load();
  }

  void _primeState(Map<String, dynamic> preferences) {
    _openToNewIntro = preferences['open_to_new_intro'] == true;
    _attendWithOpenSocialAccess =
        preferences['attend_with_open_social_access'] == true;
    _selectedMatchIds = List<String>.from(
      List<dynamic>.from(
        preferences['selected_match_ids'] as List? ?? const [],
      ).map((value) => value.toString()),
    );
    _submittedAt = DateTime.tryParse(
      preferences['submitted_at']?.toString() ?? '',
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _errorMessage = null;
    });

    try {
      final results = await Future.wait([
        SupabaseService.instance.getMyEventPairingPreferences(widget.eventId),
        SupabaseService.instance.getMyEligibleEventMatches(widget.eventId),
      ]);

      final latestPreferences = results[0] as Map<String, dynamic>?;
      final eligibleMatches = List<Map<String, dynamic>>.from(
        results[1] as List,
      );
      if (!mounted) return;

      if (latestPreferences != null) {
        _pairingPreferencesStatus =
            latestPreferences['pairing_preferences_status']?.toString() ??
            _pairingPreferencesStatus;
        _primeState(latestPreferences);
      }

      setState(() {
        _eligibleMatches = eligibleMatches;
        if (_eligibleMatches.isEmpty && !_attendWithOpenSocialAccess) {
          _infoMessage =
              'No eligible Matches are available for this event yet.';
        } else {
          _infoMessage = null;
        }
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorMessage = _friendlyPairingPreferencesError(e);
      });
    }
  }

  String _friendlyPairingPreferencesError(Object error) {
    final message = error.toString();
    if (message.contains('pairing_preferences_not_open')) {
      return 'Pairing Preferences are not currently open.';
    }
    if (message.contains('attendee_not_approved')) {
      return 'Pairing Preferences are available only to approved guests.';
    }
    if (message.contains('pair_ticket_already_released')) {
      return 'Your Pair Ticket has already been released.';
    }
    if (message.contains('too_many_selected_matches')) {
      return 'Select no more than 3 Matches.';
    }
    if (message.contains('invalid_selected_match')) {
      return 'One of your selected Matches is no longer available for this event. Refresh and try again.';
    }
    if (message.contains('open_social_access_must_be_exclusive')) {
      return 'Open Social Access cannot be combined with another preference.';
    }
    if (message.contains('pairing_preference_required')) {
      return 'Select at least one attendance preference.';
    }
    return 'Pairing Preferences could not be loaded right now. Please try again.';
  }

  String _friendlySaveError(Object error) {
    final message = error.toString();
    if (message.contains('pairing_preferences_not_open')) {
      return 'Pairing Preferences are not currently open.';
    }
    if (message.contains('attendee_not_approved')) {
      return 'Pairing Preferences are available only to approved guests.';
    }
    if (message.contains('pair_ticket_already_released')) {
      return 'Your Pair Ticket has already been released.';
    }
    if (message.contains('too_many_selected_matches')) {
      return 'Select no more than 3 Matches.';
    }
    if (message.contains('invalid_selected_match')) {
      return 'One of your selected Matches is no longer available for this event. Refresh and try again.';
    }
    if (message.contains('open_social_access_must_be_exclusive')) {
      return 'Open Social Access cannot be combined with another preference.';
    }
    if (message.contains('pairing_preference_required')) {
      return 'Select at least one attendance preference.';
    }
    return 'Pairing Preferences could not be saved. Please try again.';
  }

  Future<void> _save() async {
    if (_saving || _isReadOnly) return;
    if (!_openToNewIntro &&
        !_attendWithOpenSocialAccess &&
        _selectedMatchIds.isEmpty) {
      setState(() {
        _errorMessage = 'Select at least one attendance preference.';
      });
      return;
    }

    setState(() {
      _saving = true;
      _errorMessage = null;
    });

    try {
      await SupabaseService.instance.saveMyEventPairingPreferences(
        eventId: widget.eventId,
        openToNewIntro: _openToNewIntro,
        attendWithOpenSocialAccess: _attendWithOpenSocialAccess,
        selectedMatchIds: _selectedMatchIds,
      );
      final refreshed = await SupabaseService.instance
          .getMyEventPairingPreferences(widget.eventId);
      if (!mounted) return;
      Navigator.of(context).pop({
        'updatedPreferences': Map<String, dynamic>.from(
          refreshed ??
              <String, dynamic>{
                'event_id': widget.eventId,
                'pairing_preferences_status': _pairingPreferencesStatus,
                'open_to_new_intro': _openToNewIntro,
                'attend_with_open_social_access': _attendWithOpenSocialAccess,
                'submitted_at': DateTime.now().toIso8601String(),
                'selected_match_ids': _selectedMatchIds,
              },
        ),
        'message': 'Pairing Preferences saved successfully.',
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorMessage = _friendlySaveError(e);
      });
    }
  }

  void _toggleOpenSocialAccess(bool enabled) {
    setState(() {
      _attendWithOpenSocialAccess = enabled;
      if (enabled) {
        _openToNewIntro = false;
        _selectedMatchIds = const [];
      }
    });
  }

  void _toggleOpenToNewIntro(bool enabled) {
    setState(() {
      _openToNewIntro = enabled;
      if (enabled) {
        _attendWithOpenSocialAccess = false;
      }
    });
  }

  void _toggleSelectedMatch(String matchId) {
    if (_attendWithOpenSocialAccess) return;
    setState(() {
      final updated = List<String>.from(_selectedMatchIds);
      if (updated.contains(matchId)) {
        updated.remove(matchId);
      } else if (updated.length < 3) {
        updated.add(matchId);
      }
      _selectedMatchIds = updated;
      if (_selectedMatchIds.isNotEmpty) {
        _attendWithOpenSocialAccess = false;
      }
      _errorMessage = null;
    });
  }

  String _matchDisplayName(Map<String, dynamic> row) {
    final firstName = row['other_user_first_name']?.toString().trim() ?? '';
    if (firstName.isNotEmpty) return firstName;
    final username = row['other_user_username']?.toString().trim() ?? '';
    if (username.isNotEmpty) return username;
    return 'FaceMeet Match';
  }

  String _submittedLabel() {
    if (_submittedAt == null) return 'Not submitted yet';
    final local = _submittedAt!.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour == 0
        ? 12
        : local.hour > 12
        ? local.hour - 12
        : local.hour;
    final minute = local.minute.toString().padLeft(2, '0');
    final suffix = local.hour >= 12 ? 'PM' : 'AM';
    return '$month/$day/${local.year} · $hour:$minute $suffix';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0F0B0B),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 18,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.86,
          minChildSize: 0.55,
          maxChildSize: 0.95,
          builder: (context, controller) {
            return ListView(
              controller: controller,
              children: [
                Center(
                  child: Container(
                    width: 52,
                    height: 5,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'Pairing Preferences',
                  style: GoogleFonts.outfit(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tell us how you would like to attend. Your selections help us prepare your event experience.',
                  style: GoogleFonts.dmSans(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  widget.eventTitle,
                  style: GoogleFonts.dmSans(
                    color: AppTheme.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF171111),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0x22FFFFFF)),
                  ),
                  child: Text(
                    _pairingPreferencesStatus == 'open'
                        ? 'Preferences are currently open.'
                        : _pairingPreferencesStatus == 'locked'
                        ? 'Preferences have been locked for this event.'
                        : 'Pairing Preferences are not currently open.',
                    style: GoogleFonts.dmSans(
                      color: const Color(0xFFF3D3CD),
                      fontSize: 12,
                      height: 1.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (_loading) ...[
                  const SizedBox(height: 24),
                  const Center(
                    child: CircularProgressIndicator(color: AppTheme.primary),
                  ),
                ] else ...[
                  if (_errorMessage != null) ...[
                    const SizedBox(height: 18),
                    _sheetMessage(_errorMessage!, error: true),
                  ],
                  if (_infoMessage != null && _errorMessage == null) ...[
                    const SizedBox(height: 18),
                    _sheetMessage(_infoMessage!),
                  ],
                  const SizedBox(height: 18),
                  _sheetSection(
                    title: 'Attend with an Existing Match',
                    description:
                        'Select up to 3 Matches you would be comfortable meeting at the event.',
                    child: _eligibleMatches.isEmpty
                        ? Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFF171111),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: const Color(0x22FFFFFF),
                              ),
                            ),
                            child: Text(
                              'No eligible Matches are available for this event yet.',
                              style: GoogleFonts.dmSans(
                                color: AppTheme.textMuted,
                                fontSize: 12,
                                height: 1.5,
                              ),
                            ),
                          )
                        : Column(
                            children: _eligibleMatches.map((row) {
                              final matchId = row['match_id']?.toString() ?? '';
                              final selected = _selectedMatchIds.contains(
                                matchId,
                              );
                              return Container(
                                margin: const EdgeInsets.only(bottom: 10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF171111),
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: selected
                                        ? const Color(0x55E8503A)
                                        : const Color(0x22FFFFFF),
                                  ),
                                ),
                                child: CheckboxListTile(
                                  value: selected,
                                  onChanged:
                                      _isReadOnly || _attendWithOpenSocialAccess
                                      ? null
                                      : (_) => _toggleSelectedMatch(matchId),
                                  activeColor: AppTheme.primary,
                                  checkColor: Colors.white,
                                  controlAffinity:
                                      ListTileControlAffinity.leading,
                                  title: Text(
                                    _matchDisplayName(row),
                                    style: GoogleFonts.dmSans(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  subtitle: Text(
                                    selected
                                        ? 'Selected for this event'
                                        : 'Available for this event',
                                    style: GoogleFonts.dmSans(
                                      color: AppTheme.textMuted,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                  ),
                  const SizedBox(height: 16),
                  _sheetSection(
                    title: 'Open to a New Introduction',
                    description:
                        'I am open to meeting a verified FaceMeet member at the event.',
                    child: _preferenceOptionTile(
                      title: 'Open to a New Introduction',
                      selected: _openToNewIntro,
                      enabled: !_isReadOnly && !_attendWithOpenSocialAccess,
                      onTap: () => _toggleOpenToNewIntro(!_openToNewIntro),
                    ),
                  ),
                  const SizedBox(height: 16),
                  _sheetSection(
                    title: 'Open Social Access',
                    description:
                        'I would prefer to attend without an Anchor Pair and meet members throughout the evening.',
                    child: _preferenceOptionTile(
                      title: 'Open Social Access',
                      selected: _attendWithOpenSocialAccess,
                      enabled: !_isReadOnly,
                      onTap: () =>
                          _toggleOpenSocialAccess(!_attendWithOpenSocialAccess),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF171111),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: const Color(0x22FFFFFF)),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.schedule_rounded,
                          color: AppTheme.primary,
                          size: 18,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _submittedLabel(),
                            style: GoogleFonts.dmSans(
                              color: const Color(0xFFF3D3CD),
                              fontSize: 12,
                              height: 1.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  if (!_isReadOnly)
                    ElevatedButton(
                      onPressed: _saving ? null : _save,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primary,
                        foregroundColor: Colors.white,
                        disabledBackgroundColor: const Color(0xFF3A312E),
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: _saving
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Colors.white,
                                ),
                              ),
                            )
                          : Text(
                              'Save Pairing Preferences',
                              style: GoogleFonts.dmSans(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    )
                  else
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: Color(0x22FFFFFF)),
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      child: Text(
                        'Close',
                        style: GoogleFonts.dmSans(fontWeight: FontWeight.w700),
                      ),
                    ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _sheetSection({
    required String title,
    required String description,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: GoogleFonts.dmSans(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          description,
          style: GoogleFonts.dmSans(
            color: AppTheme.textMuted,
            fontSize: 12,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 10),
        child,
      ],
    );
  }

  Widget _sheetMessage(String message, {bool error = false}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: error ? const Color(0x33E8503A) : const Color(0xFF171111),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: error ? const Color(0x55E8503A) : const Color(0x22FFFFFF),
        ),
      ),
      child: Text(
        message,
        style: GoogleFonts.dmSans(
          color: error ? const Color(0xFFFFD4CC) : const Color(0xFFF3D3CD),
          fontSize: 12,
          height: 1.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _preferenceOptionTile({
    required String title,
    required bool selected,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF171111),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? const Color(0x55E8503A) : const Color(0x22FFFFFF),
          ),
        ),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              color: selected ? AppTheme.primary : AppTheme.textMuted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: GoogleFonts.dmSans(
                  color: enabled ? Colors.white : Colors.white70,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
