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
  bool _gmailConnected = false;
  final Map<String, GmailReviewedDraft> _gmailDrafts = {};

  @override
  void initState() {
    super.initState();
    _data = _loadData();
  }

  Future<_DraftQueueData> _loadData() async {
    final drafts = await widget.api.listDrafts();
    final leads = await widget.api.listLeads();
    GmailStatus? gmailStatus;
    GmailHealth? gmailHealth;
    String? gmailError;
    try {
      gmailStatus = await widget.api.getGmailStatus();
      if (gmailStatus.configured) {
        try {
          gmailHealth = await widget.api.getGmailHealth();
        } catch (_) {
          gmailError = 'Gmail verification is unavailable.';
        }
      }
    } catch (_) {
      gmailError = 'Gmail connection status is unavailable.';
    }
    return _DraftQueueData(
      drafts: drafts,
      leadsById: {for (final lead in leads) lead.id: lead},
      gmailStatus: gmailStatus,
      gmailHealth: gmailHealth,
      gmailError: gmailError,
    );
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

  Future<void> _createGmailDraft(PersonalizedDraft draft, Lead? lead) async {
    if (!_canCreateGmailDraft(draft, lead)) return;
    setState(() => _busy = true);
    try {
      final alreadyHadResult = _gmailDrafts.containsKey(draft.id);
      final result = await widget.api.createGmailDraft(draft.id);
      if (!mounted) return;
      setState(() => _gmailDrafts[draft.id] = result);
      if (alreadyHadResult) {
        _showMessage('Gmail draft already exists. No duplicate was created.');
      } else {
        _showMessage('Gmail draft created. It is a draft and was not sent.');
      }
    } catch (error) {
      if (!mounted) return;
      if (error is ApiException && error.statusCode == 409) {
        _showMessage(
            'Gmail draft creation is already pending or was already handled. The review queue was kept.');
      } else {
        _showMessage('Gmail draft creation failed. The review queue was kept.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _canCreateGmailDraft(PersonalizedDraft draft, Lead? lead) {
    final status = draft.status.toLowerCase();
    final leadStatus = lead?.status.toLowerCase();
    return _dataReadyForGmail &&
        (status == 'generated' || status == 'edited') &&
        lead != null &&
        lead.email.trim().isNotEmpty &&
        draft.subject.trim().isNotEmpty &&
        draft.body.trim().isNotEmpty &&
        leadStatus != 'suppressed' &&
        leadStatus != 'unsubscribed' &&
        leadStatus != 'replied' &&
        leadStatus != 'bounced' &&
        !_gmailDrafts.containsKey(draft.id);
  }

  bool get _dataReadyForGmail {
    return _gmailConnected;
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
              _gmailConnected = data.gmailConnected;
              return _DraftQueue(
                data: data,
                busy: _busy,
                gmailDrafts: _gmailDrafts,
                onEdit: _editDraft,
                onRegenerate: _regenerateDraft,
                onCreateGmailDraft: _createGmailDraft,
              );
            },
          ),
        ],
      );
}

class _DraftQueueData {
  const _DraftQueueData(
      {required this.drafts,
      required this.leadsById,
      this.gmailStatus,
      this.gmailHealth,
      this.gmailError});

  final List<PersonalizedDraft> drafts;
  final Map<int, Lead> leadsById;
  final GmailStatus? gmailStatus;
  final GmailHealth? gmailHealth;
  final String? gmailError;

  bool get gmailConnected =>
      gmailStatus?.configured == true && gmailHealth?.isHealthy == true;
}

class _DraftQueue extends StatelessWidget {
  const _DraftQueue(
      {required this.data,
      required this.busy,
      required this.gmailDrafts,
      required this.onEdit,
      required this.onRegenerate,
      required this.onCreateGmailDraft});

  final _DraftQueueData data;
  final bool busy;
  final Map<String, GmailReviewedDraft> gmailDrafts;
  final ValueChanged<PersonalizedDraft> onEdit;
  final ValueChanged<PersonalizedDraft> onRegenerate;
  final void Function(PersonalizedDraft draft, Lead? lead) onCreateGmailDraft;

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
                const SizedBox(height: 14),
                _GmailDraftReadiness(data: data),
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
                      gmailConnected: data.gmailConnected,
                      gmailDraft: gmailDrafts[data.drafts[index].id],
                      onEdit: onEdit,
                      onRegenerate: onRegenerate,
                      onCreateGmailDraft: onCreateGmailDraft,
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

class _GmailDraftReadiness extends StatelessWidget {
  const _GmailDraftReadiness({required this.data});

  final _DraftQueueData data;

  @override
  Widget build(BuildContext context) {
    if (data.gmailError != null) {
      return const SafetyBanner(
        title: 'Gmail verification unavailable',
        message:
            'Verify Gmail in Settings before creating a Gmail draft. Local review remains available.',
        safe: false,
      );
    }
    if (!data.gmailConnected) {
      return const SafetyBanner(
        title: 'Gmail is not verified',
        message:
            'Create Gmail Draft stays disabled until Gmail is connected and its health check succeeds.',
        safe: false,
      );
    }
    final account = data.gmailHealth?.senderIdentity?.emailAddress ??
        data.gmailStatus?.senderEmail;
    return SafetyBanner(
      title: 'Gmail verified · draft-only',
      message: account == null || account.isEmpty
          ? 'Reviewed drafts can be copied to Gmail as drafts. Nothing is sent.'
          : 'Account $account is verified. Reviewed drafts create Gmail drafts only; nothing is sent.',
    );
  }
}

class _DraftQueueItem extends StatelessWidget {
  const _DraftQueueItem(
      {required this.draft,
      required this.lead,
      required this.busy,
      required this.gmailConnected,
      required this.gmailDraft,
      required this.onEdit,
      required this.onRegenerate,
      required this.onCreateGmailDraft});

  final PersonalizedDraft draft;
  final Lead? lead;
  final bool busy;
  final bool gmailConnected;
  final GmailReviewedDraft? gmailDraft;
  final ValueChanged<PersonalizedDraft> onEdit;
  final ValueChanged<PersonalizedDraft> onRegenerate;
  final void Function(PersonalizedDraft draft, Lead? lead) onCreateGmailDraft;

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

  bool get _eligible {
    final leadStatus = lead?.status.toLowerCase();
    final draftStatus = draft.status.toLowerCase();
    return gmailConnected &&
        gmailDraft == null &&
        (draftStatus == 'generated' || draftStatus == 'edited') &&
        lead != null &&
        lead!.email.trim().isNotEmpty &&
        draft.subject.trim().isNotEmpty &&
        draft.body.trim().isNotEmpty &&
        leadStatus != 'suppressed' &&
        leadStatus != 'unsubscribed' &&
        leadStatus != 'replied' &&
        leadStatus != 'bounced';
  }

  String get _gmailActionHint {
    if (gmailDraft != null) {
      return 'Already created in Gmail. This is a draft and was not sent.';
    }
    if (!gmailConnected) return 'Verify Gmail in Settings first.';
    if (lead == null || lead!.email.trim().isEmpty) {
      return 'A known lead email is required.';
    }
    if (draft.status != 'generated' && draft.status != 'edited') {
      return 'Only a reviewed generated or edited draft can be created.';
    }
    if (draft.subject.trim().isEmpty || draft.body.trim().isEmpty) {
      return 'Add a nonempty subject and body before creating the Gmail draft.';
    }
    if (['suppressed', 'unsubscribed', 'replied', 'bounced']
        .contains(lead!.status.toLowerCase())) {
      return 'This lead is blocked from outreach.';
    }
    return 'Create a Gmail draft only. No send action is available.';
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
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: busy || !_eligible
                    ? null
                    : () => onCreateGmailDraft(draft, lead),
                icon: busy && _eligible
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.mark_email_unread_outlined, size: 18),
                label: Text(gmailDraft == null
                    ? 'Create Gmail Draft'
                    : 'Gmail draft created'),
              ),
            ),
            const SizedBox(height: 6),
            Text(_gmailActionHint,
                style: const TextStyle(color: AppColors.slate, fontSize: 12)),
            if (gmailDraft != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                    color: AppColors.mintSoft,
                    borderRadius: BorderRadius.circular(10)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Gmail draft · not sent',
                          style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: AppColors.mint)),
                      if (gmailDraft!.providerDraftId?.isNotEmpty == true)
                        Text('Draft ID: ${gmailDraft!.providerDraftId}',
                            style: const TextStyle(fontSize: 12)),
                      if (gmailDraft!.providerThreadId?.isNotEmpty == true)
                        Text('Thread ID: ${gmailDraft!.providerThreadId}',
                            style: const TextStyle(fontSize: 12)),
                    ]),
              ),
            ],
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
