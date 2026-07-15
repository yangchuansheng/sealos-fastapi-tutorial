from collections.abc import Generator

from sqlalchemy import Engine, create_engine
from sqlalchemy.orm import Session, sessionmaker


class DatabaseRuntime:
    def __init__(self, database_url: str | None) -> None:
        self.engine: Engine | None = None
        self.session_factory: sessionmaker[Session] | None = None

        if database_url is not None:
            self.engine = create_engine(database_url, pool_pre_ping=True)
            self.session_factory = sessionmaker(
                bind=self.engine,
                expire_on_commit=False,
            )

    def get_session(self) -> Generator[Session, None, None]:
        if self.session_factory is None:
            raise RuntimeError("DATABASE_URL is required")

        with self.session_factory() as session:
            yield session

    def dispose(self) -> None:
        if self.engine is not None:
            self.engine.dispose()
