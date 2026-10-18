import 'package:flutter/material.dart';

import '../core/models/api_models.dart';
import '../core/services/api_client.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/design_system.dart';

class CampaignsScreen extends StatefulWidget {
  const CampaignsScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<CampaignsScreen> createState() => _CampaignsScreenState();
}

class _CampaignsScreenState extends State<CampaignsScreen> {
  late Future<_CampaignData> _data;
  final _subjectController = TextEditingController(text: 'A thoughtful idea for {{company}}');
  final _bodyController = TextEditingController(text: 'Hi {{first_name}},\n\nI noticed {{company}} is growing its team. We help teams like yours create more qualified conversations without adding manual research.\n\nWould a short conversation next week be useful?');
  final _leadIdsController = TextEditingController();
  final _providerController = TextEditingController(text: 'mock');
  int? _selectedCampaignId;
  OutreachPreview? _previewResult;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _data = _loadData();
  }

  @override
  void dispose() {
    _subjectController.dispose();
    _bodyController.dispose();
    _leadIdsController.dispose();
    _providerController.dispose();
    super.dispose();
  }

  Future<_CampaignData> _loadData() async {
    final campaigns = await widget.api.listCampaigns();
    final jobs = await widget.api.listJobs();
    return _CampaignData(campaigns, jobs);
  }

  void _refresh() => setState(() => _data = _loadData());

  List<int>? _leadIds() {
    final raw = _leadIdsController.text.trim();
    if (raw.isEmpty) return null;
    return raw.split(',').map((value) => int.tryParse(value.trim())).whereType<int>().toList();
  }

  Future<void> _createCampaign() async {
    final name = await showDialog<String>(context: context, builder: (context) => const _CreateCampaignDialog());
    if (name == null || name.trim().isEmpty) return;
    setState(() => _busy = true);
    try {
      final campaign = await widget.api.createCampaign(name: name.trim(), dryRun: true);
      if (!mounted) return;
      setState(() {
        _selectedCampaignId = campaign.id;
        _data = _loadData();
      });
      _showMessage('Campaign created in dry-run mode.');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview() async {
    final campaignId = _selectedCampaignId;
    if (campaignId == null) {
      _showMessage('Create or select a campaign first.');
      return;
    }
    if (_subjectController.text.trim().isEmpty || _bodyController.text.trim().isEmpty) {
      _showMessage('Subject and body are required.');
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await widget.api.previewOutreach(campaignId, subject: _subjectController.text.trim(), body: _bodyController.text, leadIds: _leadIds(), provider: _providerController.text.trim().isEmpty ? null : _providerController.text.trim());
      if (mounted) setState(() => _previewResult = result);
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _queueDryRun() async {
    final campaignId = _selectedCampaignId;
    if (campaignId == null) {
      _showMessage('Create or select a campaign first.');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.api.runOutreachDryRun(campaignId, subject: _subjectController.text.trim(), body: _bodyController.text, leadIds: _leadIds(), provider: _providerController.text.trim().isEmpty ? null : _providerController.text.trim());
      if (!mounted) return;
      _showMessage('Dry-run job queued.');
      _refresh();
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelJob(String id) async {
    setState(() => _busy = true);
    try {
      await widget.api.cancelJob(id);
      if (mounted) {
        _showMessage('Cancellation requested.');
        _refresh();
      }
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retryJob(String id) async {
    setState(() => _busy = true);
    try {
      await widget.api.retryJob(id);
      if (mounted) {
        _showMessage('Job retry queued.');
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
          SectionHeader(
            title: 'Campaigns & outreach',
            subtitle: 'Design, preview, and queue outreach without sending messages.',
            action: Row(mainAxisSize: MainAxisSize.min, children: [OutlinedButton.icon(onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh, size: 18), label: const Text('Refresh')), const SizedBox(width: 10), ElevatedButton.icon(onPressed: _busy ? null : _createCampaign, icon: const Icon(Icons.add), label: const Text('New campaign'))]),
          ),
          const SizedBox(height: 24),
          const SafetyBanner(title: 'Dry-run enforced in this workspace', message: 'Preview and queue actions send live=false to the backend. A provider is never contacted by these controls.'),
          const SizedBox(height: 20),
          FutureBuilder<_CampaignData>(
            future: _data,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const LoadingState(label: 'Loading campaigns and jobs…');
              if (snapshot.hasError) return ErrorState(message: snapshot.error.toString(), onRetry: _refresh);
              final data = snapshot.data;
              if (data == null) return ErrorState(message: 'The backend returned no campaign data.', onRetry: _refresh);
              final selected = _selectedCampaignId ?? (data.campaigns.isEmpty ? null : data.campaigns.first.id);
              if (_selectedCampaignId == null && selected != null) _selectedCampaignId = selected;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _CampaignList(campaigns: data.campaigns, selectedId: selected),
                  const SizedBox(height: 20),
                  _OutreachComposer(
                    campaigns: data.campaigns,
                    selectedId: selected,
                    subjectController: _subjectController,
                    bodyController: _bodyController,
                    leadIdsController: _leadIdsController,
                    providerController: _providerController,
                    preview: _previewResult,
                    busy: _busy,
                    onCampaignChanged: (id) => setState(() {
                      _selectedCampaignId = id;
                      _previewResult = null;
                    }),
                    onPreview: _preview,
                    onQueue: _queueDryRun,
                  ),
                  const SizedBox(height: 20),
                  _JobsCard(jobs: data.jobs, busy: _busy, onCancel: _cancelJob, onRetry: _retryJob),
                ],
              );
            },
          ),
        ],
      );
}

class _CampaignData {
  const _CampaignData(this.campaigns, this.jobs);

  final List<Campaign> campaigns;
  final List<Job> jobs;
}

class _CampaignList extends StatelessWidget {
  const _CampaignList({required this.campaigns, required this.selectedId});

  final List<Campaign> campaigns;
  final int? selectedId;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(title: 'Campaign library', subtitle: 'Campaign configuration and safety mode come from the backend.'),
            const SizedBox(height: 18),
            if (campaigns.isEmpty)
              const EmptyState(title: 'No campaigns yet', message: 'Create a campaign to start a dry-run outreach workflow.', icon: Icons.campaign_outlined)
            else
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: campaigns.map((campaign) => Container(
                      width: 260,
                      padding: const EdgeInsets.all(14),
                       decoration: BoxDecoration(color: campaign.id == selectedId ? AppColors.blueSoft : Theme.of(context).scaffoldBackgroundColor, borderRadius: BorderRadius.circular(12), border: Border.all(color: campaign.id == selectedId ? AppColors.blue.withValues(alpha: .35) : Theme.of(context).dividerColor)),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(campaign.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)), const SizedBox(height: 9), Row(children: [StatusPill(label: campaign.status, color: statusColor(campaign.status)), const Spacer(), const Icon(Icons.shield_outlined, size: 16, color: AppColors.mint), const SizedBox(width: 4), const Text('Dry run', style: TextStyle(fontSize: 12, color: AppColors.mint, fontWeight: FontWeight.w700))])]),
                    )).toList(),
              ),
          ],
        ),
      );
}

class _OutreachComposer extends StatelessWidget {
  const _OutreachComposer({required this.campaigns, required this.selectedId, required this.subjectController, required this.bodyController, required this.leadIdsController, required this.providerController, required this.preview, required this.busy, required this.onCampaignChanged, required this.onPreview, required this.onQueue});

  final List<Campaign> campaigns;
  final int? selectedId;
  final TextEditingController subjectController;
  final TextEditingController bodyController;
  final TextEditingController leadIdsController;
  final TextEditingController providerController;
  final OutreachPreview? preview;
  final bool busy;
  final ValueChanged<int?> onCampaignChanged;
  final VoidCallback onPreview;
  final VoidCallback onQueue;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SectionHeader(title: 'Outreach dry run', subtitle: 'Use placeholders such as {{first_name}} and {{company}}. Preview the rendered payload before queueing.'),
            const SizedBox(height: 18),
            if (campaigns.isEmpty)
              const EmptyState(title: 'Select a campaign to continue', message: 'The composer becomes available after a campaign is created.', icon: Icons.edit_note_outlined)
            else ...[
              DropdownButtonFormField<int>(initialValue: selectedId, decoration: const InputDecoration(labelText: 'Campaign'), items: campaigns.map((campaign) => DropdownMenuItem(value: campaign.id, child: Text(campaign.name))).toList(), onChanged: onCampaignChanged),
              const SizedBox(height: 12),
              Row(children: [Expanded(child: TextField(controller: subjectController, decoration: const InputDecoration(labelText: 'Subject'))), const SizedBox(width: 12), SizedBox(width: 180, child: TextField(controller: providerController, decoration: const InputDecoration(labelText: 'Provider')))]),
              const SizedBox(height: 12),
              TextField(controller: bodyController, minLines: 7, maxLines: 12, decoration: const InputDecoration(labelText: 'Body template', alignLabelWithHint: true)),
              const SizedBox(height: 12),
              TextField(controller: leadIdsController, decoration: const InputDecoration(labelText: 'Lead IDs (optional)', hintText: 'e.g. 1, 2, 3 — blank uses the backend audience')),
              const SizedBox(height: 16),
              Row(children: [OutlinedButton.icon(onPressed: busy ? null : onPreview, icon: const Icon(Icons.visibility_outlined), label: const Text('Preview safely')), const SizedBox(width: 10), ElevatedButton.icon(onPressed: busy ? null : onQueue, icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.play_arrow_rounded), label: const Text('Queue dry run'))]),
              if (preview != null) ...[const SizedBox(height: 22), const Divider(), const SizedBox(height: 18), _PreviewResult(preview: preview!)],
            ],
          ],
        ),
      );
}

class _PreviewResult extends StatelessWidget {
  const _PreviewResult({required this.preview});

  final OutreachPreview preview;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [const Icon(Icons.shield_outlined, size: 19, color: AppColors.mint), const SizedBox(width: 8), Text('Preview returned ${preview.items.length} message${preview.items.length == 1 ? '' : 's'}', style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.mint))]), const SizedBox(height: 12), if (preview.items.isEmpty) const Text('No eligible leads were returned by the backend.', style: TextStyle(color: AppColors.slate)) else ...preview.items.take(8).map((item) => Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, borderRadius: BorderRadius.circular(10)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [Expanded(child: Text(item.email, style: const TextStyle(fontWeight: FontWeight.w700))), if (item.suppressed) const StatusPill(label: 'Suppressed', color: AppColors.red)]), const SizedBox(height: 5), Text(item.subject, style: const TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 4), Text(item.body, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.slate))]))), if (preview.items.length > 8) Text('Showing 8 of ${preview.items.length} preview messages.', style: const TextStyle(color: AppColors.slate, fontSize: 12))]);
}

class _JobsCard extends StatelessWidget {
  const _JobsCard({required this.jobs, required this.busy, required this.onCancel, required this.onRetry});

  final List<Job> jobs;
  final bool busy;
  final ValueChanged<String> onCancel;
  final ValueChanged<String> onRetry;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const SectionHeader(title: 'Outreach jobs', subtitle: 'Progress and cancellation are backed by the job queue.'), const SizedBox(height: 18), if (jobs.isEmpty) const EmptyState(title: 'No outreach jobs', message: 'Queued dry runs will show progress here.', icon: Icons.work_history_outlined) else ...jobs.map((job) => Padding(padding: const EdgeInsets.only(bottom: 16), child: Column(children: [Row(children: [StatusPill(label: job.status, color: statusColor(job.status)), const SizedBox(width: 10), Expanded(child: Text(job.id, style: const TextStyle(fontWeight: FontWeight.w700))), Text('${job.progress}%'), const SizedBox(width: 12), if (job.canCancel) TextButton(onPressed: busy ? null : () => onCancel(job.id), child: const Text('Cancel')) else if (job.status == 'failed') TextButton(onPressed: busy ? null : () => onRetry(job.id), child: const Text('Retry'))]), const SizedBox(height: 8), LinearProgressIndicator(value: job.progress.clamp(0, 100).toDouble() / 100), if (job.error != null) Padding(padding: const EdgeInsets.only(top: 6), child: Align(alignment: Alignment.centerLeft, child: Text(job.error!, style: const TextStyle(color: AppColors.red, fontSize: 12))))])))]),
      );
}

class _CreateCampaignDialog extends StatefulWidget {
  const _CreateCampaignDialog();

  @override
  State<_CreateCampaignDialog> createState() => _CreateCampaignDialogState();
}

class _CreateCampaignDialogState extends State<_CreateCampaignDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(title: const Text('New dry-run campaign'), content: SizedBox(width: 420, child: TextField(controller: _controller, autofocus: true, decoration: const InputDecoration(labelText: 'Campaign name'))), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), ElevatedButton(onPressed: () => Navigator.pop(context, _controller.text), child: const Text('Create'))]);
}
