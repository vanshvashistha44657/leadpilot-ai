import 'package:flutter/material.dart';

import '../core/models/api_models.dart';
import '../core/services/api_client.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/design_system.dart';

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<DashboardMetrics> _metrics;

  @override
  void initState() {
    super.initState();
    _metrics = widget.api.getDashboardMetrics();
  }

  void _refresh() => setState(() => _metrics = widget.api.getDashboardMetrics());

  @override
  Widget build(BuildContext context) => PageContainer(
        children: [
          SectionHeader(
            title: 'Good morning, operator',
            subtitle: 'A live view of leads, outreach safety, and delivery work.',
            action: OutlinedButton.icon(onPressed: _refresh, icon: const Icon(Icons.refresh, size: 18), label: const Text('Refresh')),
          ),
          const SizedBox(height: 24),
          FutureBuilder<DashboardMetrics>(
            future: _metrics,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const LoadingState();
              if (snapshot.hasError) return ErrorState(message: snapshot.error.toString(), onRetry: _refresh);
              final data = snapshot.data;
              if (data == null) return ErrorState(message: 'The backend returned no dashboard data.', onRetry: _refresh);
              return _DashboardContent(metrics: data);
            },
          ),
        ],
      );
}

class _DashboardContent extends StatelessWidget {
  const _DashboardContent({required this.metrics});

  final DashboardMetrics metrics;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth >= 1050
                  ? (constraints.maxWidth - 48) / 4
                  : constraints.maxWidth >= 700
                      ? (constraints.maxWidth - 16) / 2
                      : constraints.maxWidth;
              return Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  SizedBox(width: width, child: MetricCard(label: 'Total leads', value: '${metrics.totalLeads}', icon: Icons.people_alt_outlined, helper: '${metrics.activeLeads} active', color: AppColors.blue)),
                  SizedBox(width: width, child: MetricCard(label: 'Campaigns', value: '${metrics.campaigns}', icon: Icons.campaign_outlined, helper: 'Configured sequences', color: AppColors.mint)),
                  SizedBox(width: width, child: MetricCard(label: 'Dry-run events', value: '${metrics.dryRunOutreachEvents}', icon: Icons.shield_outlined, helper: '${metrics.liveOutreachEvents} live events', color: AppColors.amber)),
                   SizedBox(width: width, child: MetricCard(label: 'Pending alerts', value: '${metrics.pendingAlerts}', icon: Icons.notifications_none_rounded, helper: '${metrics.suppressedLeads} suppressed leads', color: metrics.pendingAlerts > 0 ? AppColors.red : AppColors.mint)),
                  SizedBox(width: width, child: MetricCard(label: 'Revenue', value: formatMoney(metrics.revenue), icon: Icons.payments_outlined, helper: '${metrics.conversions} conversions', color: AppColors.mint)),
                  SizedBox(width: width, child: MetricCard(label: 'Recurring revenue', value: formatMoney(metrics.recurringRevenue), icon: Icons.autorenew_rounded, helper: '${metrics.projects} tracked projects', color: AppColors.purple)),
                ],
              );
            },
          ),
          const SizedBox(height: 20),
          const SafetyBanner(
            title: 'Dry-run safety is on',
            message: 'LeadPilot previews and records outreach without sending messages. Live sending remains a backend-controlled setting.',
          ),
          const SizedBox(height: 20),
          AppCard(
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                StatusPill(label: 'Replies ${metrics.totalReplies}', color: AppColors.blue),
                StatusPill(label: 'Interested ${metrics.interestedReplies}', color: AppColors.mint),
                StatusPill(label: 'Pricing ${metrics.pricingReplies}', color: AppColors.amber),
                StatusPill(label: 'Meetings ${metrics.meetingReplies}', color: AppColors.purple),
                StatusPill(label: 'Reviewed leads ${metrics.reviewedLeads}', color: AppColors.blue),
                StatusPill(label: 'Clients ${metrics.clients}', color: AppColors.mint),
                StatusPill(label: 'Projects ${metrics.projects}', color: AppColors.blue),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(title: 'Job activity', subtitle: 'Current queue state from the backend.'),
                      const SizedBox(height: 20),
                      if (metrics.jobsByStatus.isEmpty)
                        const EmptyState(title: 'No jobs yet', message: 'Queued outreach and import jobs will appear here.', icon: Icons.work_history_outlined)
                      else
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: metrics.jobsByStatus.entries.map((entry) => StatusPill(label: '${entry.key}: ${entry.value}', color: statusColor(entry.key))).toList(),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                flex: 2,
                child: AppCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(title: 'Workspace health', subtitle: 'Signals to check before outreach.'),
                      const SizedBox(height: 18),
                      _HealthRow(label: 'Lead pool', value: metrics.totalLeads > 0 ? 'Ready' : 'Empty', color: metrics.totalLeads > 0 ? AppColors.mint : AppColors.amber),
                      _HealthRow(label: 'Suppression list', value: '${metrics.suppressedLeads} records', color: AppColors.blue),
                      _HealthRow(label: 'Outreach mode', value: 'Dry run', color: AppColors.mint),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      );
}

class _HealthRow extends StatelessWidget {
  const _HealthRow({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 10),
            Expanded(child: Text(label)),
            Text(value, style: TextStyle(color: color, fontWeight: FontWeight.w800)),
          ],
        ),
      );
}
