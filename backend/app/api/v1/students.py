import os
import uuid
from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, File, HTTPException, Query, UploadFile, status
from sqlalchemy import func, or_, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.core.config import get_settings
from app.db.session import get_db
from app.models.batch import Batch
from app.models.student import Student
from app.models.user import User
from app.schemas.student import StudentCreate, StudentList, StudentOut, StudentPhotoResponse, StudentUpdate

router = APIRouter(prefix="/students", tags=["students"])

Db = Annotated[Session, Depends(get_db)]


def _student_out(db: Session, student: Student) -> StudentOut:
    out = StudentOut.model_validate(student)
    if student.batch_id is not None:
        out.batch_name = student.batch.name if student.batch else None
    return out


@router.get("", response_model=StudentList)
def list_students(
    db: Db,
    _user: User = Depends(get_current_user),
    q: str | None = Query(default=None, max_length=128),
    batch_id: int | None = Query(default=None),
    active_only: bool = Query(default=False),
    gender: str | None = Query(default=None, max_length=16),
    sort_by: str = Query(default="name", pattern="^(name|join_date|created_at)$"),
    order: str = Query(default="asc", pattern="^(asc|desc)$"),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
):
    stmt = select(Student)
    if q:
        like = f"%{q.strip()}%"
        stmt = stmt.where(
            or_(
                Student.first_name.ilike(like),
                Student.last_name.ilike(like),
                Student.phone.ilike(like),
                Student.email.ilike(like),
            )
        )
    if batch_id is not None:
        stmt = stmt.where(Student.batch_id == batch_id)
    if active_only:
        stmt = stmt.where(Student.is_active.is_(True))
    if gender:
        stmt = stmt.where(Student.gender == gender)
    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    if sort_by == "name":
        order_cols = (Student.first_name.asc(), Student.last_name.asc())
    elif sort_by == "join_date":
        order_cols = (Student.join_date.desc(),)
    else:
        order_cols = (Student.created_at.desc(),)
    students = db.scalars(
        stmt.order_by(*order_cols).limit(limit).offset(offset)
    ).all()
    return StudentList(total=total, items=[_student_out(db, s) for s in students])


@router.post("", response_model=StudentOut, status_code=status.HTTP_201_CREATED)
def create_student(payload: StudentCreate, db: Db, _user: User = Depends(get_current_user)):
    if payload.batch_id is not None and db.get(Batch, payload.batch_id) is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Selected batch does not exist")
    data = payload.model_dump()
    if data.get("join_date") is None:
        data["join_date"] = date.today()
    student = Student(**data)
    db.add(student)
    db.commit()
    db.refresh(student)
    return _student_out(db, student)


@router.get("/{student_id}", response_model=StudentOut)
def get_student(student_id: int, db: Db, _user: User = Depends(get_current_user)):
    student = db.get(Student, student_id)
    if student is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Student not found")
    return _student_out(db, student)


@router.put("/{student_id}", response_model=StudentOut)
def update_student(
    student_id: int, payload: StudentUpdate, db: Db, _user: User = Depends(get_current_user)
):
    student = db.get(Student, student_id)
    if student is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Student not found")
    data = payload.model_dump(exclude_unset=True)
    if data.get("batch_id") is not None and db.get(Batch, data["batch_id"]) is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Selected batch does not exist")
    for key, value in data.items():
        setattr(student, key, value)
    db.commit()
    db.refresh(student)
    return _student_out(db, student)


@router.delete("/{student_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_student(student_id: int, db: Db, _user: User = Depends(get_current_user)):
    student = db.get(Student, student_id)
    if student is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Student not found")
    db.delete(student)
    db.commit()
    return None


def _absolute_photo_url(relative: str | None) -> str | None:
    return f"/uploads/{relative.split("/")[-1]}" if relative else None


@router.post("/{student_id}/photo", response_model=StudentPhotoResponse)
async def upload_student_photo(
    student_id: int,
    db: Db,
    _user: User = Depends(get_current_user),
    file: UploadFile = File(...),
):
    student = db.get(Student, student_id)
    if student is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Student not found")
    settings = get_settings()
    if file.content_type not in settings.ALLOWED_IMAGE_TYPES:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Only JPEG, PNG or WebP images are allowed",
        )
    ext = os.path.splitext(file.filename or "")[1].lower()
    if ext not in (".jpg", ".jpeg", ".png", ".webp"):
        ext = ".jpg"
    os.makedirs(settings.UPLOAD_DIR, exist_ok=True)
    filename = f"student_{student_id}_{uuid.uuid4().hex[:8]}{ext}"
    path = os.path.join(settings.UPLOAD_DIR, filename)
    content = await file.read()
    if len(content) > settings.MAX_UPLOAD_MB * 1024 * 1024:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Image exceeds {settings.MAX_UPLOAD_MB} MB limit",
        )
    with open(path, "wb") as fh:
        fh.write(content)
    if student.photo_url:
        old_path = os.path.join(settings.UPLOAD_DIR, os.path.basename(student.photo_url))
        if os.path.exists(old_path):
            try:
                os.remove(old_path)
            except OSError:
                pass
    student.photo_url = f"/uploads/{filename}"
    db.commit()
    return StudentPhotoResponse(photo_url=student.photo_url)