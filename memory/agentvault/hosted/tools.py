"""Per-user tool dispatch: the existing single-owner handlers, run against the caller's own vault only."""
from .. import mcp_server, seal
from ..remote.tools import REMEMBER, REMIND, remember, remind
from . import ingest
from .store import Store

MAX_PENDING_REMINDERS = 1000

EXTRA = [REMEMBER, REMIND]

def call(store: Store, uid: str, name: str, args: dict) -> str:
    """Raises PermissionError for an unknown, canceled or deleted user, before any file is touched."""
    if not store.may_use(uid): raise PermissionError("subscription required")
    if store.encrypted(uid) and seal.current() is None: raise PermissionError("the vault is encrypted: connect this assistant again")
    vault = store.user_vault(uid)
    if name in ("remember", "remind"):  # the write paths that ingest's quota doesn't cover
        limit = store.quota(uid)
        if limit is not None and ingest.vault_bytes(vault) > limit: raise PermissionError("storage quota reached (%d MB); export or delete something first" % (limit >> 20))
        if name == "remind" and len(list((vault / "Reminders").glob("*.md"))) >= MAX_PENDING_REMINDERS: raise PermissionError("too many reminders (%d)" % MAX_PENDING_REMINDERS)
    if name == "remember": return remember(vault, args)
    if name == "remind": return remind(vault, args)
    return mcp_server.call(vault, name, args, semantic=False)
