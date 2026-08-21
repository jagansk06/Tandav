from datetime import date
from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.session import get_db
from app.models.fee import FEE_STATUS_DUE, Fee, fee_status_from
from app.models.student import Student
from app.models.user import User
from app.schemas.fee import FeeCreate, FeeList, FeeOut, FeePayment, FeeUpdate, FeeWithStudent
from app.services.fees import ensure_monthly_fees

router = APIRouter(prefix="/fees", tags=["fees"])

Db = Annotated[Session, Depends(get_db)]


def _fee_ensure(db: Session, student_id: int, month: date, amount_due: Decimal) -> Fee:
    fee = db.scalar(
        select(Fee).where(Fee.student_id == student_id, Fee.month == month.replace(day=1))
    )
    if fee is None:
        fee = Fee(student_id=student_id, month=month.replace(day=1), amount_due=amount_due)
        db.add(fee)
    return fee


def _sync_status(fee: Fee) -> None:
    fee.status = fee_status_from(fee.amount_due, fee.amount_paid)


def _with_student(db: Session, fee: Fee) -> FeeWithStudent:
    student = db.get(Student, fee.student_id)
    out = FeeWithStudent.model_validate(fee)
    out.student_name = f"{student.first_name} {student.last_name}".strip() if student else ""
    return out


@router.get("", response_model=FeeList)
def list_fees(
    db: Db,
    _user: User = Depends(get_current_user),
    month: date | None = Query(default=None),
    student_id: int | None = Query(default=None),
    batch_id: int | None = Query(default=None),
    status_filter: str | None = Query(default=None, alias="status", pattern="^(due|partial|paid)$"),
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
):
    target_month = (month or date.today()).replace(day=1)
    ensure_monthly_fees(db, target_month)
    stmt = select(Fee).join(Student, Student.id == Fee.student_id)
    if month is not None:
        stmt = stmt.where(Fee.month == month.replace(day=1))
    if student_id is not None:
        stmt = stmt.where(Fee.student_id == student_id)
    if batch_id is not None:
        stmt = stmt.where(Student.batch_id == batch_id)
    if status_filter is not None:
        stmt = stmt.where(Fee.status == status_filter)
    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    fees = db.scalars(
        stmt.order_by(Fee.month.desc(), Student.first_name.asc()).limit(limit).offset(offset)
    ).all()
    return FeeList(total=total, items=[_with_student(db, f) for f in fees])


@router.get("/summary", response_model=dict)
def fees_summary(
    db: Db,
    _user: User = Depends(get_current_user),
    month: date = Query(default=...),
    batch_id: int | None = Query(default=None),
):
    ensure_monthly_fees(db, month)
    stmt = select(Fee).join(Student, Student.id == Fee.student_id).where(Fee.month == month.replace(day=1))
    if batch_id is not None:
        stmt = stmt.where(Student.batch_id == batch_id)
    rows = db.execute(stmt).all()
    total_due = sum((r[0].amount_due for r in rows), Decimal("0.00"))
    total_paid = sum((r[0].amount_paid for r in rows), Decimal("0.00"))
    paid_count = sum(1 for r in rows if r[0].status == "paid")
    partial_count = sum(1 for r in rows if r[0].status == "partial")
    due_count = sum(1 for r in rows if r[0].status == "due")
    return {
        "month": month.replace(day=1),
        "total_records": len(rows),
        "total_due": total_due,
        "total_paid": total_paid,
        "outstanding": total_due - total_paid,
        "paid_count": paid_count,
        "partial_count": partial_count,
        "due_count": due_count,
        "collection_rate": round(float(total_paid / total_due * 100), 1) if total_due else 0.0,
    }


@router.post("/generate", response_model=dict)
def generate_monthly_fees(
    db: Db,
    _user: User = Depends(get_current_user),
    month: date | None = Query(default=None),
):
    """Generate missing monthly fee records for active students (idempotent)."""
    target = (month or date.today()).replace(day=1)
    created = ensure_monthly_fees(db, target)
    return {"month": target, "created": created}


@router.post("/students/{student_id}/{month}", response_model=FeeOut, status_code=status.HTTP_201_CREATED)
def create_fee_for_student(
    student_id: int,
    month: date,
    payload: FeeCreate,
    db: Db,
    _user: User = Depends(get_current_user),
):
    student = db.get(Student, student_id)
    if student is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Student not found")
    existing = db.scalar(select(Fee).where(Fee.student_id == student_id, Fee.month == month.replace(day=1)))
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="A fee record already exists for this student and month",
        )
    fee = Fee(
        student_id=student_id,
        month=month.replace(day=1),
        amount_due=payload.amount_due,
        amount_paid=Decimal("0.00"),
        status=FEE_STATUS_DUE,
    )
    db.add(fee)
    db.commit()
    db.refresh(fee)
    return fee


@router.get("/{fee_id}", response_model=FeeWithStudent)
def get_fee(fee_id: int, db: Db, _user: User = Depends(get_current_user)):
    fee = db.get(Fee, fee_id)
    if fee is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Fee record not found")
    return _with_student(db, fee)


@router.put("/{fee_id}/payment", response_model=FeeOut)
def record_fee_payment(
    fee_id: int,
    payload: FeePayment,
    db: Db,
    _user: User = Depends(get_current_user),
):
    """Record a payment against the month's fee; adds to amount_paid."""
    fee = db.get(Fee, fee_id)
    if fee is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Fee record not found")
    new_paid = fee.amount_paid + payload.amount_paid
    if new_paid > fee.amount_due:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Payment exceeds remaining due of {fee.amount_due - fee.amount_paid}",
        )
    fee.amount_paid = new_paid
    fee.payment_date = payload.payment_date
    fee.payment_method = payload.payment_method
    if payload.notes:
        fee.notes = payload.notes
    _sync_status(fee)
    db.commit()
    db.refresh(fee)
    return fee


@router.put("/{fee_id}", response_model=FeeOut)
def update_fee(fee_id: int, payload: FeeUpdate, db: Db, _user: User = Depends(get_current_user)):
    fee = db.get(Fee, fee_id)
    if fee is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Fee record not found")
    if payload.amount_due is not None:
        if payload.amount_due < fee.amount_paid:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Amount due cannot be less than amount already paid",
            )
        fee.amount_due = payload.amount_due
    if payload.notes is not None:
        fee.notes = payload.notes
    _sync_status(fee)
    db.commit()
    db.refresh(fee)
    return fee


@router.delete("/{fee_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_fee(fee_id: int, db: Db, _user: User = Depends(get_current_user)):
    fee = db.get(Fee, fee_id)
    if fee is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Fee record not found")
    db.delete(fee)
    db.commit()
    return None