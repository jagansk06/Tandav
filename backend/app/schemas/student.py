from datetime import date, datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field, field_validator


class StudentBase(BaseModel):
    first_name: str = Field(..., min_length=1, max_length=128)
    last_name: str = Field(default="", max_length=128)
    gender: str = Field(default="", max_length=16)
    dob: date | None = None
    phone: str = Field(..., min_length=5, max_length=20)
    email: str | None = Field(default=None, max_length=255)
    address: str | None = None
    emergency_contact_name: str | None = Field(default=None, max_length=128)
    emergency_contact_phone: str | None = Field(default=None, max_length=20)
    batch_id: int | None = None
    monthly_fee: Decimal = Field(default=Decimal("0.00"), ge=0, le=Decimal("9999999999.99"))
    join_date: date | None = None
    is_active: bool = True
    notes: str | None = None

    @field_validator("email")
    @classmethod
    def validate_email(cls, v: str | None) -> str | None:
        if v is not None:
            v = v.strip() or None
        return v


class StudentCreate(StudentBase):
    pass


class StudentUpdate(BaseModel):
    first_name: str | None = Field(default=None, min_length=1, max_length=128)
    last_name: str | None = Field(default=None, max_length=128)
    gender: str | None = Field(default=None, max_length=16)
    dob: date | None = None
    phone: str | None = Field(default=None, min_length=5, max_length=20)
    email: str | None = Field(default=None, max_length=255)
    address: str | None = None
    emergency_contact_name: str | None = Field(default=None, max_length=128)
    emergency_contact_phone: str | None = Field(default=None, max_length=20)
    batch_id: int | None = None
    monthly_fee: Decimal | None = Field(default=None, ge=0, le=Decimal("9999999999.99"))
    join_date: date | None = None
    is_active: bool | None = None
    notes: str | None = None


class StudentOut(StudentBase):
    model_config = ConfigDict(from_attributes=True)

    id: int
    photo_url: str | None = None
    batch_name: str | None = None
    created_at: datetime
    updated_at: datetime


class StudentList(BaseModel):
    items: list[StudentOut]
    total: int


class StudentPhotoResponse(BaseModel):
    photo_url: str