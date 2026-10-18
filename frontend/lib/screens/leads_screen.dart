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
      final job = await widget.api.queueImportLeads(path);
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
              return _LeadTable(leads: data.leads, total: data.total, page: _page, pageSize: _pageSize, searchController: _searchController, onReview: _reviewLead, onPageChanged: (page) => setState(() { _page = page; _leads = _loadPage(); }), onPageSizeChanged: (size) => setState(() { _pageSize = size; _page = 0; _leads = _loadPage(); }));
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
  const _LeadTable({required this.leads, required this.total, required this.page, required this.pageSize, required this.searchController, required this.onReview, required this.onPageChanged, required this.onPageSizeChanged});

  final List<Lead> leads;
  final int total;
  final int page;
  final int pageSize;
  final TextEditingController searchController;
  final ValueChanged<Lead> onReview;
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
                ],
                rows: visible.map((lead) => DataRow(onSelectChanged: (_) => onReview(lead), cells: [
                      DataCell(Text('${lead.id}')),
                      DataCell(Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [if (lead.displayName.isNotEmpty) Text(lead.displayName, style: const TextStyle(fontWeight: FontWeight.w700)), Text(lead.email, style: const TextStyle(color: AppColors.slate))])),
                      DataCell(Text(lead.company?.isNotEmpty == true ? lead.company! : '—')),
                      DataCell(Text(lead.title?.isNotEmpty == true ? lead.title! : '—')),
                       DataCell(StatusPill(label: lead.status, color: statusColor(lead.status))),
                       DataCell(Text(lead.researchStatus == 'unresearched' ? '—' : '${lead.opportunityScore}/100')),
                       DataCell(Text(lead.source?.isNotEmpty == true ? lead.source! : '—')),
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
