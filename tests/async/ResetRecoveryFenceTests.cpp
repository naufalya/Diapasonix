// Modified by Rewind Digital for rewindDV; offline recovery proof regressions.
#include <gtest/gtest.h>
#include "ASFWDriver/Async/ResetRecoveryFence.hpp"

using ASFW::Async::ResetRecoveryFence;
using ASFW::Async::ResetRecoveryBudget;

TEST(ResetRecoveryFence, RequiresObservedResetAndValidAcceptedGeneration) {
    ResetRecoveryFence fence;
    fence.AcceptReset(7, true);
    EXPECT_FALSE(fence.Ready());
    fence.ObserveReset();
    fence.AcceptReset(UINT32_MAX, true);
    EXPECT_FALSE(fence.Ready());
    fence.ObserveReset();
    fence.AcceptReset(263, true);
    EXPECT_TRUE(fence.Ready());
    EXPECT_EQ(fence.Generation(), 263u);
}

TEST(ResetRecoveryFence, EveryRetirementGateMustPassBeforeFIFOFlush) {
    for (bool dma : {false, true}) for (bool native : {false, true}) {
        ResetRecoveryFence fence;
        fence.ObserveReset(); fence.AcceptReset(7, true);
        unsigned flushes = 0;
        EXPECT_EQ(fence.Retire(fence.Epoch(), dma, native, [&] { ++flushes; return true; }),
                  dma && native);
        EXPECT_EQ(flushes, unsigned(dma && native));
        EXPECT_EQ(fence.Retired(), dma && native);
    }
}

TEST(ResetRecoveryFence, FailedControllerFlushCannotReleaseRuntime) {
    ResetRecoveryFence fence;
    fence.ObserveReset(); fence.AcceptReset(7, true);
    EXPECT_FALSE(fence.Retire(fence.Epoch(), true, true, [] { return false; }));
    EXPECT_FALSE(fence.Retired());
}

TEST(ResetRecoveryFence, ReopenedNormalTrafficCannotUseHistoricalSelfID) {
    ResetRecoveryFence fence;
    fence.ObserveReset(); fence.AcceptReset(7, false);
    fence.AcceptReset(7, true); // later timeout without another physical reset
    EXPECT_FALSE(fence.Ready());
    EXPECT_FALSE(fence.Retire(fence.Epoch(), true, true, [] { return true; }));
}

TEST(ResetRecoveryFence, WrappedWireGenerationCannotReuseOldProof) {
    ResetRecoveryFence fence;
    fence.ObserveReset(); fence.AcceptReset(7, true);
    const auto oldEpoch = fence.Epoch();
    fence.ObserveReset(); fence.AcceptReset(263, true);
    EXPECT_FALSE(fence.Retire(oldEpoch, true, true, [] { ADD_FAILURE(); return true; }));
    EXPECT_TRUE(fence.Retire(fence.Epoch(), true, true, [] { return true; }));
    EXPECT_FALSE(fence.Ready());
    EXPECT_FALSE(fence.Retire(fence.Epoch(), true, true, [] { ADD_FAILURE(); return true; }));
}

TEST(ResetRecoveryFence, ResetRacingControllerFlushInvalidatesReceipt) {
    ResetRecoveryFence fence;
    fence.ObserveReset(); fence.AcceptReset(7, true);
    EXPECT_FALSE(fence.Retire(fence.Epoch(), true, true, [&] {
        fence.ObserveReset(); fence.AcceptReset(263, true); return true;
    }));
    EXPECT_FALSE(fence.Retired());
}

TEST(ResetRecoveryBudget, RebuildCannotEraseBoundedServiceAttemptBudget) {
    ResetRecoveryBudget budget;
    EXPECT_TRUE(budget.Admit(100));
    EXPECT_FALSE(budget.Admit(100));
    EXPECT_FALSE(budget.Admit(99));
    EXPECT_FALSE(budget.Admit(5'000'099));
    EXPECT_TRUE(budget.Admit(5'000'100));
    EXPECT_TRUE(budget.Admit(10'000'100));
    EXPECT_FALSE(budget.Admit(15'000'100));
    EXPECT_FALSE(budget.Admit(60'000'099));
    EXPECT_TRUE(budget.Admit(60'000'100)); // cooldown never permanently latches admission
}

TEST(ResetRecoveryFence, DuplicateSelfIDPreservesStillClosedRecoveryBoundary) {
    ResetRecoveryFence fence;
    fence.ObserveReset(); fence.AcceptReset(7, true);
    const auto epoch = fence.Epoch();
    fence.AcceptReset(7, true);
    EXPECT_TRUE(fence.Ready());
    EXPECT_EQ(fence.Epoch(), epoch);
    EXPECT_TRUE(fence.Retire(epoch, true, true, [] { return true; }));
}
