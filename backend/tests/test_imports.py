from __future__ import annotations

from io import BytesIO
from zipfile import ZIP_DEFLATED, ZipFile

from app.db import Database
from app.repositories import ImportBatchRepository, LeadRepository
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


def test_import_records_structured_errors_and_successful_source_provenance(tmp_path):
    database = Database(tmp_path / "audit.db")
    database.initialize()
    leads = LeadRepository(database)
    batches = ImportBatchRepository(database)
    batch_id = "batch-audit"
    batches.create(batch_id, "partners.csv", "csv")

    result = LeadImportService(leads, batch_size=2).process(
        BytesIO(
            b"Email,Source,Company\n"
            b"owner@example.com,partner-list,Acme\n"
            b"not-an-email,partner-list,Invalid Co\n"
        ),
        "partners.csv",
        batch_id=batch_id,
    )
    batches.complete(batch_id, result)

    assert result["imported"] == 1
    assert result["errors"] == ["row 3: invalid email"]
    with database.session() as connection:
        batch = connection.execute("SELECT * FROM import_batches WHERE id = ?", (batch_id,)).fetchone()
    assert batch["status"] == "completed"
    assert batch["error_count"] == 1
    errors = batches.list_errors(batch_id)
    assert len(errors) == 1
    assert errors[0]["batch_id"] == batch_id
    assert errors[0]["row_number"] == 3
    assert errors[0]["field_name"] == "email"
    assert errors[0]["error_code"] == "invalid_email"
    assert errors[0]["message"] == "invalid email"
    sources = batches.list_sources(batch_id)
    assert len(sources) == 1
    assert sources[0]["source_row"] == 2
    assert sources[0]["source_label"] == "partner-list"
    assert sources[0]["lead_id"] == leads.get_by_email("owner@example.com")["id"]


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


def test_import_preview_reports_columns_samples_and_mapping(tmp_path):
    database = Database(tmp_path / "preview.db")
    database.initialize()
    preview = LeadImportService(LeadRepository(database)).preview(
        BytesIO(b"Contact,Organization\nowner@example.com,Acme\n"), "leads.csv"
    )

    assert preview["columns"] == ["Contact", "Organization"]
    assert preview["sample_rows"] == [{"Contact": "owner@example.com", "Organization": "Acme"}]
    assert preview["suggested_mapping"]["Contact"] == "contact"


def test_import_rejects_large_upload(tmp_path):
    database = Database(tmp_path / "large.db")
    database.initialize()
    service = LeadImportService(LeadRepository(database))
    service.MAX_BYTES = 4

    try:
        service.process(BytesIO(b"Email\na@b.com\n"), "leads.csv")
    except ValueError as error:
        assert "25 MB" in str(error) or "limit" in str(error)
    else:
        raise AssertionError("expected upload size limit")


def test_import_rejects_row_limit(tmp_path):
    database = Database(tmp_path / "rows.db")
    database.initialize()
    service = LeadImportService(LeadRepository(database))
    service.MAX_ROWS = 1

    try:
        service.process(BytesIO(b"Email\na@example.com\nb@example.com\n"), "leads.csv")
    except ValueError as error:
        assert "row limit" in str(error)
    else:
        raise AssertionError("expected row limit")


def test_xlsx_import_rejects_uncompressed_size_limit(tmp_path, monkeypatch):
    database = Database(tmp_path / "xlsx-limit.db")
    database.initialize()
    service = LeadImportService(LeadRepository(database))
    monkeypatch.setattr(LeadImportService, "MAX_XLSX_UNCOMPRESSED", 10)
    stream = BytesIO()
    with ZipFile(stream, "w", ZIP_DEFLATED) as workbook:
        workbook.writestr("xl/worksheets/sheet1.xml", "x" * 100)
    stream.seek(0)

    try:
        service.process(stream, "leads.xlsx")
    except ValueError as error:
        assert "uncompressed size" in str(error)
    else:
        raise AssertionError("expected XLSX uncompressed size limit")
