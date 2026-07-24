from python_app.src._env_utils import env_bool, env_float, env_int


def test_env_bool_accepts_truthy_spellings(monkeypatch):
    for raw in ["1", "true", "TRUE", " yes ", "On"]:
        monkeypatch.setenv("TEST_BOOL", raw)
        assert env_bool("TEST_BOOL") is True


def test_env_bool_returns_false_for_missing_or_unknown_values(monkeypatch):
    monkeypatch.delenv("TEST_BOOL", raising=False)
    assert env_bool("TEST_BOOL", default=True) is True

    monkeypatch.setenv("TEST_BOOL", "0")
    assert env_bool("TEST_BOOL") is False

    monkeypatch.setenv("TEST_BOOL", "maybe")
    assert env_bool("TEST_BOOL") is False


def test_env_int_uses_default_for_empty_or_invalid_values(monkeypatch):
    monkeypatch.delenv("TEST_INT", raising=False)
    assert env_int("TEST_INT", 7) == 7

    monkeypatch.setenv("TEST_INT", "")
    assert env_int("TEST_INT", 7) == 7

    monkeypatch.setenv("TEST_INT", "oops")
    assert env_int("TEST_INT", 7) == 7


def test_env_int_parses_signed_numbers(monkeypatch):
    monkeypatch.setenv("TEST_INT", "-42")
    assert env_int("TEST_INT", 7) == -42


def test_env_float_uses_default_for_empty_or_invalid_values(monkeypatch):
    monkeypatch.delenv("TEST_FLOAT", raising=False)
    assert env_float("TEST_FLOAT", 2.5) == 2.5

    monkeypatch.setenv("TEST_FLOAT", "")
    assert env_float("TEST_FLOAT", 2.5) == 2.5

    monkeypatch.setenv("TEST_FLOAT", "oops")
    assert env_float("TEST_FLOAT", 2.5) == 2.5


def test_env_float_parses_decimal_numbers(monkeypatch):
    monkeypatch.setenv("TEST_FLOAT", "3.125")
    assert env_float("TEST_FLOAT", 2.5) == 3.125
