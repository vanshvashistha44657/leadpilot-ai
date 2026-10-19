from __future__ import annotations

import secrets
from uuid import uuid4

from fastapi import Request
from fastapi.responses import JSONResponse
from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint
from starlette.responses import Response

from .config import Settings


PUBLIC_PATHS = {"/health/live", "/health/ready", "/docs", "/redoc", "/openapi.json"}


class LocalAuthMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, settings: Settings):
        super().__init__(app)
        self.settings = settings

    async def dispatch(self, request: Request, call_next: RequestResponseEndpoint) -> Response:
        host = (request.client.host if request.client else "").lower()
        is_local = host in {"127.0.0.1", "::1", "localhost", "testclient", ""} or host.startswith("127.")
        if self.settings.local_only and not is_local:
            return JSONResponse(status_code=403, content={"detail": "local access only"})
        if request.url.path not in PUBLIC_PATHS:
            token = request.headers.get("X-Local-Token", "")
            if not secrets.compare_digest(token, self.settings.local_token):
                return JSONResponse(status_code=401, content={"detail": "missing or invalid X-Local-Token"})
        response = await call_next(request)
        response.headers["X-Request-ID"] = request.state.request_id
        return response


class RequestIDMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next: RequestResponseEndpoint) -> Response:
        request.state.request_id = request.headers.get("X-Request-ID", str(uuid4()))
        return await call_next(request)
