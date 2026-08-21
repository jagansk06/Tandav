"""End-to-end API tests for the Tandav backend (run against a real PostgreSQL test DB)."""

from datetime import date
from decimal import Decimal


class TestAuth:
    def test_login_success(self, client, admin_user):
        resp = client.post("/api/v1/auth/login", json={"username": "admin", "password": "admin123"})
        assert resp.status_code == 200
        body = resp.json()
        assert body["access_token"]
        assert body["user"]["username"] == "admin"

    def test_login_wrong_password(self, client, admin_user):
        resp = client.post("/api/v1/auth/login", json={"username": "admin", "password": "nope"})
        assert resp.status_code == 401

    def test_me_requires_token(self, client):
        assert client.get("/api/v1/auth/me").status_code == 401

    def test_me(self, client, admin_user, auth_headers):
        resp = client.get("/api/v1/auth/me", headers=auth_headers)
        assert resp.status_code == 200
        assert resp.json()["full_name"] == "Test Admin"

    def test_change_password(self, client, admin_user, auth_headers):
        resp = client.post(
            "/api/v1/auth/change-password",
            json={"current_password": "admin123", "new_password": "newpass1"},
            headers=auth_headers,
        )
        assert resp.status_code == 200
        resp = client.post("/api/v1/auth/login", json={"username": "admin", "password": "newpass1"})
        assert resp.status_code == 200


class TestBatches:
    def test_crud(self, client, auth_headers):
        created = client.post(
            "/api/v1/batches", json={"name": "Kathak Basic", "monthly_fee": "1200.00"}, headers=auth_headers
        )
        assert created.status_code == 201
        bid = created.json()["id"]
        assert client.get(f"/api/v1/batches/{bid}", headers=auth_headers).status_code == 200
        updated = client.put(f"/api/v1/batches/{bid}", json={"name": "Kathak Advanced"}, headers=auth_headers)
        assert updated.status_code == 200
        assert updated.json()["name"] == "Kathak Advanced"
        assert client.delete(f"/api/v1/batches/{bid}", headers=auth_headers).status_code == 204
        assert client.get(f"/api/v1/batches/{bid}", headers=auth_headers).status_code == 404

    def test_duplicate_name_rejected(self, client, auth_headers):
        client.post("/api/v1/batches", json={"name": "SameName"}, headers=auth_headers)
        resp = client.post("/api/v1/batches", json={"name": "SameName"}, headers=auth_headers)
        assert resp.status_code == 409

    def test_search_and_active_filter(self, client, auth_headers):
        client.post("/api/v1/batches", json={"name": "Bharat Natyam"}, headers=auth_headers)
        client.post("/api/v1/batches", json={"name": "Bollywood", "is_active": False}, headers=auth_headers)
        resp = client.get("/api/v1/batches?search=bol", headers=auth_headers)
        assert resp.json()["total"] == 1
        resp = client.get("/api/v1/batches?active_only=true", headers=auth_headers)
        assert resp.json()["total"] == 1

    def test_validation(self, client, auth_headers):
        assert client.post("/api/v1/batches", json={"name": ""}, headers=auth_headers).status_code == 422


class TestStudents:
    def test_crud(self, client, auth_headers, seeded_batch):
        created = client.post(
            "/api/v1/students",
            json={"first_name": "Meera", "phone": "9876543210", "batch_id": seeded_batch["id"]},
            headers=auth_headers,
        )
        assert created.status_code == 201
        sid = created.json()["id"]
        assert created.json()["batch_name"] == "Test Batch"
        updated = client.put(f"/api/v1/students/{sid}", json={"last_name": "Iyer"}, headers=auth_headers)
        assert updated.status_code == 200
        assert updated.json()["last_name"] == "Iyer"
        assert client.delete(f"/api/v1/students/{sid}", headers=auth_headers).status_code == 204
        assert client.get(f"/api/v1/students/{sid}", headers=auth_headers).status_code == 404

    def test_search_by_name_and_phone(self, client, auth_headers, seeded_students):
        resp = client.get("/api/v1/students?q=aria", headers=auth_headers)
        assert resp.json()["total"] == 1
        resp = client.get("/api/v1/students?q=9Bella0000000", headers=auth_headers)
        assert resp.json()["total"] == 1

    def test_filter_by_batch(self, client, auth_headers, seeded_students, seeded_batch):
        resp = client.get(f"/api/v1/students?batch_id={seeded_batch['id']}", headers=auth_headers)
        assert resp.json()["total"] == 3

    def test_invalid_batch_rejected(self, client, auth_headers):
        resp = client.post("/api/v1/students", json={"first_name": "X", "phone": "12345", "batch_id": 999}, headers=auth_headers)
        assert resp.status_code == 400

    def test_photo_upload_and_replacement(self, client, auth_headers, seeded_students):
        sid = seeded_students[0]
        png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
        resp = client.post(
            f"/api/v1/students/{sid}/photo",
            files={"file": ("photo.png", png, "image/png")},
            headers=auth_headers,
        )
        assert resp.status_code == 200
        assert resp.json()["photo_url"].startswith("/uploads/")
        resp2 = client.post(
            f"/api/v1/students/{sid}/photo",
            files={"file": ("photo2.jpg", png, "image/jpeg")},
            headers=auth_headers,
        )
        assert resp2.status_code == 200
        assert resp.json()["photo_url"] != resp2.json()["photo_url"]

    def test_photo_invalid_type(self, client, auth_headers, seeded_students):
        resp = client.post(
            f"/api/v1/students/{seeded_students[0]}/photo",
            files={"file": ("doc.pdf", b"%PDF-1.4", "application/pdf")},
            headers=auth_headers,
        )
        assert resp.status_code == 400

    def test_required_fields(self, client, auth_headers):
        resp = client.post("/api/v1/students", json={"first_name": "", "phone": ""}, headers=auth_headers)
        assert resp.status_code == 422


class TestAttendance:
    def test_mark_day_and_monthly_math(self, client, auth_headers, seeded_students, seeded_batch):
        day = "2026-08-05"
        records = [
            {"student_id": s, "status": "present" if i < 2 else "absent"} for i, s in enumerate(seeded_students)
        ]
        resp = client.put(
            "/api/v1/attendance/day",
            json={"date": day, "batch_id": seeded_batch["id"], "records": records},
            headers=auth_headers,
        )
        assert resp.status_code == 200
        body = resp.json()
        assert body["total"] == 3
        assert body["present"] == 2
        assert body["absent"] == 1
        assert body["percentage"] == round(2 / 3 * 100, 1)

        monthly = client.get("/api/v1/attendance/monthly?month=2026-08-01", headers=auth_headers).json()
        row = next(r for r in monthly if r["student_id"] == seeded_students[0])
        assert row["total_classes"] == 1
        assert row["presents"] == 1
        assert row["percentage"] == 100.0

    def test_upsert_overwrites(self, client, auth_headers, seeded_students, seeded_batch):
        day = "2026-08-06"
        payload = lambda status: {"date": day, "batch_id": seeded_batch["id"], "records": [
            {"student_id": seeded_students[0], "status": status}
        ]}
        client.put("/api/v1/attendance/day", json=payload("present"), headers=auth_headers)
        resp = client.put("/api/v1/attendance/day", json=payload("absent"), headers=auth_headers)
        assert resp.json()["records"][0]["status"] == "absent"
        day2 = client.get(f"/api/v1/attendance/day?date={day}&batch_id={seeded_batch['id']}", headers=auth_headers).json()
        assert day2["absent"] == 1

    def test_duplicate_student_rejected(self, client, auth_headers, seeded_students, seeded_batch):
        resp = client.put(
            "/api/v1/attendance/day",
            json={
                "date": "2026-08-06",
                "batch_id": seeded_batch["id"],
                "records": [
                    {"student_id": seeded_students[0], "status": "present"},
                    {"student_id": seeded_students[0], "status": "present"},
                ],
            },
            headers=auth_headers,
        )
        assert resp.status_code == 400

    def test_invalid_status_rejected(self, client, auth_headers, seeded_students, seeded_batch):
        resp = client.put(
            "/api/v1/attendance/day",
            json={"date": "2026-08-06", "batch_id": seeded_batch["id"],
                  "records": [{"student_id": seeded_students[0], "status": "maybe"}]},
            headers=auth_headers,
        )
        assert resp.status_code == 422

    def test_late_counts_as_present_for_percentage(self, client, auth_headers, seeded_students, seeded_batch):
        resp = client.put(
            "/api/v1/attendance/day",
            json={"date": "2026-08-07", "batch_id": seeded_batch["id"], "records": [
                {"student_id": seeded_students[0], "status": "late"},
                {"student_id": seeded_students[1], "status": "present"},
                {"student_id": seeded_students[2], "status": "absent"},
            ]},
            headers=auth_headers,
        )
        assert resp.json()["percentage"] == round(2 / 3 * 100, 1)


class TestFees:
    def _create(self, client, headers, sid, month="2026-08-01", due="1500.00"):
        return client.post(
            f"/api/v1/fees/students/{sid}/{month}",
            json={"month": month, "amount_due": due},
            headers=headers,
        )

    def test_create_and_payment_flow(self, client, auth_headers, seeded_students):
        sid = seeded_students[0]
        created = self._create(client, auth_headers, sid)
        assert created.status_code == 201
        fee = created.json()
        assert fee["status"] == "due"
        assert fee["amount_paid"] == "0.00"

        partial = client.put(
            f"/api/v1/fees/{fee['id']}/payment",
            json={"amount_paid": "500.00", "payment_date": "2026-08-10", "payment_method": "upi"},
            headers=auth_headers,
        )
        assert partial.status_code == 200
        assert partial.json()["status"] == "partial"

        full = client.put(
            f"/api/v1/fees/{fee['id']}/payment",
            json={"amount_paid": "1000.00", "payment_date": "2026-08-12", "payment_method": "upi"},
            headers=auth_headers,
        )
        assert full.status_code == 200
        assert full.json()["status"] == "paid"
        assert full.json()["amount_paid"] == "1500.00"

    def test_overpayment_rejected(self, client, auth_headers, seeded_students):
        fee = self._create(client, auth_headers, seeded_students[1], due="1000.00").json()
        resp = client.put(
            f"/api/v1/fees/{fee['id']}/payment",
            json={"amount_paid": "2000.00", "payment_date": "2026-08-10"},
            headers=auth_headers,
        )
        assert resp.status_code == 400

    def test_duplicate_month_rejected(self, client, auth_headers, seeded_students):
        assert self._create(client, auth_headers, seeded_students[2]).status_code == 201
        assert self._create(client, auth_headers, seeded_students[2]).status_code == 409

    def test_fee_history_list_and_summary(self, client, auth_headers, seeded_students):
        sid = seeded_students[0]
        self._create(client, auth_headers, sid, month="2026-07-01", due="1500.00")
        self._create(client, auth_headers, sid, month="2026-08-01", due="1500.00")
        history = client.get(f"/api/v1/fees?student_id={sid}", headers=auth_headers).json()
        assert history["total"] == 2
        summary = client.get("/api/v1/fees/summary?month=2026-08-01", headers=auth_headers).json()
        assert summary["total_due"] == "1500.00"
        assert summary["collection_rate"] == 0.0

    def test_calculate_history(self, client, auth_headers, seeded_students):
        """Fee history per student reflects each recorded month."""
        sid = seeded_students[2]
        for m, due in [("2026-05-01", "1400.00"), ("2026-06-01", "1400.00"), ("2026-07-01", "1400.00")]:
            fee = self._create(client, auth_headers, sid, month=m, due=due).json()
            client.put(
                f"/api/v1/fees/{fee['id']}/payment",
                json={"amount_paid": "1400.00", "payment_date": "2026-07-01", "payment_method": "cash"},
                headers=auth_headers,
            )
        history = client.get(f"/api/v1/fees?student_id={sid}", headers=auth_headers).json()
        assert history["total"] == 3
        assert all(f["status"] == "paid" for f in history["items"])
        total = sum(Decimal(f["amount_paid"]) for f in history["items"])
        assert total == Decimal("4200.00")


class TestMonthlyFees:
    def _student(self, client, headers, name="Ananya", monthly_fee="2000.00", batch_id=None, active=True):
        payload = {
            "first_name": name,
            "phone": f"9{name}0000000",
            "monthly_fee": monthly_fee,
            "is_active": active,
        }
        if batch_id is not None:
            payload["batch_id"] = batch_id
        resp = client.post("/api/v1/students", json=payload, headers=headers)
        assert resp.status_code == 201, resp.text
        return resp.json()

    def test_student_monthly_fee_field(self, client, auth_headers):
        created = self._student(client, auth_headers, name="FeeField")
        assert created["monthly_fee"] == "2000.00"
        updated = client.put(
            f"/api/v1/students/{created['id']}",
            json={"monthly_fee": "2500.00"},
            headers=auth_headers,
        )
        assert updated.json()["monthly_fee"] == "2500.00"
        assert client.get(f"/api/v1/students/{created['id']}", headers=auth_headers).json()["monthly_fee"] == "2500.00"

    def test_generate_creates_for_active_only(self, client, auth_headers):
        self._student(client, auth_headers, name="GenActive", monthly_fee="2000.00")
        self._student(client, auth_headers, name="GenInactive", monthly_fee="1500.00", active=False)
        self._student(client, auth_headers, name="GenZero", monthly_fee="0.00")

        resp = client.post("/api/v1/fees/generate?month=2026-09-01", headers=auth_headers)
        assert resp.status_code == 200
        assert resp.json()["created"] == 1

        fees = client.get("/api/v1/fees?month=2026-09-01", headers=auth_headers).json()
        assert fees["total"] == 1
        assert fees["items"][0]["amount_due"] == "2000.00"
        assert fees["items"][0]["status"] == "due"

    def test_generate_idempotent(self, client, auth_headers):
        self._student(client, auth_headers, name="Idem")
        assert client.post("/api/v1/fees/generate?month=2026-09-01", headers=auth_headers).json()["created"] == 1
        assert client.post("/api/v1/fees/generate?month=2026-09-01", headers=auth_headers).json()["created"] == 0
        assert client.post("/api/v1/fees/generate?month=2026-09-01", headers=auth_headers).json()["created"] == 0
        fees = client.get("/api/v1/fees?month=2026-09-01", headers=auth_headers).json()
        assert fees["total"] == 1

    def test_generate_skips_students_joined_later(self, client, auth_headers):
        resp = client.post(
            "/api/v1/students",
            json={"first_name": "FutureJoin", "phone": "9990000000",
                  "monthly_fee": "2000.00", "join_date": "2026-10-05"},
            headers=auth_headers,
        )
        assert resp.status_code == 201
        assert client.post("/api/v1/fees/generate?month=2026-09-01", headers=auth_headers).json()["created"] == 0
        assert client.post("/api/v1/fees/generate?month=2026-10-01", headers=auth_headers).json()["created"] == 1

    def test_generate_requires_auth(self, client):
        assert client.post("/api/v1/fees/generate").status_code == 401

    def test_auto_generate_via_summary_and_list(self, client, auth_headers):
        s = self._student(client, auth_headers, name="AutoGen")
        summary = client.get("/api/v1/fees/summary?month=2026-09-01", headers=auth_headers).json()
        assert summary["total_records"] == 1
        assert summary["total_due"] == "2000.00"
        history = client.get(f"/api/v1/fees?student_id={s['id']}", headers=auth_headers).json()
        assert history["total"] >= 1

    def test_exact_scenario_aug_paid_sep_due(self, client, auth_headers):
        """Ananya: ₹2,000/month. Aug generated+paid, Sep generated, Aug stays PAID."""
        s = self._student(client, auth_headers, name="Ananya", monthly_fee="2000.00")
        sid = s["id"]

        assert client.post("/api/v1/fees/generate?month=2026-08-01", headers=auth_headers).json()["created"] == 1
        fees = client.get(f"/api/v1/fees?student_id={sid}&month=2026-08-01", headers=auth_headers).json()
        assert fees["total"] == 1
        fid = fees["items"][0]["id"]
        assert fees["items"][0]["amount_due"] == "2000.00"
        assert fees["items"][0]["status"] == "due"

        paid = client.put(
            f"/api/v1/fees/{fid}/payment",
            json={"amount_paid": "2000.00", "payment_date": "2026-08-15", "payment_method": "upi"},
            headers=auth_headers,
        )
        assert paid.json()["status"] == "paid"
        assert paid.json()["amount_paid"] == "2000.00"

        assert client.post("/api/v1/fees/generate?month=2026-09-01", headers=auth_headers).json()["created"] == 1
        sep = client.get(f"/api/v1/fees?student_id={sid}&month=2026-09-01", headers=auth_headers).json()
        assert sep["items"][0]["status"] == "due"

        aug = client.get(f"/api/v1/fees?student_id={sid}&month=2026-08-01", headers=auth_headers).json()
        assert aug["items"][0]["status"] == "paid"

        aug_sum = client.get("/api/v1/fees/summary?month=2026-08-01", headers=auth_headers).json()
        assert aug_sum["total_due"] == "2000.00"
        assert aug_sum["total_paid"] == "2000.00"
        assert aug_sum["outstanding"] == "0.00"

        sep_sum = client.get("/api/v1/fees/summary?month=2026-09-01", headers=auth_headers).json()
        assert sep_sum["total_due"] == "2000.00"
        assert sep_sum["total_paid"] == "0.00"
        assert sep_sum["outstanding"] == "2000.00"

        history = client.get(f"/api/v1/fees?student_id={sid}", headers=auth_headers).json()
        statuses = {f["month"]: f["status"] for f in history["items"]}
        assert statuses == {"2026-08-01": "paid", "2026-09-01": "due"}

    def test_multiple_students_batches_and_filters(self, client, auth_headers, seeded_batch):
        b2 = client.post(
            "/api/v1/batches", json={"name": "Second Batch", "monthly_fee": "1500.00"}, headers=auth_headers
        ).json()
        self._student(client, auth_headers, name="SOne", monthly_fee="2000.00", batch_id=seeded_batch["id"])
        self._student(client, auth_headers, name="STwo", monthly_fee="2000.00", batch_id=seeded_batch["id"])
        self._student(client, auth_headers, name="SThree", monthly_fee="1500.00", batch_id=b2["id"])

        assert client.post("/api/v1/fees/generate?month=2026-09-01", headers=auth_headers).json()["created"] == 3
        studio = client.get("/api/v1/fees/summary?month=2026-09-01", headers=auth_headers).json()
        assert studio["total_due"] == "5500.00"
        assert studio["total_records"] == 3

        batch = client.get(
            f"/api/v1/fees/summary?month=2026-09-01&batch_id={seeded_batch['id']}", headers=auth_headers
        ).json()
        assert batch["total_due"] == "4000.00"
        assert batch["total_records"] == 2

        due = client.get("/api/v1/fees?month=2026-09-01&status=due", headers=auth_headers).json()
        assert due["total"] == 3
        paid = client.get("/api/v1/fees?month=2026-09-01&status=paid", headers=auth_headers).json()
        assert paid["total"] == 0

    def test_partial_then_full_payment_on_generated_fee(self, client, auth_headers):
        s = self._student(client, auth_headers, name="Partial", monthly_fee="2000.00")
        client.post("/api/v1/fees/generate?month=2026-09-01", headers=auth_headers)
        fid = client.get(f"/api/v1/fees?student_id={s['id']}&month=2026-09-01", headers=auth_headers).json()["items"][0]["id"]

        p1 = client.put(
            f"/api/v1/fees/{fid}/payment",
            json={"amount_paid": "1000.00", "payment_date": "2026-09-05", "payment_method": "cash"},
            headers=auth_headers,
        ).json()
        assert p1["amount_paid"] == "1000.00"
        assert p1["status"] == "partial"

        p2 = client.put(
            f"/api/v1/fees/{fid}/payment",
            json={"amount_paid": "1000.00", "payment_date": "2026-09-12", "payment_method": "upi"},
            headers=auth_headers,
        ).json()
        assert p2["amount_paid"] == "2000.00"
        assert p2["status"] == "paid"

        summary = client.get("/api/v1/fees/summary?month=2026-09-01", headers=auth_headers).json()
        assert summary["total_paid"] == "2000.00"
        assert summary["outstanding"] == "0.00"

    def test_inactive_student_keeps_history(self, client, auth_headers):
        s = self._student(client, auth_headers, name="LeaveEarly", monthly_fee="2000.00")
        client.post("/api/v1/fees/generate?month=2026-08-01", headers=auth_headers)
        fees = client.get(f"/api/v1/fees?student_id={s['id']}&month=2026-08-01", headers=auth_headers).json()
        client.put(
            f"/api/v1/fees/{fees['items'][0]['id']}/payment",
            json={"amount_paid": "2000.00", "payment_date": "2026-08-02"},
            headers=auth_headers,
        )
        client.put(f"/api/v1/students/{s['id']}", json={"is_active": False}, headers=auth_headers)

        assert client.post("/api/v1/fees/generate?month=2026-09-01", headers=auth_headers).json()["created"] == 0
        history = client.get(f"/api/v1/fees?student_id={s['id']}", headers=auth_headers).json()
        assert history["total"] == 1
        assert history["items"][0]["status"] == "paid"


class TestEvents:
    def _event(self, client, headers, **kw):
        payload = {
            "name": kw.get("name", "Annual Show"),
            "event_date": kw.get("event_date", "2026-12-15"),
            "event_type": kw.get("event_type", "Annual Day"),
        }
        if kw.get("batch_id"):
            payload["batch_id"] = kw["batch_id"]
        resp = client.post("/api/v1/events", json=payload, headers=headers)
        assert resp.status_code == 201, resp.text
        return resp.json()

    def test_crud(self, client, auth_headers):
        event = self._event(client, auth_headers)
        assert event["participant_count"] == 0
        updated = client.put(f"/api/v1/events/{event['id']}", json={"name": "Renamed Show"}, headers=auth_headers)
        assert updated.json()["name"] == "Renamed Show"
        assert client.delete(f"/api/v1/events/{event['id']}", headers=auth_headers).status_code == 204
        assert client.get(f"/api/v1/events/{event['id']}", headers=auth_headers).status_code == 404

    def test_batch_participation(self, client, auth_headers, seeded_students, seeded_batch):
        event = self._event(client, auth_headers, batch_id=seeded_batch["id"])
        resp = client.post(
            f"/api/v1/events/{event['id']}/participants/batch/{seeded_batch['id']}",
            params={"costume_fee_due": 1200},
            headers=auth_headers,
        )
        assert resp.status_code == 201
        parts = resp.json()
        assert parts["total"] == 3
        assert all(p["source"] == "batch" for p in parts["items"])

        # Re-adding is idempotent
        resp2 = client.post(
            f"/api/v1/events/{event['id']}/participants/batch/{seeded_batch['id']}",
            headers=auth_headers,
        )
        assert resp2.json()["total"] == 3

    def test_individual_participation(self, client, auth_headers, seeded_students):
        event = self._event(client, auth_headers)
        resp = client.post(
            f"/api/v1/events/{event['id']}/participants",
            json={
                "student_ids": seeded_students[:2],
                "source": "individual",
                "is_costume_required": True,
                "costume_fee_due": "800.00",
            },
            headers=auth_headers,
        )
        assert resp.status_code == 201
        assert resp.json()["total"] == 2

    def test_costume_fee_flow(self, client, auth_headers, seeded_students):
        event = self._event(client, auth_headers)
        parts = client.post(
            f"/api/v1/events/{event['id']}/participants",
            json={"student_ids": [seeded_students[0]], "is_costume_required": True, "costume_fee_due": "1000.00"},
            headers=auth_headers,
        ).json()["items"]
        pid = parts[0]["id"]
        assert parts[0]["costume_status"] == "due"

        partial = client.put(
            f"/api/v1/events/participants/{pid}",
            json={"costume_fee_paid": "600.00", "costume_paid_date": "2026-11-01", "costume_payment_method": "cash"},
            headers=auth_headers,
        )
        assert partial.status_code == 200
        assert partial.json()["costume_status"] == "partial"

        full = client.put(
            f"/api/v1/events/participants/{pid}",
            json={"costume_fee_paid": "400.00"},
            headers=auth_headers,
        )
        assert full.json()["costume_status"] == "paid"

        summary = client.get(f"/api/v1/events/{event['id']}/costume-summary", headers=auth_headers).json()
        assert summary["total_costume_due"] == "1000.00"
        assert summary["total_costume_paid"] == "1000.00"
        assert summary["outstanding"] == "0.00"

    def test_costume_overpay_rejected(self, client, auth_headers, seeded_students):
        event = self._event(client, auth_headers)
        pid = client.post(
            f"/api/v1/events/{event['id']}/participants",
            json={"student_ids": [seeded_students[1]], "is_costume_required": True, "costume_fee_due": "500.00"},
            headers=auth_headers,
        ).json()["items"][0]["id"]
        resp = client.put(
            f"/api/v1/events/participants/{pid}",
            json={"costume_fee_paid": "900.00"},
            headers=auth_headers,
        )
        assert resp.status_code == 400

    def test_remove_participant_and_history(self, client, auth_headers, seeded_students):
        event = self._event(client, auth_headers, name="History Event")
        parts = client.post(
            f"/api/v1/events/{event['id']}/participants",
            json={"student_ids": seeded_students[:2]},
            headers=auth_headers,
        ).json()["items"]
        sid = parts[0]["student_id"]
        history = client.get(f"/api/v1/events/students/{sid}/history", headers=auth_headers).json()
        assert history["total"] == 1
        removed = client.delete(f"/api/v1/events/participants/{parts[0]['id']}", headers=auth_headers)
        assert removed.status_code == 204
        history = client.get(f"/api/v1/events/students/{sid}/history", headers=auth_headers).json()
        assert history["total"] == 0


class TestProgress:
    def test_create_and_attendance_sync(self, client, auth_headers, seeded_students, seeded_batch):
        day = "2026-08-05"
        client.put(
            "/api/v1/attendance/day",
            json={"date": day, "batch_id": seeded_batch["id"], "records": [
                {"student_id": seeded_students[0], "status": "present"}
            ]},
            headers=auth_headers,
        )
        resp = client.post(
            "/api/v1/progress/students/{0}".format(seeded_students[0]),
            json={"month": "2026-08-01", "skill_rating": 80, "performance_rating": 75, "discipline_rating": 90,
                  "remarks": "Good"},
            headers=auth_headers,
        )
        assert resp.status_code == 201
        body = resp.json()
        assert body["overall_score"] == round((80 + 75 + 90) / 3, 1)
        assert body["attendance_percentage"] == 100.0

    def test_update_and_delete(self, client, auth_headers, seeded_students):
        sid = seeded_students[1]
        client.post(
            f"/api/v1/progress/students/{sid}",
            json={"month": "2026-07-01", "skill_rating": 50, "performance_rating": 60, "discipline_rating": 70},
            headers=auth_headers,
        )
        updated = client.put(
            f"/api/v1/progress/students/{sid}/2026-07-01",
            json={"skill_rating": 90},
            headers=auth_headers,
        )
        assert updated.status_code == 200
        assert updated.json()["skill_rating"] == 90
        assert updated.json()["overall_score"] == round((90 + 60 + 70) / 3, 1)
        deleted = client.delete(f"/api/v1/progress/students/{sid}/2026-07-01", headers=auth_headers)
        assert deleted.status_code == 204

    def test_duplicate_rejected(self, client, auth_headers, seeded_students):
        sid = seeded_students[2]
        payload = {"month": "2026-06-01", "skill_rating": 70, "performance_rating": 70, "discipline_rating": 70}
        assert client.post(f"/api/v1/progress/students/{sid}", json=payload, headers=auth_headers).status_code == 201
        assert client.post(f"/api/v1/progress/students/{sid}", json=payload, headers=auth_headers).status_code == 409

    def test_rating_range_validation(self, client, auth_headers, seeded_students):
        resp = client.post(
            f"/api/v1/progress/students/{seeded_students[0]}",
            json={"month": "2026-06-01", "skill_rating": 120, "performance_rating": 70, "discipline_rating": 70},
            headers=auth_headers,
        )
        assert resp.status_code == 422


class TestDashboardAndReports:
    def test_dashboard(self, client, auth_headers, seeded_students, seeded_batch):
        resp = client.get("/api/v1/dashboard", headers=auth_headers)
        assert resp.status_code == 200
        body = resp.json()
        assert body["stats"]["total_students"] == 3
        assert body["stats"]["active_batches"] == 1
        assert body["fee_summary"]["month"] == date.today().replace(day=1).isoformat()

    def test_reports_monthly(self, client, auth_headers, seeded_students, seeded_batch):
        client.put(
            "/api/v1/attendance/day",
            json={"date": "2026-08-05", "batch_id": seeded_batch["id"], "records": [
                {"student_id": s, "status": "present"} for s in seeded_students
            ]},
            headers=auth_headers,
        )
        resp = client.get("/api/v1/reports/monthly?month=2026-08-01", headers=auth_headers)
        assert resp.status_code == 200
        row = next(r for r in resp.json()["rows"] if r["batch_name"] == "Test Batch")
        assert row["total_students"] == 3
        assert row["attendance_total"] == 3
        assert row["attendance_percentage"] == 100.0


class TestSearchAndFilters:
    def test_students_filter_by_gender_and_active(self, client, auth_headers, seeded_students):
        sid = seeded_students[0]
        client.put(f"/api/v1/students/{sid}", json={"gender": "Female"}, headers=auth_headers)
        client.put(f"/api/v1/students/{seeded_students[1]}", json={"gender": "Male"}, headers=auth_headers)
        client.put(f"/api/v1/students/{seeded_students[2]}", json={"is_active": False}, headers=auth_headers)
        resp = client.get("/api/v1/students?gender=Female", headers=auth_headers)
        assert resp.json()["total"] == 1
        resp = client.get("/api/v1/students?active_only=true", headers=auth_headers)
        assert resp.json()["total"] == 2

    def test_events_upcoming_past(self, client, auth_headers):
        client.post("/api/v1/events", json={"name": "Past Event", "event_date": "2020-01-01"}, headers=auth_headers)
        client.post("/api/v1/events", json={"name": "Future Event", "event_date": "2030-01-01"}, headers=auth_headers)
        resp = client.get("/api/v1/events?upcoming_only=true", headers=auth_headers)
        assert resp.json()["total"] == 1
        assert resp.json()["items"][0]["name"] == "Future Event"
        resp = client.get("/api/v1/events?past_only=true", headers=auth_headers)
        assert resp.json()["total"] == 1
        assert resp.json()["items"][0]["name"] == "Past Event"