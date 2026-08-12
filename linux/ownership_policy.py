"""Pure single-owner pairing policy for the BlueZ orchestrator."""

from __future__ import annotations

from enum import Enum


class OwnershipAction(Enum):
    OPEN_ONBOARDING = "open-onboarding"
    CLOSE_ONBOARDING = "close-onboarding"
    KEEP_STATE = "keep-state"


def ownership_action(*, bonded_devices: int, onboarding_open: bool) -> OwnershipAction:
    if bonded_devices < 0:
        raise ValueError("bonded device count cannot be negative")
    if bonded_devices > 0 and onboarding_open:
        return OwnershipAction.CLOSE_ONBOARDING
    if bonded_devices == 0 and not onboarding_open:
        return OwnershipAction.OPEN_ONBOARDING
    return OwnershipAction.KEEP_STATE
