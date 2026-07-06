# Appends newly-detected skipped attendance rows to the running
# sevakdb_skipped_attendance_rows.xlsx tracking file (sheet "Skipped_Rows"),
# de-duplicating by DocId so re-running a chunk never double-records a skip.
#
# Usage: python append_skipped_rows.py <input_json_path>
# input_json_path: JSON array of objects with keys matching the sheet's
# columns: RowNumber, MemberMasterId, Name_en, Name_mr, AttendanceDate,
# Zone, Baithak, MonthKey, DocId, FirestorePath, Reason
import sys
import json
import openpyxl

XLSX_PATH = r"C:/Users/psawarwadkar/Downloads/sevakdb_skipped_attendance_rows.xlsx"
SHEET_NAME = "Skipped_Rows"
COLUMNS = [
    "RowNumber", "MemberMasterId", "Name_en", "Name_mr", "AttendanceDate",
    "Zone", "Baithak", "MonthKey", "DocId", "FirestorePath", "Reason",
]

input_path = sys.argv[1]
with open(input_path, "r", encoding="utf-8") as f:
    new_rows = json.load(f)

wb = openpyxl.load_workbook(XLSX_PATH)
ws = wb[SHEET_NAME]

existing_doc_ids = {row[0] for row in ws.iter_rows(min_row=2, min_col=9, max_col=9, values_only=True) if row[0]}

added = 0
for r in new_rows:
    if r.get("DocId") in existing_doc_ids:
        continue
    ws.append([r.get(col, "") for col in COLUMNS])
    existing_doc_ids.add(r.get("DocId"))
    added += 1

if added:
    wb.save(XLSX_PATH)

print(f"Appended {added} new skipped row(s) ({len(new_rows) - added} already recorded).")
