import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models/api_models.dart';
import '../core/services/api_client.dart';
import '../core/widgets/design_system.dart';

class FulfillmentScreen extends StatefulWidget {
  const FulfillmentScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<FulfillmentScreen> createState() => _FulfillmentScreenState();
}

class _FulfillmentScreenState extends State<FulfillmentScreen> {
  final _clientName = TextEditingController();
  final _offer = TextEditingController();
  final _audience = TextEditingController();
  final _tone = TextEditingController(text: 'professional');
  final _cta = TextEditingController();
  BriefResponse? _response;
  bool _busy = false;

  @override
  void dispose() {
    for (final controller in [_clientName, _offer, _audience, _tone, _cta]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _generate() async {
    if ([_clientName, _offer, _audience, _cta].any((controller) => controller.text.trim().isEmpty)) {
      _showMessage('Client, offer, audience, and call to action are required.');
      return;
    }
    setState(() => _busy = true);
    try {
      final response = await widget.api.generateBrief(clientName: _clientName.text.trim(), offer: _offer.text.trim(), targetAudience: _audience.text.trim(), tone: _tone.text.trim().isEmpty ? 'professional' : _tone.text.trim(), callToAction: _cta.text.trim());
      if (mounted) setState(() => _response = response);
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _copy(String value) {
    Clipboard.setData(ClipboardData(text: value));
    _showMessage('Copied to clipboard.');
  }

  void _showMessage(String message) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) => PageContainer(
        children: [
          SectionHeader(title: 'Fulfillment', subtitle: 'Turn client inputs into a clear, reusable campaign brief.', action: ElevatedButton.icon(onPressed: _busy ? null : _generate, icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.auto_awesome_outlined), label: const Text('Generate brief'))),
          const SizedBox(height: 24),
          LayoutBuilder(builder: (context, constraints) {
            final form = _BriefForm(clientName: _clientName, offer: _offer, audience: _audience, tone: _tone, cta: _cta, onGenerate: _generate, busy: _busy);
            final output = _response == null ? const AppCard(child: EmptyState(title: 'Your brief will appear here', message: 'Complete the client inputs and ask the backend to generate a fulfillment brief.', icon: Icons.description_outlined)) : _BriefOutput(response: _response!, onCopy: _copy);
            return constraints.maxWidth < 900 ? Column(children: [form, const SizedBox(height: 20), output]) : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: form), const SizedBox(width: 20), Expanded(child: output)]);
          }),
        ],
      );
}

class _BriefForm extends StatelessWidget {
  const _BriefForm({required this.clientName, required this.offer, required this.audience, required this.tone, required this.cta, required this.onGenerate, required this.busy});

  final TextEditingController clientName;
  final TextEditingController offer;
  final TextEditingController audience;
  final TextEditingController tone;
  final TextEditingController cta;
  final VoidCallback onGenerate;
  final bool busy;

  @override
  Widget build(BuildContext context) => AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const SectionHeader(title: 'Client brief inputs', subtitle: 'These values are sent to the real fulfillment endpoint.'), const SizedBox(height: 20), TextField(controller: clientName, decoration: const InputDecoration(labelText: 'Client name')), const SizedBox(height: 14), TextField(controller: offer, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Offer', alignLabelWithHint: true)), const SizedBox(height: 14), TextField(controller: audience, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Target audience', alignLabelWithHint: true)), const SizedBox(height: 14), Row(children: [Expanded(child: TextField(controller: tone, decoration: const InputDecoration(labelText: 'Tone'))), const SizedBox(width: 12), Expanded(child: TextField(controller: cta, decoration: const InputDecoration(labelText: 'Call to action')))]), const SizedBox(height: 20), SizedBox(width: double.infinity, child: ElevatedButton.icon(onPressed: busy ? null : onGenerate, icon: const Icon(Icons.auto_awesome_outlined), label: const Text('Generate with backend')))]));
}

class _BriefOutput extends StatelessWidget {
  const _BriefOutput({required this.response, required this.onCopy});

  final BriefResponse response;
  final ValueChanged<String> onCopy;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [const Expanded(child: SectionHeader(title: 'Generated brief')), IconButton(tooltip: 'Copy brief', onPressed: () => onCopy(response.brief), icon: const Icon(Icons.copy_outlined))]), const SizedBox(height: 16), SelectableText(response.brief, style: Theme.of(context).textTheme.bodyLarge?.copyWith(height: 1.55))])), const SizedBox(height: 20), AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Prompt context', style: TextStyle(fontWeight: FontWeight.w800)), const SizedBox(height: 10), SelectableText(response.prompt, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.blueGrey, height: 1.45))]))]);
}
