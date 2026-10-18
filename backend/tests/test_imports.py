from __future__ import annotations

from io import BytesIO
from zipfile import ZIP_DEFLATED, ZipFile

from app.db import Database
from app.repositories import LeadRepository
from app.services.imports import LeadImportService
from app.services.normalization import normalize_email


def test_csv_import_streams_batches_and_deduplicates_with_suppression(tmp_path):
    database = Database(tmp_path / "import.db")
    database.initialize()
    repository = LeadRepository(database)
    repository.insert_many(
        [{"email": "existing@example.com", "normalized_email": "existing@example.com", "metadata": {}}]
    )
    repository.add_suppression("blocked@example.com", "opted out")

    csv_data = b"Email Address,First Name,Company\nNew@Example.com,New,Acme\nnew@example.com,Duplicate,Acme\nexisting@example.com,Existing,OldCo\nblocked@example.com,Blocked,Nope\nnot-an-email,Invalid,Nope\n"
    result = LeadImportService(repository, batch_size=2).process(BytesIO(csv_data))

    assert result == {
        "imported": 1,
        "duplicates": 2,
        "suppressed": 1,
        "invalid": 1,
        "processed": 5,
        "errors": ["row 6: invalid email"],
    }
    assert repository.count() == 2
    assert normalize_email(" NEW@EXAMPLE.COM ") == "new@example.com"


def test_xlsx_import_reads_first_worksheet_without_openpyxl(tmp_path):
    database = Database(tmp_path / "xlsx.db")
    database.initialize()
    repository = LeadRepository(database)
    worksheet = """<?xml version="1.0" encoding="UTF-8"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetData>
        <row r="1"><c r="A1" t="inlineStr"><is><t>Email</t></is></c><c r="B1" t="inlineStr"><is><t>Company Name</t></is></c></row>
        <row r="2"><c r="A2" t="inlineStr"><is><t>owner@example.com</t></is></c><c r="B2" t="inlineStr"><is><t>Acme</t></is></c></row>
      </sheetData>
    </worksheet>"""
    stream = BytesIO()
    with ZipFile(stream, "w", ZIP_DEFLATED) as workbook:
        workbook.writestr("xl/worksheets/sheet1.xml", worksheet)
    stream.seek(0)

    result = LeadImportService(repository).process(stream, "leads.xlsx")

    assert result["imported"] == 1
    assert result["invalid"] == 0
    assert repository.get_by_email("owner@example.com")["company"] == "Acme"
