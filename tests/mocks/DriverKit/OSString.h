#pragma once
#include <DriverKit/OSObject.h>
class OSString : public OSObject {
public:
    static OSString* withCString(const char* cString) { return new OSString(); }
    bool isEqualTo(const char*) const { return false; }
    const char* getCStringNoCopy() const { return ""; }
};
