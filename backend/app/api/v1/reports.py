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
from app.models.fee import Fee
from app.models.student import Student
from app.models.user import User
from app.schemas.dashboard import MonthlyReport, MonthlyReportRow

router = APIRouter(prefix="/reports", tags=["reports"])

Db = Annotated[Session, Depends(get_db)]


@router.get("/monthly", response_model=MonthlyReport)
def monthly_report(
    db: Db,
    _user: User = Depends(get_current_user),
    month: date = Query(default=...),
    batch_id: int | None = Query(default=None),
):
    """Per-batch monthly report: students, attendance totals and fee collection."""
    target_month = month.replace(day=1)
    next_month_start = date(
        target_month.year + 1, 1, 1
    ) if target_month.month == 12 else date(target_month.year, target_month.month + 1, 1)

    batches = db.scalars(select(Batch).order_by(Batch.name)).all()

    def row_for(b: Batch | None) -> MonthlyReportRow:
        bid = b.id if b else None
        students_stmt = select(Student.id).where(Student.batch_id == bid)
        student_ids = set(db.scalars(students_stmt).all())

        att_rows = db.execute(
            select(Attendance, Student)
            .join(Student, Student.id == Attendance.student_id)
            .where(
                Attendance.attendance_date >= target_month,
                Attendance.attendance_date < next_month_start,
            )
            .where(Student.batch_id == bid)
        ).all()
        att_total = len(att_rows)
        att_present = sum(1 for r in att_rows if r[0].status == "present")
        att_late = sum(1 for r in att_rows if r[0].status == "late")
        att_pct = round((att_present + att_late) / att_total * 100, 1) if att_total else 0.0

        fees_stmt = select(Fee).where(Fee.month == target_month)
        if bid is not None:
            fees_stmt = fees_stmt.join(Student, Student.id == Fee.student_id).where(
                Student.batch_id == bid
            )
        fees = db.scalars(fees_stmt).all()
        fees_due = sum((f.amount_due for f in fees), Decimal("0.00"))
        fees_paid = sum((f.amount_paid for f in fees), Decimal("0.00"))
        collection_rate = round(float(fees_paid / fees_due * 100), 1) if fees_due else 0.0

        return MonthlyReportRow(
            batch_id=bid,
            batch_name=b.name if b else "Unassigned",
            total_students=len(student_ids),
            attendance_total=att_total,
            attendance_present=att_present,
            attendance_percentage=att_pct,
            fees_due=fees_due,
            fees_paid=fees_paid,
            fee_outstanding=fees_due - fees_paid,
            fee_collection_rate=collection_rate,
        )

    rows = []
    if batch_id is not None:
        b = db.get(Batch, batch_id)
        if b is None:
            rows = []
        else:
            rows.append(row_for(b))
    else:
        for b in batches:
            rows.append(row_for(b))
        rows.append(row_for(None))
    return MonthlyReport(month=target_month, rows=rows)