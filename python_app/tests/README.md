# EbookReader Test Suite

This directory contains comprehensive unit tests for the EbookReader project, achieving **99% code coverage** for the main ebook_reader.py module.

## Test Structure

### Test Files

- **`test_text_processor.py`** - Tests for TextProcessor class (27 tests)
  - HTML to plain text conversion
  - Heading extraction
  - Title extraction from text
  - Edge cases and error handling

- **`test_epub_parser.py`** - Tests for EpubParser class (20 tests)
  - EPUB file parsing
  - OPF metadata extraction
  - Chapter extraction
  - Error handling and edge cases

- **`test_pdf_parser.py`** - Tests for PdfParser class (12 tests)  
  - PDF file parsing
  - Page extraction as chapters
  - Metadata handling
  - Error scenarios

- **`test_ebook_reader.py`** - Tests for main EbookReader class (22 tests)
  - File loading and initialization
  - Property access
  - Chapter structure methods
  - Factory function testing

- **`test_data_classes.py`** - Tests for data classes and constants (20 tests)
  - Chapter and Book dataclasses
  - Module constants and regex patterns
  - Import behavior

### Running Tests

#### Basic Test Run
```bash
cd tests
python3 run_tests.py
```

#### With Coverage Report
```bash
cd tests  
python3 run_tests.py --coverage
```

#### Individual Test Files
```bash
python3 -m unittest test_text_processor.py
python3 -m unittest test_epub_parser.py
python3 -m unittest test_pdf_parser.py
python3 -m unittest test_ebook_reader.py  
python3 -m unittest test_data_classes.py
```

## Coverage Results

**Total: 101 tests - All passing ✅**

```
Name                     Stmts   Miss  Cover   Missing
----------------------------------------------------
src/ebook_reader.py       198      2    99%   20-21
----------------------------------------------------
TOTAL                     198      2    99%
```

The only uncovered lines are the pypdf import exception handling (lines 20-21), which is expected since pypdf may or may not be available.

## Test Features

### Comprehensive Mocking
- Mock EPUB files created with zipfile
- Mock PDF readers using unittest.mock
- Temporary file handling for realistic tests

### Edge Case Coverage
- Empty inputs and None handling
- File not found scenarios  
- Invalid file formats
- Extraction errors
- Encoding issues (UTF-8 vs Latin-1)

### Property Testing
- Data class equality and representation
- Regex pattern validation
- Constants and configuration validation

### Integration Testing  
- End-to-end file loading
- Parser factory selection
- Backward compatibility methods

## Test Data

Tests use dynamically generated mock data:
- Mock EPUB files with proper container.xml and OPF structure
- Mock PDF objects with configurable pages and metadata  
- Various HTML content samples for text processing
- Edge case inputs (empty, None, malformed data)

## Best Practices Followed

1. **Isolation** - Each test is independent with proper setup/teardown
2. **Naming** - Clear, descriptive test method names
3. **Coverage** - Tests cover both happy path and error scenarios  
4. **Mocking** - External dependencies mocked appropriately
5. **Assertions** - Specific assertions with clear error messages
6. **Documentation** - Each test has descriptive docstrings

## Continuous Testing

The test suite is designed to:
- Run quickly (< 1 second total)
- Provide clear failure messages
- Support coverage reporting
- Work across different environments
- Validate all public API methods

This comprehensive test suite ensures the EbookReader codebase is robust, maintainable, and reliable.