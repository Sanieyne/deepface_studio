import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/api_client.dart';
import '../services/auth_service.dart';
import '../services/database_service.dart';
import '../theme/app_theme.dart';

/// Cosmic-Gen AI Pro Subscription & Gumroad Payment Dialog
/// Offers Pro ($4.99/mo) with unlimited local generation + 100 monthly cloud credits,
/// seamless browser checkout, real-time webhook polling, and license key activation.
class SubscriptionPlanDialog extends StatefulWidget {
  final bool isSubscribed;
  final String currentPlan;
  final ValueChanged<bool>? onPlanChanged;

  const SubscriptionPlanDialog({
    super.key,
    required this.isSubscribed,
    required this.currentPlan,
    this.onPlanChanged,
  });

  static Future<bool?> show(
    BuildContext context, {
    required bool isSubscribed,
    String currentPlan = 'Free Tier',
    ValueChanged<bool>? onPlanChanged,
  }) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => SubscriptionPlanDialog(
        isSubscribed: isSubscribed,
        currentPlan: currentPlan,
        onPlanChanged: onPlanChanged,
      ),
    );
  }

  @override
  State<SubscriptionPlanDialog> createState() => _SubscriptionPlanDialogState();
}

class _SubscriptionPlanDialogState extends State<SubscriptionPlanDialog> {
  late bool _isSubscribed;
  late String _currentPlan;
  bool _isLoading = false;
  bool _isAwaitingWebhook = false;
  Timer? _pollingTimer;

  final TextEditingController _licenseKeyController = TextEditingController();
  bool _isVerifyingLicense = false;
  String? _licenseError;
  String? _licenseSuccess;

  // Gumroad Product Permalink
  static const String proPermalink = 'pro';

  @override
  void initState() {
    super.initState();
    _isSubscribed = widget.isSubscribed;
    _currentPlan = widget.currentPlan;
  }

  @override
  void dispose() {
    _pollingTimer?.cancel();
    _licenseKeyController.dispose();
    super.dispose();
  }

  Future<void> _openBrowserUrl(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [url]);
      }
    } catch (e) {
      debugPrint('[SubscriptionDialog] Failed to open URL ($url): $e');
    }
  }

  Future<void> _startCheckout() async {
    final user = AuthService.instance.currentUser;
    final email = user?.email ?? '';
    final userId = user?.id ?? '';

    // Build Gumroad checkout URL prefilled with email and user_id for webhook attribution
    final uri = Uri(
      scheme: 'https',
      host: 'gumroad.com',
      path: '/l/$proPermalink',
      queryParameters: {
        if (email.isNotEmpty) 'email': email,
        if (userId.isNotEmpty) 'user_id': userId,
      },
    );

    setState(() {
      _isAwaitingWebhook = true;
      _licenseError = null;
      _licenseSuccess = null;
    });

    await _openBrowserUrl(uri.toString());

    // Start background auto-poller (checks for webhook delivery every 3 seconds for 2.5 minutes)
    _pollingTimer?.cancel();
    int ticks = 0;
    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      ticks++;
      if (ticks > 50) {
        timer.cancel();
        if (mounted) setState(() => _isAwaitingWebhook = false);
        return;
      }

      final updatedUser = await AuthService.instance.getCurrentUser(forceRefresh: true);
      if (updatedUser != null && updatedUser.isSubscribed) {
        timer.cancel();
        if (mounted) {
          setState(() {
            _isSubscribed = true;
            _currentPlan = 'Pro';
            _isAwaitingWebhook = false;
          });
          await DatabaseService.instance.setSetting('user_subscription_status', 'pro');
          widget.onPlanChanged?.call(true);
          Navigator.of(context).pop(true);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('🎉 Payment confirmed! Welcome to Cosmic-Gen Pro! Unlimited local generation is active.'),
              backgroundColor: Color(0xFF10B981),
            ),
          );
        }
      }
    });
  }

  Future<void> _verifyLicenseKey() async {
    final key = _licenseKeyController.text.trim();
    if (key.isEmpty) {
      setState(() => _licenseError = 'Please enter your Gumroad license key.');
      return;
    }

    setState(() {
      _isVerifyingLicense = true;
      _licenseError = null;
      _licenseSuccess = null;
    });

    try {
      final client = ApiClient();
      final response = await client.post(
        '/payments/verify-license',
        jsonBody: {'licenseKey': key},
      );

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if (response.statusCode == 200 && data['success'] == true) {
        await AuthService.instance.getCurrentUser(forceRefresh: true);
        await DatabaseService.instance.setSetting('user_subscription_status', 'pro');

        if (mounted) {
          setState(() {
            _isSubscribed = true;
            _currentPlan = 'Pro';
            _isVerifyingLicense = false;
            _licenseSuccess = 'License verified! Welcome to Cosmic-Gen Pro.';
          });

          widget.onPlanChanged?.call(true);
          Future.delayed(const Duration(milliseconds: 1200), () {
            if (mounted) Navigator.of(context).pop(true);
          });
        }
      } else {
        final msg = data['message']?.toString() ?? 'Invalid license key or already claimed.';
        if (mounted) {
          setState(() {
            _isVerifyingLicense = false;
            _licenseError = msg;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isVerifyingLicense = false;
          _licenseError = 'Verification failed: ${e.toString().replaceAll("Exception: ", "")}';
        });
      }
    }
  }

  Future<void> _toggleFreeDowngrade() async {
    setState(() => _isLoading = true);
    try {
      await DatabaseService.instance.setSetting('user_subscription_status', 'free');
      if (mounted) {
        setState(() {
          _isSubscribed = false;
          _currentPlan = 'Free Tier';
          _isLoading = false;
        });
        widget.onPlanChanged?.call(false);
        Navigator.of(context).pop(false);
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = LuminaTheme.isDark(context);
    final bg = dark ? LuminaColors.darkCard : LuminaColors.lightCard;
    final border = dark ? LuminaColors.darkBorder : LuminaColors.lightBorder;
    final muted = dark ? LuminaColors.darkMuted : LuminaColors.lightMuted;
    final user = AuthService.instance.currentUser;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      child: Container(
        width: 720,
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 760),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: dark ? 0.6 : 0.2),
              blurRadius: 36,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(28, 22, 20, 14),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: LuminaColors.primaryGradient,
                      borderRadius: BorderRadius.circular(14),
                      boxShadow: [
                        BoxShadow(
                          color: LuminaColors.primaryGlow.withValues(alpha: 0.35),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Icon(Icons.workspace_premium_rounded, color: Colors.white, size: 24),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Cosmic-Gen Pro Membership',
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          user != null
                              ? 'Signed in as ${user.email}. Upgrade to Pro for unlimited generation & 100 credits.'
                              : 'Unlock unlimited local image & video generation with 100 monthly cloud credits.',
                          style: TextStyle(fontSize: 12.5, color: muted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close_rounded, size: 20, color: muted),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            // Real-time awaiting webhook notification banner
            if (_isAwaitingWebhook)
              Container(
                margin: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: LuminaColors.primaryStart.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: LuminaColors.primaryEnd.withValues(alpha: 0.4)),
                ),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2.2, color: LuminaColors.primaryEnd),
                    ),
                    const SizedBox(width: 12),
                    const Expanded(
                      child: Text(
                        'Gumroad checkout opened in your browser! Complete checkout to auto-unlock Pro.',
                        style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    ),
                    TextButton(
                      onPressed: () => setState(() => _isAwaitingWebhook = false),
                      child: const Text('Dismiss', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ),

            // Plan Cards Comparison
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Free Tier Card
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(color: border),
                              color: dark ? Colors.white.withValues(alpha: 0.02) : Colors.black.withValues(alpha: 0.02),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Text(
                                      'Free Tier',
                                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                    ),
                                    const Spacer(),
                                    if (!_isSubscribed)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: Colors.green.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
                                        ),
                                        child: const Text(
                                          'CURRENT',
                                          style: TextStyle(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w900,
                                            color: Colors.green,
                                            letterSpacing: 0.4,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                const Text(
                                  'Free Forever',
                                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Preview mode with cloud GPU pay-as-you-go',
                                  style: TextStyle(fontSize: 11.5, color: muted),
                                ),
                                const SizedBox(height: 14),
                                const Divider(height: 1),
                                const SizedBox(height: 14),
                                _buildFeatureRow('Browse template galleries & models', true, dark, muted),
                                _buildFeatureRow('Offline database project storage', true, dark, muted),
                                _buildFeatureRow('Pay-as-you-go Cloud GPU rentals', true, dark, muted),
                                _buildFeatureRow('Unlimited local generation', false, dark, muted),
                                _buildFeatureRow('100 monthly compute credits', false, dark, muted),
                                _buildFeatureRow('High-resolution 4K AI upscaling', false, dark, muted),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton(
                                    onPressed: _isSubscribed ? _toggleFreeDowngrade : null,
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      side: BorderSide(color: border),
                                    ),
                                    child: Text(
                                      !_isSubscribed ? 'Current Plan' : 'Downgrade to Free',
                                      style: TextStyle(fontSize: 12.5, color: muted, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),

                        // Lifetime Software License Card ($35)
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(18),
                              border: Border.all(
                                color: const Color(0xFF10B981),
                                width: 1.8,
                              ),
                              color: dark ? const Color(0xFF12231D) : const Color(0xFFF1FBF6),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF10B981).withValues(alpha: 0.22),
                                  blurRadius: 20,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Text(
                                      'Lifetime License',
                                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                    ),
                                    const Spacer(),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        gradient: const LinearGradient(colors: [Color(0xFF059669), Color(0xFF10B981)]),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: const Text(
                                        'ONE-TIME • FULL OWNERSHIP',
                                        style: TextStyle(
                                          fontSize: 9,
                                          fontWeight: FontWeight.w900,
                                          color: Colors.white,
                                          letterSpacing: 0.4,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    const Text(
                                      '\$35',
                                      style: TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w900,
                                        color: Color(0xFF10B981),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      'one-time payment',
                                      style: TextStyle(fontSize: 12, color: muted),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Lifetime software activation • Top up cloud credits anytime',
                                  style: TextStyle(fontSize: 11.5, color: muted),
                                ),
                                const SizedBox(height: 14),
                                const Divider(height: 1),
                                const SizedBox(height: 14),
                                _buildFeatureRow('One-time software purchase (\$35 USD)', true, dark, muted, highlight: true),
                                _buildFeatureRow('No recurring subscriptions or monthly fees', true, dark, muted, highlight: true),
                                _buildFeatureRow('Unlimited high-speed local generation', true, dark, muted, highlight: true),
                                _buildFeatureRow('100% offline data privacy & local GPU power', true, dark, muted, highlight: true),
                                _buildFeatureRow('Pay-as-you-go optional cloud credits top-up', true, dark, muted, highlight: true),
                                _buildFeatureRow('Hardware-encrypted activation key', true, dark, muted, highlight: true),
                                const SizedBox(height: 14),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: _isSubscribed ? null : _startCheckout,
                                    style: ElevatedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                      backgroundColor: _isSubscribed ? Colors.grey.shade700 : const Color(0xFF10B981),
                                      foregroundColor: Colors.white,
                                      elevation: _isSubscribed ? 0 : 3,
                                      shadowColor: const Color(0xFF10B981).withValues(alpha: 0.4),
                                    ),
                                    child: Text(
                                      _isSubscribed ? 'Active (Software Activated)' : 'Buy License (\$35 USD)',
                                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),

                    // License Key Fallback Entry Form
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.key_rounded, size: 16, color: muted),
                              const SizedBox(width: 8),
                              const Text(
                                'Have a Gumroad License Key?',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '(Enter key to activate Pro instantly)',
                                style: TextStyle(fontSize: 11.5, color: muted),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: SizedBox(
                                  height: 40,
                                  child: TextField(
                                    controller: _licenseKeyController,
                                    style: const TextStyle(fontSize: 13),
                                    decoration: InputDecoration(
                                      hintText: 'e.g. 12345678-ABCD-EFGH-IJKL-9876543210AB',
                                      hintStyle: TextStyle(fontSize: 12, color: muted),
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                        borderSide: BorderSide(color: border),
                                      ),
                                      enabledBorder: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(10),
                                        borderSide: BorderSide(color: border),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              ElevatedButton(
                                onPressed: _isVerifyingLicense ? null : _verifyLicenseKey,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: LuminaColors.primaryEnd,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                ),
                                child: _isVerifyingLicense
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                      )
                                    : const Text('Activate License', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),
                          if (_licenseError != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              _licenseError!,
                              style: const TextStyle(fontSize: 11.5, color: Colors.redAccent, fontWeight: FontWeight.w600),
                            ),
                          ],
                          if (_licenseSuccess != null) ...[
                            const SizedBox(height: 6),
                            Text(
                              _licenseSuccess!,
                              style: const TextStyle(fontSize: 11.5, color: Color(0xFF10B981), fontWeight: FontWeight.w600),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Footer Note
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: (dark ? Colors.white : Colors.black).withValues(alpha: 0.03),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(24)),
              ),
              child: Row(
                children: [
                  Icon(Icons.shield_outlined, size: 16, color: muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Secure checkout powered by Gumroad. Cancel subscription anytime with 1 click.',
                      style: TextStyle(fontSize: 12, color: muted),
                    ),
                  ),
                  if (_isLoading)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureRow(String text, bool included, bool dark, Color muted, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            included ? Icons.check_circle_rounded : Icons.cancel_outlined,
            size: 14,
            color: included
                ? (highlight ? const Color(0xFF10B981) : Colors.green.shade600)
                : Colors.grey.shade500,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11.5,
                color: included
                    ? (dark ? Colors.white70 : Colors.black87)
                    : muted.withValues(alpha: 0.7),
                decoration: included ? null : TextDecoration.lineThrough,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
