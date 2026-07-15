import time
from pathlib import Path

from alembic import command
from alembic.config import Config
from fastapi.testclient import TestClient

from app.main import create_app


PROJECT_ROOT = Path(__file__).resolve().parents[1]
UNREADY_RESPONSE = {"detail": "Database is not ready"}


def test_health_waits_for_migrated_schema(
    test_database_url: str,
    monkeypatch,
) -> None:
    monkeypatch.setenv("DATABASE_URL", test_database_url)
    config = Config(PROJECT_ROOT / "alembic.ini")
    command.downgrade(config, "base")

    try:
        with TestClient(create_app(test_database_url)) as client:
            response = client.get("/health")

        assert response.status_code == 503, response.json()
        assert response.json() == UNREADY_RESPONSE
    finally:
        command.upgrade(config, "head")


def test_health_requires_database_configuration(monkeypatch) -> None:
    monkeypatch.delenv("DATABASE_URL", raising=False)

    with TestClient(create_app()) as client:
        response = client.get("/health")

    assert response.status_code == 503
    assert response.json() == UNREADY_RESPONSE


def test_health_rejects_unreachable_database() -> None:
    started_at = time.monotonic()
    unreachable_url = (
        "postgresql+psycopg://tasks:tasks@127.0.0.1:1/tasks"
    )

    with TestClient(create_app(unreachable_url)) as client:
        response = client.get("/health")

    assert time.monotonic() - started_at < 3
    assert response.status_code == 503
    assert response.json() == UNREADY_RESPONSE


def test_health_accepts_migrated_database(test_database_url: str) -> None:
    with TestClient(create_app(test_database_url)) as client:
        response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
