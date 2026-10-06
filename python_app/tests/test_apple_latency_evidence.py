"""Verify raw Apple export ingestion without asserting product performance."""

import hashlib
import json
from uuid import UUID

import pytest

from scripts.apple_latency_evidence import load_apple_journeys


@pytest.fixture
def export():
    journeys = []
    for index, (kind, transitions) in enumerate(
        (
            ("book_open", ("open_requested", "readable_content", "controls_usable")),
            ("progressive_playback", ("play_requested", "audio_queued", "audio_audible")),
            ("seek", ("seek_requested", "seek_target_reached")),
        ),
        1,
    ):
        journeys.append(
            {
                "id": str(UUID(int=index)),
                "kind": kind,
                "context": {
                    "documentKind": "epub",
                    "cacheClass": "cold" if index == 1 else "unknown",
                },
                "records": [
                    {"transition": transition, "elapsedNanoseconds": step * 1_000_000}
                    for step, transition in enumerate(transitions)
                ],
            }
        )
    return journeys


def load(tmp_path, export, *, corpus="epub", cache="cold", raw=None, digest=None, ids=None):
    path = tmp_path / "capture.json"
    data = json.dumps(export).encode() if raw is None else raw
    path.write_bytes(data)
    ids = (
        ids
        if ids is not None
        else {name: item["id"] for name, item in zip(("open", "play", "seek"), export)}
    )
    return load_apple_journeys(
        path, digest or hashlib.sha256(data).hexdigest(), ids, corpus_kind=corpus, cache_state=cache
    )


def test_epub_derives_separate_observed_boundaries(tmp_path, export):
    assert load(tmp_path, export) == {
        "readable_content": 1,
        "controls_usable": 2,
        "reader_usable": 2,
        "audio_queued": 1,
        "audio_audible": 2,
        "seek_target_reached": 1,
    }


def publication():
    return {
        "publicationId": "0123456789abcdef0123456789abcdef",
        "producer": {
            "version": 1,
            "attemptId": "123e4567-e89b-12d3-a456-426614174000",
            "segmentReadyElapsedNanoseconds": 9_000_000_000,
            "artifactPublishedElapsedNanoseconds": 10_000_000_000,
        },
    }


def stream_request(journey, identifier="0123456789abcdef0123456789abcdef"):
    return {
        "journeyId": journey["id"],
        "requestId": "123e4567-e89b-12d3-a456-426614174001",
        "publicationId": identifier,
    }


@pytest.mark.parametrize("identifier", [
    "0123456789abcdef0123456789abcdef", "0123456789ABCDEF0123456789ABCDEF",
    "123e4567-e89b-12d3-a456-426614174000", "123E4567-E89B-12D3-A456-426614174000",
    "0", "12345678901234567890",
])
@pytest.mark.parametrize("with_producer", [False, True])
def test_stream_request_preserves_client_timings(tmp_path, export, identifier, with_producer):
    expected = load(tmp_path, export)
    for index in (1, 2):
        export[index]["streamRequest"] = stream_request(export[index], identifier)
        if with_producer:
            export[index]["streamPublication"] = {**publication(), "publicationId": identifier}
    assert load(tmp_path, export) == expected


def test_stream_request_uuid_comparison_is_case_insensitive(tmp_path, export):
    export[1]["id"] = "123e4567-e89b-12d3-a456-426614174002"
    export[1]["streamRequest"] = stream_request(export[1])
    export[1]["streamRequest"]["journeyId"] = export[1]["id"].upper()
    export[1]["streamRequest"]["requestId"] = export[1]["streamRequest"]["requestId"].upper()
    assert load(tmp_path, export)["audio_audible"] == 2


@pytest.mark.parametrize("field", ["journeyId", "requestId"])
@pytest.mark.parametrize("value", [None, True, 7, "", "PRIVATE_BOOK_CONTENT", "0" * 32,
    "{" + str(UUID(int=1)) + "}", "urn:uuid:" + str(UUID(int=1))])
def test_stream_request_invalid_uuid_is_redacted(tmp_path, export, field, value):
    export[1]["streamRequest"] = {**stream_request(export[1]), field: value}
    with pytest.raises(ValueError) as error:
        load(tmp_path, export)
    assert "PRIVATE_BOOK_CONTENT" not in str(error.value)
    assert str(tmp_path) not in str(error.value)


@pytest.mark.parametrize("identifier", [None, True, 12, "", "PRIVATE_BOOK_CONTENT", "١٢٣",
    "123456789012345678901", "g" * 32, "{" + str(UUID(int=1)) + "}"])
def test_stream_request_invalid_publication_is_redacted(tmp_path, export, identifier):
    export[2]["streamRequest"] = stream_request(export[2], identifier)
    with pytest.raises(ValueError) as error:
        load(tmp_path, export)
    assert "PRIVATE_BOOK_CONTENT" not in str(error.value)
    assert str(tmp_path) not in str(error.value)


@pytest.mark.parametrize("mutation", ["open", "null", "extra", "missing", "journey_mismatch",
    "publication_mismatch", "publication_case_mismatch", "unknown_journey_field"])
def test_stream_request_schema_and_correlation_are_strict(tmp_path, export, mutation):
    index = 0 if mutation == "open" else 1
    metadata = stream_request(export[index])
    if mutation == "null":
        metadata = None
    elif mutation == "extra":
        metadata["text"] = "PRIVATE_BOOK_CONTENT"
    elif mutation == "missing":
        metadata.pop("requestId")
    elif mutation == "journey_mismatch":
        metadata["journeyId"] = export[2]["id"]
    elif mutation in ("publication_mismatch", "publication_case_mismatch"):
        export[index]["streamPublication"] = publication()
        metadata["publicationId"] = "0" if mutation == "publication_mismatch" else metadata["publicationId"].upper()
    elif mutation == "unknown_journey_field":
        export[index]["title"] = "PRIVATE_BOOK_CONTENT"
    export[index]["streamRequest"] = metadata
    with pytest.raises(ValueError) as error:
        load(tmp_path, export)
    assert "PRIVATE_BOOK_CONTENT" not in str(error.value)


@pytest.mark.parametrize("field", ["journeyId", "requestId", "publicationId"])
def test_stream_request_duplicate_nested_fields_are_rejected(tmp_path, export, field):
    metadata = stream_request(export[1])
    export[1]["streamRequest"] = metadata
    original = json.dumps(field) + ": " + json.dumps(metadata[field])
    raw = json.dumps(export).replace(original, original + ", " + original).encode()
    with pytest.raises(ValueError, match="Duplicate"):
        load(tmp_path, export, raw=raw)


@pytest.mark.parametrize("identifier", [
    "0123456789abcdef0123456789abcdef", "0123456789ABCDEF0123456789ABCDEF",
    "123e4567-e89b-12d3-a456-426614174000", "123E4567-E89B-12D3-A456-426614174000",
    "0", "12345678901234567890",
])
def test_publication_metadata_does_not_change_client_timings(tmp_path, export, identifier):
    legacy = load(tmp_path, export)
    for index in (1, 2):
        export[index]["streamPublication"] = {**publication(), "publicationId": identifier}
    assert load(tmp_path, export) == legacy


@pytest.mark.parametrize("identifier", [None, True, 12, "", "PRIVATE_BOOK_CONTENT",
    "١٢٣", "123456789012345678901", "g" * 32, "{" + str(UUID(int=1)) + "}"])
def test_invalid_publication_identity_is_redacted(tmp_path, export, identifier):
    export[1]["streamPublication"] = {**publication(), "publicationId": identifier}
    with pytest.raises(ValueError) as error:
        load(tmp_path, export)
    assert "PRIVATE_BOOK_CONTENT" not in str(error.value)
    assert str(tmp_path) not in str(error.value)


@pytest.mark.parametrize("field,value", [
    ("version", True), ("version", 1.0), ("version", 2),
    ("attemptId", "PRIVATE_BOOK_CONTENT"), ("attemptId", "0" * 32), ("attemptId", None),
    ("segmentReadyElapsedNanoseconds", True), ("segmentReadyElapsedNanoseconds", -1),
    ("segmentReadyElapsedNanoseconds", 1.5), ("segmentReadyElapsedNanoseconds", "1"),
    ("segmentReadyElapsedNanoseconds", 2**64), ("segmentReadyElapsedNanoseconds", None),
    ("artifactPublishedElapsedNanoseconds", 1), ("artifactPublishedElapsedNanoseconds", 2**64),
    ("artifactPublishedElapsedNanoseconds", True), ("artifactPublishedElapsedNanoseconds", float("nan")),
])
def test_invalid_producer_metadata_is_redacted(tmp_path, export, field, value):
    metadata = publication()
    metadata["producer"][field] = value
    export[2]["streamPublication"] = metadata
    with pytest.raises(ValueError) as error:
        load(tmp_path, export)
    assert "PRIVATE_BOOK_CONTENT" not in str(error.value)


@pytest.mark.parametrize("mutation", ["open", "null", "extra", "missing", "producer_extra", "producer_missing"])
def test_publication_schema_and_allowed_journey_are_strict(tmp_path, export, mutation):
    metadata = publication()
    if mutation == "null":
        metadata = None
    elif mutation == "extra":
        metadata["title"] = "PRIVATE_BOOK_CONTENT"
    elif mutation == "missing":
        metadata.pop("producer")
    elif mutation == "producer_extra":
        metadata["producer"]["text"] = "PRIVATE_BOOK_CONTENT"
    elif mutation == "producer_missing":
        metadata["producer"].pop("attemptId")
    export[0 if mutation == "open" else 1]["streamPublication"] = metadata
    with pytest.raises(ValueError) as error:
        load(tmp_path, export)
    assert "PRIVATE_BOOK_CONTENT" not in str(error.value)


@pytest.mark.parametrize("elapsed", [0, 2**64 - 1])
def test_producer_unsigned_boundaries_remain_separate_from_client_clock(tmp_path, export, elapsed):
    expected = load(tmp_path, export)
    metadata = publication()
    metadata["producer"]["segmentReadyElapsedNanoseconds"] = elapsed
    metadata["producer"]["artifactPublishedElapsedNanoseconds"] = elapsed
    export[1]["streamPublication"] = metadata
    assert load(tmp_path, export) == expected


def test_duplicate_nested_producer_fields_remain_rejected(tmp_path, export):
    export[1]["streamPublication"] = publication()
    raw = json.dumps(export).replace('"version": 1', '"version": 1, "version": 1').encode()
    with pytest.raises(ValueError, match="Duplicate"):
        load(tmp_path, export, raw=raw)


def test_publication_does_not_enable_unknown_journey_fields(tmp_path, export):
    export[1]["streamPublication"] = publication()
    export[1]["title"] = "PRIVATE_BOOK_CONTENT"
    with pytest.raises(ValueError, match="fields") as error:
        load(tmp_path, export)
    assert "PRIVATE_BOOK_CONTENT" not in str(error.value)


@pytest.mark.parametrize(
    "corpus,document",
    [
        ("selectable_text_pdf", "selectable_text_pdf"),
        ("sideways_two_up_scanned_pdf", "normalized_scanned_pdf"),
    ],
)
def test_pdf_requires_corrected_first_page_for_reader_usability(tmp_path, export, corpus, document):
    export[0]["context"]["documentKind"] = document
    with pytest.raises(ValueError, match="incomplete"):
        load(tmp_path, export, corpus=corpus)
    export[0]["records"].append({"transition": "first_pdf_page", "elapsedNanoseconds": 9_000_000})
    result = load(tmp_path, export, corpus=corpus)
    assert result["reader_usable"] == result["first_pdf_page"] == 9


def test_warm_requires_prepared_disk_context(tmp_path, export):
    export[0]["context"]["cacheClass"] = "in_memory_warm"
    with pytest.raises(ValueError, match="context"):
        load(tmp_path, export, cache="relaunch_warm")
    export[0]["context"]["cacheClass"] = "prepared_disk"
    assert load(tmp_path, export, cache="relaunch_warm")["reader_usable"] == 2


@pytest.mark.parametrize("index", [0, 1, 2])
def test_selected_cancelled_or_incomplete_journey_is_rejected(tmp_path, export, index):
    final = export[index]["records"].pop()
    with pytest.raises(ValueError, match="incomplete"):
        load(tmp_path, export)
    export[index]["records"].append({**final, "transition": "cancelled"})
    with pytest.raises(ValueError, match="cancelled"):
        load(tmp_path, export)


def test_unselected_cancelled_journey_does_not_discard_valid_capture(tmp_path, export):
    export.append(
        {
            "id": str(UUID(int=9)),
            "kind": "seek",
            "context": {"documentKind": "epub", "cacheClass": "unknown"},
            "records": [
                {"transition": "seek_requested", "elapsedNanoseconds": 0},
                {"transition": "cancelled", "elapsedNanoseconds": 1},
            ],
        }
    )
    assert load(tmp_path, export)["seek_target_reached"] == 1


def test_queue_must_precede_audible_even_when_timestamps_tie(tmp_path, export):
    export[1]["records"][1:] = [
        {"transition": "audio_audible", "elapsedNanoseconds": 1},
        {"transition": "audio_queued", "elapsedNanoseconds": 1},
    ]
    with pytest.raises(ValueError, match="precedes"):
        load(tmp_path, export)


@pytest.mark.parametrize("elapsed", [True, -1, 0.1, "100", None, 2**64, float("nan"), float("inf")])
def test_elapsed_requires_unsigned_integer_nanoseconds(tmp_path, export, elapsed):
    export[0]["records"][1]["elapsedNanoseconds"] = elapsed
    with pytest.raises(ValueError, match="timing"):
        load(tmp_path, export)


def test_decreasing_and_nonzero_initial_timing_rejected(tmp_path, export):
    export[0]["records"][2]["elapsedNanoseconds"] = 1
    with pytest.raises(ValueError, match="timing"):
        load(tmp_path, export)
    export[0]["records"][2]["elapsedNanoseconds"] = 2_000_000
    export[0]["records"][0]["elapsedNanoseconds"] = 1
    with pytest.raises(ValueError, match="initial"):
        load(tmp_path, export)


def test_duplicate_global_and_selected_ids_rejected(tmp_path, export):
    export.append(export[0])
    with pytest.raises(ValueError, match="Duplicate.*identifier"):
        load(tmp_path, export)
    export.pop()
    ids = {name: export[0]["id"] for name in ("open", "play", "seek")}
    with pytest.raises(ValueError, match="distinct"):
        load(tmp_path, export, ids=ids)


def test_duplicate_json_keys_rejected(tmp_path, export):
    raw = (
        json.dumps(export)
        .replace('"kind": "book_open"', '"kind": "book_open", "kind": "book_open"')
        .encode()
    )
    with pytest.raises(ValueError, match="Duplicate.*field"):
        load(tmp_path, export, raw=raw)


@pytest.mark.parametrize("level", ["journey", "context", "record"])
def test_unknown_privacy_fields_rejected_without_echoing_value(tmp_path, export, level):
    target = {
        "journey": export[0],
        "context": export[0]["context"],
        "record": export[0]["records"][0],
    }[level]
    target["title"] = "PRIVATE_BOOK_CONTENT"
    with pytest.raises(ValueError, match="fields") as error:
        load(tmp_path, export)
    assert "PRIVATE_BOOK_CONTENT" not in str(error.value)


@pytest.mark.parametrize("raw", [b"{", b"\xff", b"{}", b"null"])
def test_invalid_artifact_json_is_redacted(tmp_path, export, raw):
    with pytest.raises(ValueError) as error:
        load(tmp_path, export, raw=raw)
    assert str(tmp_path) not in str(error.value)


def test_missing_file_and_hash_mismatch_are_redacted(tmp_path, export):
    ids = {name: item["id"] for name, item in zip(("open", "play", "seek"), export)}
    with pytest.raises(ValueError, match="read") as error:
        load_apple_journeys(
            tmp_path / "PRIVATE_NAME.json", "a" * 64, ids, corpus_kind="epub", cache_state="cold"
        )
    assert "PRIVATE_NAME" not in str(error.value)
    with pytest.raises(ValueError, match="digest mismatch"):
        load(tmp_path, export, digest="a" * 64)


def test_wrong_kind_and_unknown_transition_rejected(tmp_path, export):
    export[0]["records"][1]["transition"] = "unrecognized"
    with pytest.raises(ValueError, match="transition"):
        load(tmp_path, export)
    export[0]["records"][1]["transition"] = "readable_content"
    ids = {"open": export[1]["id"], "play": export[0]["id"], "seek": export[2]["id"]}
    with pytest.raises(ValueError, match="wrong kind"):
        load(tmp_path, export, ids=ids)
