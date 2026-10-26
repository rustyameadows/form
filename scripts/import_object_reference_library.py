#!/usr/bin/env python3
"""Import reference data from the supplied workbook without executing workbook content.

Usage: python3 scripts/import_object_reference_library.py path/to/workbook.xlsx
Uses only the standard library. The workbook remains unchanged.
"""
import json
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
from zipfile import ZipFile

NS = {"s": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
KEYS = {
    "Catalog": ["id", "name", "domain", "category", "construction", "distinction",
                "options", "referenceType", "referenceName", "referenceURL", "notes"],
    "Materials and options": ["domain", "group", "choices", "details", "referenceName", "referenceURL"],
    "Package examples": ["name", "components", "catalogIDs", "sizing", "surfaces", "notes"],
}


def read_workbook(path):
    with ZipFile(path) as z:
        strings = []
        if "xl/sharedStrings.xml" in z.namelist():
            strings = ["".join(n.itertext()) for n in ET.fromstring(z.read("xl/sharedStrings.xml"))]
        rels = {r.attrib["Id"]: r.attrib["Target"] for r in ET.fromstring(z.read("xl/_rels/workbook.xml.rels"))}
        output = {}
        for sheet in ET.fromstring(z.read("xl/workbook.xml")).find("s:sheets", NS):
            title = sheet.attrib["name"]
            if title not in KEYS:
                continue
            target = rels[sheet.attrib["{http://schemas.openxmlformats.org/officeDocument/2006/relationships}id"]]
            target = target.lstrip("/") if target.startswith("/") else "xl/" + target
            rows = []
            for row in ET.fromstring(z.read(target)).findall("s:sheetData/s:row", NS):
                values = {}
                for cell in row.findall("s:c", NS):
                    # Preserve column positions, including absent/empty cells.
                    col = 0
                    for char in cell.attrib["r"]:
                        if not char.isalpha():
                            break
                        col = col * 26 + ord(char.upper()) - 64
                    value = cell.find("s:v", NS)
                    text = value.text if value is not None else None
                    if cell.attrib.get("t") == "s" and text is not None:
                        text = strings[int(text)]
                    elif cell.attrib.get("t") == "inlineStr":
                        text = "".join(cell.find("s:is", NS).itertext())
                    values[col - 1] = text
                if any(values.values()):
                    rows.append(values)
            output[title] = [dict(zip(KEYS[title], (r.get(i) or "" for i in range(len(KEYS[title]))))) for r in rows[3:]]
        return {"sourceName": Path(path).name, "sourceDate": "2026-10-25",
                "references": output["Catalog"], "materialOptions": output["Materials and options"],
                "workExamples": output["Package examples"]}


if __name__ == "__main__":
    destination = Path(__file__).resolve().parents[1] / "Sources/FormCore/Resources/ObjectReferences.json"
    data = read_workbook(sys.argv[1])
    ids = [r["id"] for r in data["references"]]
    if len(ids) != len(set(ids)) or not all(ids):
        raise ValueError("Catalog IDs must be present and unique")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")
    print(f"Imported {len(ids)} references, {len(data['materialOptions'])} option groups, {len(data['workExamples'])} examples")
