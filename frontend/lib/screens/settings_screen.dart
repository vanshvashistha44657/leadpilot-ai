import 'package:flutter/material.dart';

import '../core/models/api_models.dart';
import '../core/services/api_client.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/design_system.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.api, required this.isDark, required this.onToggleTheme});

  final ApiService api;
  final bool isDark;
  final VoidCallback onToggleTheme;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late Future<_SettingsData> _data;
  final _baseUrl = TextEditingController();
  final _token = TextEditingController();
  final _senderName = TextEditingController();
  final _senderEmail = TextEditingController();
  final _physicalAddress = TextEditingController();
  final _unsubscribeUrl = TextEditingController();
  final _aiProvider = TextEditingController();
  final _aiModel = TextEditingController();
  final _aiBaseUrl = TextEditingController();
  final _aiTimeout = TextEditingController();
  final _aiRetries = TextEditingController();
  final _aiBackoff = TextEditingController();
  bool _hydrated = false;
  bool _aiHydrated = false;
  bool _addressPlaceholder = false;
  bool _unsubscribePlaceholder = false;
  bool _dryRun = true;
  bool _compliance = false;
  String _provider = 'mock';
  bool _busy = false;
  AIConnectivityResult? _aiConnectivity;

  @override
  void initState() {
    super.initState();
    _baseUrl.text = widget.api.config.baseUrl;
    _token.text = widget.api.config.localToken;
    _data = _load();
  }

  @override
  void dispose() {
    for (final controller in [_baseUrl, _token, _senderName, _senderEmail, _physicalAddress, _unsubscribeUrl, _aiProvider, _aiModel, _aiBaseUrl, _aiTimeout, _aiRetries, _aiBackoff]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<_SettingsData> _load() async {
    final results = await Future.wait<dynamic>([
      widget.api.getSettings(),
      widget.api.listProviders(),
      widget.api.getAIStatus(),
      widget.api.getAIConfig(),
      widget.api.getAIUsage(),
      widget.api.getGmailStatus(),
    ]);
    final settings = results[0] as PublicSettings;
    final providers = results[1] as List<ProviderStatus>;
    final aiStatus = results[2] as AIProviderStatus;
    final aiConfig = results[3] as AIProviderConfig;
    final aiUsage = results[4] as AIUsageSummary;
    final gmailStatus = results[5] as GmailStatus;
    HealthResponse? health;
    String? healthError;
    try {
      health = await widget.api.checkReady();
    } catch (error) {
      healthError = error.toString();
    }
    return _SettingsData(settings, providers, health, healthError, aiStatus, aiConfig, aiUsage, gmailStatus);
  }

  void _hydrate(PublicSettings settings) {
    if (_hydrated) return;
    _hydrated = true;
    _senderName.text = settings.senderName ?? '';
    _senderEmail.text = settings.senderEmail ?? '';
    _addressPlaceholder = settings.physicalAddressConfigured;
    _unsubscribePlaceholder = settings.unsubscribeUrlConfigured;
    _physicalAddress.text = settings.physicalAddressConfigured ? 'Configured on backend' : '';
    _unsubscribeUrl.text = settings.unsubscribeUrlConfigured ? 'Configured on backend' : '';
    _dryRun = settings.dryRun;
    _compliance = settings.complianceAcknowledged;
    _provider = settings.provider;
  }

  void _hydrateAI(AIProviderConfig config) {
    if (_aiHydrated) return;
    _aiHydrated = true;
    _aiProvider.text = config.provider;
    _aiModel.text = config.model ?? '';
    _aiBaseUrl.text = config.baseUrl ?? '';
    _aiTimeout.text = config.timeoutSeconds.toString();
    _aiRetries.text = config.maxRetries.toString();
    _aiBackoff.text = config.retryBackoffSeconds.toString();
  }

  void _refresh() => setState(() {
        _hydrated = false;
        _aiHydrated = false;
        _aiConnectivity = null;
        _data = _load();
      });

  Future<void> _applyConnection() async {
    if (_baseUrl.text.trim().isEmpty) {
      _showMessage('Enter an API base URL.');
      return;
    }
    setState(() => _busy = true);
    widget.api.updateConnection(baseUrl: _baseUrl.text, localToken: _token.text);
    try {
      final health = await widget.api.checkReady();
      if (mounted) _showMessage('Connected: ${health.status}, database ${health.database}.');
      if (mounted) _refresh();
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveSettings() async {
    setState(() => _busy = true);
    try {
      await widget.api.updateSettings({
        'sender_name': _senderName.text.trim(),
        'sender_email': _senderEmail.text.trim(),
        'physical_address': _addressPlaceholder && _physicalAddress.text == 'Configured on backend' ? null : _physicalAddress.text.trim(),
        'unsubscribe_url': _unsubscribePlaceholder && _unsubscribeUrl.text == 'Configured on backend' ? null : _unsubscribeUrl.text.trim(),
        'compliance_acknowledged': _compliance,
        'dry_run': _dryRun,
        'provider': _provider,
      });
      if (mounted) {
        _showMessage('Settings saved to the backend.');
        _refresh();
      }
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backup() async {
    setState(() => _busy = true);
    try {
      final result = await widget.api.backupDatabase();
      if (mounted) _showMessage('Backup created: ${result['path']} (${result['size_bytes']} bytes).');
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAIConfig() async {
    final timeout = double.tryParse(_aiTimeout.text.trim());
    final retries = int.tryParse(_aiRetries.text.trim());
    final backoff = double.tryParse(_aiBackoff.text.trim());
    if (timeout == null || retries == null || backoff == null) {
      _showMessage('AI timeout, retries, and backoff must be valid numbers.');
      return;
    }
    setState(() => _busy = true);
    try {
      await widget.api.updateAIConfig({
        'provider': _aiProvider.text.trim(),
        'model': _aiModel.text.trim(),
        'base_url': _aiBaseUrl.text.trim(),
        'timeout_seconds': timeout,
        'max_retries': retries,
        'retry_backoff_seconds': backoff,
      });
      if (mounted) {
        _showMessage('AI provider settings saved. The API key remains environment-only.');
        _refresh();
      }
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testAIConnectivity() async {
    setState(() => _busy = true);
    try {
      final result = await widget.api.checkAIConnectivity();
      if (mounted) setState(() => _aiConnectivity = result);
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setAutomationPaused(bool paused) async {
    setState(() => _busy = true);
    try {
      if (paused) {
        await widget.api.stopAutomation();
      } else {
        await widget.api.resumeAutomation();
      }
      if (mounted) {
        _showMessage(paused ? 'Global automation stop enabled.' : 'Automation resumed in the backend.');
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
          SectionHeader(title: 'Settings & integrations', subtitle: 'Configure the local connection, sender details, safety flags, and providers.', action: IconButton(tooltip: 'Refresh settings', onPressed: _busy ? null : _refresh, icon: const Icon(Icons.refresh))),
          const SizedBox(height: 24),
          FutureBuilder<_SettingsData>(
            future: _data,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return Column(children: [_ConnectionCard(baseUrl: _baseUrl, token: _token, health: null, healthError: null, busy: _busy, onApply: _applyConnection), const LoadingState(label: 'Checking backend settings…')]);
              }
              if (snapshot.hasError) {
                return Column(children: [_ConnectionCard(baseUrl: _baseUrl, token: _token, health: null, healthError: snapshot.error.toString(), busy: _busy, onApply: _applyConnection), const SizedBox(height: 20), ErrorState(message: snapshot.error.toString(), onRetry: _refresh)]);
              }
              final data = snapshot.data;
              if (data == null) return ErrorState(message: 'The backend returned no settings.', onRetry: _refresh);
              _hydrate(data.settings);
              _hydrateAI(data.aiConfig);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _ConnectionCard(
                    baseUrl: _baseUrl,
                    token: _token,
                    health: data.health,
                    healthError: data.healthError,
                    busy: _busy,
                    onApply: _applyConnection,
                  ),
                  const SizedBox(height: 20),
                  _SafetyCard(
                    settings: data.settings,
                    dryRun: _dryRun,
                    compliance: _compliance,
                    busy: _busy,
                    onDryRunChanged: (value) => setState(() => _dryRun = value),
                    onComplianceChanged: (value) => setState(() => _compliance = value),
                    onAutomationChanged: _setAutomationPaused,
                  ),
                  const SizedBox(height: 20),
                   _SenderCard(
                    senderName: _senderName,
                    senderEmail: _senderEmail,
                    physicalAddress: _physicalAddress,
                    unsubscribeUrl: _unsubscribeUrl,
                    provider: _provider,
                    providers: data.providers,
                    onProviderChanged: (value) {
                      if (value != null) setState(() => _provider = value);
                    },
                   ),
                   const SizedBox(height: 20),
                   _AIConfigurationCard(
                     status: data.aiStatus,
                     config: data.aiConfig,
                     usage: data.aiUsage,
                     connectivity: _aiConnectivity,
                     provider: _aiProvider,
                     model: _aiModel,
                     baseUrl: _aiBaseUrl,
                     timeout: _aiTimeout,
                     retries: _aiRetries,
                     backoff: _aiBackoff,
                     busy: _busy,
                     onSave: _saveAIConfig,
                     onTest: _testAIConnectivity,
                   ),
                   const SizedBox(height: 20),
                   _IntegrationStatusCard(aiStatus: data.aiStatus, gmailStatus: data.gmailStatus),
                  const SizedBox(height: 20),
                  _AppearanceCard(isDark: widget.isDark, onToggleTheme: widget.onToggleTheme),
                  const SizedBox(height: 20),
                  AppCard(
                    child: Row(
                      children: [
                        const Expanded(
                          child: SectionHeader(
                            title: 'Data operations',
                            subtitle: 'Create a real backend database backup when needed.',
                          ),
                        ),
                        OutlinedButton.icon(
                          onPressed: _busy ? null : _backup,
                          icon: const Icon(Icons.backup_outlined),
                          label: const Text('Backup database'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : _saveSettings,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.save_outlined),
                      label: const Text('Save backend settings'),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      );
}

class _SettingsData {
  const _SettingsData(this.settings, this.providers, this.health, this.healthError, this.aiStatus, this.aiConfig, this.aiUsage, this.gmailStatus);

  final PublicSettings settings;
  final List<ProviderStatus> providers;
  final HealthResponse? health;
  final String? healthError;
  final AIProviderStatus aiStatus;
  final AIProviderConfig aiConfig;
  final AIUsageSummary aiUsage;
  final GmailStatus gmailStatus;
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({required this.baseUrl, required this.token, required this.health, required this.healthError, required this.busy, required this.onApply});

  final TextEditingController baseUrl;
  final TextEditingController token;
  final HealthResponse? health;
  final String? healthError;
  final bool busy;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) => AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const SectionHeader(title: 'API connection', subtitle: 'Values are held in memory and sent only to the configured backend.'), const SizedBox(height: 18), Row(children: [Expanded(child: TextField(controller: baseUrl, decoration: const InputDecoration(labelText: 'Base URL', prefixIcon: Icon(Icons.link)))), const SizedBox(width: 12), Expanded(child: TextField(controller: token, obscureText: true, decoration: const InputDecoration(labelText: 'Local token', prefixIcon: Icon(Icons.key_outlined))))]), const SizedBox(height: 14), Row(children: [if (health != null) StatusPill(label: '${health!.status} · database ${health!.database}', color: AppColors.mint) else const StatusPill(label: 'Not verified', color: AppColors.amber), if (healthError != null) Expanded(child: Padding(padding: const EdgeInsets.only(left: 12), child: Text(healthError!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.red, fontSize: 12)))), const Spacer(), OutlinedButton.icon(onPressed: busy ? null : onApply, icon: const Icon(Icons.wifi_tethering_outlined), label: const Text('Apply & verify'))]) ]));
}

class _SafetyCard extends StatelessWidget {
  const _SafetyCard({required this.settings, required this.dryRun, required this.compliance, required this.busy, required this.onDryRunChanged, required this.onComplianceChanged, required this.onAutomationChanged});

  final PublicSettings settings;
  final bool dryRun;
  final bool compliance;
  final bool busy;
  final ValueChanged<bool> onDryRunChanged;
  final ValueChanged<bool> onComplianceChanged;
  final ValueChanged<bool> onAutomationChanged;

  @override
  Widget build(BuildContext context) => AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [SafetyBanner(title: settings.automationPaused ? 'Global automation stop is active' : (dryRun ? 'Dry-run mode is enabled' : 'Live mode is selected'), message: settings.automationPaused ? 'No new automation jobs can be queued. Existing queued or running jobs receive cancellation requests.' : (dryRun ? 'Outreach requests remain preview-only until you intentionally change the backend setting.' : 'Live mode requires provider configuration, sender details, compliance acknowledgement, and backend approval.'), safe: dryRun && !settings.automationPaused), const SizedBox(height: 14), SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Keep outreach in dry-run mode', style: TextStyle(fontWeight: FontWeight.w700)), subtitle: const Text('The backend still enforces its own live-send checks.'), value: dryRun, onChanged: busy ? null : onDryRunChanged), SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Compliance acknowledgement', style: TextStyle(fontWeight: FontWeight.w700)), subtitle: const Text('Required by the backend before live sending can be ready.'), value: compliance, onChanged: busy ? null : onComplianceChanged), Row(children: [Expanded(child: Text(settings.automationPaused ? 'Resume when you are ready to run scheduled work.' : 'Use this kill switch to stop queued and running automation.', style: Theme.of(context).textTheme.bodySmall)), OutlinedButton.icon(onPressed: busy ? null : () => onAutomationChanged(!settings.automationPaused), icon: Icon(settings.automationPaused ? Icons.play_arrow_rounded : Icons.stop_circle_outlined), label: Text(settings.automationPaused ? 'Resume automation' : 'Stop automation'))]), const Divider(), const SizedBox(height: 10), Wrap(spacing: 10, runSpacing: 10, children: [StatusPill(label: settings.liveSendingEnabled ? 'Live sending enabled' : 'Live sending disabled', color: settings.liveSendingEnabled ? AppColors.amber : AppColors.slate), StatusPill(label: settings.liveSendReady ? 'Live send ready' : 'Live send not ready', color: settings.liveSendReady ? AppColors.mint : AppColors.amber)])]));
}

class _SenderCard extends StatelessWidget {
  const _SenderCard({required this.senderName, required this.senderEmail, required this.physicalAddress, required this.unsubscribeUrl, required this.provider, required this.providers, required this.onProviderChanged});

  final TextEditingController senderName;
  final TextEditingController senderEmail;
  final TextEditingController physicalAddress;
  final TextEditingController unsubscribeUrl;
  final String provider;
  final List<ProviderStatus> providers;
  final ValueChanged<String?> onProviderChanged;

  @override
  Widget build(BuildContext context) => AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const SectionHeader(title: 'Sender & integrations', subtitle: 'Provider status is read from the real backend registry; no integration is marked successful locally.'), const SizedBox(height: 18), Row(children: [Expanded(child: TextField(controller: senderName, decoration: const InputDecoration(labelText: 'Sender name'))), const SizedBox(width: 12), Expanded(child: TextField(controller: senderEmail, decoration: const InputDecoration(labelText: 'Sender email')))]), const SizedBox(height: 12), TextField(controller: physicalAddress, minLines: 2, maxLines: 3, decoration: const InputDecoration(labelText: 'Physical address', alignLabelWithHint: true)), const SizedBox(height: 12), TextField(controller: unsubscribeUrl, decoration: const InputDecoration(labelText: 'Unsubscribe URL')), const SizedBox(height: 12), DropdownButtonFormField<String>(initialValue: providers.any((item) => item.name == provider) ? provider : null, decoration: const InputDecoration(labelText: 'Selected provider'), items: providers.map((item) => DropdownMenuItem(value: item.name, child: Text(item.name))).toList(), onChanged: onProviderChanged), const SizedBox(height: 18), if (providers.isEmpty) const Text('No provider statuses returned.', style: TextStyle(color: AppColors.slate)) else Wrap(spacing: 10, runSpacing: 10, children: providers.map((item) => StatusPill(label: '${item.name}: ${item.configured ? 'configured' : 'not configured'}', color: item.configured ? AppColors.mint : AppColors.slate)).toList())]));
}

class _AIConfigurationCard extends StatelessWidget {
  const _AIConfigurationCard({
    required this.status,
    required this.config,
    required this.usage,
    required this.connectivity,
    required this.provider,
    required this.model,
    required this.baseUrl,
    required this.timeout,
    required this.retries,
    required this.backoff,
    required this.busy,
    required this.onSave,
    required this.onTest,
  });

  final AIProviderStatus status;
  final AIProviderConfig config;
  final AIUsageSummary usage;
  final AIConnectivityResult? connectivity;
  final TextEditingController provider;
  final TextEditingController model;
  final TextEditingController baseUrl;
  final TextEditingController timeout;
  final TextEditingController retries;
  final TextEditingController backoff;
  final bool busy;
  final VoidCallback onSave;
  final VoidCallback onTest;

  Color _connectivityColor() {
    switch (connectivity?.status) {
      case 'connected':
        return AppColors.mint;
      case 'not_configured':
      case 'invalid_configuration':
        return AppColors.amber;
      default:
        return AppColors.red;
    }
  }

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SectionHeader(
            title: 'AI provider configuration',
            subtitle: 'Configure non-secret OpenAI-compatible settings here. The API key is read only from the backend process environment and is never displayed or stored in SQLite.',
          ),
          const SizedBox(height: 16),
          Wrap(spacing: 10, runSpacing: 10, children: [
            StatusPill(label: 'Provider: ${status.name}', color: status.configured ? AppColors.mint : AppColors.amber),
            StatusPill(label: status.apiKeyConfigured ? 'API key configured' : 'API key missing', color: status.apiKeyConfigured ? AppColors.mint : AppColors.amber),
            StatusPill(label: 'Model: ${config.model ?? 'not set'}', color: AppColors.slate),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: provider, decoration: const InputDecoration(labelText: 'Provider label', helperText: 'Any label using the OpenAI-compatible adapter'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: model, decoration: const InputDecoration(labelText: 'Model'))),
          ]),
          const SizedBox(height: 12),
          TextField(controller: baseUrl, decoration: const InputDecoration(labelText: 'Provider base URL', helperText: 'For example, https://api.openai.com/v1')),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: timeout, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Timeout seconds'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: retries, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Max retries'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: backoff, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Retry backoff seconds'))),
          ]),
          if (config.configurationErrors.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(config.configurationErrors.join(' · '), style: const TextStyle(color: AppColors.red, fontSize: 12)),
          ],
          const SizedBox(height: 14),
          Row(children: [
            OutlinedButton.icon(onPressed: busy ? null : onSave, icon: const Icon(Icons.save_outlined), label: const Text('Save AI settings')),
            const SizedBox(width: 10),
            ElevatedButton.icon(onPressed: busy ? null : onTest, icon: const Icon(Icons.network_check_outlined), label: const Text('Test connectivity')),
          ]),
          const SizedBox(height: 14),
          if (connectivity != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, borderRadius: BorderRadius.circular(12)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(connectivity!.status == 'connected' ? Icons.check_circle_outline : Icons.error_outline, color: _connectivityColor()),
                const SizedBox(width: 10),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  StatusPill(label: connectivity!.status.replaceAll('_', ' '), color: _connectivityColor()),
                  const SizedBox(height: 6),
                  Text(connectivity!.detail, style: const TextStyle(color: AppColors.slate, fontSize: 12)),
                  const SizedBox(height: 4),
                  Text('Checked ${connectivity!.checkedAt.toLocal()}', style: const TextStyle(color: AppColors.slate, fontSize: 11)),
                ])),
              ]),
            ),
          const SizedBox(height: 12),
          Text('Usage: ${usage.requests} requests · ${usage.totalTokens} tokens · ${usage.estimatedCostUsd.toStringAsFixed(4)} USD', style: const TextStyle(color: AppColors.slate, fontSize: 12)),
          if (config.baseUrl != null) Text('Active base URL: ${config.baseUrl}', style: const TextStyle(color: AppColors.slate, fontSize: 12)),
        ]),
      );
}

class _IntegrationStatusCard extends StatelessWidget {
  const _IntegrationStatusCard({required this.aiStatus, required this.gmailStatus});

  final AIProviderStatus aiStatus;
  final GmailStatus gmailStatus;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SectionHeader(title: 'AI & Gmail readiness', subtitle: 'Configuration status is read from the backend. Secrets and tokens are never returned to the desktop UI.'),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: _IntegrationRow(icon: Icons.auto_awesome_outlined, title: 'AI personalization', state: aiStatus.configured ? 'Configured' : 'Unavailable', detail: aiStatus.reason, color: aiStatus.configured ? AppColors.mint : AppColors.amber)),
            const SizedBox(width: 16),
            Expanded(child: _IntegrationRow(icon: Icons.mail_outline, title: 'Gmail API', state: gmailStatus.configured ? 'Configured' : 'Not configured', detail: gmailStatus.reason, color: gmailStatus.supportsLiveSend ? AppColors.mint : AppColors.slate)),
          ]),
          const SizedBox(height: 12),
          const Text('Live email remains blocked until OAuth, sender verification, compliance settings, a controlled integration test, and explicit approval are all complete.', style: TextStyle(color: AppColors.slate, fontSize: 12)),
        ]),
      );
}

class _IntegrationRow extends StatelessWidget {
  const _IntegrationRow({required this.icon, required this.title, required this.state, required this.detail, required this.color});

  final IconData icon;
  final String title;
  final String state;
  final String detail;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, borderRadius: BorderRadius.circular(12)), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(icon, color: color), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.w800)), const SizedBox(height: 4), StatusPill(label: state, color: color), const SizedBox(height: 6), Text(detail, maxLines: 3, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.slate, fontSize: 12))]))]));
}

class _AppearanceCard extends StatelessWidget {
  const _AppearanceCard({required this.isDark, required this.onToggleTheme});

  final bool isDark;
  final VoidCallback onToggleTheme;

  @override
  Widget build(BuildContext context) => AppCard(child: SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Dark theme', style: TextStyle(fontWeight: FontWeight.w700)), subtitle: Text(isDark ? 'Dark theme is active.' : 'Light theme is active.'), value: isDark, onChanged: (_) => onToggleTheme()));
}
