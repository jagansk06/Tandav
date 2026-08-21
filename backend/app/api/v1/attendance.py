from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import delete, func, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.session import get_db
from app.models.attendance import (
    ATTENDANCE_ABSENT,
    ATTENDANCE_LATE,
    Attendance,
    MonthlyAttendance,
)
from app.models.batch import Batch
from app.models.student import Student
from app.models.user import User
from app.schemas.attendance import (
    AttendanceBatchSave,
    AttendanceDayOut,
    AttendanceStatusUpdate,
    MonthlyAttendanceOut,
    MonthlyAttendanceSummary,
    AttendanceStudentRow,
)

router = APIRouter(prefix="/attendance", tags=["attendance"])

Db = Annotated[Session, Depends(get_db)]


def recompute_monthly_attendance(db: Session, student_id: int, month: date) -> MonthlyAttendance:
    """Recalculate the monthly attendance aggregate for a student from daily records."""
    start = month.replace(day=1)
    if month.month == 12:
        end = date(month.year + 1, 1, 1)
    else:
        end = date(month.year, month.month + 1, 1)
    rows = db.scalars(
        select(Attendance).where(
            Attendance.student_id == student_id,
            Attendance.attendance_date >= start,
            Attendance.attendance_date < end,
        )
    ).all()
    presents = sum(1 for r in rows if r.status == "present")
    lates = sum(1 for r in rows if r.status == "late")
    absents = sum(1 for r in rows if r.status == "absent")
    total = len(rows)
    percentage = round((presents + lates) / total * 100, 1) if total else 0.0
    summary = db.scalar(
        select(MonthlyAttendance).where(
            MonthlyAttendance.student_id == student_id, MonthlyAttendance.month == start
        )
    )
    if summary is None:
        summary = MonthlyAttendance(student_id=student_id, month=start)
        db.add(summary)
    summary.total_classes = total
    summary.presents = presents
    summary.lates = lates
    summary.absents = absents
    summary.percentage = percentage
    db.flush()
    return summary


def recompute_month(db: Session, month: date, batch_id: int | None = None) -> None:
    """Recompute monthly aggregates for every student who has attendance in the month."""
    stmt = select(Attendance.student_id).where(
        Attendance.attendance_date >= month.replace(day=1),
        Attendance.attendance_date <= month.replace(day=28),
        Attendance.attendance_date < (
            date(month.year + 1, 1, 1) if month.month == 12 else date(month.year, month.month + 1, 1)
        ),
    ).distinct()
    if batch_id is not None:
        stmt = stmt.join(Student, Student.id == Attendance.student_id).where(Student.batch_id == batch_id)
    for (student_id,) in db.execute(stmt).all():
        recompute_monthly_attendance(db, student_id, month)
    db.commit()


@router.get("/day", response_model=AttendanceDayOut)
def get_day_attendance(
    db: Db,
    _user: User = Depends(get_current_user),
    date: date = Query(default=...),
    batch_id: int | None = Query(default=None),
):
    """Return attendance board for a date (optionally for a batch: all active students listed)."""
    records_by_student = {
        r.student_id: r
        for r in db.scalars(
            select(Attendance).where(Attendance.attendance_date == date)
        ).all()
    }
    students_stmt = select(Student).where(Student.is_active.is_(True))
    if batch_id is not None:
        students_stmt = students_stmt.where(Student.batch_id == batch_id)
    students = db.scalars(students_stmt.order_by(Student.first_name)).all()
    if batch_id is not None:
        batch = db.get(Batch, batch_id)
        if batch is None:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Batch not found")
        batch_name = batch.name
        records = [
            AttendanceStudentRow(
                student_id=s.id,
                student_name=f"{s.first_name} {s.last_name}".strip(),
                batch_id=s.batch_id,
                batch_name=batch_name,
                status=(records_by_student[s.id].status if s.id in records_by_student else None),
                attendance_id=(records_by_student[s.id].id if s.id in records_by_student else None),
                notes=(records_by_student[s.id].notes if s.id in records_by_student else None),
            )
            for s in students
        ]
        total = len(records)
        present = sum(1 for r in records if r.status == "present")
        absent = sum(1 for r in records if r.status == "absent")
        late = sum(1 for r in records if r.status == "late")
        unmarked = sum(1 for r in records if r.status is None)
        percentage = round((present + late) / total * 100, 1) if total else 0.0
    else:
        all_records = [
            AttendanceStudentRow(
                student_id=s.id,
                student_name=f"{s.first_name} {s.last_name}".strip(),
                batch_id=s.batch_id,
                batch_name=s.batch.name if s.batch else None,
                status=(records_by_student[s.id].status if s.id in records_by_student else None),
                attendance_id=(records_by_student[s.id].id if s.id in records_by_student else None),
                notes=(records_by_student[s.id].notes if s.id in records_by_student else None),
            )
            for s in students
        ]
        present = sum(1 for r in all_records if r.status == "present")
        absent = sum(1 for r in all_records if r.status == "absent")
        late = sum(1 for r in all_records if r.status == "late")
        unmarked = sum(1 for r in all_records if r.status is None)
        total = len(all_records)
        percentage = round((present + late) / total * 100, 1) if total else 0.0
        records = all_records
        batch_name = "All batches"
    return AttendanceDayOut(
        date=date,
        batch_id=batch_id or 0,
        batch_name=batch_name,
        total=total,
        present=present,
        absent=absent,
        late=late,
        unmarked=unmarked,
        percentage=percentage,
        records=sorted(records, key=lambda r: (r.batch_name or "", r.student_name)),
    )


@router.put("/day", response_model=AttendanceDayOut)
def save_day_attendance(
    payload: AttendanceBatchSave,
    db: Db,
    _user: User = Depends(get_current_user),
):
    """Save (upsert) attendance marks for a batch on a given date."""
    batch = db.get(Batch, payload.batch_id)
    if batch is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Batch not found")
    student_ids = {r.student_id for r in payload.records}
    existing = {
        r.student_id: r
        for r in db.scalars(
            select(Attendance).where(
                Attendance.attendance_date == payload.date,
                Attendance.student_id.in_(student_ids),
            )
        ).all()
    }
    seen = set()
    for record in payload.records:
        if record.student_id in seen:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=f"Duplicate student_id {record.student_id}")
        seen.add(record.student_id)
        student = db.get(Student, record.student_id)
        if student is None:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=f"Student {record.student_id} does not exist")
        entry = existing.get(record.student_id)
        if entry is None:
            entry = Attendance(
                student_id=record.student_id,
                attendance_date=payload.date,
                status=record.status,
                notes=record.notes,
            )
            db.add(entry)
        entry.status = record.status
        entry.batch_id = payload.batch_id
        entry.notes = record.notes
    db.commit()
    recompute_month(db, payload.date)
    return get_day_attendance(db=db, _user=_user, date=payload.date, batch_id=payload.batch_id)


@router.post("/day/{attendance_id}/status", response_model=AttendanceStudentRow)
def update_attendance_status(
    attendance_id: int,
    payload: AttendanceStatusUpdate,
    db: Db,
    _user: User = Depends(get_current_user),
):
    entry = db.get(Attendance, attendance_id)
    if entry is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Attendance record not found")
    entry.status = payload.status
    entry.notes = payload.notes
    db.commit()
    recompute_month(db, entry.attendance_date)
    student = db.get(Student, entry.student_id)
    return AttendanceStudentRow(
        student_id=student.id,
        student_name=f"{student.first_name} {student.last_name}".strip(),
        batch_id=student.batch_id,
        batch_name=student.batch.name if student.batch else None,
        status=entry.status,
        attendance_id=entry.id,
        notes=entry.notes,
    )


@router.delete("/day/{attendance_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_attendance_record(
    attendance_id: int,
    db: Db,
    _user: User = Depends(get_current_user),
):
    entry = db.get(Attendance, attendance_id)
    if entry is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Attendance record not found")
    marked_date = entry.attendance_date
    db.delete(entry)
    db.commit()
    recompute_month(db, marked_date)
    return None


def _monthly_summary_rows(db: Session, month: date, batch_id: int | None = None):
    stmt = select(MonthlyAttendance, Student).join(Student, Student.id == MonthlyAttendance.student_id)
    if batch_id is not None:
        stmt = stmt.where(Student.batch_id == batch_id)
    rows = db.execute(stmt.where(MonthlyAttendance.month == month.replace(day=1)).order_by(Student.first_name)).all()
    return [
        MonthlyAttendanceSummary(
            month=ma.month,
            student_id=ma.student_id,
            student_name=f"{s.first_name} {s.last_name}".strip(),
            batch_id=s.batch_id,
            batch_name=s.batch.name if s.batch else None,
            total_classes=ma.total_classes,
            presents=ma.presents,
            absents=ma.absents,
            lates=ma.lates,
            percentage=ma.percentage,
        )
        for ma, s in rows
    ]


@router.get("/monthly", response_model=list[MonthlyAttendanceSummary])
def monthly_summary(
    db: Db,
    _user: User = Depends(get_current_user),
    month: date = Query(default=...),
    batch_id: int | None = Query(default=None),
):
    recompute_month(db, month, batch_id=batch_id)
    return _monthly_summary_rows(db, month, batch_id)


@router.get("/students/{student_id}/monthly", response_model=MonthlyAttendanceOut)
def student_monthly(
    student_id: int,
    db: Db,
    _user: User = Depends(get_current_user),
    month: date = Query(default=...),
):
    student = db.get(Student, student_id)
    if student is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Student not found")
    summary = recompute_monthly_attendance(db, student_id, month)
    db.commit()
    return summary