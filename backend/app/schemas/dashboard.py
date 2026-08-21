from datetime import date
from decimal import Decimal

from pydantic import BaseModel


class DashboardStats(BaseModel):
    total_students: int
    active_students: int
    total_batches: int
    active_batches: int
    total_events: int
    upcoming_events: int
    today_present: int
    today_absent: int
    today_late: int
    today_unmarked: int
    today_total_marked: int


class FeeSummary(BaseModel):
    month: date
    total_due: Decimal
    total_paid: Decimal
    outstanding: Decimal
    paid_count: int
    partial_count: int
    due_count: int
    total_records: int


class UpcomingEvent(BaseModel):
    id: int
    name: str
    event_type: str
    event_date: date
    location: str | None = None
    participant_count: int = 0


class RecentStudent(BaseModel):
    id: int
    full_name: str
    batch_name: str | None = None
    joined: date


class DashboardOut(BaseModel):
    stats: DashboardStats
    fee_summary: FeeSummary
    monthly_attendance: list[dict]
    upcoming_events: list[UpcomingEvent]
    recent_students: list[RecentStudent]


class MonthlyReportRow(BaseModel):
    batch_id: int | None = None
    batch_name: str = "General"
    total_students: int
    attendance_total: int
    attendance_present: int
    attendance_percentage: float
    fees_due: Decimal
    fees_paid: Decimal
    fee_outstanding: Decimal
    fee_collection_rate: float


class MonthlyReport(BaseModel):
    month: date
    rows: list[MonthlyReportRow]

    @property
    def total_fees_paid(self) -> Decimal:
        return sum((r.fees_paid for r in self.rows), Decimal("0.00"))

    @property
    def total_due(self) -> Decimal:
        return sum((r.fees_due for r in self.rows), Decimal("0.00"))