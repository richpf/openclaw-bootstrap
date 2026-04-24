"""
key_validators.py — validate API keys by probing provider endpoints.

All validators return (ok: bool, message: str).
They do NOT raise on soft failures (wrong key) — they return ok=False.
They DO raise on network/configuration errors unless catch_errors=True.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from typing import Callable, Optional, Tuple

ValidationResult = Tuple[bool, str]


# ---------------------------------------------------------------------------
# HTTP helpers (no third-party libs — just stdlib)
# ---------------------------------------------------------------------------

def _http_get(url: str, headers: dict) -> Tuple[int, str]:
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode(errors="replace")


def _http_post(url: str, headers: dict, body: bytes) -> Tuple[int, str]:
    req = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status, resp.read().decode(errors="replace")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode(errors="replace")


# ---------------------------------------------------------------------------
# Anthropic
# ---------------------------------------------------------------------------

def validate_anthropic_key(api_key: str) -> ValidationResult:
    """
    Validate an Anthropic API key.

    Strategy: POST a minimal 1-token request.  We expect either:
      - 200 (success — key valid, charges ~$0.000003)
      - 401 (invalid key)
      - 400 (bad request but key recognised — treat as valid)
    Any other HTTP error → invalid.
    """
    if not api_key or not api_key.strip():
        return False, "Empty key"

    url = "https://api.anthropic.com/v1/messages"
    headers = {
        "x-api-key": api_key.strip(),
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
    }
    body = json.dumps({
        "model": "claude-haiku-20240307",
        "max_tokens": 1,
        "messages": [{"role": "user", "content": "hi"}],
    }).encode()

    try:
        status, text = _http_post(url, headers, body)
    except Exception as exc:
        return False, f"Network error: {exc}"

    if status in (200, 400):
        return True, f"OK (HTTP {status})"
    if status == 401:
        return False, "Invalid API key (401 Unauthorized)"
    if status == 529:
        # Anthropic overloaded — treat as valid key (infrastructure issue)
        return True, "Anthropic overloaded (529) — key assumed valid"
    return False, f"Unexpected HTTP {status}: {text[:200]}"


# ---------------------------------------------------------------------------
# OpenRouter
# ---------------------------------------------------------------------------

def validate_openrouter_key(api_key: str) -> ValidationResult:
    """
    Validate an OpenRouter API key via GET /api/v1/auth/key.
    Returns ok=True if the response contains a valid key info object.
    """
    if not api_key or not api_key.strip():
        return False, "Empty key"

    url = "https://openrouter.ai/api/v1/auth/key"
    headers = {
        "Authorization": f"Bearer {api_key.strip()}",
        "Content-Type": "application/json",
    }

    try:
        status, text = _http_get(url, headers)
    except Exception as exc:
        return False, f"Network error: {exc}"

    if status == 200:
        try:
            data = json.loads(text)
            label = data.get("data", {}).get("label") or data.get("label") or "unknown"
            return True, f"OK — label={label}"
        except json.JSONDecodeError:
            return True, "OK (non-JSON body)"
    if status == 401:
        return False, "Invalid API key (401)"
    return False, f"Unexpected HTTP {status}: {text[:200]}"


# ---------------------------------------------------------------------------
# Telegram
# ---------------------------------------------------------------------------

def validate_telegram_token(bot_token: str) -> ValidationResult:
    """
    Validate a Telegram bot token via getMe.
    Returns ok=True if the bot responds with its own info.
    """
    if not bot_token or not bot_token.strip():
        return False, "Empty token"

    url = f"https://api.telegram.org/bot{bot_token.strip()}/getMe"
    headers = {"Content-Type": "application/json"}

    try:
        status, text = _http_get(url, headers)
    except Exception as exc:
        return False, f"Network error: {exc}"

    if status == 200:
        try:
            data = json.loads(text)
            if data.get("ok"):
                username = data["result"].get("username", "unknown")
                return True, f"OK — @{username}"
        except json.JSONDecodeError:
            pass
        return False, f"Unexpected body: {text[:200]}"
    if status == 401:
        return False, "Invalid bot token (401)"
    return False, f"Unexpected HTTP {status}: {text[:200]}"


# ---------------------------------------------------------------------------
# Generic optional key (no validation — just non-empty check)
# ---------------------------------------------------------------------------

def validate_optional_key(api_key: str, name: str = "key") -> ValidationResult:
    """For optional keys — just check non-empty, no network call."""
    if not api_key or not api_key.strip():
        return False, f"{name} is empty (skipped)"
    return True, f"{name} provided (not validated)"
