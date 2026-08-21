from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.session import get_db
from app.models.attendance import MonthlyAttendance
from app.models.progress import MonthlyProgress
from app.models.student import Student
from app.models.user import User
from app.schemas.progress import ProgressCreate, ProgressList, ProgressOut, ProgressUpdate, ProgressWithStudent

router = APIRouter(prefix="/progress", tags=["progress"])

Db = Annotated[Session, Depends(get_db)]


def _with_student(db: Session, p: MonthlyProgress) -> ProgressWithStudent:
    student = db.get(Student, p.student_id)
    out = ProgressWithStudent.model_validate(p)
    out.student_name = f"{student.first_name} {student.last_name}".strip() if student else ""
    return out


def _sync_attendance(db: Session, p: MonthlyProgress) -> MonthlyProgress:
    summary = db.scalar(
        select(MonthlyAttendance).where(
            MonthlyAttendance.student_id == p.student_id, MonthlyAttendance.month == p.month
        )
    )
    p.attendance_percentage = summary.percentage if summary else None
    return p


@router.post("/students/{student_id}", response_model=ProgressOut, status_code=status.HTTP_201_CREATED)
def create_progress(
    student_id: int,
    payload: ProgressCreate,
    db: Db,
    _user: User = Depends(get_current_user),
):
    student = db.get(Student, student_id)
    if student is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Student not found")
    existing = db.scalar(
        select(MonthlyProgress).where(
            MonthlyProgress.student_id == student_id, MonthlyProgress.month == payload.month.replace(day=1)
        )
    )
    if existing:
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="Progress record already exists for this student and month",
        )
    progress = MonthlyProgress(student_id=student_id, **payload.model_dump())
    progress.month = payload.month.replace(day=1)
    db.add(progress)
    db.flush()
    _sync_attendance(db, progress)
    db.commit()
    db.refresh(progress)
    return progress


@router.put("/students/{student_id}/{month}", response_model=ProgressOut)
def update_progress(
    student_id: int,
    month: date,
    payload: ProgressUpdate,
    db: Db,
    _user: User = Depends(get_current_user),
):
    progress = db.scalar(
        select(MonthlyProgress).where(
            MonthlyProgress.student_id == student_id, MonthlyProgress.month == month.replace(day=1)
        )
    )
    if progress is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Progress record not found")
    for key, value in payload.model_dump(exclude_unset=True).items():
        setattr(progress, key, value)
    db.flush()
    _sync_attendance(db, progress)
    db.commit()
    db.refresh(progress)
    return progress


@router.get("", response_model=ProgressList)
def list_progress(
    db: Db,
    _user: User = Depends(get_current_user),
    month: date | None = Query(default=None),
    student_id: int | None = Query(default=None),
    batch_id: int | None = Query(default=None),
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
):
    stmt = select(MonthlyProgress).join(Student, Student.id == MonthlyProgress.student_id)
    if month is not None:
        stmt = stmt.where(MonthlyProgress.month == month.replace(day=1))
    if student_id is not None:
        stmt = stmt.where(MonthlyProgress.student_id == student_id)
    if batch_id is not None:
        stmt = stmt.where(Student.batch_id == batch_id)
    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    rows = db.scalars(
        stmt.order_by(MonthlyProgress.month.desc(), Student.first_name.asc()).limit(limit).offset(offset)
    ).all()
    return ProgressList(total=total, items=[_with_student(db, p) for p in rows])


@router.get("/students/{student_id}", response_model=ProgressList)
def student_progress_history(
    student_id: int,
    db: Db,
    _user: User = Depends(get_current_user),
    limit: int = Query(default=24, ge=1, le=120),
):
    student = db.get(Student, student_id)
    if student is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Student not found")
    rows = db.scalars(
        select(MonthlyProgress)
        .where(MonthlyProgress.student_id == student_id)
        .order_by(MonthlyProgress.month.desc())
        .limit(limit)
    ).all()
    return ProgressList(total=len(rows), items=[_with_student(db, p) for p in rows])


@router.get("/students/{student_id}/{month}", response_model=ProgressOut)
def get_progress(
    student_id: int,
    month: date,
    db: Db,
    _user: User = Depends(get_current_user),
):
    progress = db.scalar(
        select(MonthlyProgress).where(
            MonthlyProgress.student_id == student_id, MonthlyProgress.month == month.replace(day=1)
        )
    )
    if progress is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Progress record not found")
    return progress


@router.delete("/students/{student_id}/{month}", status_code=status.HTTP_204_NO_CONTENT)
def delete_progress(
    student_id: int,
    month: date,
    db: Db,
    _user: User = Depends(get_current_user),
):
    progress = db.scalar(
        select(MonthlyProgress).where(
            MonthlyProgress.student_id == student_id, MonthlyProgress.month == month.replace(day=1)
        )
    )
    if progress is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Progress record not found")
    db.delete(progress)
    db.commit()
    return None