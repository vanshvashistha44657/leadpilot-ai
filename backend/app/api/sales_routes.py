from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query

from ..dependencies import Services, get_services
from ..models import (
    FollowUpOut,
    FollowUpQueueRequest,
    PackageProfitRequest,
    PackageProfitResult,
    PackageRecommendationRequest,
    PackageRecommendationOut,
    PackageRecommendationResponse,
    PaymentCreate,
    PaymentOut,
    PaymentStatusUpdate,
    ProposalCreate,
    ProposalOut,
    ProposalStatusUpdate,
    RenewalCreate,
    RenewalOut,
    RenewalStatusUpdate,
    WebsitePackageCreate,
    WebsitePackageOut,
)
from ..services.sales import calculate_package_profit, recommend_packages


router = APIRouter()
ServiceDep = Annotated[Services, Depends(get_services)]


@router.post("/api/packages", response_model=WebsitePackageOut, status_code=201, tags=["sales"])
def create_package(payload: WebsitePackageCreate, services: ServiceDep) -> WebsitePackageOut:
    result = services.packages.create(payload.model_dump())
    services.audit.record("package.created", "local", {"package_id": result["id"]})
    return WebsitePackageOut.model_validate(result)


@router.get("/api/packages", response_model=list[WebsitePackageOut], tags=["sales"])
def list_packages(
    services: ServiceDep,
    include_inactive: bool = Query(default=False),
) -> list[WebsitePackageOut]:
    return [
        WebsitePackageOut.model_validate(row)
        for row in services.packages.list(include_inactive=include_inactive)
    ]


@router.post("/api/packages/recommend", response_model=PackageRecommendationResponse, tags=["sales"])
def recommend_website_packages(
    payload: PackageRecommendationRequest,
    services: ServiceDep,
) -> PackageRecommendationResponse:
    recommendations = recommend_packages(services.packages.list(), payload)
    return PackageRecommendationResponse(
        recommendations=[
            # The recommendation model intentionally includes the package's financial inputs
            # so an operator can audit the deterministic ranking.
            PackageRecommendationOut.model_validate(row)
            for row in recommendations
        ]
    )


@router.post("/api/packages/profit", response_model=PackageProfitResult, tags=["sales"])
def calculate_package_profit_request(payload: PackageProfitRequest) -> PackageProfitResult:
    values = payload.model_dump(exclude={"months", "name", "description", "active"})
    return calculate_package_profit(values, months=payload.months)


@router.post("/api/packages/{package_id}/profit", response_model=PackageProfitResult, tags=["sales"])
def package_profit(
    package_id: int,
    services: ServiceDep,
    months: int = Query(default=12, ge=1, le=120),
) -> PackageProfitResult:
    package = services.packages.get(package_id)
    if not package:
        raise HTTPException(status_code=404, detail="package not found")
    return calculate_package_profit(package, months=months, package_id=package_id)


@router.post("/api/proposals", response_model=ProposalOut, status_code=201, tags=["sales"])
def create_proposal(payload: ProposalCreate, services: ServiceDep) -> ProposalOut:
    if not services.clients.get(payload.client_id):
        raise HTTPException(status_code=404, detail="client not found")
    values = payload.model_dump()
    if payload.package_id is not None:
        package = services.packages.get(payload.package_id)
        if not package:
            raise HTTPException(status_code=404, detail="package not found")
        values["amount"] = package["setup_price"] if payload.amount is None else payload.amount
        values["recurring_amount"] = (
            package["hosting_monthly_revenue"] + package["maintenance_monthly_revenue"]
            if payload.recurring_amount is None
            else payload.recurring_amount
        )
        for field in (
            "hosting_monthly_revenue",
            "maintenance_monthly_revenue",
            "delivery_labor_cost",
            "ai_api_cost",
            "domain_cost",
            "database_cost",
            "liability_cost",
            "other_cost",
        ):
            if values[field] is None:
                values[field] = package[field]
    else:
        values["amount"] = payload.amount or 0
        values["recurring_amount"] = payload.recurring_amount or 0
        for field in (
            "hosting_monthly_revenue",
            "maintenance_monthly_revenue",
            "delivery_labor_cost",
            "ai_api_cost",
            "domain_cost",
            "database_cost",
            "liability_cost",
            "other_cost",
        ):
            values[field] = values[field] or 0
    result = services.proposals.create(values)
    services.audit.record("proposal.created", "local", {"proposal_id": result["id"]})
    return ProposalOut.model_validate(result)


@router.get("/api/proposals", response_model=list[ProposalOut], tags=["sales"])
def list_proposals(
    services: ServiceDep,
    client_id: int | None = Query(default=None, gt=0),
    limit: int = Query(default=100, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
) -> list[ProposalOut]:
    return [
        ProposalOut.model_validate(row)
        for row in services.proposals.list(client_id=client_id, limit=limit, offset=offset)
    ]


@router.patch("/api/proposals/{proposal_id}/status", response_model=ProposalOut, tags=["sales"])
def update_proposal_status(
    proposal_id: int,
    payload: ProposalStatusUpdate,
    services: ServiceDep,
) -> ProposalOut:
    result = services.proposals.set_status(proposal_id, payload.status)
    if not result:
        raise HTTPException(status_code=404, detail="proposal not found")
    return ProposalOut.model_validate(result)


@router.post("/api/payments", response_model=PaymentOut, status_code=201, tags=["sales"])
def create_payment(payload: PaymentCreate, services: ServiceDep) -> PaymentOut:
    if not services.clients.get(payload.client_id):
        raise HTTPException(status_code=404, detail="client not found")
    if payload.proposal_id is not None:
        proposal = services.proposals.get(payload.proposal_id)
        if not proposal:
            raise HTTPException(status_code=404, detail="proposal not found")
        if proposal["client_id"] != payload.client_id:
            raise HTTPException(status_code=422, detail="proposal does not belong to client")
    result = services.payments.create(payload.model_dump())
    services.audit.record("payment.created", "local", {"payment_id": result["id"]})
    return PaymentOut.model_validate(result)


@router.get("/api/payments", response_model=list[PaymentOut], tags=["sales"])
def list_payments(
    services: ServiceDep,
    client_id: int | None = Query(default=None, gt=0),
    limit: int = Query(default=100, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
) -> list[PaymentOut]:
    return [
        PaymentOut.model_validate(row)
        for row in services.payments.list(client_id=client_id, limit=limit, offset=offset)
    ]


@router.patch("/api/payments/{payment_id}/status", response_model=PaymentOut, tags=["sales"])
def update_payment_status(
    payment_id: int,
    payload: PaymentStatusUpdate,
    services: ServiceDep,
) -> PaymentOut:
    result = services.payments.set_status(payment_id, payload.status, payload.paid_at)
    if not result:
        raise HTTPException(status_code=404, detail="payment not found")
    return PaymentOut.model_validate(result)


@router.post("/api/renewals", response_model=RenewalOut, status_code=201, tags=["sales"])
def create_renewal(payload: RenewalCreate, services: ServiceDep) -> RenewalOut:
    if not services.clients.get(payload.client_id):
        raise HTTPException(status_code=404, detail="client not found")
    if payload.project_id is not None:
        with services.database.session() as connection:
            project = connection.execute(
                "SELECT client_id FROM projects WHERE id = ?", (payload.project_id,)
            ).fetchone()
        if not project:
            raise HTTPException(status_code=404, detail="project not found")
        if project["client_id"] != payload.client_id:
            raise HTTPException(status_code=422, detail="project does not belong to client")
    result = services.renewals.create(payload.model_dump())
    services.audit.record("renewal.created", "local", {"renewal_id": result["id"]})
    return RenewalOut.model_validate(result)


@router.get("/api/renewals", response_model=list[RenewalOut], tags=["sales"])
def list_renewals(
    services: ServiceDep,
    client_id: int | None = Query(default=None, gt=0),
    limit: int = Query(default=100, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
) -> list[RenewalOut]:
    return [
        RenewalOut.model_validate(row)
        for row in services.renewals.list(client_id=client_id, limit=limit, offset=offset)
    ]


@router.patch("/api/renewals/{renewal_id}/status", response_model=RenewalOut, tags=["sales"])
def update_renewal_status(
    renewal_id: int,
    payload: RenewalStatusUpdate,
    services: ServiceDep,
) -> RenewalOut:
    result = services.renewals.set_status(renewal_id, payload.status)
    if not result:
        raise HTTPException(status_code=404, detail="renewal not found")
    return RenewalOut.model_validate(result)


@router.post("/api/follow-ups/queue", response_model=list[FollowUpOut], status_code=201, tags=["follow-ups"])
def queue_follow_ups(payload: FollowUpQueueRequest, services: ServiceDep) -> list[FollowUpOut]:
    try:
        result = services.followups.queue(payload)
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    services.audit.record(
        "follow_up.queued",
        "local",
        {"campaign_id": payload.campaign_id, "queued": len(result), "dry_run": True},
    )
    return [FollowUpOut.model_validate(row) for row in result]


@router.get("/api/follow-ups", response_model=list[FollowUpOut], tags=["follow-ups"])
def list_follow_ups(
    services: ServiceDep,
    status: str | None = Query(default=None, max_length=40),
    limit: int = Query(default=100, ge=1, le=1000),
    offset: int = Query(default=0, ge=0),
) -> list[FollowUpOut]:
    return [
        FollowUpOut.model_validate(row)
        for row in services.follow_ups.list(status=status, limit=limit, offset=offset)
    ]
