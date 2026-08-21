from datetime import date, datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field

from app.models.event import COSTUME_STATUSES, PARTICIPATION_SOURCE_BATCH, PARTICIPATION_SOURCE_INDIVIDUAL
from app.models.fee import PAYMENT_METHODS


class EventBase(BaseModel):
    name: str = Field(..., min_length=1, max_length=255)
    description: str | None = None
    event_type: str = Field(default="", max_length=64)
    event_date: date
    location: str | None = Field(default=None, max_length=255)
    batch_id: int | None = None
    is_active: bool = True


class EventCreate(EventBase):
    pass


class EventUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=255)
    description: str | None = None
    event_type: str | None = Field(default=None, max_length=64)
    event_date: date | None = None
    location: str | None = Field(default=None, max_length=255)
    batch_id: int | None = None
    is_active: bool | None = None


class EventOut(EventBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    batch_name: str | None = None
    participant_count: int = 0
    created_at: datetime


class EventList(BaseModel):
    items: list[EventOut]
    total: int


class ParticipationCreate(BaseModel):
    student_ids: list[int] = Field(..., min_length=1)
    source: str = Field(default=PARTICIPATION_SOURCE_INDIVIDUAL, pattern=f"({PARTICIPATION_SOURCE_BATCH}|{PARTICIPATION_SOURCE_INDIVIDUAL})")
    is_costume_required: bool = False
    costume_fee_due: Decimal = Field(default=Decimal("0.00"), ge=0)
    notes: str | None = Field(default=None, max_length=255)


class ParticipationUpdate(BaseModel):
    is_costume_required: bool | None = None
    costume_fee_due: Decimal | None = Field(default=None, ge=0)
    costume_fee_paid: Decimal | None = Field(default=None, ge=0)
    costume_paid_date: date | None = None
    costume_payment_method: str | None = Field(default=None, pattern="|".join(PAYMENT_METHODS))
    notes: str | None = Field(default=None, max_length=255)


class ParticipationOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    event_id: int
    student_id: int
    student_name: str = ""
    batch_name: str | None = None
    source: str
    is_costume_required: bool
    costume_fee_due: Decimal
    costume_fee_paid: Decimal
    costume_status: str
    costume_paid_date: date | None = None
    costume_payment_method: str | None = None
    notes: str | None = None
    registered_at: datetime


class ParticipationList(BaseModel):
    items: list[ParticipationOut]
    total: int


class CostumeSummary(BaseModel):
    total_costume_due: Decimal
    total_costume_paid: Decimal
    outstanding: Decimal