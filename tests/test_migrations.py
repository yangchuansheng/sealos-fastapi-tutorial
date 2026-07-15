from io import StringIO
from pathlib import Path

from alembic import command
from alembic.config import Config
from sqlalchemy import Boolean, Integer, String, create_engine, inspect, text


PROJECT_ROOT = Path(__file__).resolve().parents[1]


def test_fresh_and_repeat_upgrade(
    test_database_url: str,
) -> None:
    output = StringIO()
    config = Config(PROJECT_ROOT / "alembic.ini", stdout=output)
    engine = create_engine(test_database_url, pool_pre_ping=True)

    try:
        command.downgrade(config, "base")
        assert "tasks" not in inspect(engine).get_table_names()

        command.upgrade(config, "head")
        command.upgrade(config, "head")
        command.current(config)

        assert "0001 (head)" in output.getvalue()
        with engine.connect() as connection:
            assert connection.execute(
                text("SELECT version_num FROM alembic_version")
            ).scalar_one() == "0001"

        inspector = inspect(engine)
        columns = {column["name"]: column for column in inspector.get_columns("tasks")}
        assert list(columns) == ["id", "title", "completed"]
        assert isinstance(columns["id"]["type"], Integer)
        assert columns["id"]["nullable"] is False
        assert columns["id"]["autoincrement"] is True
        assert isinstance(columns["title"]["type"], String)
        assert columns["title"]["type"].length == 200
        assert columns["title"]["nullable"] is False
        assert isinstance(columns["completed"]["type"], Boolean)
        assert columns["completed"]["nullable"] is False
        assert str(columns["completed"]["default"]).lower() in {
            "false",
            "false::boolean",
        }
        assert inspector.get_pk_constraint("tasks")["constrained_columns"] == ["id"]

        command.downgrade(config, "base")
        assert "tasks" not in inspect(engine).get_table_names()

        command.upgrade(config, "head")
        with engine.connect() as connection:
            assert connection.execute(
                text("SELECT version_num FROM alembic_version")
            ).scalar_one() == "0001"
    finally:
        engine.dispose()
