from datetime import date, datetime
from decimal import Decimal

from sqlalchemy import Date, DateTime, ForeignKey, Numeric, String, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.session import Base

FEE_STATUS_DUE = "due"
FEE_STATUS_PARTIAL = "partial"
FEE_STATUS_PAID = "paid"
FEE_STATUSES = (FEE_STATUS_DUE, FEE_STATUS_PARTIAL, FEE_STATUS_PAID)

PAYMENT_METHODS = ("cash", "upi", "card", "bank_transfer", "other")


class Fee(Base):
    """Monthly fee record per student (one row per student per month = fee history)."""

    __tablename__ = "fees"
    __table_args__ = (
        UniqueConstraint("student_id", "month", name="uq_fees_student_month"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    student_id: Mapped[int] = mapped_column(
        ForeignKey("students.id", ondelete="CASCADE"), nullable=False, index=True
    )
    month: Mapped[date] = mapped_column(Date, nullable=False, index=True)  # first day of month
    amount_due: Mapped[Decimal] = mapped_column(Numeric(12, 2), default=Decimal("0.00"), nullable=False)
    amount_paid: Mapped[Decimal] = mapped_column(Numeric(12, 2), default=Decimal("0.00"), nullable=False)
    status: Mapped[str] = mapped_column(String(16), default=FEE_STATUS_DUE, nullable=False)
    payment_date: Mapped[date | None] = mapped_column(Date, nullable=True)
    payment_method: Mapped[str | None] = mapped_column(String(32), nullable=True)
    notes: Mapped[str | None] = mapped_column(String(255), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    student: Mapped["Student"] = relationship(back_populates="fees")


def fee_status_from(amount_due: Decimal, amount_paid: Decimal) -> str:
    if amount_paid >= amount_due and amount_due > 0:
        return FEE_STATUS_PAID
    if amount_paid > 0:
        return FEE_STATUS_PARTIAL
    return FEE_STATUS_DUE