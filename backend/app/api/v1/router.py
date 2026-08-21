from fastapi import APIRouter

from app.api.v1 import attendance, auth, batches, dashboard, events, fees, progress, reports, students

api_router = APIRouter()
api_router.include_router(auth.router)
api_router.include_router(batches.router)
api_router.include_router(students.router)
api_router.include_router(attendance.router)
api_router.include_router(fees.router)
api_router.include_router(events.router)
api_router.include_router(progress.router)
api_router.include_router(dashboard.router)
api_router.include_router(reports.router)