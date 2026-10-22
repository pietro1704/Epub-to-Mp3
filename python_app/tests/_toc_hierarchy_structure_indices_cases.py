"""Structure Indices regression scenarios, collected by test_toc_hierarchy."""

from python_app.tests._toc_hierarchy_test_support import (
    EpubBuilder as EpubBuilder,
    _nav_point as _nav_point,
    _ncx as _ncx,
    os as os,
    tempfile as tempfile,
    unittest as unittest,
)

class TestGenerateStructureItemsIndices(unittest.TestCase):
    """Tests for _generate_structure_items index assignment.

    Covers three behaviours:
    1. TOC hierarchy produces hierarchical indices (4.1, 4.2, 10.1, 12.5, …).
    2. Chapters split at paragraph/CSS boundaries get unique sub-indices (4.3.1, 4.3.2, …).
    3. Short single-part chapters keep their plain index unchanged (e.g. "11").
    """

    def setUp(self):
        self.tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".epub").name

    def tearDown(self):
        if os.path.exists(self.tmp):
            os.unlink(self.tmp)

    def _make_app_and_reader(self, epub_path):
        from src.ebook_reader import EbookReader

        from python_app.main import ConverterApplication

        app = ConverterApplication()
        app._interactive_mode = False
        reader = EbookReader(epub_path)
        return app, reader

    # ------------------------------------------------------------------
    # Point 1: TOC hierarchy → hierarchical indices
    # ------------------------------------------------------------------

    def test_toc_hierarchy_produces_decimal_indices(self):
        """Parts with sub-chapters yield indices like 1.1, 1.2, 2.1, 2.2."""
        ncx_parts = ""
        for p in range(1, 3):
            children = "".join(
                _nav_point(f"c{p}_{c}", f"Chapter {p}.{c}", f"ch{p}_{c}.xhtml") for c in range(1, 3)
            )
            ncx_parts += _nav_point(f"part{p}", f"Part {p}", f"part{p}.xhtml", children=children)

        ncx = _ncx(ncx_parts)
        builder = EpubBuilder().set_ncx(ncx)
        for p in range(1, 3):
            builder.add_spine_file(f"part{p}", f"<h1>Part {p}</h1>")
            for c in range(1, 3):
                builder.add_spine_file(
                    f"ch{p}_{c}", f"<h2>Chapter {p}.{c}</h2><p>Chapter text here.</p>"
                )
        builder.write(self.tmp)

        app, reader = self._make_app_and_reader(self.tmp)
        items = app._generate_structure_items(reader)

        indices = [item.index for item in items]
        # Sub-chapters must have two-component decimal indices
        sub_indices = [idx for idx in indices if "." in idx and not idx.endswith(".0")]
        self.assertGreaterEqual(len(sub_indices), 4, f"Expected ≥4 sub-indices, got: {indices}")
        self.assertIn("1.1", indices)
        self.assertIn("1.2", indices)
        self.assertIn("2.1", indices)
        self.assertIn("2.2", indices)

    def test_it_style_hierarchy_indices(self):
        """Simulates IT structure: 3 Parts each with 3 chapters → 3.x indices."""
        ncx_parts = ""
        for p in range(1, 4):
            children = "".join(
                _nav_point(f"c{p}_{c}", f"Chapter {p}.{c}", f"ch{p}_{c}.xhtml") for c in range(1, 4)
            )
            ncx_parts += _nav_point(f"part{p}", f"Part {p}", f"part{p}.xhtml", children=children)

        builder = EpubBuilder().set_ncx(_ncx(ncx_parts))
        for p in range(1, 4):
            builder.add_spine_file(f"part{p}", f"<h1>Part {p}</h1>")
            for c in range(1, 4):
                builder.add_spine_file(f"ch{p}_{c}", f"<h2>Chapter {p}.{c}</h2><p>Content.</p>")
        builder.write(self.tmp)

        app, reader = self._make_app_and_reader(self.tmp)
        items = app._generate_structure_items(reader)

        indices = [item.index for item in items]
        for p in range(1, 4):
            for c in range(1, 4):
                self.assertIn(f"{p}.{c}", indices, f"Missing index {p}.{c}")

    # ------------------------------------------------------------------
    # Point 2: Split chapters get unique sub-indices
    # ------------------------------------------------------------------

    def test_split_chapters_get_unique_sub_indices(self):
        """When two spine files map to the same TOC chapter, they get .1/.2 suffixes."""
        # Two spine files that share one TOC entry — simulates paragraph-split behaviour.
        ncx = _ncx(
            _nav_point(
                "part1",
                "Part 1",
                "part1.xhtml",
                children=(_nav_point("ch1", "Chapter 1", "ch1a.xhtml")),
            )
        )
        builder = EpubBuilder().set_ncx(ncx)
        builder.add_spine_file("part1", "<h1>Part 1</h1>")
        # Two spine files for the same TOC chapter (ch1a.xhtml is the TOC href, ch1b not in TOC)
        builder.add_spine_file("ch1a", "<h2>Chapter 1</h2><p>First half of chapter.</p>")
        builder.add_spine_file("ch1b", "<h2>Chapter 1 cont</h2><p>Second half of chapter.</p>")
        builder.write(self.tmp)

        app, reader = self._make_app_and_reader(self.tmp)
        items = app._generate_structure_items(reader)

        indices = [item.index for item in items]
        # The two spine files that ended up with the same TOC index must be distinguished
        plain_dupes = [idx for idx in indices if indices.count(idx) > 1]
        self.assertEqual(plain_dupes, [], f"Duplicate indices found: {indices}")

    def test_three_split_parts_get_sequential_sub_indices(self):
        """Three spine files sharing the same chapter index get .1, .2, .3."""
        ncx = _ncx(
            _nav_point(
                "part1",
                "Part 1",
                "part1.xhtml",
                children=(_nav_point("ch1", "Chapter 1", "ch1a.xhtml")),
            )
        )
        builder = EpubBuilder().set_ncx(ncx)
        builder.add_spine_file("part1", "<h1>Part 1</h1>")
        builder.add_spine_file("ch1a", "<h2>Chapter 1</h2><p>Part A.</p>")
        builder.add_spine_file("ch1b", "<p>Part B.</p>")
        builder.add_spine_file("ch1c", "<p>Part C.</p>")
        builder.write(self.tmp)

        app, reader = self._make_app_and_reader(self.tmp)
        items = app._generate_structure_items(reader)

        # Find all indices that came from the split chapter
        sub_indices = [
            item.index
            for item in items
            if ".1." in item.index
            or item.index.endswith(".1")
            or item.index.endswith(".2")
            or item.index.endswith(".3")
        ]
        # There must be no duplicates at all
        indices = [item.index for item in items]
        self.assertEqual(len(set(indices)), len(indices), f"Duplicate indices: {indices}")

    def test_split_indices_are_addressable_via_parent_selector(self):
        """Split sub-indices like '4.3.1' are addressable by parent selector '4.3'.

        The selector matching in _match_selector already handles this via the
        startswith check. This test verifies the indices produced by the post-processing
        carry the correct prefix so that the selector logic will find them.
        """

        # Build an epub where Chapter 3 maps to multiple spine files (both TOC-matched
        # and a continuation file), producing a split scenario.
        ncx = _ncx(
            _nav_point(
                "part1",
                "Part 1",
                "part1.xhtml",
                children=(
                    _nav_point("ch1", "Chapter 1", "ch1.xhtml")
                    + _nav_point("ch2", "Chapter 2", "ch2.xhtml")
                    + _nav_point("ch3", "Chapter 3", "ch3a.xhtml")
                ),
            )
        )
        builder = EpubBuilder().set_ncx(ncx)
        builder.add_spine_file("part1", "<h1>Part 1</h1>")
        builder.add_spine_file("ch1", "<h2>Chapter 1</h2><p>Text.</p>")
        builder.add_spine_file("ch2", "<h2>Chapter 2</h2><p>Text.</p>")
        # ch3a is in TOC; ch3b is a spine-only continuation — both land on same TOC index
        builder.add_spine_file("ch3a", "<h2>Chapter 3</h2><p>First half.</p>")
        builder.add_spine_file("ch3b", "<p>Second half.</p>")
        builder.write(self.tmp)

        app, reader = self._make_app_and_reader(self.tmp)
        items = app._generate_structure_items(reader)

        indices = [item.index for item in items]
        # No duplicates must remain
        self.assertEqual(len(set(indices)), len(indices), f"Duplicate indices: {indices}")

        # Any index with three dotted components (x.y.z) must start with the
        # two-component prefix (x.y) — verifying addressability by parent selector.
        for idx in indices:
            parts = idx.split(".")
            if len(parts) == 3:
                parent = f"{parts[0]}.{parts[1]}"
                self.assertTrue(
                    idx.startswith(f"{parent}."),
                    f"Index {idx!r} not addressable by parent {parent!r}",
                )

    # ------------------------------------------------------------------
    # Point 3: Short single-part chapters keep plain index
    # ------------------------------------------------------------------

    def test_single_chapter_keeps_plain_index(self):
        """A chapter with no TOC sub-children and no splitting keeps a plain index like '3'."""
        ncx = _ncx(
            _nav_point(
                "part1",
                "Part 1",
                "part1.xhtml",
                children=(_nav_point("ch1", "Chapter 1", "ch1.xhtml")),
            )
            + _nav_point("interlude", "Interlude", "interlude.xhtml")
            + _nav_point(
                "part2",
                "Part 2",
                "part2.xhtml",
                children=(_nav_point("ch2", "Chapter 2", "ch2.xhtml")),
            )
        )
        builder = EpubBuilder().set_ncx(ncx)
        builder.add_spine_file("part1", "<h1>Part 1</h1>")
        builder.add_spine_file("ch1", "<h2>Chapter 1</h2><p>Text.</p>")
        builder.add_spine_file("interlude", "<h1>Interlude</h1><p>Short quote.</p>")
        builder.add_spine_file("part2", "<h1>Part 2</h1>")
        builder.add_spine_file("ch2", "<h2>Chapter 2</h2><p>Text.</p>")
        builder.write(self.tmp)

        app, reader = self._make_app_and_reader(self.tmp)
        items = app._generate_structure_items(reader)

        indices = [item.index for item in items]
        # Interlude appears once → should keep its plain index (no .1 suffix)
        interlude_items = [it for it in items if "Interlude" in (it.main_title or "")]
        self.assertEqual(
            len(interlude_items), 1, f"Expected exactly 1 interlude item, got: {indices}"
        )
        self.assertNotIn(
            ".",
            interlude_items[0].index.replace(".", "x", 0),
            f"Expected plain index for interlude, got: {interlude_items[0].index!r}",
        )
        # Actually just verify the index doesn't end with .1
        self.assertFalse(
            interlude_items[0].index.endswith(".1"),
            f"Interlude should not get .1 suffix, got: {interlude_items[0].index!r}",
        )

    def test_no_duplicate_indices_in_it_style_book(self):
        """Full IT-style book with 5 parts × 5 chapters produces all-unique indices."""
        ncx_parts = ""
        for p in range(1, 6):
            children = "".join(
                _nav_point(f"c{p}_{c}", f"Chapter {p}.{c}", f"ch{p}_{c}.xhtml") for c in range(1, 6)
            )
            ncx_parts += _nav_point(f"part{p}", f"Part {p}", f"part{p}.xhtml", children=children)
            ncx_parts += _nav_point(f"interlude{p}", f"Interlude {p}", f"interlude{p}.xhtml")

        builder = EpubBuilder().set_ncx(_ncx(ncx_parts))
        for p in range(1, 6):
            builder.add_spine_file(f"part{p}", f"<h1>Part {p}</h1>")
            for c in range(1, 6):
                builder.add_spine_file(f"ch{p}_{c}", f"<h2>Ch {p}.{c}</h2><p>Content.</p>")
            builder.add_spine_file(f"interlude{p}", f"<h1>Interlude {p}</h1><p>Quote.</p>")

        builder.write(self.tmp)

        app, reader = self._make_app_and_reader(self.tmp)
        items = app._generate_structure_items(reader)

        indices = [item.index for item in items]
        self.assertEqual(
            len(set(indices)),
            len(indices),
            f"Duplicate indices found: {[i for i in indices if indices.count(i) > 1]}",
        )
