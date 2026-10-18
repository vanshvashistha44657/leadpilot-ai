from __future__ import annotations

import csv
import io
import zipfile
from typing import Any, BinaryIO, Callable, Iterator
from xml.etree import ElementTree

from ..repositories import LeadRepository
from .normalization import clean_text, normalize_email


class LeadImportService:
    FIELD_ALIASES = {
        "email address": "email",
        "e-mail": "email",
        "first name": "first_name",
        "firstname": "first_name",
        "last name": "last_name",
        "lastname": "last_name",
        "job title": "title",
        "company name": "company",
    }

    def __init__(self, repository: LeadRepository, batch_size: int = 100):
        self.repository = repository
        self.batch_size = max(1, batch_size)

    def process(self, stream: BinaryIO, filename: str | None = None, checkpoint: Callable[[], None] | None = None) -> dict[str, Any]:
        rows = self._xlsx_rows(stream) if (filename or "").lower().endswith(".xlsx") else self._csv_rows(stream)
        reader = iter(rows)
        try:
            fieldnames = next(reader)
        except StopIteration:
            fieldnames = None
        if not fieldnames or not any(self._canonical_key(key) == "email" for key in fieldnames):
            return {"imported": 0, "duplicates": 0, "suppressed": 0, "invalid": 0, "processed": 0, "errors": ["CSV/XLSX must include an email column"]}

        result = {"imported": 0, "duplicates": 0, "suppressed": 0, "invalid": 0, "processed": 0, "errors": []}
        batch: list[dict[str, Any]] = []
        seen: set[str] = set()
        for row_number, raw_row in enumerate(reader, start=2):
            if checkpoint and result["processed"] % self.batch_size == 0:
                checkpoint()
            result["processed"] += 1
            row = {self._canonical_key(key): value for key, value in raw_row.items() if key}
            try:
                normalized = normalize_email(row.get("email"))
            except ValueError as exc:
                result["invalid"] += 1
                if len(result["errors"]) < 20:
                    result["errors"].append(f"row {row_number}: {exc}")
                continue
            if normalized in seen:
                result["duplicates"] += 1
                continue
            seen.add(normalized)
            batch.append(
                {
                    "email": str(row.get("email", "")).strip(),
                    "normalized_email": normalized,
                    "first_name": clean_text(row.get("first_name")),
                    "last_name": clean_text(row.get("last_name")),
                    "company": clean_text(row.get("company")),
                    "title": clean_text(row.get("title")),
                    "source": clean_text(row.get("source")) or "csv",
                    "metadata": {},
                }
            )
            if len(batch) >= self.batch_size:
                self._flush(batch, result)
                batch.clear()
                if checkpoint:
                    checkpoint()
        if batch:
            self._flush(batch, result)
            if checkpoint:
                checkpoint()
        return result

    @staticmethod
    def _csv_rows(stream: BinaryIO) -> Iterator[dict[str, str]]:
        """Yield CSV rows without reading the complete upload into memory."""
        stream.seek(0)
        text_stream = io.TextIOWrapper(stream, encoding="utf-8-sig", newline="")
        try:
            reader = csv.DictReader(text_stream)
            if reader.fieldnames:
                yield {key: key for key in reader.fieldnames if key}
            for row in reader:
                yield {str(key): value or "" for key, value in row.items() if key}
        finally:
            # UploadFile owns the underlying stream; detach so the request layer
            # can close it normally after processing.
            try:
                text_stream.detach()
            except ValueError:
                pass

    @classmethod
    def _xlsx_rows(cls, stream: BinaryIO) -> Iterator[dict[str, str]]:
        """Read the first worksheet from XLSX using stdlib streaming XML.

        This intentionally supports the common tabular export shape rather than
        attempting to execute formulas or interpret workbook formatting. Values
        are treated as source data and never enriched or fabricated.
        """
        stream.seek(0)
        with zipfile.ZipFile(stream) as workbook:
            shared_strings = cls._shared_strings(workbook)
            sheet_name = cls._first_worksheet(workbook)
            if sheet_name not in workbook.namelist():
                raise ValueError("XLSX must contain a first worksheet")
            with workbook.open(sheet_name) as sheet:
                rows: list[str] | None = None
                for _, element in ElementTree.iterparse(sheet, events=("end",)):
                    if element.tag.rsplit("}", 1)[-1] != "row":
                        continue
                    cells: dict[int, str] = {}
                    for cell in list(element):
                        if cell.tag.rsplit("}", 1)[-1] != "c":
                            continue
                        reference = cell.attrib.get("r", "A1")
                        column = cls._column_number(reference)
                        value_node = next((child for child in list(cell) if child.tag.rsplit("}", 1)[-1] in {"v", "t", "is"}), None)
                        value = ""
                        if value_node is not None:
                            value = "".join(value_node.itertext())
                        if cell.attrib.get("t") == "s":
                            try:
                                value = shared_strings[int(value)]
                            except (ValueError, IndexError):
                                value = ""
                        cells[column] = value
                    if rows is None:
                        width = max(cells.keys(), default=0)
                        rows = [""] * width
                        for index, value in cells.items():
                            rows[index - 1] = value
                        yield {value: value for value in rows if value}
                    else:
                        width = max([len(rows), *cells.keys()], default=len(rows))
                        values = [""] * width
                        for index, value in cells.items():
                            values[index - 1] = value
                        yield {rows[index]: values[index] if index < len(values) else "" for index in range(len(rows))}
                    element.clear()

    @staticmethod
    def _column_number(reference: str) -> int:
        column = 0
        for char in reference:
            if not char.isalpha():
                break
            column = column * 26 + ord(char.upper()) - ord("A") + 1
        return max(1, column)

    @staticmethod
    def _shared_strings(workbook: zipfile.ZipFile) -> list[str]:
        name = "xl/sharedStrings.xml"
        if name not in workbook.namelist():
            return []
        values: list[str] = []
        with workbook.open(name) as source:
            for _, element in ElementTree.iterparse(source, events=("end",)):
                if element.tag.rsplit("}", 1)[-1] == "si":
                    values.append("".join(element.itertext()))
                    element.clear()
        return values

    @staticmethod
    def _first_worksheet(workbook: zipfile.ZipFile) -> str:
        """Resolve the workbook's first visible worksheet through OOXML rels."""
        workbook_xml = "xl/workbook.xml"
        relationships_xml = "xl/_rels/workbook.xml.rels"
        if workbook_xml not in workbook.namelist() or relationships_xml not in workbook.namelist():
            return "xl/worksheets/sheet1.xml"
        with workbook.open(workbook_xml) as source:
            root = ElementTree.parse(source).getroot()
        first_sheet = next((node for node in root.iter() if node.tag.rsplit("}", 1)[-1] == "sheet"), None)
        if first_sheet is None:
            return "xl/worksheets/sheet1.xml"
        relationship_id = next((value for key, value in first_sheet.attrib.items() if key.rsplit("}", 1)[-1] == "id"), None)
        if not relationship_id:
            return "xl/worksheets/sheet1.xml"
        with workbook.open(relationships_xml) as source:
            root = ElementTree.parse(source).getroot()
        relationship = next((node for node in root.iter() if node.attrib.get("Id") == relationship_id), None)
        target = relationship.attrib.get("Target", "worksheets/sheet1.xml") if relationship is not None else "worksheets/sheet1.xml"
        target = target.lstrip("/")
        return target if target.startswith("xl/") else f"xl/{target}"

    def _flush(self, batch: list[dict[str, Any]], result: dict[str, Any]) -> None:
        emails = [lead["normalized_email"] for lead in batch]
        suppressed = self.repository.suppressed_emails(emails)
        existing = self.repository.existing_emails(emails)
        eligible = []
        for lead in batch:
            email = lead["normalized_email"]
            if email in suppressed:
                result["suppressed"] += 1
            elif email in existing:
                result["duplicates"] += 1
            else:
                eligible.append(lead)
        inserted = self.repository.insert_many(eligible)
        result["imported"] += inserted
        result["duplicates"] += len(eligible) - inserted

    @classmethod
    def _canonical_key(cls, key: str | None) -> str:
        normalized = (key or "").strip().casefold().replace("_", " ")
        return cls.FIELD_ALIASES.get(normalized, normalized.replace(" ", "_"))
