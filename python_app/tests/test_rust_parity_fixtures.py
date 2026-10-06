"""Generate and lock deterministic Rust migration intermediate fixtures."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

from src.ebook_reader import EbookReader
from src.ios_entrypoints import prepare_chunks
from src.text_sanitizer import sanitize_for_edge_recovery, split_into_sentences

ROOT = Path(__file__).resolve().parents[2]
CORPUS = ROOT / "tests" / "fixtures" / "rust_parity" / "v1"
INPUTS = ROOT / "python_app" / "tests" / "fixtures"

def _canonical(value):
    if isinstance(value, dict):
        return {k: _canonical(value[k]) for k in sorted(value)}
    if isinstance(value, list):
        return [_canonical(item) for item in value]
    if isinstance(value, Path):
        return "<path>"
    return value

def _write(name, value):
    path = CORPUS / name
    path.write_text(json.dumps(_canonical(value), ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")

def _toc(item):
    return {"title": item.title, "href": item.href, "level": item.level, "children": [_toc(child) for child in item.children]}

def _chapter(chapter):
    return {"index": chapter.index, "name": chapter.name, "sourcePath": chapter.source_path, "text": chapter.text, "level": chapter.level, "speechText": chapter.speech_text, "footnotes": chapter.footnotes, "stableId": chapter.stable_id, "formatting": [{"text": s.text, "formatting": s.formatting} for s in (chapter.formatting_segments or [])]}

def build_corpus():
    reader = EbookReader(INPUTS / "epubs" / "test_multifeature.epub")
    chapters = reader.get_chapters()
    parsed = {"format": "epub", "title": reader.title, "author": reader.author, "language": reader.language, "sourceFormat": getattr(reader, "source_format", "epub"), "toc": [_toc(item) for item in reader.get_toc()], "chapters": [_chapter(item) for item in chapters]}
    _write("parsed.json", parsed)
    _write("normalized_text.json", {"chapters": [{"index": c.index, "text": sanitize_for_edge_recovery(c.text), "speechText": sanitize_for_edge_recovery(c.speech_text or "")} for c in chapters], "sentences": split_into_sentences("One sentence. Two sentences!", max_chars=1500)})
    sample = "First paragraph.\n\nSecond paragraph with enough words to remain deterministic."
    _write("chunks.json", {"regular": prepare_chunks(sample, voice="en-US-AriaNeural"), "streaming": prepare_chunks(sample, voice="en-US-AriaNeural", streaming=True)})
    key_input = "rust-parity-v1\0test_multifeature.epub"
    _write("cache_keys.json", {"algorithm": "sha256", "inputs": [key_input], "keys": [hashlib.sha256(key_input.encode()).hexdigest()]})
    _write("job.json", {"finished": {"jobId": "<uuid>", "state": "finished", "outputs": [], "error": None}, "failed": {"jobId": "<uuid>", "state": "failed", "outputs": [], "error": "fixture failure"}})
    _write("fulltext.json", {"miss": {"cache": "miss", "fulltext": "<text>"}, "hit": {"cache": "hit", "fulltext": "<text>"}})
    _write("stream_manifest.json", {"jobId": "<uuid>", "chapters": [{"index": 0, "chunks": [{"id": "<id>", "index": 0, "url": "<url>"}], "retiredChunks": [{"id": "<id>", "file": "<path>"}]}]})
    (CORPUS / "sse.ndjson").write_text("\n".join(json.dumps(item, sort_keys=True) for item in [{"event": "job", "data": {"state": "queued"}}, {"event": "chunk", "data": {"id": "<id>", "index": 0}}, {"event": "job", "data": {"state": "finished"}}]) + "\n", encoding="utf-8")
    manifest = {"version": 1, "files": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(CORPUS.glob("*.json")) if p.name != "manifest.json"} | {"sse.ndjson": hashlib.sha256((CORPUS / "sse.ndjson").read_bytes()).hexdigest()}}
    _write("manifest.json", manifest)

def test_golden_fixture_corpus_is_current():
    build_corpus()
    manifest = json.loads((CORPUS / "manifest.json").read_text())
    for name, digest in manifest["files"].items():
        assert hashlib.sha256((CORPUS / name).read_bytes()).hexdigest() == digest
    assert set(manifest["files"]) == {"parsed.json", "normalized_text.json", "chunks.json", "cache_keys.json", "job.json", "fulltext.json", "stream_manifest.json", "sse.ndjson"}

def test_fixture_normalizer_preserves_shape_and_replaces_only_paths():
    value = {"path": Path("/private/input.epub"), "items": [None, "hello"], "count": 2}
    assert _canonical(value) == {"count": 2, "items": [None, "hello"], "path": "<path>"}
