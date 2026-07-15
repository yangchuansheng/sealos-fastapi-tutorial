from fastapi import FastAPI

__all__ = ["app", "create_app"]


def create_app() -> FastAPI:
    return FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


app = create_app()
