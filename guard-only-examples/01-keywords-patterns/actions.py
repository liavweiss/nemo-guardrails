import re
from nemoguardrails.actions import action

BLOCKED_PHRASES = [
    "bomb", "hack", "kill", "weapon", "steal", "illegal", "harmful",
    "how to make a bomb", "how to hack", "credit card", "password steal",
]

SENSITIVE_PATTERNS = [
    re.compile(r"\b\d{3}-\d{2}-\d{4}\b"),
    re.compile(r"\b\d{16}\b"),
    re.compile(r"my password is\s+\S+", re.I),
    re.compile(r"api[_\s]?key\s*[:=]\s*\S+", re.I),
]


@action()
def check_harmful_keywords(text: str) -> bool:
    if not text or not isinstance(text, str):
        return False
    return any(phrase in text.lower().strip() for phrase in BLOCKED_PHRASES)


@action()
def check_sensitive_patterns(text: str) -> bool:
    if not text or not isinstance(text, str):
        return False
    return any(p.search(text) for p in SENSITIVE_PATTERNS)


@action()
def check_output_harmful_keywords(text: str) -> bool:
    if not text or not isinstance(text, str):
        return False
    return any(phrase in text.lower().strip() for phrase in BLOCKED_PHRASES)
