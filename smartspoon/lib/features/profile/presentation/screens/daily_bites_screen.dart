// daily_bites_screen.dart — daily bite goal + progress screen.
//
// Shows today's bite total against the user's per-meal daily goals (from
// UnifiedDataService) and lets them view/adjust progress. A goal-tracking view
// reached from the profile area.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:smartspoon/features/profile/presentation/widgets/profile_redesign_widgets.dart'; // Provides ProfileCard (PremiumGlassCard wrapper)
import 'package:smartspoon/features/insights/domain/services/unified_data_service.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/geometric_background.dart';

class DailyBitesScreen extends StatefulWidget {
  const DailyBitesScreen({super.key});

  @override
  State<DailyBitesScreen> createState() => _DailyBitesScreenState();
}

class _DailyBitesScreenState extends State<DailyBitesScreen> {
  // Local state for sliders
  double _breakfastBites = 15;
  double _lunchBites = 20;
  double _dinnerBites = 15;
  double _snackBites = 5;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final uds = context.read<UnifiedDataService>();
      setState(() {
        _breakfastBites = uds.breakfastGoal;
        _lunchBites = uds.lunchGoal;
        _dinnerBites = uds.dinnerGoal;
        _snackBites = uds.snackGoal;
      });
    });
  }

  bool _isSaving = false;

  Future<void> _save() async {
    if (_isSaving) return;

    setState(() => _isSaving = true);

    try {
      final total = _breakfastBites + _lunchBites + _dinnerBites + _snackBites;

      final uds = context.read<UnifiedDataService>();
      await uds.setDailyGoals(
        _breakfastBites,
        _lunchBites,
        _dinnerBites,
        _snackBites,
      );

      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Daily bite goal updated to ${total.toInt()}!',
              style: GoogleFonts.figtree(color: Colors.white),
            ),
            backgroundColor: AppTheme.sageDeep,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Failed to save goals: $e',
              style: GoogleFonts.figtree(color: Colors.white),
            ),
            backgroundColor: AppTheme.paprika,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = _breakfastBites + _lunchBites + _dinnerBites + _snackBites;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          // Background
          Container(
            decoration: BoxDecoration(
              gradient: Theme.of(context).brightness == Brightness.dark
                  ? AppTheme.darkBackgroundGradient
                  : AppTheme.backgroundGradient,
            ),
          ),
          const GeometricBackground(),

          SafeArea(
            child: Column(
              children: [
                _buildAppBar(context),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        // Total Summary
                        Container(
                          padding: const EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            gradient: AppTheme.headerGradient,
                            borderRadius: BorderRadius.circular(24),
                            boxShadow: [
                              BoxShadow(
                                color: AppTheme.caramel.withValues(alpha: 0.3),
                                blurRadius: 20,
                                offset: const Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Column(
                            children: [
                              Text(
                                'TOTAL DAILY GOAL',
                                style: GoogleFonts.figtree(
                                  color: Colors.white.withValues(alpha: 0.75),
                                  fontSize: 14,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.5,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  Text(
                                    '${total.toInt()}',
                                    style: AppTheme.serif(
                                      color: Colors.white,
                                      fontSize: 56,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    'bites',
                                    style: GoogleFonts.figtree(
                                      color: Colors.white.withValues(alpha: 0.75),
                                      fontSize: 18,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),

                        const SizedBox(height: 32),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            'MEAL BREAKDOWN',
                            style: GoogleFonts.figtree(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.caramel,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        _buildMealSlider(
                          'Breakfast',
                          _breakfastBites,
                          (val) => setState(() => _breakfastBites = val),
                          Icons.wb_sunny_outlined,
                        ),
                        const SizedBox(height: 16),
                        _buildMealSlider(
                          'Lunch',
                          _lunchBites,
                          (val) => setState(() => _lunchBites = val),
                          Icons.restaurant_outlined,
                        ),
                        const SizedBox(height: 16),
                        _buildMealSlider(
                          'Dinner',
                          _dinnerBites,
                          (val) => setState(() => _dinnerBites = val),
                          Icons.nights_stay_outlined,
                        ),
                        const SizedBox(height: 16),
                        _buildMealSlider(
                          'Snacks',
                          _snackBites,
                          (val) => setState(() => _snackBites = val),
                          Icons.cookie_outlined,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: Icon(
              Icons.arrow_back_ios_new,
              color: Theme.of(context).colorScheme.onSurface,
              size: 20,
            ),
            onPressed: () => Navigator.pop(context),
          ),
          Text(
            'Daily Bites',
            style: AppTheme.serif(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          TextButton(
            onPressed: _save,
            child: Text(
              'Save',
              style: GoogleFonts.figtree(
                color: AppTheme.caramel,
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMealSlider(
    String label,
    double value,
    ValueChanged<double> onChanged,
    IconData icon,
  ) {
    return ProfileCard(
      accentColor: AppTheme.caramel,
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.caramel.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: AppTheme.caramel, size: 20),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.figtree(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              Text(
                '${value.toInt()} bites',
                style: GoogleFonts.figtree(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.caramel,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SliderTheme(
            data: SliderThemeData(
              activeTrackColor: AppTheme.caramel,
              inactiveTrackColor: Theme.of(
                context,
              ).colorScheme.onSurface.withValues(alpha: 0.05),
              thumbColor: AppTheme.caramel,
              overlayColor: AppTheme.caramel.withValues(alpha: 0.2),
              trackHeight: 4,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
            ),
            child: Slider(
              value: value,
              min: 0,
              max: 50,
              divisions: 50,
              label: value.round().toString(),
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
