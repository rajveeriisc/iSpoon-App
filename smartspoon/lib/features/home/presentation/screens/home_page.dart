// home_page.dart — top-level app shell with bottom navigation.
//
// HomePage hosts the three main tabs (Home, Insights, Profile) behind a glass
// bottom nav bar and a shared gradient/geometric background. HomeContent renders
// the Home tab itself: it watches McuBleService for connected spoons and shows
// per-device status/temperature/eating cards (or empty-state cards when none),
// plus health-insight and bite-detection sections. Also requests first-launch
// permissions and triggers a one-time cloud restore on login.
import 'package:flutter/material.dart';
import 'package:smartspoon/core/widgets/bowl_spoon_icon.dart';
import 'package:smartspoon/features/profile/index.dart';
import 'package:smartspoon/features/insights/index.dart';
import 'package:smartspoon/features/home/presentation/widgets/home_cards.dart'
    as home_widgets;
import 'package:smartspoon/features/ai_lab/presentation/screens/ai_lab_page.dart';
import 'package:smartspoon/core/theme/app_theme.dart';
import 'package:smartspoon/core/widgets/card_layout.dart';
import 'package:smartspoon/core/widgets/geometric_background.dart';
import 'package:smartspoon/core/widgets/premium_header.dart';
import 'package:smartspoon/core/services/permission_service.dart';
import 'package:smartspoon/core/services/sync_service.dart';
import 'package:provider/provider.dart';
import 'package:smartspoon/features/devices/index.dart' as devices;
import 'package:smartspoon/features/devices/presentation/widgets/heater_capability_prompt.dart';

// HomePage widget serves as the main entry point for the app's home screen
class HomePage extends StatefulWidget {
  /// Bottom-nav tab: 0 home, 1 insights, 2 profile.
  final int initialIndex;

  const HomePage({super.key, this.initialIndex = 0});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Tracks the currently selected bottom navigation item
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex.clamp(0, 3);
    // Request permissions once on first ever launch (no-op on all subsequent opens)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      PermissionService.requestIfNeeded(context);
    });

    // Restore meal/bite history from the cloud if local storage looks empty
    // (reinstall or first login on a new device). Guarded to only attempt
    // once per app session.
    _checkAndRestoreData();
  }

  Future<void> _checkAndRestoreData() async {
    final didRestore = await SyncService().autoRestoreOnLoginIfNeeded();
    if (didRestore && mounted) {
      // Data was pulled from the cloud. Force the UnifiedDataService
      // to reload its SQLite summary so the home page updates immediately.
      context.read<UnifiedDataService>().refreshTodaySnapshot();
    }
  }

  // Updates the selected index when a bottom navigation item is tapped
  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  // Returns a greeting based on the current time of day:
  // before 12:00 -> Good Morning, 12:00-17:00 -> Good Afternoon,
  // after 17:00 -> Good Evening.
  String get _greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) {
      return 'Good Morning,';
    } else if (hour < 17) {
      return 'Good Afternoon,';
    } else {
      return 'Good Evening,';
    }
  }

  // Determines which content to display based on the selected index
  Widget _buildBody() {
    switch (_selectedIndex) {
      case 0:
        return const HomeContent();
      case 1:
        // InsightsController now provided globally in main.dart
        return const InsightsDashboard();
      case 2:
        return const AiLabPage();
      case 3:
        return const ProfilePage();
      default:
        return const HomeContent();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true, // Allow body to extend behind the bottom nav
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      body: Stack(
        children: [
          // 1. Premium theme-aware gradient background
          Container(
            decoration: BoxDecoration(
              gradient: Theme.of(context).brightness == Brightness.dark
                  ? AppTheme.darkBackgroundGradient
                  : (_selectedIndex == 1
                        ? AppTheme
                              .mistBackgroundGradient // Mist for Insights
                        : AppTheme
                              .backgroundGradient), // Dawn for Home & Profile
            ),
          ),
          // 2. Subtle geometric background pattern
          const GeometricBackground(),
          // 3. Main Content Area
          SafeArea(
            bottom: false,
            child: Column(
              children: [
                // Custom Header
                if (_selectedIndex == 0)
                  PremiumHeader(title: _greeting, subtitle: 'Eating overview'),

                // Body Content
                Expanded(child: _buildBody()),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _buildBottomNav(context),
    );
  }

  Widget _buildBottomNav(BuildContext context) {
    // Height and margin both come from CardLayout, which is also what the
    // scrolling lists use to work out how far to stop short of this bar.
    return Container(
      margin: EdgeInsets.only(
        left: AppTheme.spaceMd,
        right: AppTheme.spaceMd,
        bottom: CardLayout.navBarMargin(context),
      ),
      height: kBottomNavHeight,
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? AppTheme.darkSurface
            : AppTheme.surface,
        borderRadius: BorderRadius.circular(AppTheme.radiusLg),
        border: Border.all(
          color: Theme.of(context).brightness == Brightness.dark
              ? AppTheme.darkBorder
              : AppTheme.line,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: Theme.of(context).brightness == Brightness.dark
                  ? 0.22
                  : 0.08,
            ),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        children: [
          _buildNavItem(0, Icon(Icons.grid_view_rounded), 'Home'),
          _buildNavItem(1, Icon(Icons.insights_rounded), 'Insights'),
          // 'AI Lab' named the technology; 'Mealsense' names what the page is
          // about. Icon moved off the brain for the same reason.
          _buildNavItem(2, const BowlSpoonIcon(), 'Mealsense'),
          _buildNavItem(3, Icon(Icons.person_rounded), 'Profile'),
        ],
      ),
    );
  }

  Widget _buildNavItem(int index, Widget icon, String label) {
    final isSelected = _selectedIndex == index;
    // colorScheme.primary adapts per theme (teal in light, mint in dark) so
    // the active state stays legible on the dark glass bar.
    final selectedColor = Theme.of(context).colorScheme.primary;
    final unselectedColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.55);
    return Expanded(
      child: Semantics(
        button: true,
        selected: isSelected,
        label: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => _onItemTapped(index),
            customBorder: const StadiumBorder(),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 36,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? selectedColor.withValues(alpha: 0.12)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(AppTheme.radiusSm),
                  ),
                  child: IconTheme(data: IconThemeData(color: isSelected ? selectedColor : unselectedColor,
                    size: 22), child: icon),
                ),
                // Persistent labels aid discoverability; only the color and
                // weight react to selection so the layout never shifts.
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    fontSize: 11,
                    fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected ? selectedColor : unselectedColor,
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

// HomeContent widget displays the main content of the home page
class HomeContent extends StatelessWidget {
  const HomeContent({super.key});

  @override
  Widget build(BuildContext context) {
    // Reduced top padding because custom header handles spacing.
    // The static footer is passed as the Consumer's `child` so it is built
    // once and NOT rebuilt on every McuBleService notify (up to 10Hz while
    // a spoon is streaming) — only the live device cards rebuild.
    return Consumer<devices.SpoonRuntime>(
      child: const _HomeFooter(),
      builder: (context, ble, footer) {
        final uds = context.watch<UnifiedDataService>();
        final deviceIds = ble.visibleDeviceIds;
        final unpaired = ble.unpairedNearbyDevices;
        return SingleChildScrollView(
          padding: CardLayout.listPadding(context, top: AppTheme.spaceSm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (unpaired.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  'New spoon nearby',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                const SizedBox(height: 10),
                ...unpaired.map((d) {
                  final name = d.displayName;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: ListTile(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      tileColor: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.6),
                      leading: const Icon(Icons.bluetooth_searching),
                      title: Text(
                        name.isEmpty ? 'iSpoon Pro' : name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: const Text('Tap to pair and save this spoon'),
                      trailing: const Icon(Icons.add_circle_outline),
                      // Shared with AddDeviceScreen's pairing flow — this tile
                      // used to call SavedBleDevice.detectHeater(name) alone,
                      // with no ambiguous-name prompt, so a renamed Pro spoon
                      // (any name not containing "pro") connected from here
                      // silently lost its heater controls. See
                      // heater_capability_prompt.dart.
                      onTap: () {
                        // Provisional only — the spoon declares its real
                        // capability over GATT on connect and the coordinator
                        // overwrites this. No spoon-type question is asked.
                        ble.setDeviceCapability(
                          d.id,
                          provisionalHeaterCapability(name),
                        );
                        ble.connectToDevice(
                          d.id,
                          displayName: d.displayName,
                        );
                      },
                    ),
                  );
                }),
                const SizedBox(height: 12),
              ],
              if (deviceIds.isEmpty) ...[
                const SizedBox(height: 10),
                const home_widgets.SpoonConnectedCard(),
                const SizedBox(height: 20),
                const home_widgets.TemperatureCard(),
                const SizedBox(height: 20),
                const home_widgets.EatingAnalysisCard(),
                const SizedBox(height: 24),
              ] else ...[
                // ── SINGLE selected-spoon view ───────────────────────────────
                // The home page shows ONE spoon at a time (spoon = person). The
                // user picks a spoon and the WHOLE page follows it — status,
                // temperature and eating analysis — whether or not it's
                // currently connected. No more one-section-per-spoon list.
                Builder(
                  builder: (context) {
                    final connectedId = ble.connectedDeviceId ??
                        (ble.sessionDisplayId != null &&
                                ble.isLinkingTo(ble.sessionDisplayId!)
                            ? ble.sessionDisplayId
                            : null);
                    final selectedId = uds.selectedDeviceIdAmong(
                      deviceIds,
                      connectedId,
                    );

                    String nameFor(String id) {
                      var name = '';
                      String? productId;
                      for (final d in ble.previousDevices) {
                        if (d.id == id) {
                          name = d.displayName;
                          productId = d.productId;
                          break;
                        }
                      }
                      final source =
                          (productId != null && productId.isNotEmpty)
                              ? productId
                              : id.replaceAll(':', '');
                      final tail = (source.length > 4
                              ? source.substring(source.length - 4)
                              : source)
                          .toUpperCase();
                      if (name.isEmpty) return 'I-Spoon ($tail)';
                      // Two chips both reading "iSpoon Pro" cannot be told
                      // apart; the end of the Device ID can.
                      final sameName = ble.previousDevices
                              .where((d) => d.displayName == name)
                              .length >
                          1;
                      return sameName ? '$name · $tail' : name;
                    }

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Spoon picker — only when there's more than one paired
                        // spoon. Tapping a chip switches the whole page.
                        if (deviceIds.length > 1) ...[
                          const SizedBox(height: 10),
                          Text(
                            'Viewing spoon',
                            style: Theme.of(context).textTheme.labelMedium
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurface
                                      .withValues(alpha: 0.6),
                                ),
                          ),
                          const SizedBox(height: 8),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                for (final id in deviceIds)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: ChoiceChip(
                                      label: Text(nameFor(id)),
                                      selected: id == selectedId,
                                      avatar: Icon(
                                        uds.isEffectivelyConnectedFor(id)
                                            ? Icons.bluetooth_connected
                                            : Icons.bluetooth_disabled,
                                        size: 16,
                                      ),
                                      onSelected: (_) async {
                                        await uds.selectSpoon(id);
                                        if (!context.mounted) return;
                                        final name = nameFor(id);
                                        if (!ble.isConnectedTo(id)) {
                                          ScaffoldMessenger.of(context)
                                            ..hideCurrentSnackBar()
                                            ..showSnackBar(SnackBar(
                                              content:
                                                  Text('Connecting to $name…'),
                                              duration:
                                                  const Duration(seconds: 12),
                                            ));
                                        }
                                        final outcome =
                                            await ble.reconnectSavedDevice(id);
                                        if (!context.mounted) return;
                                        await home_widgets.explainSpoonSwitch(
                                          context,
                                          ble,
                                          id,
                                          name,
                                          outcome,
                                        );
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                        const SizedBox(height: 12),
                        home_widgets.SpoonConnectedCard(deviceId: selectedId),
                        // Temperature is a LIVE reading — only while connected.
                        if (uds.isEffectivelyConnectedFor(selectedId)) ...[
                          const SizedBox(height: 20),
                          home_widgets.TemperatureCard(deviceId: selectedId),
                        ],
                        // Eating Analysis is stored per-spoon data — always show
                        // it for the selected spoon, connected or not.
                        const SizedBox(height: 20),
                        home_widgets.EatingAnalysisCard(deviceId: selectedId),
                        const SizedBox(height: 24),
                      ],
                    );
                  },
                ),
              ],
              footer!,
            ],
          ),
        );
      },
    );
  }
}

/// Static section below the device cards — shared by the connected and
/// no-device layouts (previously duplicated in both branches).
class _HomeFooter extends StatelessWidget {
  const _HomeFooter();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Eating Insights',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: 16),
        const home_widgets.DailyTipCard(),
        const SizedBox(height: 16),
        const home_widgets.MotivationCard(),
        const SizedBox(height: 20),
      ],
    );
  }
}
