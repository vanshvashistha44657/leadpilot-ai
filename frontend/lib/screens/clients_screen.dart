import 'package:flutter/material.dart';

import '../core/models/api_models.dart';
import '../core/services/api_client.dart';
import '../core/widgets/design_system.dart';

class ClientsScreen extends StatefulWidget {
  const ClientsScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<ClientsScreen> createState() => _ClientsScreenState();
}

class _ClientsScreenState extends State<ClientsScreen> {
  late Future<_ClientData> _data;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _data = _load();
  }

  Future<_ClientData> _load() async => _ClientData(await widget.api.listClients(), await widget.api.listProjects());

  void _refresh() => setState(() => _data = _load());

  Future<void> _createClient() async {
    final values = await showDialog<JsonMap>(context: context, builder: (context) => const _ClientDialog());
    if (values == null) return;
    setState(() => _busy = true);
    try {
      await widget.api.createClient(companyName: values['company_name'] as String, contactName: values['contact_name'] as String?, email: values['email'] as String?, notes: values['notes'] as String?);
      if (mounted) {
        _showMessage('Client saved locally.');
        _refresh();
      }
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _createProject(List<Client> clients) async {
    if (clients.isEmpty) {
      _showMessage('Create a client before creating a project.');
      return;
    }
    final values = await showDialog<JsonMap>(context: context, builder: (context) => _ProjectDialog(clients: clients));
    if (values == null) return;
    setState(() => _busy = true);
    try {
      await widget.api.createProject(clientId: values['client_id'] as int, name: values['name'] as String, previewUrl: values['preview_url'] as String?, domain: values['domain'] as String?, hostingPlan: values['hosting_plan'] as String?, databasePlan: values['database_plan'] as String?);
      if (mounted) {
        _showMessage('Project created. Deployment remains unverified until a real provider confirms it.');
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
            title: 'Clients & projects',
            subtitle: 'Track proposals, delivery work, previews, hosting, and renewals without claiming unverified deployments.',
            action: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _refresh,
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Refresh'),
                ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: _busy ? null : _createClient,
                  icon: const Icon(Icons.person_add_alt_1_outlined),
                  label: const Text('New client'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          FutureBuilder<_ClientData>(
            future: _data,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const LoadingState(label: 'Loading client operations…');
              }
              if (snapshot.hasError) {
                return ErrorState(message: snapshot.error.toString(), onRetry: _refresh);
              }
              final data = snapshot.data;
              if (data == null) {
                return ErrorState(message: 'The backend returned no client data.', onRetry: _refresh);
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: MetricCard(
                          label: 'Clients',
                          value: '${data.clients.length}',
                          icon: Icons.business_outlined,
                          helper: 'Local CRM records',
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: MetricCard(
                          label: 'Projects',
                          value: '${data.projects.length}',
                          icon: Icons.web_asset_outlined,
                          helper: 'Delivery records',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SectionHeader(
                          title: 'Client pipeline',
                          subtitle: 'Status stays operator-controlled until contracts or payments are integrated.',
                        ),
                        const SizedBox(height: 16),
                        if (data.clients.isEmpty)
                          const EmptyState(
                            title: 'No clients yet',
                            message: 'Promote an interested lead into a client record when authorized.',
                            icon: Icons.business_outlined,
                          )
                        else
                          ...data.clients.map(
                            (client) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: CircleAvatar(
                                child: Text(
                                  client.companyName.isEmpty ? '?' : client.companyName.substring(0, 1).toUpperCase(),
                                ),
                              ),
                              title: Text(
                                client.companyName,
                                style: const TextStyle(fontWeight: FontWeight.w800),
                              ),
                              subtitle: Text(
                                [client.contactName, client.email].whereType<String>().where((value) => value.isNotEmpty).join(' · ').isEmpty
                                    ? 'No contact details stored'
                                    : [client.contactName, client.email].whereType<String>().where((value) => value.isNotEmpty).join(' · '),
                              ),
                              trailing: StatusPill(label: client.status, color: statusColor(client.status)),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  AppCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SectionHeader(
                          title: 'Fulfillment projects',
                          subtitle: 'Preview, deployment, domains, and plans are recorded as facts only.',
                        ),
                        const SizedBox(height: 16),
                        if (data.projects.isEmpty)
                          EmptyState(
                            title: 'No projects yet',
                            message: 'Create a project after a client approves a proposal.',
                            icon: Icons.web_asset_outlined,
                            action: OutlinedButton.icon(
                              onPressed: _busy ? null : () => _createProject(data.clients),
                              icon: const Icon(Icons.add),
                              label: const Text('Create project'),
                            ),
                          )
                        else ...[
                          Align(
                            alignment: Alignment.centerRight,
                            child: OutlinedButton.icon(
                              onPressed: _busy ? null : () => _createProject(data.clients),
                              icon: const Icon(Icons.add),
                              label: const Text('New project'),
                            ),
                          ),
                          const SizedBox(height: 8),
                          ...data.projects.map(
                            (project) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.language_outlined),
                              title: Text(
                                project.name,
                                style: const TextStyle(fontWeight: FontWeight.w800),
                              ),
                              subtitle: Text(
                                [project.previewUrl, project.domain, project.hostingPlan].whereType<String>().where((value) => value.isNotEmpty).join(' · ').isEmpty
                                    ? 'No verified deployment or hosting details'
                                    : [project.previewUrl, project.domain, project.hostingPlan].whereType<String>().where((value) => value.isNotEmpty).join(' · '),
                              ),
                              trailing: StatusPill(label: project.status, color: statusColor(project.status)),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      );
}

class _ClientData {
  const _ClientData(this.clients, this.projects);

  final List<Client> clients;
  final List<Project> projects;
}

class _ClientDialog extends StatefulWidget {
  const _ClientDialog();

  @override
  State<_ClientDialog> createState() => _ClientDialogState();
}

class _ClientDialogState extends State<_ClientDialog> {
  final _company = TextEditingController();
  final _contact = TextEditingController();
  final _email = TextEditingController();
  final _notes = TextEditingController();

  @override
  void dispose() {
    for (final controller in [_company, _contact, _email, _notes]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(title: const Text('New client'), content: SizedBox(width: 460, child: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: _company, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Company name *')), const SizedBox(height: 12), TextField(controller: _contact, decoration: const InputDecoration(labelText: 'Contact name')), const SizedBox(height: 12), TextField(controller: _email, decoration: const InputDecoration(labelText: 'Email')), const SizedBox(height: 12), TextField(controller: _notes, maxLines: 3, decoration: const InputDecoration(labelText: 'Notes'))])), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), ElevatedButton(onPressed: _company.text.trim().isEmpty ? null : () => Navigator.pop(context, {'company_name': _company.text.trim(), 'contact_name': _contact.text.trim().isEmpty ? null : _contact.text.trim(), 'email': _email.text.trim().isEmpty ? null : _email.text.trim(), 'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim()}), child: const Text('Save client'))]);
}

class _ProjectDialog extends StatefulWidget {
  const _ProjectDialog({required this.clients});

  final List<Client> clients;

  @override
  State<_ProjectDialog> createState() => _ProjectDialogState();
}

class _ProjectDialogState extends State<_ProjectDialog> {
  late int _clientId = widget.clients.first.id;
  final _name = TextEditingController();
  final _preview = TextEditingController();
  final _domain = TextEditingController();
  final _hosting = TextEditingController();
  final _database = TextEditingController();

  @override
  void dispose() {
    for (final controller in [_name, _preview, _domain, _hosting, _database]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(title: const Text('New fulfillment project'), content: SizedBox(width: 480, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [DropdownButtonFormField<int>(initialValue: _clientId, decoration: const InputDecoration(labelText: 'Client'), items: widget.clients.map((client) => DropdownMenuItem(value: client.id, child: Text(client.companyName))).toList(), onChanged: (value) { if (value != null) setState(() => _clientId = value); }), const SizedBox(height: 12), TextField(controller: _name, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Project name *')), const SizedBox(height: 12), TextField(controller: _preview, decoration: const InputDecoration(labelText: 'Preview URL (optional)')), const SizedBox(height: 12), TextField(controller: _domain, decoration: const InputDecoration(labelText: 'Domain (optional)')), const SizedBox(height: 12), TextField(controller: _hosting, decoration: const InputDecoration(labelText: 'Hosting plan')), const SizedBox(height: 12), TextField(controller: _database, decoration: const InputDecoration(labelText: 'Database plan'))]))), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), ElevatedButton(onPressed: _name.text.trim().isEmpty ? null : () => Navigator.pop(context, {'client_id': _clientId, 'name': _name.text.trim(), 'preview_url': _preview.text.trim().isEmpty ? null : _preview.text.trim(), 'domain': _domain.text.trim().isEmpty ? null : _domain.text.trim(), 'hosting_plan': _hosting.text.trim().isEmpty ? null : _hosting.text.trim(), 'database_plan': _database.text.trim().isEmpty ? null : _database.text.trim()}), child: const Text('Create project'))]);
}
