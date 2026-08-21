from datetime import date, datetime

from sqlalchemy import Date, DateTime, Float, ForeignKey, Integer, String, Text, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.session import Base


class MonthlyProgress(Base):
    __tablename__ = "monthly_progress"
    __table_args__ = (
        UniqueConstraint("student_id", "month", name="uq_monthly_progress_student_month"),
    )

    id: Mapped[int] = mapped_column(primary_key=True)
    student_id: Mapped[int] = mapped_column(
        ForeignKey("students.id", ondelete="CASCADE"), nullable=False, index=True
    )
    month: Mapped[date] = mapped_column(Date, nullable=False, index=True)  # first day of month
    skill_rating: Mapped[int] = mapped_column(Integer, default=0, nullable=False)  # 0-100
    performance_rating: Mapped[int] = mapped_column(Integer, default=0, nullable=False)  # 0-100
    discipline_rating: Mapped[int] = mapped_column(Integer, default=0, nullable=False)  # 0-100
    attendance_percentage: Mapped[float | None] = mapped_column(Float, nullable=True)
    remarks: Mapped[str | None] = mapped_column(Text, nullable=True)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    @property
    def overall_score(self) -> float:
        scores = [self.skill_rating, self.performance_rating, self.discipline_rating]
        effective = [s for s in scores if s > 0]
        if not effective:
            return 0.0
        return round(sum(effective) / len(effective), 1)