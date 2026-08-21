from datetime import date

from pydantic import BaseModel, ConfigDict, Field

RATING_MIN = 0
RATING_MAX = 100


class ProgressCreate(BaseModel):
    month: date
    skill_rating: int = Field(default=0, ge=RATING_MIN, le=RATING_MAX)
    performance_rating: int = Field(default=0, ge=RATING_MIN, le=RATING_MAX)
    discipline_rating: int = Field(default=0, ge=RATING_MIN, le=RATING_MAX)
    remarks: str | None = None


class ProgressUpdate(BaseModel):
    skill_rating: int | None = Field(default=None, ge=RATING_MIN, le=RATING_MAX)
    performance_rating: int | None = Field(default=None, ge=RATING_MIN, le=RATING_MAX)
    discipline_rating: int | None = Field(default=None, ge=RATING_MIN, le=RATING_MAX)
    remarks: str | None = None


class ProgressOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    student_id: int
    month: date
    skill_rating: int
    performance_rating: int
    discipline_rating: int
    overall_score: float
    attendance_percentage: float | None = None
    remarks: str | None = None


class ProgressWithStudent(ProgressOut):
    student_name: str = ""


class ProgressList(BaseModel):
    items: list[ProgressWithStudent]
    total: int