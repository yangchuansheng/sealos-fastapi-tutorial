from fastapi import FastAPI

__all__ = ["app", "create_app"]


def create_app() -> FastAPI:
    application = FastAPI(title="Tasks API", version="0.1.0")

    @application.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    return application


app = create_app()
