import 'package:flutter/material.dart';

import 'core/services/api_client.dart';
import 'core/theme/app_theme.dart';
import 'screens/alerts_screen.dart';
import 'screens/campaigns_screen.dart';
import 'screens/clients_screen.dart';
import 'screens/dashboard_screen.dart';
import 'screens/drafts_screen.dart';
import 'screens/fulfillment_screen.dart';
import 'screens/leads_screen.dart';
import 'screens/pricing_screen.dart';
import 'screens/settings_screen.dart';

class LeadPilotApp extends StatefulWidget {
  const LeadPilotApp({super.key});

  @override
  State<LeadPilotApp> createState() => _LeadPilotAppState();
}

class _LeadPilotAppState extends State<LeadPilotApp> {
  late final ApiService api = ApiService(ApiConfig.fromEnvironment());
  ThemeMode _themeMode = ThemeMode.light;

  @override
  void dispose() {
    api.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'LeadPilot AI',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: _themeMode,
        home: AppShell(
          api: api,
          isDark: _themeMode == ThemeMode.dark,
          onToggleTheme: () => setState(() => _themeMode = _themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark),
        ),
      );
}

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.api, required this.isDark, required this.onToggleTheme});

  final ApiService api;
  final bool isDark;
  final VoidCallback onToggleTheme;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _selectedIndex = 0;

  static const _items = [
    _NavItem('Overview', Icons.grid_view_rounded),
    _NavItem('Leads & import', Icons.people_alt_outlined),
    _NavItem('Draft review', Icons.rate_review_outlined),
    _NavItem('Campaigns', Icons.campaign_outlined),
    _NavItem('Clients & projects', Icons.business_center_outlined),
    _NavItem('Pricing & profit', Icons.show_chart_rounded),
    _NavItem('Fulfillment', Icons.auto_awesome_outlined),
    _NavItem('Alerts', Icons.notifications_none_rounded),
    _NavItem('Settings', Icons.settings_outlined),
  ];

  List<Widget> get _screens => [
        DashboardScreen(api: widget.api),
        LeadsScreen(api: widget.api),
        DraftsScreen(api: widget.api),
        CampaignsScreen(api: widget.api),
        ClientsScreen(api: widget.api),
        PricingScreen(api: widget.api),
        FulfillmentScreen(api: widget.api),
        AlertsScreen(api: widget.api),
        SettingsScreen(api: widget.api, isDark: widget.isDark, onToggleTheme: widget.onToggleTheme),
      ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final extended = constraints.maxWidth >= 1120;
          final current = _items[_selectedIndex];
          return Scaffold(
            body: Row(
              children: [
                Container(
                  width: extended ? 260 : 82,
                  decoration: BoxDecoration(
                    color: Theme.of(context).navigationRailTheme.backgroundColor,
                    border: Border(right: BorderSide(color: Theme.of(context).dividerColor)),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: EdgeInsets.fromLTRB(extended ? 20 : 14, 24, extended ? 20 : 14, 20),
                        child: Row(
                          mainAxisAlignment: extended ? MainAxisAlignment.start : MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: BoxDecoration(color: AppColors.navy, borderRadius: BorderRadius.circular(11)),
                              child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 22),
                            ),
                            if (extended) ...[
                              const SizedBox(width: 11),
                              const Text('LeadPilot', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
                            ],
                          ],
                        ),
                      ),
                      Expanded(
                        child: NavigationRail(
                          extended: extended,
                          selectedIndex: _selectedIndex,
                          onDestinationSelected: (index) => setState(() => _selectedIndex = index),
                          leading: extended
                              ? const Padding(
                                  padding: EdgeInsets.only(left: 4, bottom: 12),
                                  child: Align(alignment: Alignment.centerLeft, child: Text('WORKSPACE', style: TextStyle(fontSize: 10, color: AppColors.slate, fontWeight: FontWeight.w800, letterSpacing: 1.2))),
                                )
                              : null,
                          destinations: [
                            for (final item in _items)
                              NavigationRailDestination(icon: Icon(item.icon), label: Text(item.label)),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 18),
                        child: IconButton(
                          tooltip: widget.isDark ? 'Use light theme' : 'Use dark theme',
                          onPressed: widget.onToggleTheme,
                          icon: Icon(widget.isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        height: 76,
                        padding: const EdgeInsets.symmetric(horizontal: 28),
                        decoration: BoxDecoration(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(current.label, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                                  Text('Local-first revenue operations', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.slate)),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Open alerts',
                               onPressed: () => setState(() => _selectedIndex = 7),
                              icon: const Icon(Icons.notifications_none_rounded),
                            ),
                            const SizedBox(width: 8),
                            CircleAvatar(
                              radius: 18,
                              backgroundColor: AppColors.blueSoft,
                              child: Text('LP', style: TextStyle(color: AppColors.blue, fontWeight: FontWeight.w800)),
                            ),
                          ],
                        ),
                      ),
                      Expanded(child: IndexedStack(index: _selectedIndex, children: _screens)),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      );
}

class _NavItem {
  const _NavItem(this.label, this.icon);

  final String label;
  final IconData icon;
}
