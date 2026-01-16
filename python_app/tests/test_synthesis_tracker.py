# -*- coding: utf-8 -*-
"""
Unit tests for synthesis_tracker module
"""

import tempfile
import unittest
from pathlib import Path

from python_app.src.synthesis_tracker import SegmentRecord, SynthesisTracker, ValidationReport


class TestSegmentRecord(unittest.TestCase):
    """Test cases for SegmentRecord dataclass"""

    def test_create_simple_text(self):
        """Test creating SegmentRecord with simple text"""
        text = "This is a simple test with ten words here right now okay."
        record = SegmentRecord.create(index=0, text=text)

        self.assertEqual(record.index, 0)
        self.assertEqual(record.text, text)
        self.assertEqual(record.char_count, len(text))
        self.assertEqual(record.word_count, 10)
        self.assertGreater(record.estimated_duration_seconds, 0)
        self.assertEqual(record.status, "pending")
        self.assertIsNone(record.audio_path)
        self.assertIsNone(record.actual_duration_seconds)
        self.assertIsNone(record.error)

    def test_create_empty_text(self):
        """Test creating SegmentRecord with empty text"""
        record = SegmentRecord.create(index=1, text="")

        self.assertEqual(record.index, 1)
        self.assertEqual(record.word_count, 0)
        self.assertEqual(record.estimated_duration_seconds, 0.0)

    def test_create_with_custom_wpm(self):
        """Test creating SegmentRecord with custom words per minute"""
        text = "This has exactly five words here."
        record = SegmentRecord.create(index=2, text=text, words_per_minute=200)

        # 5 words at 200 WPM = 5/200 * 60 = 1.5 seconds
        self.assertAlmostEqual(record.estimated_duration_seconds, 1.5, places=2)

    def test_text_hash_uniqueness(self):
        """Test that different texts produce different hashes"""
        record1 = SegmentRecord.create(0, "Text A")
        record2 = SegmentRecord.create(0, "Text B")
        record3 = SegmentRecord.create(0, "Text A")

        self.assertNotEqual(record1.text_hash, record2.text_hash)
        self.assertEqual(record1.text_hash, record3.text_hash)

    def test_text_hash_consistency(self):
        """Test that same text always produces same hash"""
        text = "Consistent text for hashing"
        record1 = SegmentRecord.create(0, text)
        record2 = SegmentRecord.create(1, text)

        self.assertEqual(record1.text_hash, record2.text_hash)


class TestSynthesisTracker(unittest.TestCase):
    """Test cases for SynthesisTracker class"""

    def setUp(self):
        """Set up test fixtures"""
        self.tracker = SynthesisTracker(chapter_title="Test Chapter")

    def test_initialization(self):
        """Test SynthesisTracker initialization"""
        self.assertEqual(self.tracker.chapter_title, "Test Chapter")
        self.assertEqual(len(self.tracker.segments), 0)

    def test_record_new_segment(self):
        """Test recording a new segment"""
        self.tracker.record_segment(index=0, text="Test segment text", status="pending")

        self.assertEqual(len(self.tracker.segments), 1)
        segment = self.tracker.get_segment(0)
        self.assertIsNotNone(segment)
        self.assertEqual(segment.text, "Test segment text")
        self.assertEqual(segment.status, "pending")

    def test_update_existing_segment(self):
        """Test updating an existing segment"""
        # Record pending segment
        self.tracker.record_segment(index=0, text="Test text", status="pending")

        # Update to success with audio info
        audio_path = Path("/tmp/test.mp3")
        self.tracker.record_segment(
            index=0, text="Test text", audio_path=audio_path, duration=5.5, status="success"
        )

        segment = self.tracker.get_segment(0)
        self.assertEqual(segment.status, "success")
        self.assertEqual(segment.audio_path, str(audio_path))
        self.assertEqual(segment.actual_duration_seconds, 5.5)

    def test_record_failed_segment(self):
        """Test recording a failed segment"""
        self.tracker.record_segment(
            index=0, text="Failed text", status="failed", error="Network timeout"
        )

        segment = self.tracker.get_segment(0)
        self.assertEqual(segment.status, "failed")
        self.assertEqual(segment.error, "Network timeout")

    def test_get_missing_segments(self):
        """Test getting missing (failed or pending) segments"""
        self.tracker.record_segment(0, "Text 0", status="success")
        self.tracker.record_segment(1, "Text 1", status="pending")
        self.tracker.record_segment(2, "Text 2", status="failed")
        self.tracker.record_segment(3, "Text 3", status="success")

        missing = self.tracker.get_missing_segments()
        self.assertEqual(len(missing), 2)
        missing_indices = [s.index for s in missing]
        self.assertIn(1, missing_indices)
        self.assertIn(2, missing_indices)

    def test_get_successful_segments(self):
        """Test getting successful segments"""
        self.tracker.record_segment(0, "Text 0", status="success")
        self.tracker.record_segment(1, "Text 1", status="pending")
        self.tracker.record_segment(2, "Text 2", status="success")

        successful = self.tracker.get_successful_segments()
        self.assertEqual(len(successful), 2)
        success_indices = [s.index for s in successful]
        self.assertEqual(success_indices, [0, 2])

    def test_validate_completeness_success(self):
        """Test validation when all segments are successful"""
        for i in range(3):
            self.tracker.record_segment(i, f"Text {i}" * 20, status="pending")
            # Simulate successful conversion with realistic duration
            self.tracker.record_segment(
                i,
                f"Text {i}" * 20,
                audio_path=Path(f"/tmp/{i}.mp3"),
                duration=4.0,  # 4 seconds per segment
                status="success",
            )

        report = self.tracker.validate_completeness()
        self.assertTrue(report.is_valid)
        self.assertEqual(report.total_segments, 3)
        self.assertEqual(report.successful_segments, 3)
        self.assertEqual(report.failed_segments, 0)
        self.assertEqual(len(report.missing_segments), 0)
        self.assertEqual(len(report.validation_errors), 0)

    def test_validate_completeness_with_failures(self):
        """Test validation when some segments failed"""
        self.tracker.record_segment(0, "Text 0", status="success")
        self.tracker.record_segment(1, "Text 1", status="failed", error="Timeout")
        self.tracker.record_segment(2, "Text 2", status="pending")

        report = self.tracker.validate_completeness()
        self.assertFalse(report.is_valid)
        self.assertEqual(report.total_segments, 3)
        self.assertEqual(report.successful_segments, 1)
        self.assertEqual(report.failed_segments, 2)
        self.assertEqual(report.missing_segments, [1, 2])
        self.assertGreater(len(report.validation_errors), 0)

    def test_validate_completeness_duration_mismatch(self):
        """Test validation detects duration mismatch"""
        # Create segment with 100 words (should be ~40 seconds at 150 WPM)
        text = " ".join(["word"] * 100)
        self.tracker.record_segment(0, text, status="pending")

        # Record success with very short duration (major mismatch)
        self.tracker.record_segment(
            0,
            text,
            audio_path=Path("/tmp/test.mp3"),
            duration=5.0,  # Way too short
            status="success",
        )

        report = self.tracker.validate_completeness(tolerance=0.15)
        self.assertFalse(report.is_valid)
        self.assertGreater(len(report.validation_errors), 0)
        self.assertIn("Duration mismatch", report.validation_errors[0])

    def test_export_and_load_json(self):
        """Test exporting and loading tracker from JSON"""
        with tempfile.TemporaryDirectory() as tmpdir:
            # Create tracker with data
            self.tracker.record_segment(0, "Text A", status="success", duration=3.5)
            self.tracker.record_segment(1, "Text B", status="failed", error="Error")

            # Export to JSON
            json_path = Path(tmpdir) / "tracker.json"
            self.tracker.export_to_json(json_path)

            # Verify file exists
            self.assertTrue(json_path.exists())

            # Load from JSON
            loaded_tracker = SynthesisTracker.load_from_json(json_path)

            # Verify data matches
            self.assertEqual(loaded_tracker.chapter_title, "Test Chapter")
            self.assertEqual(len(loaded_tracker.segments), 2)

            seg0 = loaded_tracker.get_segment(0)
            self.assertEqual(seg0.text, "Text A")
            self.assertEqual(seg0.status, "success")

            seg1 = loaded_tracker.get_segment(1)
            self.assertEqual(seg1.text, "Text B")
            self.assertEqual(seg1.status, "failed")
            self.assertEqual(seg1.error, "Error")

    def test_get_synthesis_log(self):
        """Test getting synthesis log as list of dicts"""
        self.tracker.record_segment(0, "Text A", status="success")
        self.tracker.record_segment(1, "Text B", status="failed")

        log = self.tracker.get_synthesis_log()
        self.assertEqual(len(log), 2)
        self.assertIsInstance(log[0], dict)
        self.assertEqual(log[0]["index"], 0)
        self.assertEqual(log[0]["status"], "success")
        self.assertEqual(log[1]["index"], 1)
        self.assertEqual(log[1]["status"], "failed")

    def test_repr(self):
        """Test string representation"""
        self.tracker.record_segment(0, "Text A", status="success")
        self.tracker.record_segment(1, "Text B", status="failed")

        repr_str = repr(self.tracker)
        self.assertIn("Test Chapter", repr_str)
        self.assertIn("total=2", repr_str)
        self.assertIn("success=1", repr_str)
        self.assertIn("failed=1", repr_str)


class TestValidationReport(unittest.TestCase):
    """Test cases for ValidationReport dataclass"""

    def test_creation(self):
        """Test ValidationReport creation"""
        report = ValidationReport(
            is_valid=True,
            total_segments=5,
            successful_segments=5,
            failed_segments=0,
            missing_segments=[],
            expected_duration=60.0,
            actual_duration=58.5,
            duration_diff_percent=-2.5,
            validation_errors=[],
        )

        self.assertTrue(report.is_valid)
        self.assertEqual(report.total_segments, 5)
        self.assertAlmostEqual(report.duration_diff_percent, -2.5)

    def test_to_dict(self):
        """Test converting report to dictionary"""
        report = ValidationReport(
            is_valid=False,
            total_segments=3,
            successful_segments=2,
            failed_segments=1,
            missing_segments=[2],
            expected_duration=30.0,
            actual_duration=20.0,
            duration_diff_percent=-33.3,
            validation_errors=["Segment 2 failed"],
        )

        report_dict = report.to_dict()
        self.assertIsInstance(report_dict, dict)
        self.assertFalse(report_dict["is_valid"])
        self.assertEqual(report_dict["missing_segments"], [2])
        self.assertEqual(len(report_dict["validation_errors"]), 1)

    def test_save_and_load(self):
        """Test saving and loading ValidationReport"""
        with tempfile.TemporaryDirectory() as tmpdir:
            report = ValidationReport(
                is_valid=True,
                total_segments=10,
                successful_segments=10,
                failed_segments=0,
                missing_segments=[],
                expected_duration=120.0,
                actual_duration=118.0,
                duration_diff_percent=-1.67,
                validation_errors=[],
            )

            # Save to file
            report_path = Path(tmpdir) / "validation.json"
            report.save(report_path)

            # Verify file exists
            self.assertTrue(report_path.exists())

            # Load from file
            loaded_report = ValidationReport.load(report_path)

            # Verify data matches
            self.assertTrue(loaded_report.is_valid)
            self.assertEqual(loaded_report.total_segments, 10)
            self.assertEqual(loaded_report.successful_segments, 10)
            self.assertAlmostEqual(loaded_report.expected_duration, 120.0)
            self.assertAlmostEqual(loaded_report.actual_duration, 118.0)


if __name__ == "__main__":
    unittest.main()
