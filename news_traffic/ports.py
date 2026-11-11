"""Explicit extension boundaries. No provider is implied to be connected."""
from typing import Protocol


class NewsCandidateExtractor(Protocol):
    def extract(self, article: dict) -> dict:
        """Only public article + provenance; must subsequently pass schemas.validate."""
        ...


class CalendarReadAdapter(Protocol):
    def read_schedules(self, user_id: str) -> list[dict]: ...


class RouteReadAdapter(Protocol):
    def read_trip(self, origin: dict, destination: dict, departure_at: str) -> dict: ...


class NotificationChannel(Protocol):
    def enqueue(self, db, user_id: str, result: dict, kind: str) -> None: ...


class InAppChannel:
    def enqueue(self, db, user_id, result, kind):
        import json
        db.execute('INSERT OR IGNORE INTO notifications VALUES(?,?,?,?,?,?,NULL)',
                   (user_id, result['schedule_id'], result['impact_id'], result['impact_version'], kind,
                    json.dumps(result, ensure_ascii=False, sort_keys=True)))
