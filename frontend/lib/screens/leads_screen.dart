import 'dart:async';

import 'package:flutter/material.dart';

import '../core/models/api_models.dart';
import '../core/services/api_client.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/design_system.dart';

class LeadsScreen extends StatefulWidget {
  const LeadsScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<LeadsScreen> createState() => _LeadsScreenState();
}

class _LeadsScreenState extends State<LeadsScreen> {
  late Future<_LeadPage> _leads;
  final _searchController = TextEditingController();
  final _csvPathController = TextEditingController();
  String _search = '';
  int _page = 0;
  int _pageSize = 25;
  bool _busy = false;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _leads = _loadPage();
    _searchController.addListener(() {
      if (_searchController.text == _search) return;
      _searchDebounce?.cancel();
      _searchDebounce = Timer(const Duration(milliseconds: 250), () {
        if (!mounted) return;
        setState(() {
          _search = _searchController.text.trim();
          _page = 0;
          _leads = _loadPage();
        });
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _csvPathController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<_LeadPage> _loadPage() async {
    final results = await Future.wait([
      widget.api.listLeads(limit: _pageSize, offset: _page * _pageSize, search: _search),
      widget.api.countLeads(search: _search),
    ]);
    return _LeadPage(results[0] as List<Lead>, results[1] as int);
  }

  void _refresh() => setState(() => _leads = _loadPage());

  Future<void> _importCsv() async {
    final path = _csvPathController.text.trim();
    if (path.isEmpty) {
       _showMessage('Enter a local CSV or XLSX path first.');
      return;
    }
    setState(() => _busy = true);
    try {
      final preview = await widget.api.previewLeadImport(path);
      if (!mounted) return;
      final mapping = await showDialog<JsonMap>(context: context, builder: (context) => _ImportPreviewDialog(preview: preview));
      if (mapping == null) return;
      final job = await widget.api.queueImportLeads(path, mapping: mapping);
      if (!mounted) return;
      _showMessage('Import queued as ${job.id.substring(0, 8)}. Check the dashboard job activity for progress.');
      _csvPathController.clear();
      _refresh();
      _watchImport(job.id);
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _draftLead(Lead lead) async {
    final values = await showDialog<JsonMap>(context: context, builder: (context) => const _DraftOptionsDialog());
    if (values == null) return;
    setState(() => _busy = true);
    try {
      final draft = await widget.api.generateDraft(leadId: lead.id, offer: values['offer'] as String, tone: values['tone'] as String, callToAction: values['call_to_action'] as String);
      if (!mounted) return;
      final edited = await showDialog<JsonMap>(context: context, builder: (context) => _DraftEditorDialog(draft: draft));
      if (edited != null) {
        await widget.api.updateDraft(draft.id, subject: edited['subject'] as String, body: edited['body'] as String);
        if (mounted) _showMessage('Draft saved as user-edited. It was not sent.');
      }
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _watchImport(String jobId) async {
    for (var attempt = 0; attempt < 120; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      try {
        final job = await widget.api.getJob(jobId);
        if (job.status == 'completed' || job.status == 'failed' || job.status == 'cancelled') {
          if (!mounted) return;
          if (job.status == 'completed') {
            final imported = job.result?['imported'] ?? 0;
            final duplicates = job.result?['duplicates'] ?? 0;
            _showMessage('Import complete: $imported imported, $duplicates duplicates.');
            _refresh();
          } else {
            _showMessage('Import ${job.status}: ${job.error ?? 'check job details'}');
          }
          return;
        }
      } catch (_) {
        // The screen remains usable; the job can still be inspected from the
        // dashboard after a transient connection failure.
        return;
      }
    }
  }

  Future<void> _addLead() async {
    final values = await showDialog<JsonMap>(context: context, builder: (context) => const _AddLeadDialog());
    if (values == null) return;
    setState(() => _busy = true);
    try {
      await widget.api.createLead(
        email: values['email'] as String,
        firstName: values['first_name'] as String?,
        lastName: values['last_name'] as String?,
        company: values['company'] as String?,
        title: values['title'] as String?,
        source: values['source'] as String?,
      );
      if (!mounted) return;
      _showMessage('Lead created.');
      _refresh();
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewLead(Lead lead) async {
    final values = await showDialog<JsonMap>(context: context, builder: (context) => _ResearchDialog(lead: lead));
    if (values == null) return;
    setState(() => _busy = true);
    try {
      final research = await widget.api.reviewLead(lead.id, websiteUrl: values['website_url'] as String?, verifiedNotes: values['verified_notes'] as String?);
      if (mounted) {
        _showMessage('Research saved with opportunity score ${research.opportunityScore}/100.');
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
            title: 'Leads & import',
            subtitle: 'Keep the audience clean, searchable, and suppression-aware.',
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(onPressed: _busy ? null : _addLead, icon: const Icon(Icons.person_add_alt_1_outlined, size: 18), label: const Text('Add lead')),
                const SizedBox(width: 10),
                IconButton(tooltip: 'Refresh leads', onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh)),
              ],
            ),
          ),
          const SizedBox(height: 24),
          AppCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                 const SectionHeader(title: 'Import CSV or XLSX', subtitle: 'The backend validates, normalizes, deduplicates, and checks suppressions in bounded batches.'),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _csvPathController,
                         decoration: const InputDecoration(prefixIcon: Icon(Icons.file_upload_outlined), labelText: 'Local CSV or XLSX path', hintText: r'C:\data\leads.xlsx'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton.icon(onPressed: _busy ? null : _importCsv, icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.upload_file_outlined), label: const Text('Import')),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          FutureBuilder<_LeadPage>(
            future: _leads,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const LoadingState(label: 'Loading leads…');
              if (snapshot.hasError) return ErrorState(message: snapshot.error.toString(), onRetry: _refresh);
              final data = snapshot.data ?? const _LeadPage([], 0);
               return _LeadTable(leads: data.leads, total: data.total, page: _page, pageSize: _pageSize, searchController: _searchController, onReview: _reviewLead, onDraft: _draftLead, onPageChanged: (page) => setState(() { _page = page; _leads = _loadPage(); }), onPageSizeChanged: (size) => setState(() { _pageSize = size; _page = 0; _leads = _loadPage(); }));
            },
          ),
        ],
      );
}

class _LeadPage {
  const _LeadPage(this.leads, this.total);

  final List<Lead> leads;
  final int total;
}

class _LeadTable extends StatelessWidget {
  const _LeadTable({required this.leads, required this.total, required this.page, required this.pageSize, required this.searchController, required this.onReview, required this.onDraft, required this.onPageChanged, required this.onPageSizeChanged});

  final List<Lead> leads;
  final int total;
  final int page;
  final int pageSize;
  final TextEditingController searchController;
  final ValueChanged<Lead> onReview;
  final ValueChanged<Lead> onDraft;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<int> onPageSizeChanged;

  @override
  Widget build(BuildContext context) {
    final pageCount = total == 0 ? 1 : (total / pageSize).ceil();
    final safePage = page.clamp(0, pageCount - 1).toInt();
    final visible = leads;
    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Row(
              children: [
                 Expanded(child: Text('$total matching leads', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800))),
                SizedBox(width: 260, child: TextField(controller: searchController, decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.search, size: 19), hintText: 'Search leads'))),
              ],
            ),
          ),
          const Divider(height: 1),
          if (visible.isEmpty)
            const EmptyState(title: 'No leads found', message: 'Try a different search or import a CSV to build the lead pool.', icon: Icons.people_outline)
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columnSpacing: 28,
                horizontalMargin: 20,
                columns: const [
                  DataColumn(label: Text('ID')),
                  DataColumn(label: Text('Contact')),
                  DataColumn(label: Text('Company')),
                  DataColumn(label: Text('Title')),
                   DataColumn(label: Text('Status')),
                   DataColumn(label: Text('Opportunity')),
                   DataColumn(label: Text('Source')),
                   DataColumn(label: Text('Draft')),
                ],
                rows: visible.map((lead) => DataRow(onSelectChanged: (_) => onReview(lead), cells: [
                      DataCell(Text('${lead.id}')),
                      DataCell(Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [if (lead.displayName.isNotEmpty) Text(lead.displayName, style: const TextStyle(fontWeight: FontWeight.w700)), Text(lead.email, style: const TextStyle(color: AppColors.slate))])),
                      DataCell(Text(lead.company?.isNotEmpty == true ? lead.company! : '—')),
                      DataCell(Text(lead.title?.isNotEmpty == true ? lead.title! : '—')),
                       DataCell(StatusPill(label: lead.status, color: statusColor(lead.status))),
                       DataCell(Text(lead.researchStatus == 'unresearched' ? '—' : '${lead.opportunityScore}/100')),
                       DataCell(Text(lead.source?.isNotEmpty == true ? lead.source! : '—')),
                       DataCell(IconButton(tooltip: 'Generate draft', onPressed: lead.status == 'suppressed' || lead.status == 'unsubscribed' || lead.status == 'replied' || lead.status == 'bounced' ? null : () => onDraft(lead), icon: const Icon(Icons.auto_awesome_outlined))),
                    ])).toList(),
              ),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Row(
              children: [
                Text('Page ${safePage + 1} of $pageCount', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.slate)),
                const Spacer(),
                const Text('Rows', style: TextStyle(color: AppColors.slate, fontSize: 12)),
                const SizedBox(width: 8),
                DropdownButton<int>(value: pageSize, underline: const SizedBox.shrink(), items: const [25, 50, 100].map((size) => DropdownMenuItem(value: size, child: Text('$size'))).toList(), onChanged: (value) { if (value != null) onPageSizeChanged(value); }),
                const SizedBox(width: 10),
                IconButton(onPressed: safePage > 0 ? () => onPageChanged(safePage - 1) : null, icon: const Icon(Icons.chevron_left)),
                IconButton(onPressed: safePage < pageCount - 1 ? () => onPageChanged(safePage + 1) : null, icon: const Icon(Icons.chevron_right)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ImportPreviewDialog extends StatefulWidget {
  const _ImportPreviewDialog({required this.preview});

  final ImportPreview preview;

  @override
  State<_ImportPreviewDialog> createState() => _ImportPreviewDialogState();
}

class _ImportPreviewDialogState extends State<_ImportPreviewDialog> {
  late final Map<String, String> _mapping = {for (final entry in widget.preview.suggestedMapping.entries) entry.key: entry.value};

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Preview ${widget.preview.filename}'),
        content: SizedBox(
          width: 760,
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${widget.preview.rowCount} rows detected · ${widget.preview.columns.length} columns'),
              const SizedBox(height: 12),
              if (widget.preview.errors.isNotEmpty) Text(widget.preview.errors.join(' · '), style: const TextStyle(color: AppColors.red)),
              const Text('Column mapping', style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              ...widget.preview.columns.map((column) => Row(children: [Expanded(child: Text(column)), const SizedBox(width: 12), Expanded(child: DropdownButton<String>(isExpanded: true, value: _mapping[column] == null || const ['email', 'first_name', 'last_name', 'company', 'title', 'source'].contains(_mapping[column]) == false ? 'ignore' : _mapping[column], items: const [DropdownMenuItem(value: 'ignore', child: Text('Ignore')), DropdownMenuItem(value: 'email', child: Text('Email')), DropdownMenuItem(value: 'first_name', child: Text('First name')), DropdownMenuItem(value: 'last_name', child: Text('Last name')), DropdownMenuItem(value: 'company', child: Text('Company')), DropdownMenuItem(value: 'title', child: Text('Title')), DropdownMenuItem(value: 'source', child: Text('Source'))], onChanged: (value) => setState(() => _mapping[column] = value ?? 'ignore')))])),
              const SizedBox(height: 12),
              const Text('Sample rows are shown for mapping only; the backend revalidates the full upload.', style: TextStyle(color: AppColors.slate, fontSize: 12)),
            ]),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), ElevatedButton(onPressed: widget.preview.limitExceeded || widget.preview.errors.isNotEmpty ? null : () => Navigator.pop(context, {for (final entry in _mapping.entries) if (entry.value != 'ignore') entry.key: entry.value}), child: const Text('Queue import'))],
      );
}

class _DraftOptionsDialog extends StatefulWidget {
  const _DraftOptionsDialog();

  @override
  State<_DraftOptionsDialog> createState() => _DraftOptionsDialogState();
}

class _DraftOptionsDialogState extends State<_DraftOptionsDialog> {
  final _offer = TextEditingController();
  final _tone = TextEditingController(text: 'professional');
  final _cta = TextEditingController(text: 'Reply if this is useful.');

  @override
  void dispose() { _offer.dispose(); _tone.dispose(); _cta.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AlertDialog(title: const Text('Draft outreach'), content: SizedBox(width: 500, child: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: _offer, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Offer / service brief *')), const SizedBox(height: 12), TextField(controller: _tone, decoration: const InputDecoration(labelText: 'Tone')), const SizedBox(height: 12), TextField(controller: _cta, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Call to action *'))])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), ElevatedButton(onPressed: _offer.text.trim().isEmpty || _cta.text.trim().isEmpty ? null : () => Navigator.pop(context, {'offer': _offer.text.trim(), 'tone': _tone.text.trim(), 'call_to_action': _cta.text.trim()}), child: const Text('Generate draft'))]);
}

class _DraftEditorDialog extends StatefulWidget {
  const _DraftEditorDialog({required this.draft});

  final PersonalizedDraft draft;

  @override
  State<_DraftEditorDialog> createState() => _DraftEditorDialogState();
}

class _DraftEditorDialogState extends State<_DraftEditorDialog> {
  late final _subject = TextEditingController(text: widget.draft.subject);
  late final _body = TextEditingController(text: widget.draft.body);

  @override
  void dispose() { _subject.dispose(); _body.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AlertDialog(title: const Text('Review personalized draft'), content: SizedBox(width: 600, child: Column(mainAxisSize: MainAxisSize.min, children: [const Text('AI-generated content is editable. This phase never sends or schedules email.', style: TextStyle(color: AppColors.slate)), const SizedBox(height: 12), TextField(controller: _subject, decoration: const InputDecoration(labelText: 'Subject')), const SizedBox(height: 12), TextField(controller: _body, minLines: 8, maxLines: 14, decoration: const InputDecoration(labelText: 'Body', alignLabelWithHint: true))])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Discard')), ElevatedButton(onPressed: () => Navigator.pop(context, {'subject': _subject.text.trim(), 'body': _body.text.trim()}), child: const Text('Save edited draft'))]);
}

class _ResearchDialog extends StatefulWidget {
  const _ResearchDialog({required this.lead});

  final Lead lead;

  @override
  State<_ResearchDialog> createState() => _ResearchDialogState();
}

class _ResearchDialogState extends State<_ResearchDialog> {
  late final TextEditingController _website = TextEditingController(text: widget.lead.websiteUrl ?? '');
  late final TextEditingController _notes = TextEditingController(text: widget.lead.researchNotes ?? '');

  @override
  void dispose() {
    _website.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('Review ${widget.lead.company?.isNotEmpty == true ? widget.lead.company : widget.lead.email}'),
        content: SizedBox(width: 500, child: Column(mainAxisSize: MainAxisSize.min, children: [const Text('Only enter facts you verified from an authorized source. LeadPilot does not invent website findings.', style: TextStyle(color: Colors.blueGrey)), const SizedBox(height: 14), TextField(controller: _website, decoration: const InputDecoration(labelText: 'Verified website URL')), const SizedBox(height: 12), TextField(controller: _notes, minLines: 3, maxLines: 6, decoration: const InputDecoration(labelText: 'Verified notes', alignLabelWithHint: true))])),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), ElevatedButton(onPressed: () => Navigator.pop(context, {'website_url': _website.text.trim().isEmpty ? null : _website.text.trim(), 'verified_notes': _notes.text.trim().isEmpty ? null : _notes.text.trim()}), child: const Text('Save review'))],
      );
}

class _AddLeadDialog extends StatefulWidget {
  const _AddLeadDialog();

  @override
  State<_AddLeadDialog> createState() => _AddLeadDialogState();
}

class _AddLeadDialogState extends State<_AddLeadDialog> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _company = TextEditingController();
  final _title = TextEditingController();
  final _source = TextEditingController(text: 'manual');

  @override
  void dispose() {
    for (final controller in [_email, _firstName, _lastName, _company, _title, _source]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Add lead'),
        content: SizedBox(
          width: 480,
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                children: [
                  TextFormField(controller: _email, decoration: const InputDecoration(labelText: 'Email *'), validator: (value) => value == null || !value.contains('@') ? 'Enter a valid email.' : null),
                  const SizedBox(height: 12),
                  Row(children: [Expanded(child: TextFormField(controller: _firstName, decoration: const InputDecoration(labelText: 'First name'))), const SizedBox(width: 12), Expanded(child: TextFormField(controller: _lastName, decoration: const InputDecoration(labelText: 'Last name')))]),
                  const SizedBox(height: 12),
                  Row(children: [Expanded(child: TextFormField(controller: _company, decoration: const InputDecoration(labelText: 'Company'))), const SizedBox(width: 12), Expanded(child: TextFormField(controller: _title, decoration: const InputDecoration(labelText: 'Title')))]),
                  const SizedBox(height: 12),
                  TextFormField(controller: _source, decoration: const InputDecoration(labelText: 'Source')),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(onPressed: () { if (!(_formKey.currentState?.validate() ?? false)) return; Navigator.pop(context, {'email': _email.text.trim(), 'first_name': _firstName.text.trim(), 'last_name': _lastName.text.trim(), 'company': _company.text.trim(), 'title': _title.text.trim(), 'source': _source.text.trim()}); }, child: const Text('Create lead')),
        ],
      );
}
