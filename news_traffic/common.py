import hashlib
import json
from datetime import datetime, timezone, timedelta
from pathlib import Path

ROOT = Path(__file__).parent
CONFIG = json.loads((ROOT / 'config.json').read_text(encoding='utf-8'))
KST = timezone(timedelta(hours=9))


def now():
    return datetime.now(KST).isoformat()


def dt(value):
    result = datetime.fromisoformat(value)
    if result.tzinfo is None:
        raise ValueError('offset datetime required')
    return result


def digest(value):
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()[:24]


class DomainError(ValueError):
    def __init__(self, code, detail=''):
        super().__init__(detail or code)
        self.code = code
