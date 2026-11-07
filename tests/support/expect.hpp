#pragma once

#include <cstdlib>
#include <iostream>
#include <string>

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

inline void expect(bool condition, const std::string& message) {
  expect(condition, message.c_str());
}

// Fatal form, only for preconditions where continuing would crash or hang
// (a null result about to be dereferenced, a fixture that failed to open).
[[noreturn]] inline void fail(const char* message) {
  std::cerr << "FAIL: " << message << '\n';
  std::_Exit(1);
}

inline void require(bool condition, const char* message) {
  if (!condition) {
    fail(message);
  }
}

inline void require(bool condition, const std::string& message) {
  require(condition, message.c_str());
}

// Expression forms: the message is the source location and the expression.
#define WAM_EXPECT_STRINGIFY_(x) #x
#define WAM_EXPECT_LOCATION_(line) __FILE__ ":" WAM_EXPECT_STRINGIFY_(line)
#define EXPECT(x) expect(static_cast<bool>(x), WAM_EXPECT_LOCATION_(__LINE__) ": " #x)
#define REQUIRE(x) require(static_cast<bool>(x), WAM_EXPECT_LOCATION_(__LINE__) ": " #x)
