"""Monthly recurring fee record generation.

Generates one fee record per active student per month (idempotently).
"""
from datetime import date
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.fee import Fee, FEE_STATUS_DUE
from app.models.student import Student


def ensure_monthly_fees(db: Session, month: date) -> int:
    """Create missing fee records for the given month for all eligible active students.

    A student is eligible when they:
      - are active (is_active=True)
      - have a monthly_fee > 0
      - joined on or before the target month

    Idempotent: existing (student, month) records are left untouched and are
    never duplicated (unique constraint uq_fees_student_month backs this up).
    Returns the number of records created.
    """
    month_start = month.replace(day=1)
    next_month_start = (
        date(month_start.year + 1, 1, 1)
        if month_start.month == 12
        else date(month_start.year, month_start.month + 1, 1)
    )

    existing = set(
        db.scalars(
            select(Fee.student_id).where(Fee.month == month_start)
        ).all()
    )

    students = db.scalars(
        select(Student).where(
            Student.is_active.is_(True),
            Student.monthly_fee > Decimal("0.00"),
            Student.join_date < next_month_start,
        )
    ).all()

    created = 0
    for student in students:
        if student.id in existing:
            continue
        db.add(
            Fee(
                student_id=student.id,
                month=month_start,
                amount_due=student.monthly_fee,
                amount_paid=Decimal("0.00"),
                status=FEE_STATUS_DUE,
            )
        )
        created += 1
    if created:
        db.commit()
    return created
