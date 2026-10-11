// Host-only off-path dispatch. Recovery/lifecycle/allocator/MMIO methods are production.
#include "ASFWDriver/Async/AsyncSubsystem.hpp"
#include <cstdlib>
namespace ASFW::Async {
AsyncHandle AsyncSubsystem::Read(const ReadParams&, CompletionCallback) { std::abort(); }
AsyncHandle AsyncSubsystem::ReadWithRetry(const ReadParams&, const RetryPolicy&, CompletionCallback) { std::abort(); }
AsyncHandle AsyncSubsystem::Write(const WriteParams&, CompletionCallback) { std::abort(); }
AsyncHandle AsyncSubsystem::Lock(const LockParams&, uint16_t, CompletionCallback) { std::abort(); }
AsyncHandle AsyncSubsystem::CompareSwap(const CompareSwapParams&, CompareSwapCallback) { std::abort(); }
AsyncHandle AsyncSubsystem::PhyRequest(const PhyParams&, CompletionCallback) { std::abort(); }
bool AsyncSubsystem::Cancel(AsyncHandle) { std::abort(); }
}
