"""Legacy CLI boundaries preserve facade patches and early-exit ownership."""

import argparse
import asyncio
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import pytest

import main as cli


def application_without_runtime_resources():
    # Construct only the coordinator state required by the early-exit seam.
    app = cli.ConverterApplication.__new__(cli.ConverterApplication)
    app.converter = SimpleNamespace()
    app.localization = SimpleNamespace(t=lambda key, **values: key)
    app._show_structure = Mock()
    return app


def test_structure_only_uses_current_facade_reader_and_preserves_input(tmp_path):
    path = tmp_path / "owned.epub"
    path.write_bytes(b"owned input fixture")
    app = application_without_runtime_resources()
    reader = SimpleNamespace(title="Owned title")
    profile = object()
    args = argparse.Namespace(input_file=str(path), show_structure=True, filter_chapters=True)
    with patch.object(cli, "EbookReader", return_value=reader) as open_reader:
        assert app._run_single_conversion(args, hardware_profile=profile) == 0
    open_reader.assert_called_once_with(str(path))
    app._show_structure.assert_called_once_with(reader, filter_chapters=True)
    assert app.converter.hardware_profile is profile
    assert path.read_bytes() == b"owned input fixture"


def test_missing_input_exits_before_reader_or_conversion(tmp_path):
    app = application_without_runtime_resources()
    args = argparse.Namespace(input_file=str(tmp_path / "absent.epub"), show_structure=True)
    with patch.object(cli, "EbookReader") as open_reader:
        assert app._run_single_conversion(args, hardware_profile=object()) == 1
    open_reader.assert_not_called()
    app._show_structure.assert_not_called()


def test_reader_cancellation_propagates_and_does_not_present_stale_structure(tmp_path):
    path = tmp_path / "cancelled.epub"
    path.write_bytes(b"preserved")
    app = application_without_runtime_resources()
    args = argparse.Namespace(input_file=str(path), show_structure=True)
    with patch.object(cli, "EbookReader", side_effect=asyncio.CancelledError):
        with pytest.raises(asyncio.CancelledError):
            app._run_single_conversion(args, hardware_profile=object())
    app._show_structure.assert_not_called()
    assert path.read_bytes() == b"preserved"


def test_subclass_keeps_original_facade_identity():
    class SpecializedApplication(cli.ConverterApplication):
        pass

    app = SpecializedApplication.__new__(SpecializedApplication)
    assert app._cli_runtime is cli


def test_cache_phase_preserves_input_identity_and_explicit_cleanup_exit():
    app = application_without_runtime_resources()
    path = Path("owned.epub")
    args = argparse.Namespace(clear_cache=False)
    kept, status = app._clear_requested_book_outputs(args, None, [], [], None, path)
    assert kept is path
    assert status is None
    app._handle_clear_cache = Mock(return_value=7)
    args = argparse.Namespace(clear_cache=True, input_file=None)
    kept, status = app._clear_requested_book_outputs(args, None, [], [], None, path)
    assert kept is None
    assert status == 7
    app._handle_clear_cache.assert_called_once_with()


def test_argument_schema_retains_aliases_conflicts_and_parser_identity():
    parser = argparse.ArgumentParser()
    assert cli._add_conversion_arguments(parser, input_required=False, include_menu_flag=False) is parser
    args = parser.parse_args(["--show-language", "--chapter", "7.13", "--no-formatting-cues"])
    assert args.detect_language is True
    assert args.chapters == ["7.13"]
    assert args.formatting_cues is False
    with pytest.raises(SystemExit) as error:
        parser.parse_args(["--formatting-cues", "--no-formatting-cues"])
    assert error.value.code == 2


@pytest.fixture(params=["class", "instance", "subclass", "subclass_instance"])
def static_entrypoint(request):
    class SpecializedApplication(cli.ConverterApplication):
        pass

    application_type = (
        SpecializedApplication if request.param.startswith("subclass") else cli.ConverterApplication
    )
    if request.param.endswith("instance"):
        return application_type.__new__(application_type)
    return application_type


def test_manifest_uses_rebound_facade_path(static_entrypoint, tmp_path):
    manifest = tmp_path / "books.txt"
    manifest.write_text("# owned selection\n\nowned.epub\n", encoding="utf-8")
    with patch.object(cli, "Path", wraps=Path) as path_factory:
        assert static_entrypoint._read_batch_manifest(str(manifest)) == ["owned.epub"]
    path_factory.assert_called_once_with(str(manifest))
    assert manifest.read_text(encoding="utf-8") == "# owned selection\n\nowned.epub\n"


def test_missing_manifest_uses_rebound_facade_path(static_entrypoint, tmp_path, capsys):
    manifest = tmp_path / "missing.txt"
    with patch.object(cli, "Path", wraps=Path) as path_factory:
        assert static_entrypoint._read_batch_manifest(str(manifest)) == []
    path_factory.assert_called_once_with(str(manifest))
    assert "List file not found" in capsys.readouterr().out


@pytest.mark.parametrize("failure", [None, OSError("open refused")])
def test_dashboard_uses_rebound_facade_process(
    static_entrypoint, tmp_path, capsys, failure
):
    dashboard = tmp_path / "metrics-dashboard.html"
    dashboard.write_text("owned dashboard", encoding="utf-8")
    process = SimpleNamespace(Popen=Mock(side_effect=failure), DEVNULL=object())
    with patch.object(cli, "subprocess", process), patch.object(cli, "Path", wraps=Path) as paths:
        static_entrypoint._open_metrics_dashboard(tmp_path)
    paths.assert_called_once_with(tmp_path)
    process.Popen.assert_called_once_with(
        ["open", str(dashboard)], stdout=process.DEVNULL, stderr=process.DEVNULL
    )
    expected = "Could not open metrics dashboard" if failure else "Opened metrics dashboard"
    assert expected in capsys.readouterr().out
    assert dashboard.read_text(encoding="utf-8") == "owned dashboard"


def test_metrics_bundle_uses_rebound_facade_clock_and_archive(static_entrypoint, tmp_path):
    from unittest.mock import MagicMock

    metrics = tmp_path / "metrics-summary.json"
    metrics.write_text('{"owned": true}', encoding="utf-8")
    archive = MagicMock()
    archives = SimpleNamespace(ZipFile=Mock(return_value=archive), ZIP_DEFLATED=object())
    clock = SimpleNamespace(time=Mock(return_value=1234.9))
    with (
        patch.object(cli, "time", clock),
        patch.object(cli, "zipfile", archives),
        patch.object(cli, "Path", wraps=Path) as paths,
    ):
        static_entrypoint._export_metrics_bundle(tmp_path)
    paths.assert_called_once_with(tmp_path)
    clock.time.assert_called_once_with()
    archives.ZipFile.assert_called_once_with(
        tmp_path / "metrics-bundle-1234.zip", "w", compression=archives.ZIP_DEFLATED
    )
    archive.__enter__.return_value.write.assert_called_once_with(metrics, arcname=metrics.name)
    assert metrics.read_text(encoding="utf-8") == '{"owned": true}'
