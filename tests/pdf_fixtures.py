from __future__ import annotations

import atexit
import shutil
import tempfile
from io import BytesIO
from pathlib import Path

WEEK_39 = "Testplan 26-39.pdf"
WEEK_40 = "Testplan 26-40.pdf"

FOOTER = (
    "(Änderung Vorbehalten)",
    "Allergene und Zusatzstoffe: Gluten (1), Weizen (1a), Dinkel (1b), Roggen (1c), Hafer (1d), "
    "Gerste (1e), Sellerie (2), Milchprodukte (3), Senf (4), Schalenfrüchte (5), Ei (6),",
    "Soja (7), Sesam (9)",
    "Konservierungsstoff: Natriumnitrit(a), Antioxidationsmittel: Ascorbat (b)",
    "Testküche Bio Catering 030-0000000 kantine@organiced-kitchen.example DE-ÖKO-000",
)

MENUS: dict[str, tuple[str, ...]] = {
    WEEK_39: (
        "WOCHENPLAN",
        "21.09.26 – 25.09.26",
        "MONTAG",
        "Penne mit Erbsen-Minz Pesto (1a, 5)",
        "Tomaten Gurken Salat (4)",
        "Obst",
        "DIENSTAG",
        "Brokkoli Cremesuppe (2, 3)",
        "Laugenbrezel (1a)",
        "Kirsch Joghurt (3)",
        "MITTWOCH",
        "Hirse-Gemüse Pfanne /Frische Kräuter (3, 7)",
        "Couscous",
        "Radieschen Salat (4)",
        "SÜSSER DONNERSTAG",
        "Pfannkuchen mit Blaubeeren (1a, 3, 6)",
        "Vanillesoße (3)",
        "Rohkost Sticks",
        "FREITAG",
        "Bohnen Eintopf (2)",
        "Brot (1a)",
        "Apfel Crumble (1a)",
        "„Wer mit Freude kocht, braucht kein Rezept, nur ein biss-",
        "chen Mut.“",
        "Tante Erna",
        *FOOTER,
    ),
    WEEK_40: (
        "WOCHENPLAN",
        "28.09.26 – 02.10.26",
        "Bunter veganer MONTAG",
        "Spaghetti mit Kürbis-Salbei Sauce (1a)",
        "Gurkensalat mit Dill (4)",
        "Obst",
        "DIENSTAG",
        "Süßkartoffel Auflauf (3)",
        "Rotkohl-Birnen Rohkost (4)",
        "Vanille Joghurt (3)",
        "Süß-saurer MITTWOCH",
        "Ananas-Chili mit Kidneybohnen (7)",
        "Reis",
        "Feldsalat mit Kürbiskernen (4)",
        "Süßer DONNERSTAG",
        "Zucchini-Möhren Puffer mit Kräuterquark (1a, 3, 6)",
        "Kartoffeln",
        "Obst",
        "FREITAG",
        "Kürbis-Kokos Suppe (2)",
        "Dinkelbrot (1b)",
        "Haferkekse (1d)",
        "„Ein voller Bauch lernt gern.“",
        "Opa Hubert",
        *FOOTER,
    ),
}


def menu_lines(name: str) -> list[str]:
    return list(MENUS[name])


def build_pdf(lines: tuple[str, ...] | list[str]) -> bytes:
    from reportlab.lib.pagesizes import A4
    from reportlab.pdfgen.canvas import Canvas

    buffer = BytesIO()
    canvas = Canvas(buffer, pagesize=A4, invariant=1)
    canvas.setFont("Helvetica", 7)
    y = A4[1] - 40
    for line in lines:
        canvas.drawString(30, y, line)
        y -= 14
    canvas.save()
    return buffer.getvalue()


def _write_fixtures() -> Path:
    directory = Path(tempfile.mkdtemp(prefix="school_menu_fixtures_"))
    atexit.register(shutil.rmtree, directory, ignore_errors=True)
    for name, lines in MENUS.items():
        (directory / name).write_bytes(build_pdf(lines))
    return directory


FIXTURES = _write_fixtures()
REAL_FIXTURES = Path(__file__).parent / "fixtures"
