#!/bin/zsh
# Actual AsyncSubsystem lifecycle/reset owner. Hardware is mocked; unused I/O aborts.
set -euo pipefail
cd "${0:A:h}/../.."
[[ $# == 2 ]] || { print -u2 'Usage: run-async-reset-recovery-regression.zsh pinned-googletest output-directory'; exit 2; }
gtest=${1:A}
output=${2:A}
[[ $(git -C "$gtest" rev-parse HEAD) == 6910c9d9165801d8827d628cb72eb7ea9dd538c5 ]]
mkdir -p "$output"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
flags=(-std=c++23 -DASFW_HOST_TEST -g -fno-access-control -fblocks -ffunction-sections -fdata-sections -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -Wno-character-conversion -Wno-deprecated-copy -Itests/mocks -Itests/support -I. -IASFWDriver -IASFWDriver/Async -IASFWDriver/Hardware -IASFWDriver/Testing -Idocs -IAppleHeaders -I"$gtest/googletest/include" -I"$gtest/googletest")
xcrun clang++ $flags tests/async/AsyncResetRecoveryTests.cpp \
 ASFWDriver/Async/AsyncSubsystem{Lifecycle,BusReset,Diagnostics,Interrupts}.cpp \
 ASFWDriver/Async/Rx/{RxPath,ARPacketParser,PacketRouter}.cpp \
 ASFWDriver/Async/Engine/ContextManager.cpp ASFWDriver/Async/DMAMemoryImpl.cpp \
 ASFWDriver/Async/Tx/{DescriptorBuilder,Submitter,ResponseSender}.cpp \
 ASFWDriver/Async/Core/{Transaction,TransactionManager}.cpp \
 ASFWDriver/Async/Track/{LabelAllocator,PayloadRegistry}.cpp \
 ASFWDriver/Bus/GenerationTracker.cpp ASFWDriver/Debug/BusResetPacketCapture.cpp ASFWDriver/Debug/AsyncTraceCapture.cpp \
 ASFWDriver/Shared/Rings/{DescriptorRing,BufferRing}.cpp \
 ASFWDriver/Shared/Memory/{DMAMemoryManager,PayloadHandle}.cpp \
 ASFWDriver/Common/BarrierUtils.cpp tests/support/AsyncRecoveryOffPathStub.cpp \
 tests/support/{HardwareInterfaceStub,LoggingStubs,SanitizerDefaults}.cpp ASFWDriver/Logging/LogRing.cpp \
 "$gtest/googletest/src/gtest-all.cc" "$gtest/googletest/src/gtest_main.cc" -pthread -Wl,-dead_strip -o "$output/AsyncResetRecoveryTests"
ASAN_OPTIONS=abort_on_error=1:halt_on_error=1:detect_stack_use_after_return=1 UBSAN_OPTIONS=halt_on_error=1:print_stacktrace=1 "$output/AsyncResetRecoveryTests"
