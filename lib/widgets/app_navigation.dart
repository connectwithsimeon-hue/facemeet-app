import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

const int discoverTabIndex = 0;
const int sparksTabIndex = 1;
const int eventsTabIndex = 2;
const int liveTabIndex = 3;
const int chatsTabIndex = 4;
const int profileTabIndex = 5;

class AppNavigation extends StatelessWidget {
  final int currentIndex;
  final Function(int) onTap;
  final int sessionsBadge;
  final int chatBadge;
  final bool hasLiveTopics;

  const AppNavigation({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.sessionsBadge = 0,
    this.chatBadge = 0,
    this.hasLiveTopics = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            height: 64,
            decoration: BoxDecoration(
              color: const Color(0x26FFFFFF),
              borderRadius: BorderRadius.circular(32),
              border: Border.all(color: const Color(0x1AFFFFFF), width: 1),
            ),
            child: Row(
              children: [
                Expanded(
                  child: _NavItem(
                    icon: Icons.explore_rounded,
                    activeIcon: Icons.explore_rounded,
                    label: 'Discover',
                    isActive: currentIndex == discoverTabIndex,
                    onTap: () => onTap(discoverTabIndex),
                  ),
                ),
                Expanded(
                  child: _NavItem(
                    icon: Icons.bolt_outlined,
                    activeIcon: Icons.bolt_rounded,
                    label: 'Sessions',
                    isActive: currentIndex == sparksTabIndex,
                    onTap: () => onTap(sparksTabIndex),
                    badge: sessionsBadge > 0 ? sessionsBadge : null,
                  ),
                ),
                Expanded(
                  child: _NavItem(
                    icon: Icons.event_outlined,
                    activeIcon: Icons.event_rounded,
                    label: 'Events',
                    isActive: currentIndex == eventsTabIndex,
                    onTap: () => onTap(eventsTabIndex),
                  ),
                ),
                Expanded(
                  child: _NavItem(
                    icon: Icons.podcasts_outlined,
                    activeIcon: Icons.podcasts_rounded,
                    label: 'Live',
                    isActive: currentIndex == liveTabIndex,
                    onTap: () => onTap(liveTabIndex),
                    liveGlow: hasLiveTopics,
                  ),
                ),
                Expanded(
                  child: _NavItem(
                    icon: Icons.chat_bubble_outline_rounded,
                    activeIcon: Icons.chat_bubble_rounded,
                    label: 'Chat',
                    isActive: currentIndex == chatsTabIndex,
                    onTap: () => onTap(chatsTabIndex),
                    badge: chatBadge > 0 ? chatBadge : null,
                  ),
                ),
                Expanded(
                  child: _NavItem(
                    icon: Icons.person_outline_rounded,
                    activeIcon: Icons.person_rounded,
                    label: 'Profile',
                    isActive: currentIndex == profileTabIndex,
                    onTap: () => onTap(profileTabIndex),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final VoidCallback onTap;
  final int? badge;
  final bool liveGlow;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.onTap,
    this.badge,
    this.liveGlow = false,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnim;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scaleAnim = Tween<double>(
      begin: 1.0,
      end: 0.88,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) {
        _controller.reverse();
        widget.onTap();
      },
      onTapCancel: () => _controller.reverse(),
      child: ScaleTransition(
        scale: _scaleAnim,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 8),
          decoration: BoxDecoration(
            color: widget.isActive
                ? const Color(0x33E8503A)
                : widget.liveGlow
                ? const Color(0x1FE8503A)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Icon(
                    widget.isActive ? widget.activeIcon : widget.icon,
                    size: 22,
                    color: widget.isActive
                        ? const Color(0xFFE8503A)
                        : const Color(0x66FFFFFF),
                  ),
                  if (widget.badge != null && widget.badge! > 0)
                    Positioned(
                      right: -6,
                      top: -4,
                      child: Container(
                        width: 16,
                        height: 16,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8503A),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: Text(
                            '${widget.badge}',
                            style: GoogleFonts.dmSans(
                              fontSize: 9,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (widget.liveGlow && widget.badge == null)
                    Positioned(
                      right: -3,
                      top: -2,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8503A),
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFFE8503A,
                              ).withValues(alpha: 0.8),
                              blurRadius: 10,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                widget.label,
                style: GoogleFonts.dmSans(
                  fontSize: 10,
                  fontWeight: widget.isActive
                      ? FontWeight.w600
                      : FontWeight.w400,
                  color: widget.isActive
                      ? const Color(0xFFE8503A)
                      : const Color(0x66FFFFFF),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Navigation Rail for tablet
class AppNavigationRail extends StatelessWidget {
  final int currentIndex;
  final Function(int) onTap;
  final bool hasLiveTopics;

  const AppNavigationRail({
    super.key,
    required this.currentIndex,
    required this.onTap,
    this.hasLiveTopics = false,
  });

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      backgroundColor: const Color(0x14FFFFFF),
      selectedIndex: currentIndex,
      onDestinationSelected: onTap,
      labelType: NavigationRailLabelType.all,
      selectedIconTheme: const IconThemeData(
        color: Color(0xFFE8503A),
        size: 24,
      ),
      unselectedIconTheme: const IconThemeData(
        color: Color(0x66FFFFFF),
        size: 22,
      ),
      selectedLabelTextStyle: GoogleFonts.dmSans(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: const Color(0xFFE8503A),
      ),
      unselectedLabelTextStyle: GoogleFonts.dmSans(
        fontSize: 12,
        fontWeight: FontWeight.w400,
        color: const Color(0x66FFFFFF),
      ),
      destinations: [
        const NavigationRailDestination(
          icon: Icon(Icons.explore_rounded),
          label: Text('Discover'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.bolt_rounded),
          label: Text('Sparks'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.event_rounded),
          label: Text('Events'),
        ),
        NavigationRailDestination(
          icon: _RailLiveIcon(isLive: hasLiveTopics),
          label: const Text('Live'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.chat_bubble_rounded),
          label: Text('Chats'),
        ),
        const NavigationRailDestination(
          icon: Icon(Icons.person_rounded),
          label: Text('Profile'),
        ),
      ],
    );
  }
}

class _RailLiveIcon extends StatelessWidget {
  final bool isLive;

  const _RailLiveIcon({required this.isLive});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        const Icon(Icons.podcasts_rounded),
        if (isLive)
          Positioned(
            right: -3,
            top: -2,
            child: Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: const Color(0xFFE8503A),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFFE8503A).withValues(alpha: 0.8),
                    blurRadius: 10,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
