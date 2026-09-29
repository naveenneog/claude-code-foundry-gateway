from contextlib import contextmanager, nullcontext
import json

import pytest
from rich.text import Text

from claude_finops.errors import FinOpsError
from claude_finops.guarded_publication import guarded_publish
from claude_finops import publication_output


def test_console_creation_stays_inside_the_protected_writer(capsys):
    with guarded_publish(nullcontext):
        publication_output.write_renderable(None, Text("CURRENT_REPORT"), no_color=True)
    assert "CURRENT_REPORT" in capsys.readouterr().out
    with pytest.raises(FinOpsError, match="unguarded"):
        publication_output.write_renderable(None, Text("UNGUARDED_REPORT"))
    assert "UNGUARDED_REPORT" not in capsys.readouterr().out


@pytest.mark.parametrize("sink", ["report", "profile", "prompt"])
@pytest.mark.parametrize("current", [False, True])
def test_new_io_paths_check_origin_before_any_effect(tmp_path, monkeypatch, sink, current):
    valid = [True]
    prompted = []
    monkeypatch.setattr(publication_output.typer, "prompt",
                        lambda *args, **kwargs: prompted.append(args[0]) or 2)

    @contextmanager
    def origin():
        if not valid[0]:
            raise FinOpsError("The sign-in changed.", 3)
        yield

    destination = tmp_path / "new-folder" / "report.json"
    operations = {
        "report": lambda: publication_output.write_export(destination, "PRIVATE_REPORT", create_parents=True),
        "profile": lambda: publication_output.write_profile(destination, {"backend": "fake"}),
        "prompt": lambda: publication_output.prompt_number("PRIVATE_PROMPT", default=1),
    }
    with guarded_publish(origin):
        valid[0] = current
        if current:
            operations[sink]()
        else:
            with pytest.raises(FinOpsError, match="sign-in changed"):
                operations[sink]()
    assert destination.exists() is (current and sink != "prompt")
    assert destination.parent.exists() is (current and sink != "prompt")
    assert bool(prompted) is (current and sink == "prompt")


def test_profile_overwrite_remains_an_explicit_choice(tmp_path):
    destination = tmp_path / "profile.json"
    with guarded_publish(nullcontext):
        publication_output.write_profile(destination, {"backend": "fake"})
        before = destination.read_bytes()
        with pytest.raises(FinOpsError, match="Profile exists") as failure:
            publication_output.write_profile(destination, {"backend": "direct"})
        assert failure.value.code == 6 and destination.read_bytes() == before
        publication_output.write_profile(destination, {"backend": "direct"}, force=True)
    assert json.loads(destination.read_text()) == {"backend": "direct"}


def test_file_input_and_profile_locations_return_values_not_writer_handles(tmp_path):
    source = tmp_path / "input.json"
    source.write_text('{"current": true}', encoding="utf-8")
    assert publication_output.read_text(str(source)) == '{"current": true}'
    assert publication_output.profile_path(source) == str(source)
    assert isinstance(publication_output.profile_path(), str)


def test_config_loader_accepts_cli_path_text_without_exposing_path_objects(tmp_path):
    from claude_finops.config import load_config
    source = tmp_path / "config.json"
    source.write_text('{"backend": "fake"}', encoding="utf-8")
    assert load_config(str(source)).backend == "fake"
