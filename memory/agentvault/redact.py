"""Secret redaction. Every string is passed through redact() before it touches the vault."""
import re

_E = r"(?<![A-Za-z0-9_])"  # left edge: not in the middle of a word
_RULES = [
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"), None),
    ("anthropic", re.compile(_E + r"sk-ant-[A-Za-z0-9_\-]{20,}"), None),
    ("openai", re.compile(_E + r"sk-(?:proj-|svcacct-)?[A-Za-z0-9_\-]{32,}"), None),
    ("aws", re.compile(_E + r"(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9])"), None),
    ("github", re.compile(_E + r"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})"), None),
    ("google", re.compile(_E + r"AIza[0-9A-Za-z_\-]{30,}"), None),
    ("jwt", re.compile(_E + r"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"), None),
    # keep "Bearer " and replace only the token
    ("bearer", re.compile(r"(?i)(\bBearer\s+)[A-Za-z0-9._\-]{16,}"), 1),
    # keep `name = ` and replace only the value
    ("assignment", re.compile(r"(?i)(\b(?:password|passwd|secret|token|api[_-]?key)[\"']?\s*[=:]\s*[\"']?)[^\s\"',;]{8,}"), 1),
]

def redact(text: str) -> str:
    for kind, rx, keep in _RULES:
        mark = "[redacted:%s]" % kind
        text = rx.sub((lambda m, k=keep, mk=mark: m.group(k) + mk) if keep else mark, text)
    return text
