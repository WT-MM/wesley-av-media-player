#include "qt/render_lifecycle.hpp"

#include <cstdlib>
#include <iostream>

namespace {

int failures = 0;

void expect(bool condition, const char *message) {
  if (condition)
    return;
  std::cerr << "FAIL: " << message << '\n';
  ++failures;
}

}  // namespace

int main() {
  using wam::qt::RenderLifecycle;
  using wam::qt::RenderPhase;
  using wam::qt::RenderTicket;

  RenderLifecycle lifecycle;
  const RenderTicket initial = lifecycle.snapshot();
  expect(RenderLifecycle::phase(initial) == RenderPhase::Empty,
         "the initial phase is Empty");
  expect(RenderLifecycle::generation(initial) == 1,
         "the initial generation is one");
  expect(!lifecycle.readyTicket(), "the initial generation is not ready");
  expect(!lifecycle.validatesReady(initial),
         "an Empty ticket cannot validate as Ready");
  expect(!lifecycle.validatesFailed(initial),
         "an Empty ticket cannot validate as Failed");

  const auto first_creating = lifecycle.beginCreation();
  expect(first_creating.has_value(),
         "the first create attempt acquires the Empty generation");
  if (!first_creating)
    return EXIT_FAILURE;
  expect(RenderLifecycle::phase(*first_creating) == RenderPhase::Creating,
         "beginCreation transitions to Creating");
  expect(RenderLifecycle::generation(*first_creating) ==
             RenderLifecycle::generation(initial),
         "beginCreation preserves the generation");
  expect(lifecycle.snapshot() == *first_creating,
         "the Creating ticket is the current ticket");
  expect(!lifecycle.beginCreation(),
         "only one creation attempt can own a generation");

  const auto first_ready = lifecycle.completeCreation(*first_creating, true);
  expect(first_ready.has_value(), "the current creation can become Ready");
  if (!first_ready)
    return EXIT_FAILURE;
  expect(RenderLifecycle::phase(*first_ready) == RenderPhase::Ready,
         "successful creation transitions to Ready");
  expect(RenderLifecycle::generation(*first_ready) ==
             RenderLifecycle::generation(*first_creating),
         "successful creation preserves the generation");
  expect(lifecycle.readyTicket() == first_ready,
         "readyTicket returns the exact current Ready ticket");
  expect(lifecycle.validatesReady(*first_ready),
         "the exact current Ready ticket validates");
  expect(!lifecycle.validatesReady(*first_creating),
         "the Creating ticket no longer validates as Ready");
  expect(!lifecycle.completeCreation(*first_creating, true),
         "a creation ticket can complete only once");

  const auto invalidated_ready = lifecycle.invalidate();
  expect(invalidated_ready == first_ready,
         "invalidate reports the exact ticket it retired");
  const RenderTicket after_invalidate = lifecycle.snapshot();
  expect(RenderLifecycle::phase(after_invalidate) == RenderPhase::Empty,
         "invalidate returns the lifecycle to Empty");
  expect(RenderLifecycle::generation(after_invalidate) ==
             RenderLifecycle::generation(*first_ready) + 1,
         "invalidate advances the generation exactly once");
  expect(!lifecycle.readyTicket(),
         "an invalidated generation has no Ready ticket");
  expect(!lifecycle.validatesReady(*first_ready),
         "an invalidated Ready ticket is stale");
  expect(!lifecycle.invalidate(),
         "repeated invalidate is idempotent while Empty");
  expect(lifecycle.snapshot() == after_invalidate,
         "repeated invalidate does not advance the generation");

  const auto failing_creation = lifecycle.beginCreation();
  expect(failing_creation.has_value(),
         "the next Empty generation can begin creation");
  if (!failing_creation)
    return EXIT_FAILURE;
  expect(RenderLifecycle::generation(*failing_creation) ==
             RenderLifecycle::generation(after_invalidate),
         "the retry creation uses the current generation");
  const auto failed = lifecycle.completeCreation(*failing_creation, false);
  expect(failed.has_value(), "the current creation can become Failed");
  if (!failed)
    return EXIT_FAILURE;
  expect(RenderLifecycle::phase(*failed) == RenderPhase::Failed,
         "failed creation transitions to Failed");
  expect(RenderLifecycle::generation(*failed) ==
             RenderLifecycle::generation(*failing_creation),
         "failed creation preserves the generation");
  expect(lifecycle.validatesFailed(*failed),
         "the exact current Failed ticket validates");
  expect(!lifecycle.readyTicket(), "a Failed generation is not Ready");

  for (int attempt = 0; attempt < 100; ++attempt) {
    expect(!lifecycle.beginCreation(),
           "a Failed generation latches across render attempts");
    expect(lifecycle.snapshot() == *failed,
           "a latched failure keeps the exact ticket");
  }

  expect(lifecycle.retryFailure(),
         "an explicit retry advances a Failed generation");
  const RenderTicket after_retry = lifecycle.snapshot();
  expect(RenderLifecycle::phase(after_retry) == RenderPhase::Empty,
         "retryFailure returns the lifecycle to Empty");
  expect(RenderLifecycle::generation(after_retry) ==
             RenderLifecycle::generation(*failed) + 1,
         "retryFailure advances the generation exactly once");
  expect(!lifecycle.validatesFailed(*failed),
         "the retired Failed ticket is stale");
  expect(!lifecycle.retryFailure(),
         "retryFailure is idempotent after leaving Failed");
  expect(lifecycle.snapshot() == after_retry,
         "repeated retryFailure does not advance the generation");

  const auto retried_creation = lifecycle.beginCreation();
  expect(retried_creation.has_value(),
         "an explicitly retried generation may begin creation");
  if (retried_creation) {
    expect(RenderLifecycle::generation(*retried_creation) ==
               RenderLifecycle::generation(after_retry),
           "creation after retry uses the advanced generation");
    expect(!lifecycle.completeCreation(*failing_creation, true),
           "a stale creation ticket cannot complete a newer generation");
    expect(lifecycle.snapshot() == *retried_creation,
           "a stale completion cannot mutate the current generation");
  }

  if (failures == 0)
    std::cout << "render lifecycle tests passed\n";
  return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
