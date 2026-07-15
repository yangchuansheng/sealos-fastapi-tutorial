from fastapi import FastAPI

__all__ = ["app", "create_app"]


def create_app() -> FastAPI:
    application = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

    @application.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    return application


app = create_app()
