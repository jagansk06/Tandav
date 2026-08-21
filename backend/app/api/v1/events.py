from datetime import date
from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.api.deps import get_current_user
from app.db.session import get_db
from app.models.batch import Batch
from app.models.event import (
    COSTUME_STATUS_NONE,
    Event,
    EventParticipation,
    PARTICIPATION_SOURCE_BATCH,
    costume_status_from,
)
from app.models.student import Student
from app.models.user import User
from app.schemas.event import (
    CostumeSummary,
    EventCreate,
    EventList,
    EventOut,
    EventUpdate,
    ParticipationCreate,
    ParticipationList,
    ParticipationOut,
    ParticipationUpdate,
)

router = APIRouter(prefix="/events", tags=["events"])

Db = Annotated[Session, Depends(get_db)]


def _event_out(db: Session, event: Event) -> EventOut:
    out = EventOut.model_validate(event)
    if event.batch_id is not None:
        out.batch_name = event.batch.name if event.batch else None
    out.participant_count = len(event.participations)
    return out


def _participation_out(db: Session, p: EventParticipation) -> ParticipationOut:
    out = ParticipationOut.model_validate(p)
    student = db.get(Student, p.student_id)
    if student:
        out.student_name = f"{student.first_name} {student.last_name}".strip()
        if student.batch:
            out.batch_name = student.batch.name
    return out


def _costume_summary(db: Session, event_id: int) -> CostumeSummary:
    rows = db.scalars(select(EventParticipation).where(EventParticipation.event_id == event_id)).all()
    total_due = sum((r.costume_fee_due for r in rows), Decimal("0.00"))
    total_paid = sum((r.costume_fee_paid for r in rows), Decimal("0.00"))
    return CostumeSummary(
        total_costume_due=total_due,
        total_costume_paid=total_paid,
        outstanding=total_due - total_paid,
    )


@router.get("", response_model=EventList)
def list_events(
    db: Db,
    _user: User = Depends(get_current_user),
    q: str | None = Query(default=None, max_length=128),
    batch_id: int | None = Query(default=None),
    upcoming_only: bool = Query(default=False),
    past_only: bool = Query(default=False),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
):
    stmt = select(Event)
    if q:
        stmt = stmt.where(Event.name.ilike(f"%{q}%"))
    if batch_id is not None:
        stmt = stmt.where(Event.batch_id == batch_id)
    today = date.today()
    if upcoming_only:
        stmt = stmt.where(Event.event_date >= today)
    if past_only:
        stmt = stmt.where(Event.event_date < today)
    total = db.scalar(select(func.count()).select_from(stmt.subquery())) or 0
    events = db.scalars(
        stmt.order_by(Event.event_date.desc()).limit(limit).offset(offset)
    ).all()
    return EventList(total=total, items=[_event_out(db, e) for e in events])


@router.post("", response_model=EventOut, status_code=status.HTTP_201_CREATED)
def create_event(payload: EventCreate, db: Db, _user: User = Depends(get_current_user)):
    if payload.batch_id is not None and db.get(Batch, payload.batch_id) is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Selected batch does not exist")
    event = Event(**payload.model_dump())
    db.add(event)
    db.commit()
    db.refresh(event)
    return _event_out(db, event)


@router.get("/{event_id}", response_model=EventOut)
def get_event(event_id: int, db: Db, _user: User = Depends(get_current_user)):
    event = db.get(Event, event_id)
    if event is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Event not found")
    return _event_out(db, event)


@router.put("/{event_id}", response_model=EventOut)
def update_event(
    event_id: int, payload: EventUpdate, db: Db, _user: User = Depends(get_current_user)
):
    event = db.get(Event, event_id)
    if event is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Event not found")
    data = payload.model_dump(exclude_unset=True)
    if data.get("batch_id") is not None and db.get(Batch, data["batch_id"]) is None:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail="Selected batch does not exist")
    for key, value in data.items():
        setattr(event, key, value)
    db.commit()
    db.refresh(event)
    return _event_out(db, event)


@router.delete("/{event_id}", status_code=status.HTTP_204_NO_CONTENT)
def delete_event(event_id: int, db: Db, _user: User = Depends(get_current_user)):
    event = db.get(Event, event_id)
    if event is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Event not found")
    db.delete(event)
    db.commit()
    return None


@router.get("/{event_id}/participants", response_model=ParticipationList)
def event_participants(
    event_id: int,
    db: Db,
    _user: User = Depends(get_current_user),
    costume_status: str | None = Query(default=None, pattern="^(none|due|partial|paid)$"),
):
    if db.get(Event, event_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Event not found")
    stmt = select(EventParticipation).where(EventParticipation.event_id == event_id)
    if costume_status:
        stmt = stmt.where(EventParticipation.costume_status == costume_status)
    parts = db.scalars(stmt.order_by(EventParticipation.registered_at)).all()
    return ParticipationList(total=len(parts), items=[_participation_out(db, p) for p in parts])


@router.get("/{event_id}/costume-summary", response_model=CostumeSummary)
def event_costume_summary(event_id: int, db: Db, _user: User = Depends(get_current_user)):
    if db.get(Event, event_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Event not found")
    return _costume_summary(db, event_id)


@router.post("/{event_id}/participants/batch/{batch_id}", response_model=ParticipationList, status_code=status.HTTP_201_CREATED)
def add_batch_participants(
    event_id: int,
    batch_id: int,
    db: Db,
    _user: User = Depends(get_current_user),
    costume_fee_due: Decimal = Query(default=Decimal("0.00"), ge=0),
):
    """Add all active students of a batch to an event (batch-based participation)."""
    event = db.get(Event, event_id)
    if event is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Event not found")
    batch = db.get(Batch, batch_id)
    if batch is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Batch not found")
    students = db.scalars(
        select(Student).where(Student.batch_id == batch_id, Student.is_active.is_(True))
    ).all()
    existing = {
        p.student_id
        for p in db.scalars(
            select(EventParticipation).where(EventParticipation.event_id == event_id)
        ).all()
    }
    added = 0
    for student in students:
        if student.id in existing:
            continue
        db.add(
            EventParticipation(
                event_id=event_id,
                student_id=student.id,
                source=PARTICIPATION_SOURCE_BATCH,
                costume_fee_due=costume_fee_due if costume_fee_due > 0 else Decimal("0.00"),
                costume_status=costume_status_from(costume_fee_due, Decimal("0.00"), True),
                is_costume_required=costume_fee_due > 0,
            )
        )
        added += 1
    db.commit()
    return event_participants(event_id, db, _user, costume_status=None)


@router.post("/{event_id}/participants", response_model=ParticipationList, status_code=status.HTTP_201_CREATED)
def add_participants(
    event_id: int,
    payload: ParticipationCreate,
    db: Db,
    _user: User = Depends(get_current_user),
):
    """Add individually selected students to an event."""
    if db.get(Event, event_id) is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Event not found")
    student_ids = set(payload.student_ids)
    found = {
        s.id
        for s in db.scalars(select(Student).where(Student.id.in_(student_ids))).all()
    }
    missing = student_ids - found
    if missing:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Students not found: {sorted(missing)}",
        )
    existing = {
        p.student_id
        for p in db.scalars(
            select(EventParticipation).where(EventParticipation.event_id == event_id)
        ).all()
    }
    for sid in student_ids - existing:
        db.add(
            EventParticipation(
                event_id=event_id,
                student_id=sid,
                source=payload.source,
                is_costume_required=payload.is_costume_required,
                costume_fee_due=payload.costume_fee_due,
                costume_status=costume_status_from(
                    payload.costume_fee_due, Decimal("0.00"), payload.is_costume_required
                ),
                notes=payload.notes,
            )
        )
    db.commit()
    return event_participants(event_id, db, _user, costume_status=None)


@router.put("/participants/{participation_id}", response_model=ParticipationOut)
def update_participation(
    participation_id: int,
    payload: ParticipationUpdate,
    db: Db,
    _user: User = Depends(get_current_user),
):
    """Update costume fee fields / notes for a participation record."""
    p = db.get(EventParticipation, participation_id)
    if p is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Participation not found")
    data = payload.model_dump(exclude_unset=True)
    if "is_costume_required" in data:
        p.is_costume_required = data.pop("is_costume_required")
        if not p.is_costume_required:
            p.costume_fee_due = Decimal("0.00")
            p.costume_fee_paid = Decimal("0.00")
            p.costume_paid_date = None
            p.costume_payment_method = None
    if "costume_fee_due" in data:
        new_due = data.pop("costume_fee_due")
        if new_due < p.costume_fee_paid:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Costume fee due cannot be less than the amount already paid",
            )
        p.costume_fee_due = new_due
        if new_due > 0:
            p.is_costume_required = True
    if "costume_fee_paid" in data:
        new_paid = p.costume_fee_paid + data.pop("costume_fee_paid")
        if new_paid > p.costume_fee_due:
            raise HTTPException(
                status_code=status.HTTP_400_BAD_REQUEST,
                detail="Costume fee payment cannot exceed the amount due",
            )
        p.costume_fee_paid = new_paid
        if p.costume_fee_due > 0:
            p.is_costume_required = True
    for key, value in data.items():
        setattr(p, key, value)
    p.costume_status = costume_status_from(p.costume_fee_due, p.costume_fee_paid, p.is_costume_required)
    if p.costume_status == COSTUME_STATUS_NONE:
        p.costume_paid_date = None
        p.costume_payment_method = None
    db.commit()
    db.refresh(p)
    return _participation_out(db, p)


@router.delete("/participants/{participation_id}", status_code=status.HTTP_204_NO_CONTENT)
def remove_participant(
    participation_id: int,
    db: Db,
    _user: User = Depends(get_current_user),
):
    p = db.get(EventParticipation, participation_id)
    if p is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Participation not found")
    db.delete(p)
    db.commit()
    return None


@router.get("/students/{student_id}/history", response_model=ParticipationList)
def student_participation_history(
    student_id: int,
    db: Db,
    _user: User = Depends(get_current_user),
):
    """Event participation history for a single student."""
    student = db.get(Student, student_id)
    if student is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Student not found")
    parts = db.scalars(
        select(EventParticipation)
        .where(EventParticipation.student_id == student_id)
        .order_by(EventParticipation.registered_at.desc())
    ).all()
    return ParticipationList(total=len(parts), items=[_participation_out(db, p) for p in parts])