#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Test runner for all EbookReader tests with coverage reporting
"""

import sys
import unittest
import os
from pathlib import Path

# Add the src directory to the path so we can import our modules
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

def run_all_tests():
    """Run all test suites and return the result"""
    # Discover and run all tests
    loader = unittest.TestLoader()
    start_dir = os.path.dirname(__file__)
    suite = loader.discover(start_dir, pattern='test_*.py')
    
    # Run the tests
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    
    return result

def run_with_coverage():
    """Run tests with coverage reporting"""
    try:
        import coverage
        
        # Start coverage
        cov = coverage.Coverage(source=['src'])
        cov.start()
        
        # Run tests
        result = run_all_tests()
        
        # Stop coverage and generate report
        cov.stop()
        cov.save()
        
        print("\n" + "="*60)
        print("COVERAGE REPORT")
        print("="*60)
        
        # Console report
        cov.report(show_missing=True)
        
        # Generate HTML report
        try:
            cov.html_report(directory='coverage_html')
            print(f"\nHTML coverage report generated in: coverage_html/index.html")
        except Exception as e:
            print(f"Could not generate HTML report: {e}")
        
        return result, cov
        
    except ImportError:
        print("Coverage package not installed. Running tests without coverage.")
        print("To install: pip install coverage")
        return run_all_tests(), None

def main():
    """Main test runner"""
    print("Running EbookReader Test Suite")
    print("="*60)
    
    # Check if we should run with coverage
    use_coverage = '--coverage' in sys.argv or '-c' in sys.argv
    
    if use_coverage:
        result, cov = run_with_coverage()
    else:
        result = run_all_tests()
        cov = None
    
    # Print summary
    print("\n" + "="*60)
    print("TEST SUMMARY")
    print("="*60)
    
    if result.wasSuccessful():
        print(f"✅ All tests passed! ({result.testsRun} tests)")
        exit_code = 0
    else:
        print(f"❌ Tests failed!")
        print(f"   - Tests run: {result.testsRun}")
        print(f"   - Failures: {len(result.failures)}")
        print(f"   - Errors: {len(result.errors)}")
        exit_code = 1
    
    # Print coverage summary if available
    if cov:
        print(f"\nFor detailed coverage report, see: coverage_html/index.html")
    
    return exit_code

if __name__ == '__main__':
    exit_code = main()
    sys.exit(exit_code)