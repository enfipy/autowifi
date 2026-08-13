"""Credential-to-connection orchestration independent of D-Bus bindings."""

from __future__ import annotations

from collections import OrderedDict
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Protocol

from autowifi_protocol import NetworkCredential, StatusMessage


ActivationFinished = Callable[[str | None], None]
StatusUpdated = Callable[[StatusMessage], None]


class ActivationBackend(Protocol):
    def activate(
        self,
        settings: dict,
        finished: ActivationFinished,
    ) -> None: ...


@dataclass
class _Request:
    status: StatusMessage
    subscribers: list[StatusUpdated] = field(default_factory=list)


class NetworkManagerAdapter:
    """Turn one validated credential into an asynchronous connection result."""

    def __init__(self, backend: ActivationBackend) -> None:
        self.backend = backend
        self.requests: OrderedDict[str, _Request] = OrderedDict()

    def activate(self, credential: NetworkCredential, update: StatusUpdated) -> None:
        existing = self.requests.get(credential.request_id)
        if existing is not None:
            update(existing.status)
            if existing.status.state == "connecting":
                existing.subscribers.append(update)
            return

        connecting = StatusMessage(credential.request_id, "connecting")
        request = _Request(connecting, [update])
        self.requests[credential.request_id] = request
        self._trim_completed_requests()
        update(connecting)

        def finished(error: str | None) -> None:
            if error is None:
                request.status = StatusMessage(credential.request_id, "connected")
            else:
                request.status = StatusMessage(credential.request_id, "failed", error)
            for subscriber in request.subscribers:
                subscriber(request.status)
            request.subscribers.clear()

        self.backend.activate(credential.networkmanager_settings(), finished)

    def _trim_completed_requests(self) -> None:
        while len(self.requests) > 32:
            request_id, request = next(iter(self.requests.items()))
            if request.status.state == "connecting":
                break
            del self.requests[request_id]
