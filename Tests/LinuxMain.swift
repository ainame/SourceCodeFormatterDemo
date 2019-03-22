import XCTest

import SourceCodeFormatterTests

var tests = [XCTestCaseEntry]()
tests += SourceCodeFormatterTests.allTests()
XCTMain(tests)