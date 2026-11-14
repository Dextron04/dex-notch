"""Secret redaction. Every string is passed through redact() before it touches the vault.
Bias: a false positive costs a few characters of prose; a false negative puts a credential in a shared vault."""
import re

_E = r"(?<![A-Za-z0-9_])"  # left edge: not in the middle of a word
_KW = r"(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)"
_RULES = [
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)"), None),
    ("anthropic", re.compile(_E + r"sk-ant-[A-Za-z0-9_\-]{20,}"), None),
    ("openai", re.compile(_E + r"sk-(?:proj-|svcacct-)?[A-Za-z0-9_\-]{32,}"), None),
    ("stripe", re.compile(_E + r"(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}"), None),
    ("slack", re.compile(_E + r"xox[abprs]-[A-Za-z0-9\-]{10,}"), None),
    ("huggingface", re.compile(_E + r"hf_[A-Za-z0-9]{30,}"), None),
    ("gitlab", re.compile(_E + r"glpat-[A-Za-z0-9_\-]{20,}"), None),
    ("npm", re.compile(_E + r"npm_[A-Za-z0-9]{30,}"), None),
    ("aws", re.compile(_E + r"(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9])"), None),
    ("github", re.compile(_E + r"(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})"), None),
    ("google", re.compile(_E + r"AIza[0-9A-Za-z_\-]{30,}"), None),
    ("jwt", re.compile(_E + r"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"), None),
    # scheme://user:pass@host  -> keep the scheme and host
    ("url-credentials", re.compile(r"(?<=://)[^/\s:@]+:[^/\s@]+(?=@)"), None),
    # keep the leading flag/scheme word, replace only the secret that follows
    ("bearer", re.compile(r"(?i)(\bBearer\s+)[A-Za-z0-9._\-]{16,}"), 1),
    ("basic", re.compile(r"(?i)(\bBasic\s+)[A-Za-z0-9+/=]{12,}"), 1),
    ("basic-auth", re.compile(r"(\s-u\s+)[^\s:]+:\S+"), 1),
    ("cli-secret", re.compile(r"(\s-w\s+)[^\s\[]{8,}"), 1),
    # NAME=value / "name": "value" where the NAME merely CONTAINS password/secret/token/api_key/...: DB_PASSWORD, GITHUB_TOKEN
    ("assignment", re.compile(r"(?i)((?<![A-Za-z0-9])[A-Za-z0-9_.\-]{0,40}" + _KW + r"[A-Za-z0-9_\-]*[\"']?\s*[=:]\s*[\"']?)[^\s\"',;]{8,}"), 1),
]

def redact(text: str) -> str:
    for kind, rx, keep in _RULES:
        mark = "[redacted:%s]" % kind
        text = rx.sub((lambda m, k=keep, mk=mark: m.group(k) + mk) if keep else mark, text)
    return text
