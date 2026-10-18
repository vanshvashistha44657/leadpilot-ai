from app.models import PricingRequest
from app.services.pricing import calculate_pricing


def test_pricing_math_includes_delivery_and_platform_costs():
    result = calculate_pricing(
        PricingRequest(
            leads=100,
            price_per_lead=20,
            expected_close_rate=0.1,
            revenue_per_conversion=500,
            email_cost_per_lead=0.5,
            labor_cost=200,
            other_cost=50,
            platform_fee_percent=10,
        )
    )

    assert result.billable_revenue == 2000
    assert result.expected_conversions == 10
    assert result.expected_downstream_revenue == 5000
    assert result.delivery_cost == 300
    assert result.platform_fee == 200
    assert result.total_cost == 500
    assert result.net_profit == 1500
    assert result.margin_percent == 75


def test_zero_revenue_has_zero_margin_instead_of_dividing_by_zero():
    result = calculate_pricing(PricingRequest(leads=10, price_per_lead=0, labor_cost=5))
    assert result.net_profit == -5
    assert result.margin_percent == 0
