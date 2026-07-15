import os
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Response
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session

from app.database import DatabaseRuntime
from app.models import TaskRecord

__all__ = ["Task", "TaskCreate", "TaskUpdate", "app", "create_app"]


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
        try:
            yield
        finally:
            runtime.dispose()

    application = FastAPI(
        title="Tasks API",
        version="0.1.0",
        lifespan=lifespan,
    )
    tasks: dict[int, Task] = {}
    next_task_id = 1

    def get_task_or_404(task_id: int) -> Task:
        if task_id not in tasks:
            raise HTTPException(status_code=404, detail="Task not found")
        return tasks[task_id]

    @application.get("/health")
    def health() -> dict[str, str]:
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
    def list_tasks() -> list[Task]:
        return [tasks[task_id] for task_id in sorted(tasks)]

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
    def update_task(task_id: int, payload: TaskUpdate) -> Task:
        get_task_or_404(task_id)

        task = Task(id=task_id, **payload.model_dump())
        tasks[task_id] = task
        return task

    @application.delete("/tasks/{task_id}", status_code=204)
    def delete_task(task_id: int) -> Response:
        get_task_or_404(task_id)

        del tasks[task_id]
        return Response(status_code=204)

    return application


app = create_app()
