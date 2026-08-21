"""Dev/seed data bootstrap.

WARNING: This only ever runs explicitly (`python -m app.seed`) and is meant
for development/demo use against a non-production database. It creates an
initial admin user (if none exists) and a small set of demo batches,
students, attendance, fees, events and progress records so the UI can be
exercised end-to-end. Production data is never seeded by the server itself.
"""

import random
import sys
from datetime import date, timedelta
from decimal import Decimal

from sqlalchemy import select

from app.api.v1.attendance import recompute_month
from app.core.config import get_settings
from app.core.security import hash_password
from app.db.session import SessionLocal
from app.models.attendance import Attendance
from app.models.batch import Batch
from app.models.event import Event, EventParticipation
from app.models.fee import Fee
from app.models.progress import MonthlyProgress
from app.models.student import Student
from app.models.user import User
from app.models.event import PARTICIPATION_SOURCE_BATCH, costume_status_from

SEED_BATCHES = [
    ("Classical Foundations", "Bharatanatyam", "Beginner", "Mon/Wed 5:00-6:30 PM", "2000.00"),
    ("Kathak Intermediate", "Kathak", "Intermediate", "Tue/Thu 6:30-8:00 PM", "2500.00"),
    ("Bollywood Groove", "Bollywood", "All levels", "Sat 4:00-5:30 PM + Sun 10:00-11:30 AM", "2200.00"),
    ("Contemporary Flow", "Contemporary", "Intermediate", "Fri 5:00-6:30 PM", "2400.00"),
]

FIRST_NAMES_M = ["Aarav", "Vihaan", "Arjun", "Kabir", "Rohan", "Ishaan", "Dev", "Karan", "Yash", "Aditya"]
FIRST_NAMES_F = ["Aanya", "Diya", "Ananya", "Ishita", "Kavya", "Meera", "Saanvi", "Tanvi", "Riya", "Anika"]
LAST_NAMES = ["Sharma", "Verma", "Patel", "Reddy", "Nair", "Iyer", "Kapoor", "Singh", "Mehta", "Joshi"]
EVENT_TYPES = ["Annual Day", "Navratri Special", "Competition", "Workshop", "Stage Show"]


def _month_start(d: date) -> date:
    return d.replace(day=1)


def run(force: bool = False) -> None:
    settings = get_settings()
    db = SessionLocal()
    try:
        if db.scalar(select(User).limit(1)) is None:
            db.add(
                User(
                    username=settings.SEED_ADMIN_USERNAME,
                    full_name=settings.SEED_ADMIN_FULL_NAME,
                    email=settings.SEED_ADMIN_EMAIL or None,
                    password_hash=hash_password(settings.SEED_ADMIN_PASSWORD),
                )
            )
            print("Created admin user", settings.SEED_ADMIN_USERNAME)

        if db.scalar(select(Batch).limit(1)) is not None and not force:
            print("Seed data already present (use --force to re-seed).")
            return

        if force:
            db.query(Student).delete()
            db.query(Batch).delete()
            db.query(Event).delete()
            db.query(Fee).delete()
            db.query(Attendance).delete()
            db.query(MonthlyProgress).delete()

        batches = []
        for name, style, level, schedule, fee in SEED_BATCHES:
            b = Batch(
                name=name,
                dance_style=style,
                level=level,
                schedule=schedule,
                monthly_fee=Decimal(fee),
            )
            db.add(b)
            batches.append(b)
        db.flush()

        today = date.today()
        this_month = _month_start(today)
        last_month = _month_start(today - timedelta(days=20))
        prev_month = _month_start(today - timedelta(days=50))
        months = [prev_month, last_month, this_month]

        students = []
        rng = random.Random(42)
        batch_of_open_students = []
        for bi, b in enumerate(batches):
            names = FIRST_NAMES_F if bi % 2 == 0 else FIRST_NAMES_M
            count = 7 + bi
            for i in range(count):
                first = names[i % len(names)]
                s = Student(
                    first_name=first,
                    last_name=LAST_NAMES[(bi * 3 + i) % len(LAST_NAMES)],
                    gender="Female" if bi % 2 == 0 else "Male",
                    dob=date(today.year - rng.randint(8, 22), rng.randint(1, 12), rng.randint(1, 28)),
                    phone=f"9{rng.randint(100000000, 999999999)}",
                    email=f"{first.lower()}{i}{bi}@example.com",
                    batch_id=b.id,
                    join_date=today - timedelta(days=rng.randint(30, 600)),
                    is_active=True,
                )
                db.add(s)
                students.append(s)
        for i in range(4):
            first = FIRST_NAMES_F[i]
            s = Student(
                first_name=first,
                last_name=LAST_NAMES[(10 + i) % len(LAST_NAMES)],
                gender="Female",
                dob=date(today.year - rng.randint(9, 20), rng.randint(1, 12), rng.randint(1, 28)),
                phone=f"8{rng.randint(100000000, 999999999)}",
                email=f"{first.lower()}{i}@example.com",
                batch_id=None,
                join_date=today - timedelta(days=rng.randint(20, 300)),
            )
            db.add(s)
            batch_of_open_students.append(s)
        db.flush()

        for s in students + batch_of_open_students:
            for m in months:
                for day_offset in range(0, 28, 4):
                    d = m + timedelta(days=min(day_offset, 24))
                    if d > today:
                        break
                    status = rng.choices(
                        ["present", "absent", "late"], weights=[75, 15, 10], k=1
                    )[0]
                    db.add(
                        Attendance(
                            student_id=s.id,
                            batch_id=s.batch_id,
                            attendance_date=d,
                            status=status,
                        )
                    )
        db.flush()
        for m in months:
            recompute_month(db, m)

        for s in students:
            for m in [prev_month, last_month]:
                fee = Fee(
                    student_id=s.id,
                    month=m,
                    amount_due=s.batch.monthly_fee if s.batch else Decimal("2200.00"),
                )
                if rng.random() < 0.8:
                    fee.amount_paid = fee.amount_due
                    fee.status = "paid"
                    fee.payment_date = m + timedelta(days=rng.randint(1, 20))
                    fee.payment_method = rng.choice(["cash", "upi", "card"])
                db.add(fee)
            db.flush()

        events = [
            Event(
                name="Annual Day Celebration 2026",
                description="Grand annual dance showcase",
                event_type="Annual Day",
                event_date=today + timedelta(days=45),
                location="City Auditorium",
            ),
            Event(
                name="Navratri Garba Night",
                description="Traditional garba and dandiya performance",
                event_type="Navratri Special",
                event_date=today + timedelta(days=120),
                location="Studio Hall",
            ),
            Event(
                name="State Level Dance Competition",
                description="Representing the studio at the state competition",
                event_type="Competition",
                event_date=today - timedelta(days=10),
                location="District Convention Centre",
            ),
        ]
        db.add_all(events)
        db.flush()
        comp = events[2]
        for s in students[:10]:
            pf = Decimal("1500.00")
            paid = pf if rng.random() < 0.9 else Decimal("0.00")
            db.add(
                EventParticipation(
                    event_id=comp.id,
                    student_id=s.id,
                    source=PARTICIPATION_SOURCE_BATCH,
                    is_costume_required=True,
                    costume_fee_due=pf,
                    costume_fee_paid=paid,
                    costume_status=costume_status_from(pf, paid, True),
                    costume_paid_date=(comp.event_date - timedelta(days=5)) if paid else None,
                    costume_payment_method="cash" if paid else None,
                )
            )
        open_event = events[0]
        for s in batch_of_open_students:
            db.add(
                EventParticipation(
                    event_id=open_event.id,
                    student_id=s.id,
                    source="individual",
                    is_costume_required=False,
                    costume_fee_due=Decimal("0.00"),
                    costume_status="none",
                )
            )
        db.flush()

        for s in students[:14]:
            db.add(
                MonthlyProgress(
                    student_id=s.id,
                    month=last_month,
                    skill_rating=rng.randint(55, 95),
                    performance_rating=rng.randint(50, 92),
                    discipline_rating=rng.randint(60, 96),
                    remarks="Consistent practice. Focus on posture and expressions.",
                )
            )
        db.commit()
        print(
            f"Seeded {len(batches)} batches, {len(students)} batch students, "
            f"{len(batch_of_open_students)} open students, {len(events)} events."
        )
    finally:
        db.close()


if __name__ == "__main__":
    run(force="--force" in sys.argv)