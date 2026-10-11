// Actual AsyncSubsystem reset/Stop/release owner with host MMIO. No deck I/O.
#include <gtest/gtest.h>
#include "ASFWDriver/Async/AsyncSubsystem.hpp"
#include "ASFWDriver/Hardware/HardwareInterface.hpp"
using namespace ASFW;
namespace {
struct RecoveryOwner : testing::Test {
    Driver::HardwareInterface hardware;
    Async::AsyncSubsystem async;
    Shared::NativeCallbackDrain callbacks;
    void SetUp() override {
        async.hardware_ = &hardware;
        async.isRunning_ = true;
        async.acceptingSubmissions_.store(true);
        async.GetGenerationTracker().OnConfirmedBusGeneration(7);
        callbacks.Seal();
        hardware.SetTestSoftResetCompletes(true);
    }
    void Accept() {
        async.OnBusResetObserved();
        async.FenceUncertainResponse();
        async.ConfirmBusGeneration(8);
        async.OnBusResetComplete(8);
    }
};
TEST_F(RecoveryOwner, AcceptedResetKeepsGateClosedUntilWholeOldOwnerRetires) {
    Accept();
    EXPECT_TRUE(async.ResetRecoveryPending());
    EXPECT_TRUE(async.is_bus_reset_in_progress_.load());
    EXPECT_FALSE(async.PrepareTransactionContext());
    EXPECT_FALSE(async.RetireResetWire(hardware, callbacks));
    ASSERT_TRUE(async.Stop());
    EXPECT_FALSE(async.acceptingSubmissions_.load());
    ASSERT_TRUE(async.RetireResetWire(hardware, callbacks));
    EXPECT_TRUE(async.RetiredResetWire());
    EXPECT_TRUE(async.HasUncertainWire()); // no in-place reopening
    EXPECT_FALSE(async.PrepareTransactionContext());
    EXPECT_FALSE(async.RetireResetWire(hardware, callbacks));
}
TEST_F(RecoveryOwner, FailedNativeRetirementNeverWritesReset) {
    Accept(); ASSERT_TRUE(async.Stop());
    Shared::NativeCallbackDrain pending;
    EXPECT_FALSE(async.RetireResetWire(hardware, pending));
    pending.Seal(); pending.Quarantine();
    EXPECT_FALSE(async.RetireResetWire(hardware, pending));
    EXPECT_FALSE(async.RetiredResetWire());
}
TEST_F(RecoveryOwner, FailedDMAOrWrongControllerCannotRetire) {
    Accept(); ASSERT_TRUE(async.Stop());
    async.dmaContextsRetired_ = false;
    EXPECT_FALSE(async.RetireResetWire(hardware, callbacks));
    async.dmaContextsRetired_ = true;
    Driver::HardwareInterface replacement;
    EXPECT_FALSE(async.RetireResetWire(replacement, callbacks));
    EXPECT_FALSE(async.RetiredResetWire());
}
TEST_F(RecoveryOwner, RevokedMMIONeverProducesAlreadyClearFalseProof) {
    Accept(); ASSERT_TRUE(async.Stop());
    hardware.RevokeAndDrain();
    EXPECT_FALSE(async.RetireResetWire(hardware, callbacks));
    EXPECT_FALSE(async.RetiredResetWire());
}
TEST_F(RecoveryOwner, StuckSoftResetNeverReleasesOwner) {
    Accept(); ASSERT_TRUE(async.Stop());
    hardware.SetTestSoftResetCompletes(false);
    EXPECT_FALSE(async.RetireResetWire(hardware, callbacks));
    EXPECT_FALSE(async.RetiredResetWire());
}
TEST_F(RecoveryOwner, MissingObservedResetDoesNotCreateReleaseProof) {
    async.FenceUncertainResponse();
    async.OnBusResetComplete(7);
    EXPECT_FALSE(async.ResetRecoveryPending());
    ASSERT_TRUE(async.Stop());
    EXPECT_FALSE(async.RetireResetWire(hardware, callbacks));
}
TEST_F(RecoveryOwner, MismatchedOrUnconfirmedCompletionCannotAuthorizeRelease) {
    async.OnBusResetObserved();
    async.FenceUncertainResponse();
    async.OnBusResetComplete(8);
    EXPECT_FALSE(async.ResetRecoveryPending());
    EXPECT_TRUE(async.is_bus_reset_in_progress_.load());
    async.ConfirmBusGeneration(8);
    async.OnBusResetComplete(9);
    EXPECT_FALSE(async.ResetRecoveryPending());
    EXPECT_TRUE(async.is_bus_reset_in_progress_.load());
    async.OnBusResetComplete(8);
    EXPECT_TRUE(async.ResetRecoveryPending());
    async.OnBusResetComplete(8);
    EXPECT_TRUE(async.ResetRecoveryPending());
    ASSERT_TRUE(async.Stop());
    EXPECT_TRUE(async.RetireResetWire(hardware, callbacks));
}
TEST_F(RecoveryOwner, AllOnesControllerReadCannotAuthorizeResetReceipt) {
    Accept(); ASSERT_TRUE(async.Stop());
    hardware.SetTestRegister(Driver::Register32::kHCControl, UINT32_MAX);
    EXPECT_FALSE(async.RetireResetWire(hardware, callbacks));
    EXPECT_FALSE(async.RetiredResetWire());
    EXPECT_EQ(hardware.GetTestRegister(Driver::Register32::kHCControl), UINT32_MAX);
}

}
