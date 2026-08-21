import os
import sys

os.environ["DATABASE_URL"] = "postgresql+psycopg2://tandav:tandav_dev_password@127.0.0.1:5433/tandav_test"
os.environ["JWT_SECRET_KEY"] = "test-secret-key"
os.environ["SEED_ADMIN_USERNAME"] = "admin"
os.environ["SEED_ADMIN_PASSWORD"] = "admin123"
os.environ["UPLOAD_DIR"] = "/tmp/tandav_test_uploads"

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import pytest  # noqa: E402
from alembic import command  # noqa: E402
from alembic.config import Config  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app.core.security import hash_password  # noqa: E402
from app.db.session import SessionLocal, engine  # noqa: E402
from app.main import app  # noqa: E402
from app.models.user import User  # noqa: E402

ALEMBIC_CFG = Config(os.path.join(os.path.dirname(__file__), "..", "alembic.ini"))


@pytest.fixture(scope="session", autouse=True)
def _migrate_database():
    # Reset schema: drop all and re-migrate for a clean test run.
    with engine.begin() as conn:
        conn.execute(__import__("sqlalchemy").text("DROP SCHEMA public CASCADE; CREATE SCHEMA public;"))
    command.upgrade(ALEMBIC_CFG, "head")
    yield
    with engine.begin() as conn:
        conn.execute(__import__("sqlalchemy").text("DROP SCHEMA public CASCADE; CREATE SCHEMA public;"))


@pytest.fixture(autouse=True)
def _clean_tables(_migrate_database):
    with engine.begin() as conn:
        for table in [
            "users", "batches", "students", "attendance", "monthly_attendance",
            "fees", "events", "event_participations", "monthly_progress",
        ]:
            conn.execute(__import__("sqlalchemy").text(f'TRUNCATE TABLE "{table}" RESTART IDENTITY CASCADE'))
    yield


@pytest.fixture()
def client():
    return TestClient(app)


@pytest.fixture()
def admin_user():
    db = SessionLocal()
    user = User(
        username="admin",
        full_name="Test Admin",
        email="admin@test.in",
        password_hash=hash_password("admin123"),
    )
    db.add(user)
    db.commit()
    db.refresh(user)
    db.close()
    return user


@pytest.fixture()
def auth_headers(client, admin_user):
    resp = client.post(
        "/api/v1/auth/login",
        json={"username": "admin", "password": "admin123"},
    )
    assert resp.status_code == 200, resp.text
    token = resp.json()["access_token"]
    return {"Authorization": f"Bearer {token}"}


@pytest.fixture()
def seeded_batch(client, auth_headers):
    resp = client.post(
        "/api/v1/batches",
        json={"name": "Test Batch", "monthly_fee": "1500.00", "schedule": "Mon 5PM"},
        headers=auth_headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


@pytest.fixture()
def seeded_students(client, auth_headers, seeded_batch):
    ids = []
    for name in ["Aria", "Bella", "Cara"]:
        resp = client.post(
            "/api/v1/students",
            json={
                "first_name": name,
                "phone": f"9{name}0000000",
                "batch_id": seeded_batch["id"],
            },
            headers=auth_headers,
        )
        assert resp.status_code == 201, resp.text
        ids.append(resp.json()["id"])
    return ids