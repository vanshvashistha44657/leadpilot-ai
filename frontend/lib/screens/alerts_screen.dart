import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/models/api_models.dart';
import '../core/services/api_client.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/design_system.dart';

class AlertsScreen extends StatefulWidget {
  const AlertsScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends State<AlertsScreen> {
  late Future<_AlertData> _data;
  bool _includeAcknowledged = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_AlertData> _load() async {
    final alerts = await widget.api.listAlerts(includeAcknowledged: _includeAcknowledged);
    final audit = await widget.api.listAuditLog(limit: 50);
    return _AlertData(alerts, audit);
  }

  void _refresh() => setState(() => _data = _load());

  Future<void> _acknowledge(int id) async {
    setState(() => _busy = true);
    try {
      await widget.api.acknowledgeAlert(id);
      if (mounted) {
        _showMessage('Alert acknowledged.');
        _refresh();
      }
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createAlert() async {
    final values = await showDialog<Map<String, String>>(context: context, builder: (context) => const _AlertDialog());
    if (values == null) return;
    setState(() => _busy = true);
    try {
      await widget.api.createAlert(severity: values['severity']!, message: values['message']!);
      if (mounted) {
        _showMessage('Alert created.');
        _refresh();
      }
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) => PageContainer(
        children: [
          SectionHeader(title: 'Alerts & activity', subtitle: 'Acknowledge operational signals and inspect the backend audit trail.', action: Row(mainAxisSize: MainAxisSize.min, children: [OutlinedButton.icon(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh, size: 18), label: const Text('Refresh')), const SizedBox(width: 10), ElevatedButton.icon(onPressed: _busy ? null : _createAlert, icon: const Icon(Icons.add_alert_outlined), label: const Text('Create alert'))])),
          const SizedBox(height: 24),
          FutureBuilder<_AlertData>(
            future: _data,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const LoadingState(label: 'Loading alerts…');
              if (snapshot.hasError) return ErrorState(message: snapshot.error.toString(), onRetry: _refresh);
              final data = snapshot.data;
              if (data == null) return ErrorState(message: 'The backend returned no alert data.', onRetry: _refresh);
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [_AlertsCard(alerts: data.alerts, includeAcknowledged: _includeAcknowledged, busy: _busy, onToggle: (value) { setState(() { _includeAcknowledged = value; _data = _load(); }); }, onAcknowledge: _acknowledge), const SizedBox(height: 20), _AuditCard(entries: data.audit)]);
            },
          ),
        ],
      );
}

class _AlertData {
  const _AlertData(this.alerts, this.audit);

  final List<Alert> alerts;
  final List<AuditLogEntry> audit;
}

class _AlertsCard extends StatelessWidget {
  const _AlertsCard({required this.alerts, required this.includeAcknowledged, required this.busy, required this.onToggle, required this.onAcknowledge});

  final List<Alert> alerts;
  final bool includeAcknowledged;
  final bool busy;
  final ValueChanged<bool> onToggle;
  final ValueChanged<int> onAcknowledge;

  @override
  Widget build(BuildContext context) => AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [const Expanded(child: SectionHeader(title: 'Operational alerts', subtitle: 'The list is loaded from /api/alerts.')), Row(children: [const Text('Include acknowledged', style: TextStyle(fontSize: 12, color: AppColors.slate)), const SizedBox(width: 4), Switch(value: includeAcknowledged, onChanged: onToggle)])]), const SizedBox(height: 16), if (alerts.isEmpty) const EmptyState(title: 'No alerts', message: 'The workspace has no alerts matching this view.', icon: Icons.notifications_none_rounded) else ...alerts.map((alert) => _AlertRow(alert: alert, busy: busy, onAcknowledge: onAcknowledge))]));
}

class _AlertRow extends StatelessWidget {
  const _AlertRow({required this.alert, required this.busy, required this.onAcknowledge});

  final Alert alert;
  final bool busy;
  final ValueChanged<int> onAcknowledge;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              alert.severity == 'critical' ? Icons.error_outline : Icons.info_outline,
              color: statusColor(alert.severity),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      StatusPill(label: alert.severity, color: statusColor(alert.severity)),
                      const SizedBox(width: 10),
                      Text(
                        formatDate(alert.createdAt),
                        style: const TextStyle(fontSize: 12, color: AppColors.slate),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(alert.message),
                ],
              ),
            ),
            if (!alert.acknowledged)
              TextButton(
                onPressed: busy ? null : () => onAcknowledge(alert.id),
                child: const Text('Acknowledge'),
              )
            else
              const Padding(
                padding: EdgeInsets.only(left: 8, top: 6),
                child: Icon(Icons.check_circle_outline, color: AppColors.mint, size: 20),
              ),
          ],
        ),
      );
}

class _AuditCard extends StatelessWidget {
  const _AuditCard({required this.entries});

  final List<AuditLogEntry> entries;

  @override
  Widget build(BuildContext context) => AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const SectionHeader(title: 'Recent audit log', subtitle: 'Immutable action records returned by the backend.'), const SizedBox(height: 16), if (entries.isEmpty) const EmptyState(title: 'No audit events', message: 'Backend actions will be listed here as the workspace is used.', icon: Icons.receipt_long_outlined) else ...entries.take(20).map((entry) => Padding(padding: const EdgeInsets.only(bottom: 12), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Icon(Icons.history, size: 18, color: AppColors.slate), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(entry.action, style: const TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 3), Text('${entry.actor} · ${formatDate(entry.createdAt)}', style: const TextStyle(fontSize: 12, color: AppColors.slate)), if (entry.details.isNotEmpty) Text(jsonEncode(entry.details), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12, color: AppColors.slate))]))])))]));
}

class _AlertDialog extends StatefulWidget {
  const _AlertDialog();

  @override
  State<_AlertDialog> createState() => _AlertDialogState();
}

class _AlertDialogState extends State<_AlertDialog> {
  final _message = TextEditingController();
  String _severity = 'info';

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(title: const Text('Create alert'), content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, children: [DropdownButtonFormField<String>(initialValue: _severity, decoration: const InputDecoration(labelText: 'Severity'), items: const [DropdownMenuItem(value: 'info', child: Text('Info')), DropdownMenuItem(value: 'warning', child: Text('Warning')), DropdownMenuItem(value: 'critical', child: Text('Critical'))], onChanged: (value) { if (value != null) setState(() => _severity = value); }), const SizedBox(height: 12), TextField(controller: _message, maxLines: 4, decoration: const InputDecoration(labelText: 'Message', alignLabelWithHint: true))])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), ElevatedButton(onPressed: () { if (_message.text.trim().isEmpty) return; Navigator.pop(context, {'severity': _severity, 'message': _message.text.trim()}); }, child: const Text('Create alert'))]);
}
