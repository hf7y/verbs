"""Token path for a future GitHub App identity (#34, part 2 -- the
durable fix; provenance.py's stamp is the part that works today without
any App).

App private key --sign--> JWT --exchange--> installation access token
--used by--> `gh` (via GH_TOKEN) and `git` (as the Basic-auth password,
any username, over HTTPS). Installation tokens last 1 hour; TokenCache
refreshes ahead of expiry so a long overnight run never hands out a
token that dies mid-call.

Nothing in this module talks to GitHub except `mint_installation_token`,
and nothing here ever reads a real private key -- the App does not exist
yet (creating it needs a browser session under Zach's account; see the
runbook in .claude/GITHUB_APP_RUNBOOK.md). Tests exercise this against a
throwaway RSA key generated at test time and a stubbed HTTP call, never
a real GitHub App or a real key.

Where the key lives: a mode-600 PEM file OUTSIDE any repo (e.g.
~/.config/vim-arcade/github-app.pem), path given via the
VIM_ARCADE_GITHUB_APP_KEY env var -- never committed, never hardcoded.
"""

import json
import os
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

API_BASE = "https://api.github.com"

# Path to the App's PEM private key. Deliberately NOT a repo-relative
# default -- there is no safe default inside a repo, so this must be set
# explicitly by whoever runs anything in this module for real.
KEY_PATH_ENV = "VIM_ARCADE_GITHUB_APP_KEY"

# GitHub caps App JWT expiry at 10 minutes. Default TTL leaves margin.
_MAX_JWT_TTL_SECONDS = 600
_DEFAULT_JWT_TTL_SECONDS = 540
_CLOCK_SKEW_BACKDATE_SECONDS = 60


class GithubAppAuthError(RuntimeError):
    """Raised, never swallowed -- a missing key, a bad key, or a rejected
    token request must fail loud, not silently fall back to Zach's own
    token (which would defeat the entire point of a distinct identity)."""


def load_private_key(path: Optional[Path] = None) -> bytes:
    """Read the App's PEM private key from `path`, or from
    $VIM_ARCADE_GITHUB_APP_KEY if not given. Refuses a group/world
    readable file -- a GitHub App private key is exactly the kind of
    secret this ecosystem's build discipline says must never leak into a
    tracked file or a loosely-permissioned one."""
    if path is None:
        env_path = os.environ.get(KEY_PATH_ENV)
        if not env_path:
            raise GithubAppAuthError(
                f"no private key path given, and ${KEY_PATH_ENV} is not set. "
                "Point it at the App's PEM file, kept outside any repo, e.g. "
                "~/.config/vim-arcade/github-app.pem (mode 600)."
            )
        path = Path(env_path)
    path = Path(path)
    if not path.exists():
        raise GithubAppAuthError(f"GitHub App private key not found at {path}")
    mode = path.stat().st_mode & 0o777
    if mode & 0o077:
        raise GithubAppAuthError(
            f"{path} is group/world readable (mode {oct(mode)}) -- chmod 600 it. "
            "A GitHub App private key must never be readable by anyone but its owner."
        )
    return path.read_bytes()


def _b64url(data: bytes) -> str:
    import base64

    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def build_jwt(
    app_id: str,
    private_key_pem: bytes,
    now: Optional[int] = None,
    ttl_seconds: int = _DEFAULT_JWT_TTL_SECONDS,
) -> str:
    """A GitHub App JWT (RS256), signed with the App's private key --
    this is what authenticates as the APP (not yet a specific
    installation) to mint an installation access token. `now` is an
    epoch-seconds override for tests; real callers leave it None."""
    if ttl_seconds <= 0 or ttl_seconds > _MAX_JWT_TTL_SECONDS:
        raise ValueError(
            f"ttl_seconds must be in (0, {_MAX_JWT_TTL_SECONDS}] -- GitHub caps App JWT "
            "expiry at 10 minutes"
        )
    if not app_id:
        raise ValueError("app_id must be non-empty")

    try:
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import padding
    except ImportError as exc:  # pragma: no cover - environment-dependent
        raise GithubAppAuthError(
            "the 'cryptography' package is required to mint a GitHub App JWT "
            "(pip install cryptography)"
        ) from exc

    epoch_now = int(time.time()) if now is None else int(now)
    header = {"alg": "RS256", "typ": "JWT"}
    payload = {
        "iat": epoch_now - _CLOCK_SKEW_BACKDATE_SECONDS,
        "exp": epoch_now + ttl_seconds,
        "iss": app_id,
    }
    signing_input = (
        f"{_b64url(json.dumps(header, separators=(',', ':')).encode())}."
        f"{_b64url(json.dumps(payload, separators=(',', ':')).encode())}"
    )
    try:
        key = serialization.load_pem_private_key(private_key_pem, password=None)
    except ValueError as exc:
        raise GithubAppAuthError(f"private key could not be parsed: {exc}") from exc
    signature = key.sign(signing_input.encode("ascii"), padding.PKCS1v15(), hashes.SHA256())
    return f"{signing_input}.{_b64url(signature)}"


@dataclass(frozen=True)
class InstallationToken:
    token: str
    expires_at: str  # ISO8601, exactly as GitHub returned it


def _parse_github_timestamp(value: str) -> float:
    # GitHub returns e.g. "2026-08-04T23:00:00Z".
    dt = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    return dt.timestamp()


def mint_installation_token(
    app_jwt: str, installation_id: str, api_base: str = API_BASE
) -> InstallationToken:
    """Exchange an App JWT for a token scoped to one installation (one
    account/org the App is installed on). This is the token `gh`/`git`
    actually use -- the App JWT itself is never handed to them."""
    if not installation_id:
        raise ValueError("installation_id must be non-empty")
    req = urllib.request.Request(
        f"{api_base}/app/installations/{installation_id}/access_tokens",
        method="POST",
        headers={
            "Authorization": f"Bearer {app_jwt}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            data = json.loads(resp.read())
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:300]
        raise GithubAppAuthError(
            f"GitHub rejected the installation-token request: {exc.code} {detail}"
        ) from exc
    except urllib.error.URLError as exc:
        raise GithubAppAuthError(f"could not reach GitHub to mint an installation token: {exc}") from exc
    return InstallationToken(token=data["token"], expires_at=data["expires_at"])


class TokenCache:
    """Refresh-on-expiry cache for one installation's access token.
    Installation tokens last 1 hour; this mints a fresh one whenever the
    cached one is within `margin_seconds` of expiring (or missing), so a
    long-running caller never hands `gh`/`git` a token that dies
    mid-call. `jwt_builder`/`minter` are injectable so tests can stub the
    network and the signing call independently."""

    def __init__(
        self,
        app_id: str,
        private_key_pem: bytes,
        installation_id: str,
        *,
        margin_seconds: int = 120,
        api_base: str = API_BASE,
        clock: Callable[[], float] = time.time,
        jwt_builder: Callable[..., str] = build_jwt,
        minter: Callable[..., InstallationToken] = mint_installation_token,
    ):
        self._app_id = app_id
        self._key = private_key_pem
        self._installation_id = installation_id
        self._margin = margin_seconds
        self._api_base = api_base
        self._clock = clock
        self._jwt_builder = jwt_builder
        self._minter = minter
        self._token: Optional[InstallationToken] = None
        self._expires_epoch: Optional[float] = None

    def get_token(self) -> str:
        now = self._clock()
        if (
            self._token is None
            or self._expires_epoch is None
            or now >= self._expires_epoch - self._margin
        ):
            app_jwt = self._jwt_builder(self._app_id, self._key, now=int(now))
            self._token = self._minter(app_jwt, self._installation_id, api_base=self._api_base)
            self._expires_epoch = _parse_github_timestamp(self._token.expires_at)
        return self._token.token
