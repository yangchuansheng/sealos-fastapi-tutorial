import logging
import os
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Response
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.database import DatabaseRuntime
from app.models import TaskRecord

__all__ = ["Task", "TaskCreate", "TaskUpdate", "app", "create_app"]

logger = logging.getLogger(__name__)


class TaskCreate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    completed: bool = False


class TaskUpdate(BaseModel):
    title: str = Field(min_length=1, max_length=200)
    completed: bool


class Task(BaseModel):
    id: int
    title: str
    completed: bool


def create_app(database_url: str | None = None) -> FastAPI:
    runtime = DatabaseRuntime(database_url or os.environ.get("DATABASE_URL"))

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        logger.info(
            "event=service_start source_release=%s image_reference=%s",
            os.environ.get("SOURCE_RELEASE", "unknown"),
            os.environ.get("IMAGE_REFERENCE", "unknown"),
        )
        try:
            yield
        finally:
            runtime.dispose()

    application = FastAPI(
        title="Tasks API",
        version="0.1.0",
        lifespan=lifespan,
    )

    @application.get("/health")
    def health() -> dict[str, str]:
        readiness_issue = runtime.readiness_issue()
        if readiness_issue is not None:
            logger.warning("Database readiness failed: %s", readiness_issue)
            raise HTTPException(
                status_code=503,
                detail="Database is not ready",
            )
        return {"status": "ok"}

    @application.post("/tasks", response_model=Task, status_code=201)
    def create_task(
        payload: TaskCreate,
        session: Session = Depends(runtime.get_session),
    ) -> Task:
        record = TaskRecord(**payload.model_dump())
        session.add(record)
        session.commit()
        session.refresh(record)
        return Task(
            id=record.id,
            title=record.title,
            completed=record.completed,
        )

    @application.get("/tasks", response_model=list[Task])
    def list_tasks(
        session: Session = Depends(runtime.get_session),
    ) -> list[Task]:
        records = session.scalars(select(TaskRecord).order_by(TaskRecord.id)).all()
        return [
            Task(
                id=record.id,
                title=record.title,
                completed=record.completed,
            )
            for record in records
        ]

    @application.get("/tasks/{task_id}", response_model=Task)
    def get_task(
        task_id: int,
        session: Session = Depends(runtime.get_session),
    ) -> Task:
        record = session.get(TaskRecord, task_id)
        if record is None:
            raise HTTPException(status_code=404, detail="Task not found")
        return Task(
            id=record.id,
            title=record.title,
            completed=record.completed,
        )

    @application.put("/tasks/{task_id}", response_model=Task)
    def update_task(
        task_id: int,
        payload: TaskUpdate,
        session: Session = Depends(runtime.get_session),
    ) -> Task:
        record = session.get(TaskRecord, task_id)
        if record is None:
            raise HTTPException(status_code=404, detail="Task not found")

        record.title = payload.title
        record.completed = payload.completed
        session.commit()
        session.refresh(record)
        return Task(
            id=record.id,
            title=record.title,
            completed=record.completed,
        )

    @application.delete("/tasks/{task_id}", status_code=204)
    def delete_task(
        task_id: int,
        session: Session = Depends(runtime.get_session),
    ) -> Response:
        record = session.get(TaskRecord, task_id)
        if record is None:
            raise HTTPException(status_code=404, detail="Task not found")

        session.delete(record)
        session.commit()
        return Response(status_code=204)

    return application


app = create_app()
