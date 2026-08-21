from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field


class BatchBase(BaseModel):
    name: str = Field(..., min_length=1, max_length=128)
    dance_style: str = Field(default="", max_length=128)
    level: str = Field(default="", max_length=64)
    schedule: str = Field(default="", max_length=255)
    monthly_fee: Decimal = Field(default=Decimal("0.00"), ge=0)
    is_active: bool = True
    notes: str | None = None


class BatchCreate(BatchBase):
    pass


class BatchUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=128)
    dance_style: str | None = Field(default=None, max_length=128)
    level: str | None = Field(default=None, max_length=64)
    schedule: str | None = Field(default=None, max_length=255)
    monthly_fee: Decimal | None = Field(default=None, ge=0)
    is_active: bool | None = None
    notes: str | None = None


class BatchOut(BatchBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    student_count: int = 0
    created_at: datetime
    updated_at: datetime


class BatchStats(BatchOut):
    active_student_count: int = 0


class BatchList(BaseModel):
    items: list[BatchOut]
    total: int