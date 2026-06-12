import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/empty_state_widget.dart';
import '../../../widgets/profile_avatar.dart';

class ChatInboxWidget extends StatelessWidget {
  final List<Map<String, dynamic>> conversations;
  final ValueChanged<Map<String, dynamic>> onConversationTap;
  final String? selectedId;

  const ChatInboxWidget({
    super.key,
    required this.conversations,
    required this.onConversationTap,
    this.selectedId,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header
        ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
            child: Container(
              color: const Color(0xCC0D0D0F),
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Row(
                    children: [
                      Text(
                        'Sparks',
                        style: GoogleFonts.dmSans(
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0x33FF4458),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: const Color(0x66FF4458),
                            width: 1,
                          ),
                        ),
                        child: Text(
                          '${conversations.where((c) => (c['unreadCount'] as int) > 0).length} unread',
                          style: GoogleFonts.dmSans(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // Info banner
        Container(
          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: const Color(0x1A4CAF82),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0x334CAF82), width: 1),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.bolt_rounded,
                color: AppTheme.sparkGreen,
                size: 16,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Chats unlock only after a mutual Spark Session',
                  style: GoogleFonts.dmSans(
                    fontSize: 12,
                    color: AppTheme.sparkGreen,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // List
        Expanded(
          child: conversations.isEmpty
              ? EmptyStateWidget(
                  icon: Icons.chat_bubble_outline_rounded,
                  title: 'No chats yet',
                  subtitle:
                      'Complete a Spark Session and get a mutual Spark to unlock your first chat',
                  actionLabel: 'Start Discovering',
                  onAction: () {
                    final tabController = DefaultTabController.of(context);
                    tabController.animateTo(0);
                  },
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                  itemCount: conversations.length,
                  itemBuilder: (context, i) {
                    final conv = conversations[i];
                    final isSelected = selectedId == conv['id'];
                    return _ConversationItem(
                      conversation: conv,
                      isSelected: isSelected,
                      onTap: () => onConversationTap(conv),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ConversationItem extends StatefulWidget {
  final Map<String, dynamic> conversation;
  final bool isSelected;
  final VoidCallback onTap;

  const _ConversationItem({
    required this.conversation,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_ConversationItem> createState() => _ConversationItemState();
}

class _ConversationItemState extends State<_ConversationItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _scale = Tween<double>(
      begin: 1.0,
      end: 0.97,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = widget.conversation['user'] as Map<String, dynamic>;
    final unread = widget.conversation['unreadCount'] as int;
    final isOnline = user['isOnline'] as bool;

    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) {
        _ctrl.reverse();
        widget.onTap();
      },
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? const Color(0x1AFF4458)
                : AppTheme.surfaceGlass,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: widget.isSelected
                  ? const Color(0x66FF4458)
                  : AppTheme.borderGlass,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              // Avatar with online indicator
              Stack(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(26),
                      border: Border.all(
                        color: unread > 0
                            ? AppTheme.primary
                            : AppTheme.borderGlass,
                        width: 1.5,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(25),
                      child: ProfileAvatar(
                        thumbnailUrl: user['thumbnailUrl'] as String?,
                        firstName: user['name'] as String?,
                        radius: 25,
                      ),
                    ),
                  ),
                  if (isOnline)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 14,
                        height: 14,
                        decoration: BoxDecoration(
                          color: AppTheme.sparkGreen,
                          borderRadius: BorderRadius.circular(7),
                          border: Border.all(
                            color: AppTheme.backgroundDark,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              // Content
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          user['name'],
                          style: GoogleFonts.dmSans(
                            fontSize: 15,
                            fontWeight: unread > 0
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 6),
                        // Sparked badge
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0x1AFF4458),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            'Sparked ✦',
                            style: GoogleFonts.dmSans(
                              fontSize: 9,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primary,
                            ),
                          ),
                        ),
                        const Spacer(),
                        Text(
                          widget.conversation['lastMessageTime'],
                          style: GoogleFonts.dmSans(
                            fontSize: 11,
                            color: unread > 0
                                ? AppTheme.primary
                                : AppTheme.textMuted,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            widget.conversation['lastMessage'],
                            style: GoogleFonts.dmSans(
                              fontSize: 13,
                              color: unread > 0
                                  ? AppTheme.textSecondary
                                  : AppTheme.textMuted,
                              fontWeight: unread > 0
                                  ? FontWeight.w500
                                  : FontWeight.w400,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (unread > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: AppTheme.primary,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Center(
                              child: Text(
                                '$unread',
                                style: GoogleFonts.dmSans(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
