from datetime import date
from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.session import get_db
from app.models.attendance import Attendance
from app.models.batch import Batch
from app.models.event import Event, EventParticipation
from app.models.fee import Fee
from app.models.student import Student
from app.models.user import User
from app.schemas.dashboard import (
    DashboardOut,
    DashboardStats,
    FeeSummary,
    RecentStudent,
    UpcomingEvent,
)
from app.services.fees import ensure_monthly_fees

router = APIRouter(prefix="/dashboard", tags=["dashboard"])

Db = Annotated[Session, Depends(get_db)]


def _month_start(month: date) -> date:
    return month.replace(day=1)


@router.get("", response_model=DashboardOut)
def get_dashboard(
    db: Db,
    _user: User = Depends(get_current_user),
    month: date | None = Query(default=None),
):
    today = date.today()
    target_month = _month_start(month or today)
    ensure_monthly_fees(db, target_month)
    next_month_start = date(
        target_month.year + 1, 1, 1
    ) if target_month.month == 12 else date(target_month.year, target_month.month + 1, 1)

    total_students = db.scalar(select(func.count()).select_from(Student)) or 0
    active_students = (
        db.scalar(select(func.count()).select_from(Student).where(Student.is_active.is_(True))) or 0
    )
    total_batches = db.scalar(select(func.count()).select_from(Batch)) or 0
    active_batches = (
        db.scalar(select(func.count()).select_from(Batch).where(Batch.is_active.is_(True))) or 0
    )
    total_events = db.scalar(select(func.count()).select_from(Event)) or 0
    upcoming_events = (
        db.scalar(
            select(func.count()).select_from(Event).where(Event.event_date >= today)
        )
        or 0
    )

    today_marks = db.scalars(select(Attendance).where(Attendance.attendance_date == today)).all()
    today_present = sum(1 for r in today_marks if r.status == "present")
    today_absent = sum(1 for r in today_marks if r.status == "absent")
    today_late = sum(1 for r in today_marks if r.status == "late")

    fees = db.scalars(
        select(Fee).where(Fee.month >= target_month, Fee.month < next_month_start)
    ).all()
    fee_total_due = sum((f.amount_due for f in fees), Decimal("0.00"))
    fee_total_paid = sum((f.amount_paid for f in fees), Decimal("0.00"))
    fee_summary = FeeSummary(
        month=target_month,
        total_due=fee_total_due,
        total_paid=fee_total_paid,
        outstanding=fee_total_due - fee_total_paid,
        paid_count=sum(1 for f in fees if f.status == "paid"),
        partial_count=sum(1 for f in fees if f.status == "partial"),
        due_count=sum(1 for f in fees if f.status == "due"),
        total_records=len(fees),
    )

    attendance_rows = db.execute(
        select(Attendance.attendance_date, Attendance.status, func.count())
        .where(Attendance.attendance_date >= target_month, Attendance.attendance_date < next_month_start)
        .group_by(Attendance.attendance_date, Attendance.status)
    ).all()
    daily: dict[str, dict[str, int]] = {}
    for day, status_, count in attendance_rows:
        key = day.isoformat()
        daily.setdefault(key, {"present": 0, "absent": 0, "late": 0})
        daily[key][status_] = count
    monthly_attendance = [
        {"date": key, **counts} for key, counts in sorted(daily.items())
    ]

    upcoming = db.scalars(
        select(Event)
        .where(Event.event_date >= today)
        .order_by(Event.event_date.asc())
        .limit(5)
    ).all()
    upcoming_events_out = []
    for e in upcoming:
        count = (
            db.scalar(
                select(func.count())
                .select_from(EventParticipation)
                .where(EventParticipation.event_id == e.id)
            )
            or 0
        )
        upcoming_events_out.append(
            UpcomingEvent(
                id=e.id,
                name=e.name,
                event_type=e.event_type,
                event_date=e.event_date,
                location=e.location,
                participant_count=count,
            )
        )

    recent = db.scalars(
        select(Student).order_by(Student.created_at.desc()).limit(5)
    ).all()
    recent_out = [
        RecentStudent(
            id=s.id,
            full_name=f"{s.first_name} {s.last_name}".strip(),
            batch_name=s.batch.name if s.batch else None,
            joined=s.join_date,
        )
        for s in recent
    ]

    return DashboardOut(
        stats=DashboardStats(
            total_students=total_students,
            active_students=active_students,
            total_batches=total_batches,
            active_batches=active_batches,
            total_events=total_events,
            upcoming_events=upcoming_events,
            today_present=today_present,
            today_absent=today_absent,
            today_late=today_late,
            today_total_marked=len(today_marks),
            today_unmarked=active_students - len(today_marks),
        ),
        fee_summary=fee_summary,
        monthly_attendance=monthly_attendance,
        upcoming_events=upcoming_events_out,
        recent_students=recent_out,
    )