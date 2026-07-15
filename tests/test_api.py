import pytest
from fastapi.testclient import TestClient

from app.main import create_app


@pytest.fixture
def client() -> TestClient:
    return TestClient(create_app())


def test_health_is_public(client: TestClient) -> None:
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_swagger_ui_is_public(client: TestClient) -> None:
    response = client.get("/docs")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    assert "Swagger UI" in response.text


def test_create_task(client: TestClient) -> None:
    response = client.post("/tasks", json={"title": "Write tutorial"})

    assert response.status_code == 201
    assert response.json() == {
        "id": 1,
        "title": "Write tutorial",
        "completed": False,
    }
