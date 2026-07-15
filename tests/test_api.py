from collections.abc import Generator

import pytest
from fastapi.testclient import TestClient

from app.main import create_app


@pytest.fixture
def client(
    test_database_url: str,
    clean_tasks: None,
) -> Generator[TestClient, None, None]:
    with TestClient(create_app(test_database_url)) as test_client:
        yield test_client


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


def test_task_survives_application_instances(
    test_database_url: str,
    clean_tasks: None,
) -> None:
    with TestClient(create_app(test_database_url)) as first_client:
        created = first_client.post("/tasks", json={"title": "Write tutorial"})

    assert created.status_code == 201
    assert created.json() == {
        "id": 1,
        "title": "Write tutorial",
        "completed": False,
    }

    with TestClient(create_app(test_database_url)) as second_client:
        response = second_client.get(f"/tasks/{created.json()['id']}")

    assert response.status_code == 200, response.json()
    assert response.json() == created.json()


def test_list_tasks(client: TestClient) -> None:
    created = client.post("/tasks", json={"title": "Write tutorial"})

    response = client.get("/tasks")

    assert response.status_code == 200
    assert response.json() == [created.json()]


def test_list_includes_tasks_from_another_application(
    test_database_url: str,
    clean_tasks: None,
) -> None:
    expected = {
        "id": 1,
        "title": "Write tutorial",
        "completed": False,
    }
    with TestClient(create_app(test_database_url)) as first_client:
        created = first_client.post("/tasks", json={"title": expected["title"]})

    assert created.status_code == 201
    assert created.json() == expected

    with TestClient(create_app(test_database_url)) as second_client:
        response = second_client.get("/tasks")

    assert response.status_code == 200
    assert response.json() == [expected]


def test_get_task(client: TestClient) -> None:
    created = client.post("/tasks", json={"title": "Write tutorial"})
    task_id = created.json()["id"]

    response = client.get(f"/tasks/{task_id}")

    assert response.status_code == 200
    assert response.json() == created.json()


def test_update_task(client: TestClient) -> None:
    created = client.post("/tasks", json={"title": "Write tutorial"})
    task_id = created.json()["id"]
    replacement = {"title": "Publish tutorial", "completed": True}

    response = client.put(f"/tasks/{task_id}", json=replacement)

    assert response.status_code == 200
    assert response.json() == {"id": task_id, **replacement}
    assert client.get(f"/tasks/{task_id}").json() == response.json()


def test_task_update_survives_application_instances(
    test_database_url: str,
    clean_tasks: None,
) -> None:
    replacement = {"title": "Publish tutorial", "completed": True}
    with TestClient(create_app(test_database_url)) as first_client:
        created = first_client.post("/tasks", json={"title": "Write tutorial"})

    assert created.status_code == 201
    task_id = created.json()["id"]

    with TestClient(create_app(test_database_url)) as second_client:
        response = second_client.put(f"/tasks/{task_id}", json=replacement)

    assert response.status_code == 200, response.json()
    assert response.json() == {"id": task_id, **replacement}

    with TestClient(create_app(test_database_url)) as third_client:
        persisted = third_client.get(f"/tasks/{task_id}")

    assert persisted.status_code == 200
    assert persisted.json() == response.json()


def test_delete_task(client: TestClient) -> None:
    created = client.post("/tasks", json={"title": "Write tutorial"})
    task_id = created.json()["id"]

    response = client.delete(f"/tasks/{task_id}")

    assert response.status_code == 204
    assert response.content == b""
    assert client.get(f"/tasks/{task_id}").status_code == 404


def test_task_deletion_survives_application_instances(
    test_database_url: str,
    clean_tasks: None,
) -> None:
    with TestClient(create_app(test_database_url)) as first_client:
        created = first_client.post("/tasks", json={"title": "Write tutorial"})

    assert created.status_code == 201
    task_id = created.json()["id"]

    with TestClient(create_app(test_database_url)) as second_client:
        response = second_client.delete(f"/tasks/{task_id}")

    assert response.status_code == 204, response.json()
    assert response.content == b""

    with TestClient(create_app(test_database_url)) as third_client:
        missing = third_client.get(f"/tasks/{task_id}")

    assert missing.status_code == 404
    assert missing.json() == {"detail": "Task not found"}


@pytest.mark.parametrize("title", ["", "x" * 201])
def test_reject_invalid_task(client: TestClient, title: str) -> None:
    response = client.post("/tasks", json={"title": title})

    assert response.status_code == 422


@pytest.mark.parametrize("title", ["", "x" * 201])
def test_reject_invalid_task_update(client: TestClient, title: str) -> None:
    created = client.post("/tasks", json={"title": "Write tutorial"})
    task_id = created.json()["id"]

    response = client.put(
        f"/tasks/{task_id}",
        json={"title": title, "completed": True},
    )

    assert response.status_code == 422
    assert client.get(f"/tasks/{task_id}").json() == created.json()


@pytest.mark.parametrize(
    ("method", "payload"),
    [
        ("GET", None),
        ("PUT", {"title": "Unknown task", "completed": False}),
        ("DELETE", None),
    ],
)
def test_missing_task_returns_404(
    client: TestClient,
    method: str,
    payload: dict[str, object] | None,
) -> None:
    request_kwargs = {"json": payload} if payload is not None else {}

    response = client.request(method, "/tasks/999", **request_kwargs)

    assert response.status_code == 404
    assert response.json() == {"detail": "Task not found"}
