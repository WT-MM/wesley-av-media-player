#pragma once
namespace wam::media::avcodec {
class RuntimeLease final {
public:
  RuntimeLease() = default;
  ~RuntimeLease();
  RuntimeLease(const RuntimeLease&) = delete;
  RuntimeLease& operator=(const RuntimeLease&) = delete;
  [[nodiscard]] const char* acquire() noexcept;
  void release() noexcept;
private:
  bool held_{};
};
[[nodiscard]] const char* runtimeFailure() noexcept;
}
