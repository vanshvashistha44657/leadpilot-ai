import 'package:flutter/material.dart';

import '../core/models/api_models.dart';
import '../core/services/api_client.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/design_system.dart';

class DraftsScreen extends StatefulWidget {
  const DraftsScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<DraftsScreen> createState() => _DraftsScreenState();
}

class _DraftsScreenState extends State<DraftsScreen> {
  late Future<_DraftQueueData> _data;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _data = _loadData();
  }

  Future<_DraftQueueData> _loadData() async {
    final results = await Future.wait([
      widget.api.listDrafts(),
      widget.api.listLeads(),
    ]);
    final drafts = results[0] as List<PersonalizedDraft>;
    final leads = results[1] as List<Lead>;
    return _DraftQueueData(
        drafts: drafts, leadsById: {for (final lead in leads) lead.id: lead});
  }

  void _refresh() => setState(() => _data = _loadData());

  Future<void> _editDraft(PersonalizedDraft draft) async {
    final edited = await showDialog<_DraftEdits>(
      context: context,
      builder: (context) => _DraftEditorDialog(draft: draft),
    );
    if (edited == null) return;

    setState(() => _busy = true);
    try {
      await widget.api
          .updateDraft(draft.id, subject: edited.subject, body: edited.body);
      if (!mounted) return;
      _showMessage('Draft saved as edited. It was not sent.');
      _refresh();
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _regenerateDraft(PersonalizedDraft draft) async {
    setState(() => _busy = true);
    try {
      await widget.api.generateDraft(
        leadId: draft.leadId,
        offer: draft.offer,
        tone: draft.tone,
        callToAction: draft.callToAction,
        regenerate: true,
      );
      if (!mounted) return;
      _showMessage('Draft regenerated for review. It was not sent.');
      _refresh();
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
            title: 'Draft review',
            subtitle:
                'Review personalized outreach before any later dry-run workflow.',
            action: OutlinedButton.icon(
              onPressed: _busy ? null : _refresh,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Refresh'),
            ),
          ),
          const SizedBox(height: 24),
          const SafetyBanner(
            title: 'Draft review only',
            message:
                'Edit, save, and regenerate personalized content here. This workflow never sends or schedules email.',
          ),
          const SizedBox(height: 20),
          FutureBuilder<_DraftQueueData>(
            future: _data,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const LoadingState(label: 'Loading draft review queue…');
              }
              if (snapshot.hasError) {
                return ErrorState(
                    message: snapshot.error.toString(), onRetry: _refresh);
              }
              final data = snapshot.data;
              if (data == null) {
                return ErrorState(
                    message: 'The backend returned no draft data.',
                    onRetry: _refresh);
              }
              return _DraftQueue(
                data: data,
                busy: _busy,
                onEdit: _editDraft,
                onRegenerate: _regenerateDraft,
              );
            },
          ),
        ],
      );
}

class _DraftQueueData {
  const _DraftQueueData({required this.drafts, required this.leadsById});

  final List<PersonalizedDraft> drafts;
  final Map<int, Lead> leadsById;
}

class _DraftQueue extends StatelessWidget {
  const _DraftQueue(
      {required this.data,
      required this.busy,
      required this.onEdit,
      required this.onRegenerate});

  final _DraftQueueData data;
  final bool busy;
  final ValueChanged<PersonalizedDraft> onEdit;
  final ValueChanged<PersonalizedDraft> onRegenerate;

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    for (final draft in data.drafts) {
      counts.update(draft.status, (value) => value + 1, ifAbsent: () => 1);
    }

    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionHeader(
                  title:
                      '${data.drafts.length} personalized draft${data.drafts.length == 1 ? '' : 's'}',
                  subtitle:
                      'Generated content stays editable until you are satisfied with the review.',
                ),
                if (counts.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: counts.entries
                        .map((entry) => StatusPill(
                            label: '${entry.key}: ${entry.value}',
                            color: statusColor(entry.key)))
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          if (data.drafts.isEmpty)
            const EmptyState(
              title: 'No drafts to review',
              message:
                  'Generate a personalized draft from a lead to start this review queue.',
              icon: Icons.rate_review_outlined,
            )
          else
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  for (var index = 0; index < data.drafts.length; index++) ...[
                    _DraftQueueItem(
                      draft: data.drafts[index],
                      lead: data.leadsById[data.drafts[index].leadId],
                      busy: busy,
                      onEdit: onEdit,
                      onRegenerate: onRegenerate,
                    ),
                    if (index < data.drafts.length - 1)
                      const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _DraftQueueItem extends StatelessWidget {
  const _DraftQueueItem(
      {required this.draft,
      required this.lead,
      required this.busy,
      required this.onEdit,
      required this.onRegenerate});

  final PersonalizedDraft draft;
  final Lead? lead;
  final bool busy;
  final ValueChanged<PersonalizedDraft> onEdit;
  final ValueChanged<PersonalizedDraft> onRegenerate;

  String get _leadName {
    if (lead == null) return 'Lead #${draft.leadId}';
    if (lead!.displayName.isNotEmpty) return lead!.displayName;
    if (lead!.company?.trim().isNotEmpty == true) return lead!.company!;
    return lead!.email;
  }

  String get _leadDetail {
    if (lead == null) return 'Lead identity unavailable';
    final parts = <String>[lead!.email];
    if (lead!.company?.trim().isNotEmpty == true &&
        lead!.company != _leadName) {
      parts.add(lead!.company!);
    }
    if (lead!.title?.trim().isNotEmpty == true) parts.add(lead!.title!);
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Theme.of(context).dividerColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_leadName,
                          style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      Text(_leadDetail,
                          style: const TextStyle(color: AppColors.slate),
                          overflow: TextOverflow.ellipsis),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                StatusPill(
                    label: draft.status, color: statusColor(draft.status)),
              ],
            ),
            const SizedBox(height: 16),
            Text(draft.subject.isEmpty ? '(No subject)' : draft.subject,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(
              draft.body.isEmpty ? '(No body content)' : draft.body,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.slate, height: 1.4),
            ),
            if (draft.status.toLowerCase() == 'failed' &&
                draft.error?.trim().isNotEmpty == true) ...[
              const SizedBox(height: 10),
              Text('Generation failed: ${draft.error}',
                  style: const TextStyle(color: AppColors.red)),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: busy ? null : () => onEdit(draft),
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  label: const Text('Edit draft'),
                ),
                const SizedBox(width: 10),
                TextButton.icon(
                  onPressed: busy ? null : () => onRegenerate(draft),
                  icon: const Icon(Icons.autorenew_rounded, size: 18),
                  label: const Text('Regenerate'),
                ),
                const Spacer(),
                if (draft.updatedAt != null)
                  Text('Updated ${formatDate(draft.updatedAt)}',
                      style: const TextStyle(
                          color: AppColors.slate, fontSize: 12)),
              ],
            ),
          ],
        ),
      );
}

class _DraftEdits {
  const _DraftEdits({required this.subject, required this.body});

  final String subject;
  final String body;
}

class _DraftEditorDialog extends StatefulWidget {
  const _DraftEditorDialog({required this.draft});

  final PersonalizedDraft draft;

  @override
  State<_DraftEditorDialog> createState() => _DraftEditorDialogState();
}

class _DraftEditorDialogState extends State<_DraftEditorDialog> {
  late final TextEditingController _subject =
      TextEditingController(text: widget.draft.subject);
  late final TextEditingController _body =
      TextEditingController(text: widget.draft.body);

  @override
  void dispose() {
    _subject.dispose();
    _body.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Edit personalized draft'),
        content: SizedBox(
          width: 650,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                    'Changes are saved to the review queue only. This phase never sends email.',
                    style: TextStyle(color: AppColors.slate)),
                const SizedBox(height: 14),
                TextField(
                    controller: _subject,
                    decoration: const InputDecoration(labelText: 'Subject')),
                const SizedBox(height: 12),
                TextField(
                    controller: _body,
                    minLines: 8,
                    maxLines: 14,
                    decoration: const InputDecoration(
                        labelText: 'Body', alignLabelWithHint: true)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(
                context,
                _DraftEdits(
                    subject: _subject.text.trim(), body: _body.text.trim())),
            child: const Text('Save draft'),
          ),
        ],
      );
}
