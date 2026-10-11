// Modified by Rewind Digital for rewindDV.
#pragma once

#include <cstdint>

namespace ASFW::Async {

// A release proof for ONE retired runtime, never permission to reuse its labels.
// IEEE 1394-2008 6.2.5.3 and AV/C General 4.2 6.2(7) retire remote work at
// reset. OHCI 1.1 5.7 (HCControl.softReset) separately flushes local FIFOs.
// Neither an AR-request marker nor stopped DMA proves the latter boundary.
// Owned by the serialized controller queue; submissions stay closed throughout.
class ResetRecoveryFence {
public:
    void ObserveReset() noexcept {
        ready_ = retired_ = false;
        generation_ = UINT32_MAX;
        if (epoch_ == UINT64_MAX) exhausted_ = true;
        else ++epoch_;
        observed_ = !exhausted_;
    }

    void AcceptReset(uint32_t generation, bool uncertain) noexcept {
        // Duplicate accepted Self-ID while admission never reopened does not
        // erase the same pending proof. A completed normal cycle cannot create it.
        if (!observed_ && Ready() && uncertain && generation == generation_) return;
        ready_ = observed_ && !exhausted_ && generation != UINT32_MAX && uncertain;
        generation_ = ready_ ? generation : UINT32_MAX;
        observed_ = false;
        retired_ = false;
    }

    [[nodiscard]] bool Ready() const noexcept { return ready_ && !retired_; }
    [[nodiscard]] uint64_t Epoch() const noexcept { return epoch_; }
    [[nodiscard]] uint32_t Generation() const noexcept { return generation_; }
    [[nodiscard]] bool Retired() const noexcept { return retired_; }

    template<class FlushController>
    bool Retire(uint64_t expectedEpoch, bool dmaRetired, bool callbacksRetired,
                FlushController&& flushController) {
        if (!Ready() || expectedEpoch != epoch_ || !dmaRetired || !callbacksRetired)
            return false;
        if (!flushController()) return false;
        // A newer reset or invalidation cannot inherit an earlier receipt.
        if (!Ready() || expectedEpoch != epoch_) return false;
        retired_ = true;
        return true;
    }

private:
    uint64_t epoch_{0};
    uint32_t generation_{UINT32_MAX};
    bool observed_{false};
    bool ready_{false};
    bool retired_{false};
    bool exhausted_{false};
};

// Service-owned, so replacing the runtime cannot reset the retry budget.
// Delays only bound recovery activity; elapsed time is NEVER a wire-fence proof.
class ResetRecoveryBudget {
public:
    bool Admit(uint64_t nowUsec) noexcept {
        if (attempts_ && (nowUsec < lastAttempt_ || nowUsec - lastAttempt_ < 5'000'000))
            return false;
        if (!attempts_ || nowUsec - windowStart_ >= 60'000'000) {
            windowStart_ = nowUsec;
            attempts_ = 0;
        }
        if (attempts_ >= 3) return false;
        ++attempts_;
        lastAttempt_ = nowUsec;
        return true;
    }
private:
    uint64_t windowStart_{0};
    uint64_t lastAttempt_{0};
    unsigned attempts_{0};
};

} // namespace ASFW::Async
