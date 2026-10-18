import 'package:flutter/material.dart';

import '../core/models/api_models.dart';
import '../core/services/api_client.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/design_system.dart';

class PricingScreen extends StatefulWidget {
  const PricingScreen({super.key, required this.api});

  final ApiService api;

  @override
  State<PricingScreen> createState() => _PricingScreenState();
}

class _PricingScreenState extends State<PricingScreen> {
  final _leads = TextEditingController(text: '100');
  final _pricePerLead = TextEditingController(text: '25');
  final _closeRate = TextEditingController(text: '8');
  final _revenuePerConversion = TextEditingController(text: '120');
  final _emailCost = TextEditingController(text: '0.25');
  final _labor = TextEditingController(text: '300');
  final _other = TextEditingController(text: '40');
  final _platformFee = TextEditingController(text: '3');
  PricingResult? _result;
  late Future<List<WebsitePackage>> _packages;
  bool _busy = false;

  @override
  void dispose() {
    for (final controller in [_leads, _pricePerLead, _closeRate, _revenuePerConversion, _emailCost, _labor, _other, _platformFee]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _packages = widget.api.listPackages();
  }

  double _number(TextEditingController controller) => double.tryParse(controller.text.trim()) ?? 0;

  Future<void> _calculate() async {
    final leads = int.tryParse(_leads.text.trim());
    if (leads == null || leads < 0) {
      _showMessage('Leads must be a whole number of zero or more.');
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await widget.api.calculatePricing(
        leads: leads,
        pricePerLead: _number(_pricePerLead),
        expectedCloseRate: _number(_closeRate) / 100,
        revenuePerConversion: _number(_revenuePerConversion),
        emailCostPerLead: _number(_emailCost),
        laborCost: _number(_labor),
        otherCost: _number(_other),
        platformFeePercent: _number(_platformFee),
      );
      if (mounted) setState(() => _result = result);
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
          SectionHeader(title: 'Pricing & profit', subtitle: 'Turn delivery assumptions into a transparent unit economics view.', action: ElevatedButton.icon(onPressed: _busy ? null : _calculate, icon: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.calculate_outlined), label: const Text('Calculate'))),
          const SizedBox(height: 24),
           LayoutBuilder(
            builder: (context, constraints) {
              final stacked = constraints.maxWidth < 900;
              final inputs = _InputsCard(leads: _leads, pricePerLead: _pricePerLead, closeRate: _closeRate, revenuePerConversion: _revenuePerConversion, emailCost: _emailCost, labor: _labor, other: _other, platformFee: _platformFee, onCalculate: _calculate, busy: _busy);
              final output = _result == null ? const AppCard(child: EmptyState(title: 'Calculate a scenario', message: 'Submit the assumptions to get the backend-calculated revenue, cost, margin, and profit.', icon: Icons.query_stats_outlined)) : _ResultsCard(result: _result!);
              return stacked ? Column(children: [inputs, const SizedBox(height: 20), output]) : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: inputs), const SizedBox(width: 20), Expanded(child: output)]);
            },
           ),
          const SizedBox(height: 20),
          FutureBuilder<List<WebsitePackage>>(
            future: _packages,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const LoadingState(label: 'Loading sustainable website packages…');
              if (snapshot.hasError) return AppCard(child: Text('Package library unavailable: ${snapshot.error}', style: const TextStyle(color: AppColors.slate)));
              return _PackageLibrary(packages: snapshot.data ?? const [], onProfit: _showPackageProfit);
            },
          ),
        ],
      );

  Future<void> _showPackageProfit(WebsitePackage package) async {
    try {
      final result = await widget.api.calculatePackageProfit(package.id);
      if (!mounted) return;
      showDialog<void>(context: context, builder: (context) => AlertDialog(title: Text('${package.name} · 12-month economics'), content: Column(mainAxisSize: MainAxisSize.min, children: [_PackageLine(label: 'Setup revenue', value: result.setupRevenue), _PackageLine(label: 'Monthly recurring', value: result.monthlyRecurringRevenue), _PackageLine(label: 'First-year revenue', value: result.firstYearRevenue), _PackageLine(label: 'First-year cost', value: -result.firstYearCost), _PackageLine(label: 'First-year profit', value: result.firstYearProfit), _PackageLine(label: 'Margin', value: result.firstYearMarginPercent, suffix: '%')]), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))]));
    } catch (error) {
      if (mounted) _showMessage(error.toString());
    }
  }
}

class _PackageLibrary extends StatelessWidget {
  const _PackageLibrary({required this.packages, required this.onProfit});

  final List<WebsitePackage> packages;
  final ValueChanged<WebsitePackage> onProfit;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Sustainable website packages',
              subtitle: 'Use recurring hosting and maintenance revenue instead of unsupported lifetime promises.',
            ),
            const SizedBox(height: 16),
            if (packages.isEmpty)
              const EmptyState(
                title: 'No packages configured',
                message: 'Create package records through the backend API when your pricing is authorized.',
                icon: Icons.inventory_2_outlined,
              )
            else
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: packages
                    .map(
                      (package) => SizedBox(
                        width: 260,
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: Theme.of(context).scaffoldBackgroundColor,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Theme.of(context).dividerColor),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(package.name, style: const TextStyle(fontWeight: FontWeight.w800)),
                              const SizedBox(height: 8),
                              Text(
                                formatMoney(package.setupPrice),
                                style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
                              ),
                              Text(
                                '${formatMoney(package.hostingMonthlyRevenue + package.maintenanceMonthlyRevenue)}/mo recurring',
                                style: const TextStyle(color: AppColors.slate),
                              ),
                              const SizedBox(height: 12),
                              OutlinedButton.icon(
                                onPressed: () => onProfit(package),
                                icon: const Icon(Icons.query_stats_outlined, size: 17),
                                label: const Text('View economics'),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                    .toList(),
              ),
          ],
        ),
      );
}

class _PackageLine extends StatelessWidget {
  const _PackageLine({required this.label, required this.value, this.suffix = ''});

  final String label;
  final double value;
  final String suffix;

  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 10), child: Row(children: [Expanded(child: Text(label)), Text(suffix == '%' ? '${value.toStringAsFixed(2)}%' : formatMoney(value), style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.ink))]));
}

class _InputsCard extends StatelessWidget {
  const _InputsCard({required this.leads, required this.pricePerLead, required this.closeRate, required this.revenuePerConversion, required this.emailCost, required this.labor, required this.other, required this.platformFee, required this.onCalculate, required this.busy});

  final TextEditingController leads;
  final TextEditingController pricePerLead;
  final TextEditingController closeRate;
  final TextEditingController revenuePerConversion;
  final TextEditingController emailCost;
  final TextEditingController labor;
  final TextEditingController other;
  final TextEditingController platformFee;
  final VoidCallback onCalculate;
  final bool busy;

  @override
  Widget build(BuildContext context) => AppCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionHeader(
              title: 'Scenario inputs',
              subtitle: 'All values are sent to /api/pricing/calculate.',
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(child: _NumberField(controller: leads, label: 'Leads', prefix: '#')),
                const SizedBox(width: 12),
                Expanded(child: _NumberField(controller: pricePerLead, label: 'Price / lead', prefix: '\$')),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: _NumberField(controller: closeRate, label: 'Expected close rate', suffix: '%')),
                const SizedBox(width: 12),
                Expanded(child: _NumberField(controller: revenuePerConversion, label: 'Revenue / conversion', prefix: '\$')),
              ],
            ),
            const SizedBox(height: 14),
            const Divider(),
            const SizedBox(height: 14),
            Text(
              'Delivery costs',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(child: _NumberField(controller: emailCost, label: 'Email / lead', prefix: '\$')),
                const SizedBox(width: 12),
                Expanded(child: _NumberField(controller: labor, label: 'Labor', prefix: '\$')),
              ],
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: _NumberField(controller: other, label: 'Other costs', prefix: '\$')),
                const SizedBox(width: 12),
                Expanded(child: _NumberField(controller: platformFee, label: 'Platform fee', suffix: '%')),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: busy ? null : onCalculate,
                icon: const Icon(Icons.calculate_outlined),
                label: const Text('Calculate scenario'),
              ),
            ),
          ],
        ),
      );
}

class _NumberField extends StatelessWidget {
  const _NumberField({required this.controller, required this.label, this.prefix, this.suffix});

  final TextEditingController controller;
  final String label;
  final String? prefix;
  final String? suffix;

  @override
  Widget build(BuildContext context) => TextField(controller: controller, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: label, prefixText: prefix, suffixText: suffix));
}

class _ResultsCard extends StatelessWidget {
  const _ResultsCard({required this.result});

  final PricingResult result;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [AppCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const SectionHeader(title: 'Profit snapshot', subtitle: 'The numbers below are the backend response.'), const SizedBox(height: 22), Text(formatMoney(result.netProfit), style: Theme.of(context).textTheme.displaySmall?.copyWith(fontWeight: FontWeight.w900, color: result.netProfit >= 0 ? AppColors.mint : AppColors.red)), const SizedBox(height: 5), Text('${result.marginPercent.toStringAsFixed(2)}% net margin', style: TextStyle(color: result.netProfit >= 0 ? AppColors.mint : AppColors.red, fontWeight: FontWeight.w800)), const SizedBox(height: 20), Container(height: 10, clipBehavior: Clip.antiAlias, decoration: BoxDecoration(color: AppColors.redSoft, borderRadius: BorderRadius.circular(10)), child: FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: (result.marginPercent / 100).clamp(0, 1).toDouble(), child: Container(color: AppColors.mint)))]),), const SizedBox(height: 20), AppCard(child: Column(children: [_BreakdownRow(label: 'Billable revenue', value: result.billableRevenue, emphasis: true), _BreakdownRow(label: 'Delivery cost', value: -result.deliveryCost), _BreakdownRow(label: 'Platform fee', value: -result.platformFee), const Divider(height: 24), _BreakdownRow(label: 'Total cost', value: -result.totalCost, emphasis: true), _BreakdownRow(label: 'Expected downstream revenue', value: result.expectedDownstreamRevenue), _BreakdownRow(label: 'Expected conversions', value: result.expectedConversions, isMoney: false)]))]);
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({required this.label, required this.value, this.emphasis = false, this.isMoney = true});

  final String label;
  final num value;
  final bool emphasis;
  final bool isMoney;

  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(bottom: 14), child: Row(children: [Expanded(child: Text(label, style: TextStyle(fontWeight: emphasis ? FontWeight.w800 : FontWeight.w500))), Text(isMoney ? formatMoney(value) : value.toStringAsFixed(2), style: TextStyle(fontWeight: emphasis ? FontWeight.w900 : FontWeight.w700, color: value < 0 ? AppColors.red : null))]));
}
