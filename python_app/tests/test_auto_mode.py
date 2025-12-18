import types

from python_app.src.converter import AudioConverter


def _mock_pool():
    dummy_engine = types.SimpleNamespace(last_error=None)
    pool = {
        "edge": (None, dummy_engine),
        "coqui": (None, dummy_engine),
        "piper": (None, dummy_engine),
    }
    return pool


def test_pick_auto_engine_long():
    converter = AudioConverter()
    pool = _mock_pool()
    selected, order = converter._pick_auto_engine(12000, 600, pool)
    assert selected == "coqui"
    assert order[0] == "coqui"
    assert order[1] in {"piper", "edge"}


def test_pick_auto_engine_short():
    converter = AudioConverter()
    pool = _mock_pool()
    selected, order = converter._pick_auto_engine(2000, 120, pool)
    assert selected == "edge"
    assert "edge" in order


def test_next_auto_engine():
    converter = AudioConverter()
    order = ["coqui", "edge", "piper"]
    attempted = {"coqui"}
    next_engine = converter._next_auto_engine(order, attempted)
    assert next_engine == "edge"
    attempted.update(order)
    assert converter._next_auto_engine(order, attempted) is None
