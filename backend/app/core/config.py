from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Application settings loaded from environment variables (.env supported)."""

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    APP_NAME: str = "Tandav Dance Studio API"
    API_PREFIX: str = "/api/v1"
    DEBUG: bool = False

    DATABASE_URL: str = (
        "postgresql+psycopg2://tandav:tandav_dev_password@127.0.0.1:5433/tandav"
    )

    JWT_SECRET_KEY: str = "change-me-in-production"
    JWT_ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60 * 24 * 7

    UPLOAD_DIR: str = "uploads"
    MAX_UPLOAD_MB: int = 5
    ALLOWED_IMAGE_TYPES: tuple = ("image/jpeg", "image/png", "image/webp")

    CORS_ORIGINS: list = ["*"]

    SEED_ADMIN_USERNAME: str = "admin"
    SEED_ADMIN_PASSWORD: str = "admin123"
    SEED_ADMIN_FULL_NAME: str = "Studio Admin"
    SEED_ADMIN_EMAIL: str = "admin@tandav.in"


@lru_cache
def get_settings() -> Settings:
    return Settings()