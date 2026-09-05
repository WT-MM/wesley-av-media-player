#pragma once

#include <iostream>

// The failure-counting expectation shared by the self-contained test mains: a
// failed expectation is printed and counted, never fatal, so one run reports
// every failing expectation and main() returns non-zero when failures != 0.
inline int failures = 0;

inline void expect(bool condition, const char* message) {
  if (!condition) {
    std::cerr << "FAIL: " << message << '\n';
    ++failures;
  }
}
