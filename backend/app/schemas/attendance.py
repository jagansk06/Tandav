from datetime import date, datetime

from pydantic import BaseModel, ConfigDict, Field

from app.models.attendance import ATTENDANCE_STATUSES


class AttendanceMark(BaseModel):
    student_id: int
    status: str = Field(..., pattern="|".join(ATTENDANCE_STATUSES))
    notes: str | None = Field(default=None, max_length=255)


class AttendanceBatchSave(BaseModel):
    date: date
    batch_id: int
    records: list[AttendanceMark]


class AttendanceStatusUpdate(BaseModel):
    status: str = Field(..., pattern="|".join(ATTENDANCE_STATUSES))
    notes: str | None = Field(default=None, max_length=255)


class AttendanceOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    student_id: int
    batch_id: int | None = None
    attendance_date: date
    status: str
    notes: str | None = None
    marked_at: datetime


class AttendanceStudentRow(BaseModel):
    student_id: int
    student_name: str
    batch_id: int | None = None
    batch_name: str | None = None
    status: str | None = None
    attendance_id: int | None = None
    notes: str | None = None


class AttendanceDayOut(BaseModel):
    date: date
    batch_id: int
    batch_name: str
    total: int
    present: int
    absent: int
    late: int
    unmarked: int
    percentage: float
    records: list[AttendanceStudentRow]


class MonthlyAttendanceOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    student_id: int
    month: date
    total_classes: int
    presents: int
    absents: int
    lates: int
    percentage: float


class MonthlyAttendanceSummary(BaseModel):
    month: date
    student_id: int
    student_name: str
    batch_id: int | None = None
    batch_name: str | None = None
    total_classes: int
    presents: int
    absents: int
    lates: int
    percentage: float