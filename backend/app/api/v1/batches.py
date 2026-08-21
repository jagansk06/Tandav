from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.session import get_db
from app.models.user import User
from app.models.batch import Batch
from app.models.student import Student
from app.schemas.batch import BatchCreate, BatchList, BatchOut, BatchUpdate

router = APIRouter(prefix="/batches", tags=["batches"])

Db = Annotated[Session, Depends(get_db)]


def _batch_out(batch: Batch) -> BatchOut:
    out = BatchOut.model_validate(batch)
    out.student_count = len(batch.students)
    return out


@router.get("", response_model=BatchList)
def list_batches(
    db: Db,
    _user: User = Depends(get_current_user),
    search: str | None = Query(default=None, max_length=128),
    active_only: bool = Query(default=False),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
):
    stmt = select(Batch)
    if active_only:
        stmt = stmt.where(Batch.is_active.is_(True))
    if search:
        stmt = stmt.where(Batch.name.ilike(f"%{search}%"))
    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    batches = db.scalars(
        stmt.order_by(Batch.name).limit(limit).offset(offset).options()
    ).all()
    items = db.scalars(
        select(Batch)
        .where(Batch.id.in_([b.id for b in batches]) if batches else Batch.id < 0)
        .order_by(Batch.name)
    ).all()
    by_id = {b.id: b for b in items}
    return BatchList(
        total=total,
        items=[_batch_out(by_id[b.id]) for b in batches],
    )


@router.post("", response_model=BatchOut, status_code=status.HTTP_201_CREATED)
def create_batch(payload: BatchCreate, db: Db, _user: User = Depends(get_current_user)):
    existing = db.scalar(select(Batch).where(Batch.name == payload.name.strip()))
    if existing:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="A batch with this name already exists")
    batch = Batch(**payload.model_dump())
    db.add(batch)
    db.commit()
    db.refresh(batch)
    return _batch_out(batch)


@router.get("/{batch_id}", response_model=BatchOut)
def get_batch(batch_id: int, db: Db, _user: User = Depends(get_current_user)):
    batch = db.get(Batch, batch_id)
    if batch is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Batch not found")
    return _batch_out(batch)


@router.put("/{batch_id}", response_model=BatchOut)
def update_batch(batch_id: int, payload: BatchUpdate, db: Db, _user: User = Depends(get_current_user)):
    batch = db.get(Batch, batch_id)
    if batch is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Batch not found")
    data = payload.model_dump(exclude_unset=True)
    if "name" in data:
        other = db.scalar(select(Batch).where(Batch.name == data["name"].strip(), Batch.id != batch_id))
        if other:
            raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail="A batch with this name already exists")
    for key, value in data.items():
        setattr(batch, key, value)
    db.commit()
    db.refresh(batch)
    return _batch_out(batch)


@router.delete("/{batch_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_batch(batch_id: int, db: Db, _user: User = Depends(get_current_user)):
    batch = db.get(Batch, batch_id)
    if batch is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Batch not found")
    db.delete(batch)
    db.commit()
    return None