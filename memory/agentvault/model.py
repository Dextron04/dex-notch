from dataclasses import dataclass

@dataclass
class Turn:
    role: str   # "user" | "assistant" | "tool"
    text: str
    ts: str     # ISO-8601 UTC

@dataclass
class SessionMeta:
    agent: str
    session_id: str
    project: str
    cwd: str
    started: str
    title: str
    source_path: str
