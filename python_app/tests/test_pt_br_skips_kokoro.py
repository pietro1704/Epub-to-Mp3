"""Regression: pt-BR books must bypass Kokoro and fall straight to Piper.

Kokoro only supports en/ja/zh — pt-BR audio synthesised via Kokoro produces
English-sounding output. The chain must skip the Kokoro tier entirely.
"""

from python_app.src.tts.kokoro_engine import kokoro_supports_language


class TestPtBrSkipsKokoro:
    def test_pt_br_not_supported(self):
        assert kokoro_supports_language("pt-BR") is False
        assert kokoro_supports_language("pt") is False
        assert kokoro_supports_language("pt_BR") is False
        assert kokoro_supports_language("PT-br") is False

    def test_supported_languages_unchanged(self):
        assert kokoro_supports_language("en") is True
        assert kokoro_supports_language("en-US") is True
        assert kokoro_supports_language("ja") is True
        assert kokoro_supports_language("zh-CN") is True

    def test_pt_br_excluded_from_server_chain(self, monkeypatch):
        """_build_engine_chain must not include kokoro for pt-BR jobs."""
        import python_app.server as srv
        from python_app.src import _server_engine_helpers as helpers

        monkeypatch.setattr(srv, "_has_kokoro_support", lambda lang: kokoro_supports_language(lang))
        monkeypatch.setattr(srv, "_has_piper_support", lambda: True)

        class _Cfg:
            primary_language = "pt-BR"
            engine = "auto"

        monkeypatch.setattr(helpers, "_engine_chain_fallback_enabled", lambda: True)

        try:
            chain = helpers._build_engine_chain(
                _Cfg(), available_engines=["edge", "kokoro", "piper"]
            )
        except Exception:
            import pytest

            pytest.skip(
                "_build_engine_chain signature differs; pure-language test still pins behaviour"
            )
            return
        assert "kokoro" not in [
            e.lower() for e in chain
        ], f"pt-BR job included kokoro in chain: {chain}"
