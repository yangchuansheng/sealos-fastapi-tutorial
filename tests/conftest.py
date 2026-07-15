import os
from collections.abc import Generator

import pytest
from sqlalchemy import Engine, create_engine, text


@pytest.fixture(scope="session")
def test_database_url() -> str:
    database_url = os.environ.get("TEST_DATABASE_URL")
    if not database_url:
        raise pytest.UsageError(
            "TEST_DATABASE_URL is required; run tests through "
            "./scripts/test-postgres.sh"
        )
    return database_url


@pytest.fixture
def database_engine(test_database_url: str) -> Generator[Engine, None, None]:
    engine = create_engine(test_database_url, pool_pre_ping=True)
    try:
        yield engine
    finally:
        engine.dispose()


@pytest.fixture
def clean_tasks(database_engine: Engine) -> Generator[None, None, None]:
    with database_engine.begin() as connection:
        connection.execute(text("TRUNCATE TABLE tasks RESTART IDENTITY"))

    try:
        yield
    finally:
        with database_engine.begin() as connection:
            connection.execute(text("TRUNCATE TABLE tasks RESTART IDENTITY"))
