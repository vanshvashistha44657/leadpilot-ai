from __future__ import annotations

from ..models import PricingRequest, PricingResult


def calculate_pricing(request: PricingRequest) -> PricingResult:
    billable_revenue = request.leads * request.price_per_lead
    expected_conversions = request.leads * request.expected_close_rate
    expected_downstream_revenue = expected_conversions * request.revenue_per_conversion
    delivery_cost = request.leads * request.email_cost_per_lead + request.labor_cost + request.other_cost
    platform_fee = billable_revenue * (request.platform_fee_percent / 100)
    total_cost = delivery_cost + platform_fee
    net_profit = billable_revenue - total_cost
    margin_percent = (net_profit / billable_revenue * 100) if billable_revenue else 0.0
    return PricingResult(
        billable_revenue=round(billable_revenue, 2),
        expected_conversions=round(expected_conversions, 2),
        expected_downstream_revenue=round(expected_downstream_revenue, 2),
        delivery_cost=round(delivery_cost, 2),
        platform_fee=round(platform_fee, 2),
        total_cost=round(total_cost, 2),
        net_profit=round(net_profit, 2),
        margin_percent=round(margin_percent, 2),
    )
