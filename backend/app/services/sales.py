from __future__ import annotations

from decimal import Decimal, ROUND_HALF_UP
from typing import Any, Iterable, Mapping

from ..models import PackageProfitResult, PackageRecommendationRequest


_CENT = Decimal("0.01")


def _decimal(value: Any) -> Decimal:
    return Decimal(str(value or 0))


def _money(value: Decimal) -> float:
    return float(value.quantize(_CENT, rounding=ROUND_HALF_UP))


def calculate_package_profit(
    package: Mapping[str, Any],
    *,
    months: int = 12,
    package_id: int | None = None,
) -> PackageProfitResult:
    """Calculate package economics using a fixed, auditable revenue/cost formula."""
    if months < 1:
        raise ValueError("months must be at least 1")

    setup_revenue = _decimal(package.get("setup_price"))
    hosting = _decimal(package.get("hosting_monthly_revenue"))
    maintenance = _decimal(package.get("maintenance_monthly_revenue"))
    upfront_cost = sum(
        (
            _decimal(package.get("delivery_labor_cost")),
            _decimal(package.get("ai_api_cost")),
            _decimal(package.get("domain_cost")),
            _decimal(package.get("database_cost")),
            _decimal(package.get("liability_cost")),
            _decimal(package.get("other_cost")),
        ),
        Decimal("0"),
    )
    monthly_recurring = hosting + maintenance
    period_revenue = setup_revenue + monthly_recurring * months
    upfront_profit = setup_revenue - upfront_cost
    period_profit = period_revenue - upfront_cost
    margin = (period_profit / period_revenue * Decimal("100")) if period_revenue else Decimal("0")

    return PackageProfitResult(
        package_id=package_id if package_id is not None else package.get("id"),
        setup_revenue=_money(setup_revenue),
        hosting_monthly_revenue=_money(hosting),
        maintenance_monthly_revenue=_money(maintenance),
        monthly_recurring_revenue=_money(monthly_recurring),
        upfront_cost=_money(upfront_cost),
        upfront_profit=_money(upfront_profit),
        first_year_revenue=_money(period_revenue),
        first_year_cost=_money(upfront_cost),
        first_year_profit=_money(period_profit),
        first_year_margin_percent=_money(margin),
        months=months,
    )


def recommend_packages(
    packages: Iterable[Mapping[str, Any]], request: PackageRecommendationRequest
) -> list[dict[str, Any]]:
    """Filter and rank active packages without random or external inputs."""
    eligible: list[tuple[Decimal, Decimal, Decimal, str, int, Mapping[str, Any]]] = []
    max_setup = _decimal(request.max_setup_price) if request.max_setup_price is not None else None
    max_monthly = _decimal(request.max_monthly_price) if request.max_monthly_price is not None else None
    minimum_profit = _decimal(request.minimum_first_year_profit)

    for package in packages:
        if not package.get("active", True):
            continue
        setup = _decimal(package.get("setup_price"))
        hosting = _decimal(package.get("hosting_monthly_revenue"))
        maintenance = _decimal(package.get("maintenance_monthly_revenue"))
        monthly = hosting + maintenance
        if max_setup is not None and setup > max_setup:
            continue
        if max_monthly is not None and monthly > max_monthly:
            continue
        if request.requires_hosting and hosting <= 0:
            continue
        if request.requires_maintenance and maintenance <= 0:
            continue
        profit = calculate_package_profit(package).first_year_profit
        profit_decimal = _decimal(profit)
        if profit_decimal < minimum_profit:
            continue
        package_id = int(package.get("id", 0))
        name = str(package.get("name", ""))
        eligible.append((profit_decimal, monthly, setup, name.casefold(), package_id, package))

    eligible.sort(key=lambda item: (-item[0], -item[1], item[2], item[3], item[4]))
    recommendations: list[dict[str, Any]] = []
    for _, monthly, _, _, package_id, package in eligible:
        result = dict(package)
        profit = calculate_package_profit(package, package_id=package_id)
        result["monthly_recurring_revenue"] = _money(monthly)
        result["first_year_profit"] = profit.first_year_profit
        result["first_year_margin_percent"] = profit.first_year_margin_percent
        recommendations.append(result)
    return recommendations
