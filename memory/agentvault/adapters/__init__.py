from .claude_code import ClaudeCodeAdapter
from .codex import CodexAdapter
from .gemini import GeminiAdapter

def default_adapters():
    return [ClaudeCodeAdapter(), CodexAdapter(), GeminiAdapter()]
