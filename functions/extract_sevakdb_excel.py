# Extracts rows from sevakdb_attendance_full.xlsx ("Attendance" sheet — the
# richer, pre-joined sheet with Location_En/Mr, Marathi zone names, etc.)
# into a JSON file for migrate_sevakdb_attendance.js to consume.
#
# Usage: python extract_sevakdb_excel.py <limit> <offset> <output_path>
import sys
import json
import pandas as pd

limit = int(sys.argv[1])
offset = int(sys.argv[2])
output_path = sys.argv[3]

SOURCE = r"C:/Users/psawarwadkar/Downloads/sevakdb_attendance_full.xlsx"

# skiprows must skip data rows only, so re-apply header after skipping.
df = pd.read_excel(
    SOURCE,
    sheet_name="Attendance_Full",
    skiprows=range(1, offset + 1) if offset > 0 else None,
    nrows=limit,
)


def clean(v):
    if pd.isna(v):
        return None
    if isinstance(v, pd.Timestamp):
        return v.isoformat()
    return v


records = [{col: clean(row[col]) for col in df.columns} for _, row in df.iterrows()]

with open(output_path, "w", encoding="utf-8") as f:
    json.dump(records, f, ensure_ascii=False)

print(f"Wrote {len(records)} rows to {output_path}")
