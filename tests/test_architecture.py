from __future__ import annotations

import ast
import io
import tokenize
from pathlib import Path

import pytest

PURE_MODULES = ("parser.py", "cleaning.py", "models.py", "date_logic.py", "icons.py")
ROOT = Path(__file__).parents[1]
COMPONENT = ROOT / "custom_components" / "school_menu"
TESTS = ROOT / "tests"


def _imported_names(source: str) -> set[str]:
    names: set[str] = set()
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Import):
            names.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            names.add(node.module)
    return names


def _prose_offenders(path: Path) -> list[str]:
    source = path.read_text()
    offenders: list[str] = []
    for node in ast.walk(ast.parse(source)):
        is_documentable = isinstance(
            node, ast.Module | ast.ClassDef | ast.FunctionDef | ast.AsyncFunctionDef
        )
        if is_documentable and ast.get_docstring(node) is not None:
            offenders.append(f"{path.name}:docstring")
    for token in tokenize.generate_tokens(io.StringIO(source).readline):
        if token.type == tokenize.COMMENT:
            offenders.append(f"{path.name}:{token.start[0]}:{token.string.strip()}")
    return offenders


@pytest.mark.parametrize("module_name", PURE_MODULES)
def test_pure_module_does_not_import_home_assistant(module_name: str) -> None:
    module = COMPONENT / module_name
    if not module.exists():
        pytest.skip(f"{module_name} not implemented yet")
    offenders = {
        name for name in _imported_names(module.read_text()) if name.startswith("homeassistant")
    }
    assert not offenders, f"{module_name} must stay free of Home Assistant imports: {offenders}"


def test_code_files_carry_no_prose() -> None:
    offenders: list[str] = []
    for root in (COMPONENT, TESTS):
        for path in sorted(root.rglob("*.py")):
            offenders.extend(_prose_offenders(path))
    assert not offenders, f"code files must carry zero prose: {offenders}"


def test_the_prose_detector_catches_a_trailing_pragma(tmp_path: Path) -> None:
    sample = tmp_path / "sample.py"
    sample.write_text("VERSION = 1  # type: ignore[assignment]\n")
    assert _prose_offenders(sample)


def test_the_prose_detector_catches_a_docstring(tmp_path: Path) -> None:
    sample = tmp_path / "sample.py"
    sample.write_text('"""explanation"""\n\nVERSION = 1\n')
    assert _prose_offenders(sample)


def test_packages_home_assistant_ships_are_not_pinned() -> None:
    import json

    manifest = json.loads((COMPONENT / "manifest.json").read_text())
    shipped_by_core = {"aioimaplib"}
    for requirement in manifest["requirements"]:
        name = requirement.split(">")[0].split("=")[0].split("<")[0].strip().lower()
        if name in shipped_by_core:
            assert "==" not in requirement, f"{requirement} must be a minimum version"


def test_the_integration_declares_it_is_set_up_from_the_ui_only(caplog) -> None:
    from custom_components.school_menu import CONFIG_SCHEMA

    CONFIG_SCHEMA({"school_menu": {"host": "imap.example.org"}})

    assert "does not support YAML setup" in caplog.text
