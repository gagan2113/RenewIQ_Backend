"""Shared API response helpers for consistent frontend-facing envelopes."""

from __future__ import annotations

from typing import Any, Dict, Optional


def success_response(data: Any = None, message: str = "Success") -> Dict[str, Any]:
    return {
        "success": True,
        "message": message,
        "data": data,
        "error": None,
    }


def error_response(
    message: str,
    code: str,
    details: Optional[Any] = None,
    data: Any = None,
) -> Dict[str, Any]:
    return {
        "success": False,
        "message": message,
        "data": data,
        "error": {
            "code": code,
            "details": details or {},
        },
    }
