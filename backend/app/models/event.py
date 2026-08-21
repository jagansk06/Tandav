from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import Boolean, Date, DateTime, ForeignKey, Numeric, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.session import Base

PARTICIPATION_SOURCE_BATCH = "batch"
PARTICIPATION_SOURCE_INDIVIDUAL = "individual"

COSTUME_STATUS_NONE = "none"
COSTUME_STATUS_DUE = "due"
COSTUME_STATUS_PARTIAL = "partial"
COSTUME_STATUS_PAID = "paid"
COSTUME_STATUSES = (COSTUME_STATUS_NONE, COSTUME_STATUS_DUE, COSTUME_STATUS_PARTIAL, COSTUME_STATUS_PAID)


class Event(Base):
    __tablename__ = "events"

    id: Mapped[int] = mapped_column(primary_key=True)
    name: Mapped[str] = mapped_column(String(255), nullable=False, index=True)
    description: Mapped[str | None] = mapped_column(Text, nullable=True)
    event_type: Mapped[str] = mapped_column(String(64), default="", nullable=False)
    event_date: Mapped[date] = mapped_column(Date, nullable=False, index=True)
    location: Mapped[str | None] = mapped_column(String(255), nullable=True)
    batch_id: Mapped[int | None] = mapped_column(
        ForeignKey("batches.id", ondelete="SET NULL"), nullable=True, index=True
    )
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    batch: Mapped["Batch | None"] = relationship()
    participations: Mapped[list["EventParticipation"]] = relationship(
        back_populates="event", cascade="all, delete-orphan", passive_deletes=True
    )


class EventParticipation(Base):
    __tablename__ = "event_participations"
    __table_args__ = (
        # social
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    event_id: Mapped[int] = mapped_column(
        ForeignKey("events.id", ondelete="CASCADE"), nullable=False, index=True
    )
    student_id: Mapped[int] = mapped_column(
        ForeignKey("students.id", ondelete="CASCADE"), nullable=False, index=True
    )
    source: Mapped[str] = mapped_column(
        String(16), default=PARTICIPATION_SOURCE_INDIVIDUAL, nullable=False
    )
    is_costume_required: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    costume_fee_due: Mapped[Decimal] = mapped_column(
        Numeric(12, 2), default=Decimal("0.00"), nullable=False
    )
    costume_fee_paid: Mapped[Decimal] = mapped_column(
        Numeric(12, 2), default=Decimal("0.00"), nullable=False
    )
    costume_status: Mapped[str] = mapped_column(
        String(16), default=COSTUME_STATUS_NONE, nullable=False
    )
    costume_paid_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    costume_payment_method: Mapped[str | None] = mapped_column(String(32), nullable=True)
    notes: Mapped[str | None] = mapped_column(String(255), nullable=True)
    registered_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now()
    )

    event: Mapped["Event"] = relationship(back_populates="participations")
    student: Mapped["Student"] = relationship()


def costume_status_from(due: Decimal, paid: Decimal, required: bool) -> str:
    if not required or due <= 0:
        return COSTUME_STATUS_NONE
    if paid >= due:
        return COSTUME_STATUS_PAID
    if paid > 0:
        return COSTUME_STATUS_PARTIAL
    return COSTUME_STATUS_DUE