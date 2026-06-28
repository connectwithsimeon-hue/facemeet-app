import 'dart:async';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../../providers/subscription_provider.dart';
import '../../services/revenuecat_service.dart';
import '../../services/stripe_service.dart';
import '../../services/supabase_service.dart';
import '../../theme/app_theme.dart';

class PricingScreen extends StatefulWidget {
  const PricingScreen({super.key});

  @override
  State<PricingScreen> createState() => _PricingScreenState();
}

class _PricingScreenState extends State<PricingScreen>
    with WidgetsBindingObserver {
  bool _isGold = false;
  int? _selectedBundle;
  bool _isLoading = false;
  Timer? _subscriptionPollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadUserData();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscriptionPollTimer?.cancel();
    super.dispose();
  }

  // When app resumes (e.g. returning from Stripe browser on web), refresh subscription
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _selectedBundle = null;
        });
      }
      _startSubscriptionPolling();
    } else if (state == AppLifecycleState.paused) {
      _subscriptionPollTimer?.cancel();
    }
  }

  /// Poll subscription status every 3 seconds for up to 40 seconds after
  /// the app resumes — handles Stripe webhook latency gracefully (web only).
  void _startSubscriptionPolling() {
    _subscriptionPollTimer?.cancel();
    int pollCount = 0;
    const maxPolls = 13;

    _subscriptionPollTimer = Timer.periodic(const Duration(seconds: 3), (
      timer,
    ) async {
      pollCount++;
      if (pollCount > maxPolls || !mounted) {
        timer.cancel();
        return;
      }

      final subProvider = Provider.of<SubscriptionProvider>(
        context,
        listen: false,
      );
      final tierBefore = subProvider.subscriptionTier;
      await subProvider.refreshSubscription();
      final tierAfter = subProvider.subscriptionTier;

      debugPrint('PRICING POLL #$pollCount: tier=$tierAfter');

      if (tierAfter != 'free') {
        timer.cancel();
        debugPrint(
          'PRICING POLL: detected paid tier=$tierAfter — stopping poll',
        );
      }
    });
  }

  Future<void> _loadUserData() async {
    final uid = SupabaseService.instance.currentUserId;
    if (uid == null) return;
    try {
      if (mounted) {
        final subProvider = Provider.of<SubscriptionProvider>(
          context,
          listen: false,
        );
        await subProvider.refreshSubscription();
      }
      // Identify the user in RevenueCat on mobile
      if (!kIsWeb && uid.isNotEmpty) {
        await RevenueCatService.instance.identifyUser(uid);
      }
    } catch (e) {
      debugPrint('PRICING: Error loading user data: $e');
    }
  }

  Future<void> _handleSubscribe() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      RCPurchaseStatus status;
      if (kIsWeb) {
        // Web: use Stripe checkout (unchanged)
        final result = _isGold
            ? await StripeService.instance.subscribeGold(context: context)
            : await StripeService.instance.subscribeSparkPlus(context: context);
        status = result.success
            ? RCPurchaseStatus.success
            : RCPurchaseStatus.failed;
      } else {
        // Mobile: use RevenueCat native IAP
        final productId = _isGold
            ? RCProductIds.goldMonthly
            : RCProductIds.sparkPlusMonthly;
        status = await RevenueCatService.instance.purchaseProduct(productId);
        if (status == RCPurchaseStatus.success && mounted) {
          // Refresh subscription state after successful purchase
          await Provider.of<SubscriptionProvider>(
            context,
            listen: false,
          ).refreshSubscription();
        }
      }
      if (status == RCPurchaseStatus.failed && mounted) {
        final message = kIsWeb
            ? StripeService.instance.lastCheckoutError ??
                  'Checkout could not start. Please try again.'
            : 'Could not complete purchase. Please try again.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message, style: GoogleFonts.dmSans()),
            backgroundColor: AppTheme.error,
          ),
        );
      } else if (status == RCPurchaseStatus.cancelled && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Purchase cancelled.', style: GoogleFonts.dmSans()),
            backgroundColor: AppTheme.textMuted,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('PRICING: subscribe error — $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not complete purchase. Please try again.',
              style: GoogleFonts.dmSans(),
            ),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleBundlePurchase(int size) async {
    if (!mounted) return;
    setState(() {
      _selectedBundle = size;
      _isLoading = true;
    });
    try {
      RCPurchaseStatus status;
      if (kIsWeb) {
        // Web: use Stripe checkout (unchanged)
        final result = await StripeService.instance.purchaseBundle(
          size,
          context: context,
        );
        status = result.success
            ? RCPurchaseStatus.success
            : RCPurchaseStatus.failed;
      } else {
        // Mobile: use the RevenueCat package from the active offering.
        status = await RevenueCatService.instance.purchaseSparkBundle(size);
        if (status == RCPurchaseStatus.success && mounted) {
          await Provider.of<SubscriptionProvider>(
            context,
            listen: false,
          ).refreshSubscription();
        }
      }
      if (status == RCPurchaseStatus.failed && mounted) {
        final message = kIsWeb
            ? StripeService.instance.lastCheckoutError ??
                  'Checkout could not start. Please try again.'
            : 'Could not complete purchase. Please try again.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message, style: GoogleFonts.dmSans()),
            backgroundColor: AppTheme.error,
          ),
        );
      } else if (status == RCPurchaseStatus.cancelled && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Purchase cancelled.', style: GoogleFonts.dmSans()),
            backgroundColor: AppTheme.textMuted,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('PRICING: bundle purchase error — $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not complete purchase. Please try again.',
              style: GoogleFonts.dmSans(),
            ),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _selectedBundle = null;
        });
      }
    }
  }

  Future<void> _handleRestorePurchases() async {
    if (kIsWeb) return;
    setState(() => _isLoading = true);
    try {
      final success = await RevenueCatService.instance.restorePurchases();
      if (mounted) {
        if (success) {
          await Provider.of<SubscriptionProvider>(
            context,
            listen: false,
          ).refreshSubscription();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Purchases restored successfully.',
                style: GoogleFonts.dmSans(),
              ),
              backgroundColor: const Color(0xFF2ECC71),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'No purchases to restore.',
                style: GoogleFonts.dmSans(),
              ),
              backgroundColor: AppTheme.textMuted,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('PRICING: restore error — $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final subProvider = context.watch<SubscriptionProvider>();
    final subscriptionTier = subProvider.subscriptionTier;
    final sparkBalance = subProvider.sparkBalance;
    final isSparkPlusActive = subProvider.isSparkPlus;
    final isGoldActive = subProvider.isGold;

    return Scaffold(
      backgroundColor: AppTheme.backgroundDark,
      body: Stack(
        children: [
          // Background gradient
          Container(
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0.0, -0.6),
                radius: 1.2,
                colors: [Color(0x22E8503A), Color(0xFF0D0D0F)],
              ),
            ),
          ),
          SafeArea(
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildCurrentPlanBanner(
                    subscriptionTier: subscriptionTier,
                    isSparkPlusActive: isSparkPlusActive,
                    isGoldActive: isGoldActive,
                  ),
                  const SizedBox(height: 16),
                  _buildBundlesSection(isSparkPlusActive: isSparkPlusActive),
                  const SizedBox(height: 28),
                  _buildToggle(),
                  const SizedBox(height: 20),
                  _buildSubscriptionCard(),
                  const SizedBox(height: 16),
                  _buildSubscribeButton(
                    isSparkPlusActive: isSparkPlusActive,
                    isGoldActive: isGoldActive,
                    currentTier: subscriptionTier,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Cancel anytime · Billed monthly',
                    style: GoogleFonts.dmSans(
                      fontSize: 12,
                      color: AppTheme.textMuted,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildSparkBalancePill(sparkBalance),
                  const SizedBox(height: 16),
                  GestureDetector(
                    onTap: _handleRestorePurchases,
                    child: Text(
                      'Restore purchases',
                      style: GoogleFonts.dmSans(
                        fontSize: 13,
                        color: AppTheme.primary,
                        decoration: TextDecoration.underline,
                        decorationColor: AppTheme.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: 140),
                ],
              ),
            ),
          ),
          // Back button
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentPlanBanner({
    required String subscriptionTier,
    required bool isSparkPlusActive,
    required bool isGoldActive,
  }) {
    final bool isGold = isGoldActive || subscriptionTier == 'gold';
    final bool isSparkPlus =
        (isSparkPlusActive || subscriptionTier == 'spark_plus') && !isGold;

    final Color borderColor = isGold
        ? const Color(0xFFFFD700)
        : isSparkPlus
        ? AppTheme.primary
        : const Color(0xFF555555);

    final Color bgColor = isGold
        ? const Color(0xFF2A2000)
        : isSparkPlus
        ? const Color(0xFF2A0A00)
        : const Color(0xFF1A1A1A);

    final Color textColor = isGold
        ? const Color(0xFFFFD700)
        : isSparkPlus
        ? AppTheme.primary
        : const Color(0xFF888888);

    final IconData icon = isGold
        ? Icons.workspace_premium_rounded
        : isSparkPlus
        ? Icons.bolt_rounded
        : Icons.person_outline_rounded;

    final String label = isGold
        ? 'Current Plan — Gold'
        : isSparkPlus
        ? 'Current Plan — Spark+'
        : 'Current Plan — Free';

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor, width: 1.5),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: textColor, size: 18),
              const SizedBox(width: 8),
              Text(
                label,
                style: GoogleFonts.dmSans(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildToggle() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceGlass,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: AppTheme.borderGlass),
          ),
          padding: const EdgeInsets.all(4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ToggleOption(
                label: 'Spark+',
                isSelected: !_isGold,
                onTap: () => setState(() => _isGold = false),
              ),
              _ToggleOption(
                label: 'Gold',
                isSelected: _isGold,
                onTap: () => setState(() => _isGold = true),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubscriptionCard() {
    final features = _isGold
        ? [
            '5 daily bonus Sparks',
            'See who Sparked you',
            'Rewind last skip',
            'Advanced filters',
            'Priority matching',
            'Profile spotlight',
            'Super Spark requests',
            'Read receipts',
            'Incognito mode',
            '25% off Spark bundles',
          ]
        : [
            '2 daily bonus Sparks',
            'See who Sparked you',
            'Rewind last skip',
            'Advanced filters',
            'Priority matching',
            '25% off Spark bundles',
          ];

    final price = _isGold ? '\$29.99' : '\$14.99';

    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: AppTheme.surfaceGlass,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: AppTheme.borderGlass),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    price,
                    style: GoogleFonts.cormorantGaramond(
                      fontSize: 48,
                      fontWeight: FontWeight.w700,
                      color: AppTheme.primary,
                      height: 1.0,
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8, left: 4),
                    child: Text(
                      '/ month',
                      style: GoogleFonts.dmSans(
                        fontSize: 14,
                        color: AppTheme.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              ...features.asMap().entries.map((entry) {
                final isLast = entry.key == features.length - 1;
                return Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.bolt_rounded,
                            color: AppTheme.primary,
                            size: 18,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              entry.value,
                              style: GoogleFonts.dmSans(
                                fontSize: 15,
                                color: const Color(0xFFF5F0E8),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (!isLast)
                      Divider(
                        color: AppTheme.borderGlass,
                        height: 1,
                        thickness: 0.5,
                      ),
                  ],
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubscribeButton({
    required bool isSparkPlusActive,
    required bool isGoldActive,
    required String currentTier,
  }) {
    if (!_isGold) {
      if (isSparkPlusActive && !isGoldActive) {
        return _buildCurrentPlanPill('Your current plan — Spark+');
      }
      return _buildSubscribeButtonWidget('Subscribe to Spark+');
    }

    if (isGoldActive || currentTier == 'gold') {
      return _buildCurrentPlanPill('Your current plan — Gold');
    }
    return _buildSubscribeButtonWidget('Subscribe to Gold');
  }

  Widget _buildCurrentPlanPill(String label) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: double.infinity,
          height: 56,
          decoration: BoxDecoration(
            color: const Color(0xFF1A3A2A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF2ECC71), width: 1.5),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF2ECC71),
                size: 20,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: GoogleFonts.dmSans(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: const Color(0xFF2ECC71),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSubscribeButtonWidget(String label) {
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _handleSubscribe,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primary,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
        child: _isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  color: Colors.white,
                  strokeWidth: 2,
                ),
              )
            : Text(
                label,
                style: GoogleFonts.dmSans(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
      ),
    );
  }

  Widget _buildBundlesSection({required bool isSparkPlusActive}) {
    // On mobile, bundles are 3, 6, 10 (RevenueCat product IDs)
    // On web, bundles remain 3, 10, 25 (Stripe price IDs)
    final bundles = kIsWeb
        ? [
            _BundleData(
              size: 3,
              price: isSparkPlusActive ? '\$3.74' : '\$4.99',
            ),
            _BundleData(
              size: 10,
              price: isSparkPlusActive ? '\$9.74' : '\$12.99',
            ),
            _BundleData(
              size: 25,
              price: isSparkPlusActive ? '\$18.74' : '\$24.99',
            ),
          ]
        : [
            _BundleData(size: 3, price: '\$4.99'),
            _BundleData(size: 10, price: '\$12.99'),
            _BundleData(size: 25, price: '\$24.99'),
          ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'TOP UP SPARKS',
          style: GoogleFonts.dmSans(
            fontSize: 12,
            color: AppTheme.textMuted,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: bundles.asMap().entries.map((entry) {
            final idx = entry.key;
            final bundle = entry.value;
            final isSelected = _selectedBundle == bundle.size;
            return Expanded(
              child: Padding(
                padding: EdgeInsets.only(
                  right: idx == bundles.length - 1 ? 0 : 8,
                ),
                child: _BundleCard(
                  bundle: bundle,
                  isSelected: isSelected,
                  isLoading: _isLoading && isSelected,
                  onTap: () => _handleBundlePurchase(bundle.size),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildSparkBalancePill(int sparkBalance) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(30),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceGlass,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: AppTheme.borderGlass),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bolt_rounded, color: AppTheme.primary, size: 16),
              const SizedBox(width: 6),
              Text(
                '$sparkBalance Sparks remaining',
                style: GoogleFonts.dmSans(
                  fontSize: 13,
                  color: const Color(0xFFF5F0E8),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ToggleOption extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _ToggleOption({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(26),
        ),
        child: Text(
          label,
          style: GoogleFonts.dmSans(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: isSelected ? Colors.white : AppTheme.textMuted,
          ),
        ),
      ),
    );
  }
}

class _BundleData {
  final int size;
  final String price;
  const _BundleData({required this.size, required this.price});
}

class _BundleCard extends StatelessWidget {
  final _BundleData bundle;
  final bool isSelected;
  final bool isLoading;
  final VoidCallback onTap;

  const _BundleCard({
    required this.bundle,
    required this.isSelected,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppTheme.primary.withAlpha(30)
                  : AppTheme.surfaceGlass,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected ? AppTheme.primary : AppTheme.borderGlass,
                width: isSelected ? 1.5 : 1.0,
              ),
            ),
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                isLoading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: AppTheme.primary,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(
                        Icons.bolt_rounded,
                        color: AppTheme.primary,
                        size: 24,
                      ),
                const SizedBox(height: 6),
                Text(
                  '${bundle.size}',
                  style: GoogleFonts.cormorantGaramond(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                    color: const Color(0xFFF5F0E8),
                    height: 1.0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  bundle.price,
                  style: GoogleFonts.dmSans(
                    fontSize: 13,
                    color: AppTheme.textMuted,
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
