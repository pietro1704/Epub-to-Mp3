"""Application structure scenarios sharing the original unittest fixture."""

from python_app.tests._main_test_support import Chapter as Chapter
from python_app.tests._main_test_support import SimpleNamespace as SimpleNamespace


class ApplicationStructureCases:
    def test_apply_text_transforms_inline_retains_emphasis(self):
        item = self._build_structure_item(self._sample_html())
        reader = SimpleNamespace(title="Livro de Teste")
        config = self.app.config.create_conversion_config(
            engine="edge",
            footnote_mode="inline",
            footnote_context_words=8,
        )

        result = self.app._apply_text_transforms([item], config, reader)

        self.assertEqual(len(result), 1)
        text = result[0].text_override
        self.assertIsNotNone(text)
        self.assertIn("_itálico_", text)
        self.assertIn("**negrito**", text)
        self.assertIn("“aspas”", text)
        self.assertIn("nota de rodapé 1", text)
        self.assertIn("fim da nota de rodapé", text)

        segments = item.chapter.formatting_segments or []
        self.assertTrue(
            any(seg.formatting == "italic" and seg.text == "itálico" for seg in segments)
        )
        self.assertTrue(any(seg.formatting == "bold" and seg.text == "negrito" for seg in segments))
        self.assertTrue(any(seg.formatting == "quote" and seg.text == "aspas" for seg in segments))
        self.assertFalse(any("[[FOOTNOTE" in seg.text for seg in segments))
        self.assertNotIn("*", item.chapter.speech_text or "")
        self.assertNotIn("_", item.chapter.speech_text or "")
        self.assertIn("nota de rodapé 1", item.chapter.speech_text or "")
        self.assertIn("Esta nota explicativa", item.chapter.speech_text or "")

    def test_apply_text_transforms_chapter_end_moves_notes(self):
        item = self._build_structure_item(self._sample_html())
        reader = SimpleNamespace(title="Livro de Teste")
        config = self.app.config.create_conversion_config(
            engine="edge",
            footnote_mode="chapter_end",
            footnote_context_words=8,
        )

        result = self.app._apply_text_transforms([item], config, reader)
        text = result[0].text_override

        self.assertIn("Texto _itálico_ e **negrito** com “aspas” e nota.", text)
        self.assertTrue(any("nota de rodapé 1:" in line for line in text.splitlines()[1:]))
        self.assertNotIn("[[FOOTNOTE", text)

        segments = item.chapter.formatting_segments or []
        self.assertTrue(
            any(seg.formatting == "italic" and seg.text == "itálico" for seg in segments)
        )
        self.assertFalse(any("[[FOOTNOTE" in seg.text for seg in segments))
        speech = item.chapter.speech_text or ""
        self.assertNotIn("*", speech)
        self.assertNotIn("_", speech)
        self.assertIn("nota de rodapé 1", speech)

    def test_apply_text_transforms_skip_removes_notes(self):
        item = self._build_structure_item(self._sample_html())
        reader = SimpleNamespace(title="Livro de Teste")
        config = self.app.config.create_conversion_config(
            engine="edge",
            footnote_mode="skip",
            footnote_context_words=8,
        )

        result = self.app._apply_text_transforms([item], config, reader)
        text = result[0].text_override

        self.assertIn("Texto _itálico_ e **negrito** com “aspas” e nota.", text)
        self.assertNotIn("nota de rodapé", text)
        self.assertNotIn("[[FOOTNOTE", text)

        segments = item.chapter.formatting_segments or []
        self.assertTrue(
            any(seg.formatting == "italic" and seg.text == "itálico" for seg in segments)
        )
        self.assertFalse(any("[[FOOTNOTE" in seg.text for seg in segments))
        speech = item.chapter.speech_text or ""
        self.assertNotIn("*", speech)
        self.assertNotIn("_", speech)
        self.assertNotIn("nota de rodapé", speech)

    def test_deduplicate_heading(self):
        """Ensure duplicate heading lines are removed."""
        text = "Capítulo Um\nCAPÍTULO UM\nConteúdo"  # duplicate heading with different casing
        result = self.app._deduplicate_heading(text, "Capítulo Um")
        self.assertEqual(result, "CAPÍTULO UM\nConteúdo")

        text2 = "\n\nPrólogo\nPrólogo\nTexto"
        result2 = self.app._deduplicate_heading(text2, "")
        self.assertEqual(result2, "Prólogo\nTexto")

    def test_create_items_from_toc_entries_skips_parent_when_children_exist(self):
        chapter = Chapter(
            index=1,
            name="I.",
            source_path="text/ch1.html",
            text="A chegada\nTexto da chegada\nNº 34\nTexto do quarto",
        )
        toc_entries = [
            (4, "I.", None),
            (4, "I.", "A chegada"),
            (4, "I.", "Nº 34"),
        ]
        division_counters = {}

        def remap_division(value):
            return value

        items = self.app._create_items_from_toc_entries(
            chapter,
            toc_entries,
            "Book",
            division_counters,
            remap_division,
            "Author",
        )

        self.assertEqual([item.index for item in items], ["4.1", "4.2"])
        self.assertTrue(all(not item.index.endswith(".0") for item in items))

    def test_create_items_from_toc_entries_skips_empty_segments(self):
        chapter = Chapter(
            index=1,
            name="Rosto",
            source_path="text/front.html",
            text="",
        )
        toc_entries = [(1, "Rosto", None)]
        division_counters = {}

        def remap_division(value):
            return value

        items = self.app._create_items_from_toc_entries(
            chapter,
            toc_entries,
            "Book",
            division_counters,
            remap_division,
            "Author",
        )

        self.assertEqual(items, [])

    def test_build_toc_outline_map_preserves_hierarchy(self):
        toc = [
            SimpleNamespace(
                title="Parte I",
                href="text/p1.html#top",
                children=[
                    SimpleNamespace(
                        title="Capítulo 1",
                        href="text/p1.html#c1",
                        children=[
                            SimpleNamespace(
                                title="Seção A",
                                href="text/p1.html#s1",
                                children=[],
                            )
                        ],
                    )
                ],
            )
        ]
        reader = SimpleNamespace(get_toc=lambda: toc)
        outline = self.app._build_toc_outline_map(reader)
        entries = self.app._resolve_toc_outline_entries("text/p1.html", outline)
        self.assertIsNotNone(entries)
        labels = [".".join(str(p) for p in entry["path_indices"]) for entry in entries]
        self.assertEqual(labels, ["1", "1.1", "1.1.1"])

    def test_create_items_from_toc_outline_entries_uses_deep_index(self):
        chapter = Chapter(
            index=1,
            name="Capítulo 1",
            source_path="text/p1.html",
            text="Seção A\nConteúdo A\nSeção B\nConteúdo B",
        )
        toc_outline_entries = [
            {
                "path_indices": (2, 3, 1),
                "path_titles": ("Parte II", "Capítulo 3", "Seção A"),
                "title": "Seção A",
                "level": 3,
            },
            {
                "path_indices": (2, 3, 2),
                "path_titles": ("Parte II", "Capítulo 3", "Seção B"),
                "title": "Seção B",
                "level": 3,
            },
        ]
        items = self.app._create_items_from_toc_outline_entries(
            chapter,
            toc_outline_entries,
            "Book",
            "Author",
        )
        self.assertEqual([item.index for item in items], ["2.3.1", "2.3.2"])
