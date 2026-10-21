# Legacy Python compatibility tests

This suite covers the retained Python parser/converter/server compatibility
surface. Product shared conversion behavior belongs in Rust; passing legacy
Python tests does not establish Apple FFI, Flutter, browser or release acceptance.
See [runtime navigation](../../docs/agents/runtime-navigation.md) and
[legacy reference](../../docs/legacy-agent-reference.md).

Useful parser seams include `test_text_processor.py`, `test_epub_parser.py`,
`test_pdf_parser.py`, `test_ebook_reader.py` and `test_data_classes.py`. The broader
directory also contains conversion/server regression coverage. Locate the test
for the changed behavior rather than relying on the old fixed suite counts.

Fixtures include temporary EPUB ZIP/OPF/container data, mocked PDF dependencies,
HTML/encoding cases and checked-in [EPUB fixtures](fixtures/epubs/README.md).
For a legacy change, test actual public behavior and relevant malformed/empty/
missing-source inputs; compare parsing fidelity against original document content.
Mocks for optional dependencies do not prove real parser or platform integration.

Python/Ruff execution remains deferred to CI under
[execution policy](../../docs/agents/execution-policy.md). `mise.toml` defines the
current `test:unit` and `test:integration` selections; inspect their prerequisites
and CI workflows before choosing a check. Old `cd tests; run_tests.py` recipes,
101-test/99%-coverage transcripts and subsecond timing were historical reports,
not measurements of the current revision. Report the exact selection and CI SHA
actually observed; do not claim comprehensive success from these notes.
