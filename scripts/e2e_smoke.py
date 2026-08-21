import sys
from datetime import date

import httpx

BASE = "http://127.0.0.1:8000"
c = httpx.Client(base_url=BASE, timeout=20)
ok = lambda: print("  PASS")
fail = lambda e: (print(f"  FAIL: {e}"), sys.exit(1))

print("[1] health")
r = c.get("/health")
if r.status_code != 200 or r.json()["status"] != "ok": fail(r.text)
ok()

print("[2] login")
r = c.post("/api/v1/auth/login", json={"username": "admin", "password": "admin123"})
if r.status_code != 200: fail(r.text)
token = r.json()["access_token"]
c.headers["Authorization"] = f"Bearer {token}"
ok()

print("[3] dashboard summary")
r = c.get("/api/v1/dashboard")
d = r.json()
if r.status_code != 200: fail(r.text)
print(f"  students={d['stats']['total_students']} batches={d['stats']['total_batches']} events={d['stats']['total_events']} fees_collected={d['fee_summary']['total_paid']}")
ok()

print("[3.5] cleanup previous smoke-test leftovers")
r = c.get("/api/v1/batches")
for b in r.json().get("items", []):
    if b["name"] == "Smoke Test Batch":
        c.delete(f"/api/v1/batches/{b['id']}")
        print(f"  deleted leftover batch {b['id']}")
r = c.get("/api/v1/events")
for e in r.json().get("items", []):
    if e["name"] == "Smoke Test Event":
        c.delete(f"/api/v1/events/{e['id']}")
        print(f"  deleted leftover event {e['id']}")
ok()

print("[4] create batch")
r = c.post("/api/v1/batches", json={
    "name": "Smoke Test Batch", "dance_style": "Bharatanatyam",
    "level": "Beginner", "schedule": "Sat 6pm", "monthly_fee": "1500",
    "notes": "e2e", "is_active": True})
if r.status_code not in (200, 201): fail(r.text)
batch = r.json()
bid = batch["id"]
print(f"  batch_id={bid}")
ok()

print("[5] create student in batch")
r = c.post("/api/v1/students", json={
    "first_name": "Smoke", "last_name": "Student", "phone": "9999999999",
    "email": "smoke@example.com", "gender": "F", "batch_id": bid,
    "join_date": date.today().isoformat(), "is_active": True})
if r.status_code not in (200, 201): fail(r.text)
student = r.json()
sid = student["id"]
print(f"  student_id={sid}")
ok()

print("[6] mark today's attendance (present)")
today = date.today().isoformat()
r = c.put("/api/v1/attendance/day", json={
    "date": today, "batch_id": bid,
    "records": [{"student_id": sid, "status": "present", "notes": "smoke"}]})
if r.status_code != 200: fail(r.text)
day = r.json()
if day["present"] != 1 or day["percentage"] != 100: fail(day)
print(f"  present={day['present']} pct={day['percentage']}")
ok()

print("[7] monthly attendance summary")
r = c.get("/api/v1/attendance/monthly",
          params={"month": today[:7] + "-01", "batch_id": bid})
rows = r.json()
row = next(x for x in rows if x["student_id"] == sid)
print(f"  {row['student_name']}: attended={row['presents']} pct={row['percentage']}")
if row["percentage"] != 100: fail(row)
ok()

print("[8] create fee record for current month + payment")
r = c.post(f"/api/v1/fees/students/{sid}/{today[:7]}-01",
           json={"month": f"{today[:7]}-01", "amount_due": "1500"})
if r.status_code not in (200, 201): fail(r.text)
fee = r.json()
fid = fee["id"]
print(f"  fee_id={fid} paid={fee['amount_paid']} due={fee['amount_due']}")
r = c.put(f"/api/v1/fees/{fid}/payment", json={"amount_paid": "500", "payment_date": today, "payment_method": "upi"})
if r.status_code != 200: fail(r.text)
fee2 = r.json()
print(f"  after payment paid={fee2['amount_paid']} due={fee2['amount_due']}")
if float(fee2["amount_paid"]) != 500.0 or fee2["status"] != "partial": fail(fee2)
r = c.put(f"/api/v1/fees/{fid}/payment", json={"amount_paid": "1000", "payment_date": today, "payment_method": "cash"})
fee3 = r.json()
print(f"  after 2nd payment paid={fee3['amount_paid']} status={fee3['status']}")
if float(fee3["amount_paid"]) != 1500.0 or fee3["status"] != "paid": fail(fee3)
ok()

print("[9] create event + participants + costume payment")
r = c.post("/api/v1/events", json={
    "name": "Smoke Test Event", "event_type": "Recital",
    "event_date": "2026-09-01", "location": "Studio", "batch_id": bid,
    "description": "e2e"})
if r.status_code not in (200, 201): fail(r.text)
event = r.json()
eid = event["id"]
r = c.post(f"/api/v1/events/{eid}/participants", json={
    "student_ids": [sid], "is_costume_required": True,
    "costume_fee_due": "2000", "notes": "smoke participant"})
if r.status_code not in (200, 201): fail(r.text)
pid = r.json()["items"][0]["id"]
r = c.get(f"/api/v1/events/{eid}/costume-summary")
cs = r.json()
print(f"  costume due={cs['total_costume_due']} paid={cs['total_costume_paid']}")
if float(cs["total_costume_due"]) != 2000.0: fail(cs)
r = c.put(f"/api/v1/events/participants/{pid}", json={"costume_fee_paid": "500", "notes": "advance"})
if r.status_code != 200: fail(r.text)
part = r.json()
print(f"  participation costume_paid={part['costume_fee_paid']} status={part['costume_status']}")
if float(part["costume_fee_paid"]) != 500.0 or part["costume_status"] != "partial": fail(part)
ok()

print("[10] progress record")
r = c.post(f"/api/v1/progress/students/{sid}", json={
    "month": today[:7] + "-01", "skill_rating": 40, "performance_rating": 50,
    "discipline_rating": 60, "remarks": "great improvement"})
if r.status_code not in (200, 201): fail(r.text)
r = c.get(f"/api/v1/progress/students/{sid}/{today[:7]}-01")
if r.status_code != 200: fail(r.text)
pr = r.json()
print(f"  progress skill={pr['skill_rating']} perf={pr['performance_rating']} "
      f"disc={pr['discipline_rating']} overall={pr['overall_score']} pct={pr['attendance_percentage']}")
if pr["overall_score"] != 50.0 or pr["attendance_percentage"] != 100.0: fail(pr)
ok()

print("[11] student detail + related data (mirrors app flow)")
r = c.get(f"/api/v1/students/{sid}")
s = r.json()
if f"{s['first_name']} {s['last_name']}" != "Smoke Student" or s["batch_id"] != bid: fail(s)
r = c.get(f"/api/v1/fees?student_id={sid}&limit=50")
fees = r.json()["items"]
r = c.get(f"/api/v1/progress/students/{sid}")
progress = r.json()["items"]
r = c.get(f"/api/v1/attendance/students/{sid}/monthly")
att = r.json()
print(f"  fees={len(fees)} progress={len(progress)} monthly_rows={len(att)}")
if len(fees) != 1 or len(progress) != 1 or len(att) != 1: fail("related data missing")
ok()

print("[12] monthly report")
r = c.get("/api/v1/reports/monthly", params={"month": today[:7] + "-01"})
rep = r.json()
rows = rep["rows"]
my_row = next(x for x in rows if x["batch_id"] == bid)
print(f"  batches={len(rows)} smoke fees_due={my_row['fees_due']} att={my_row['attendance_percentage']}")
if float(my_row["fees_due"]) != 1500.0 or my_row["attendance_percentage"] != 100.0: fail(my_row)
ok()

print("[13] change password flow (wrong old rejected)")
r = c.post("/api/v1/auth/change-password",
           json={"current_password": "wrong", "new_password": "newpass"})
if r.status_code not in (400, 401, 403): fail(f"expected 4xx for wrong old password, got {r.status_code}: {r.text}")
print(f"  rejected with {r.status_code}")
ok()

print("[14] cleanup: delete event, student (cascade fees/progress/attendance), batch")
for path, name in [(f"/api/v1/events/{eid}", "event"), (f"/api/v1/students/{sid}", "student")]:
    r = c.delete(path)
    if r.status_code not in (200, 204): fail(f"delete {name}: {r.text}")
    print(f"  deleted {name}")
r = c.get(f"/api/v1/fees/{fid}")
if r.status_code != 404: fail(f"fee should cascade-delete, got {r.status_code}")
print("  fee cascade-deleted with student (404 on GET)")
r = c.delete(f"/api/v1/batches/{bid}")
if r.status_code not in (200, 204): fail(f"delete batch: {r.text}")
print("  deleted batch")
ok()

print("\nALL E2E SMOKE CHECKS PASSED")