import os
from contextlib import asynccontextmanager
from datetime import date

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from app.api.v1.router import api_router
from app.core.config import get_settings
from app.db.session import SessionLocal, engine

settings = get_settings()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    """On startup, ensure monthly fee records exist for the current month."""
    try:
        from app.services.fees import ensure_monthly_fees

        with SessionLocal() as db:
            ensure_monthly_fees(db, date.today())
    except Exception as exc:  # pragma: no cover - startup must not crash
        print(f"[startup] monthly fee generation skipped: {exc}")
    yield


app = FastAPI(
    title=settings.APP_NAME,
    version="1.0.0",
    description="Tandav Dance Studio Management System API",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

os.makedirs(settings.UPLOAD_DIR, exist_ok=True)
app.mount("/uploads", StaticFiles(directory=settings.UPLOAD_DIR), name="uploads")

app.include_router(api_router, prefix=settings.API_PREFIX)


@app.get("/health", tags=["health"])
def health():
    from sqlalchemy import text

    with engine.connect() as conn:
        conn.execute(text("SELECT 1"))
    return {"status": "ok", "app": settings.APP_NAME, "version": "1.0.0"}