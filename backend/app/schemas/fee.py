from datetime import date, datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field

from app.models.fee import PAYMENT_METHODS


class FeeCreate(BaseModel):
    month: date
    amount_due: Decimal = Field(..., gt=0)


class FeePayment(BaseModel):
    amount_paid: Decimal = Field(..., gt=0)
    payment_date: date
    payment_method: str | None = Field(default=None, pattern="|".join(PAYMENT_METHODS))
    notes: str | None = Field(default=None, max_length=255)


class FeeUpdate(BaseModel):
    amount_due: Decimal | None = Field(default=None, gt=0)
    notes: str | None = Field(default=None, max_length=255)


class FeeOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    student_id: int
    month: date
    amount_due: Decimal
    amount_paid: Decimal
    status: str
    payment_date: date | None = None
    payment_method: str | None = None
    notes: str | None = None
    created_at: datetime
    updated_at: datetime


class FeeWithStudent(FeeOut):
    student_name: str = ""


class FeeList(BaseModel):
    items: list[FeeWithStudent]
    total: int