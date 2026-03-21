from python_app.src.tts import piper_engine


def test_merge_small_chunks_reduces_tiny_segments():
    chunks = ["alpha", "beta", "gamma delta epsilon", "zeta"]

    merged = piper_engine._merge_small_chunks(chunks, max_chars=40, min_chars=12)

    assert len(merged) < len(chunks)
    assert all(len(chunk) <= 40 for chunk in merged)
    assert "alpha beta" in merged[0]


def test_reference_heavy_text_uses_larger_chunk_plan():
    text = """
    Bibliografia
    Agostinho, 1999.
    Dante, 2001.
    Homero, 2003.
    Platão, 2005.
    Aristóteles, 2007.
    """

    planned = piper_engine._planned_piper_chunk_chars(text, 3000)

    assert planned > 3000
    assert planned <= 6000


def test_retry_edge_before_fallback_only_when_not_already_in_safe_mode():
    from python_app import server

    assert server._should_retry_edge_before_fallback("edge", edge_slow_mode=False) is True
    assert server._should_retry_edge_before_fallback("EDGE", edge_slow_mode=True) is False
    assert server._should_retry_edge_before_fallback("piper", edge_slow_mode=False) is False
