"""Per-user tool dispatch: the existing single-owner handlers, run against the caller's own vault only."""
from .. import mcp_server
from ..remote.tools import REMEMBER, REMIND, remember, remind
from .store import Store

EXTRA = [REMEMBER, REMIND]

def call(store: Store, uid: str, name: str, args: dict) -> str:
    """Raises PermissionError for an unknown or unpaid user, before any file is touched."""
    if not store.entitled(uid): raise PermissionError("subscription required")
    vault = store.user_vault(uid)
    if name == "remember": return remember(vault, args)
    if name == "remind": return remind(vault, args)
    return mcp_server.call(vault, name, args)
