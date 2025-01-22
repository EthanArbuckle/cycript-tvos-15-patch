//
//  symbolication.c
//
//  Created by Ethan Arbuckle
//

#include <dlfcn.h>
#include "symbolication.h"

static struct {
    CSSymbolicatorRef (*CreateWithTaskFlagsAndNotification)(task_t, uint32_t, void *);
    CSSymbolOwnerRef (*GetSymbolOwnerWithAddressAtTime)(CSSymbolicatorRef, vm_address_t, uint64_t);
    CSSymbolOwnerRef (*GetSymbolOwnerWithNameAtTime)(CSSymbolicatorRef, const char *, uint64_t);
    CSSymbolRef (*GetSymbolWithAddress)(CSSymbolOwnerRef, vm_address_t);
    Boolean (*IsNull)(CSTypeRef);
    const char *(*GetSymbolName)(CSSymbolRef);
    const char *(*GetSymbolOwnerPath)(CSSymbolRef);
    CSRange (*GetSymbolRange)(CSSymbolRef);
    int (*GetSymbolOwnerCountAtTime)(CSSymbolicatorRef, uint64_t);
    int (*ForeachSymbolAtTime)(CSSymbolicatorRef, uint64_t, void (^)(CSSymbolRef));
    void (*Retain)(CSTypeRef);
    void (*Release)(CSTypeRef);
} CS;

#define ASSERT_NOT_NULL(expr) if ((expr) == NULL) { printf("Failed to locate %s\n", #expr); return; }

CSSymbolicatorRef create_symbolicator_with_task(task_t task) {
    init_core_symbolication();
    CSSymbolicatorRef symbolicator = CS.CreateWithTaskFlagsAndNotification(task, 1, NULL);
    CS.Retain(symbolicator);
    return symbolicator;
}

CSSymbolOwnerRef get_symbol_owner(CSSymbolicatorRef symbolicator, uint64_t address) {
    return CS.GetSymbolOwnerWithAddressAtTime(symbolicator, address, 0x80000000u);
}

CSSymbolOwnerRef get_symbol_owner_for_name(CSSymbolicatorRef symbolicator, const char *name) {
    return CS.GetSymbolOwnerWithNameAtTime(symbolicator, name, 0x80000000u);
}

CSSymbolRef get_symbol_at_address(CSSymbolOwnerRef symbol_owner, uint64_t address) {
    return CS.GetSymbolWithAddress(symbol_owner, address);
}

CSRange get_range_for_symbol(CSSymbolRef symbol) {
    return CS.GetSymbolRange(symbol);
}

const char *get_image_path_for_symbol_owner(CSSymbolOwnerRef symbol_owner) {
    return CS.GetSymbolOwnerPath(symbol_owner);
}

const char *get_name_for_symbol(CSSymbolRef symbol) {
    return CS.GetSymbolName(symbol);
}

const char *get_name_for_symbol_at_address(CSSymbolicatorRef symbolicator, uint64_t address) {
    CSSymbolOwnerRef symbol_owner = get_symbol_owner(symbolicator, address);
    if (CS.IsNull(symbol_owner)) {
        return NULL;
    }
    
    CSSymbolRef symbol = get_symbol_at_address(symbol_owner, address);
    if (CS.IsNull(symbol)) {
        return NULL;
    }
    
    return get_name_for_symbol(symbol);
}

bool cs_isnull(CSTypeRef ref) {
    return CS.IsNull(ref);
}

int get_symbol_owner_count(CSSymbolicatorRef symbolicator) {
    return CS.GetSymbolOwnerCountAtTime(symbolicator, 0x80000000u);
}

void foreach_symbol(CSSymbolicatorRef symbolicator, void (^handler)(CSSymbolRef)) {
    CS.ForeachSymbolAtTime(symbolicator, 0x80000000u, ^(CSSymbolRef symbol) {
        handler(symbol);
    });
}

kern_return_t init_core_symbolication(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *core_symbolication_handle = dlopen("/System/Library/PrivateFrameworks/CoreSymbolication.framework/CoreSymbolication", RTLD_LAZY);
        ASSERT_NOT_NULL(core_symbolication_handle);
        
        CS.CreateWithTaskFlagsAndNotification = dlsym(core_symbolication_handle, "CSSymbolicatorCreateWithTaskFlagsAndNotification");
        CS.GetSymbolOwnerWithAddressAtTime = dlsym(core_symbolication_handle, "CSSymbolicatorGetSymbolOwnerWithAddressAtTime");
        CS.GetSymbolOwnerWithNameAtTime = dlsym(core_symbolication_handle, "CSSymbolicatorGetSymbolOwnerWithNameAtTime");
        CS.GetSymbolWithAddress = dlsym(core_symbolication_handle, "CSSymbolOwnerGetSymbolWithAddress");
        CS.IsNull = dlsym(core_symbolication_handle, "CSIsNull");
        CS.GetSymbolName = dlsym(core_symbolication_handle, "CSSymbolGetName");
        CS.GetSymbolOwnerPath = dlsym(core_symbolication_handle, "CSSymbolOwnerGetPath");
        CS.GetSymbolRange = dlsym(core_symbolication_handle, "CSSymbolGetRange");
        CS.GetSymbolOwnerCountAtTime = dlsym(core_symbolication_handle, "CSSymbolicatorGetSymbolOwnerCountAtTime");
        CS.ForeachSymbolAtTime = dlsym(core_symbolication_handle, "CSSymbolicatorForeachSymbolAtTime");
        CS.Retain = dlsym(core_symbolication_handle, "CSRetain");
        CS.Release = dlsym(core_symbolication_handle, "CSRelease");
        
        ASSERT_NOT_NULL(CS.CreateWithTaskFlagsAndNotification);
        ASSERT_NOT_NULL(CS.GetSymbolOwnerWithAddressAtTime);
        ASSERT_NOT_NULL(CS.GetSymbolOwnerWithNameAtTime);
        ASSERT_NOT_NULL(CS.GetSymbolWithAddress);
        ASSERT_NOT_NULL(CS.IsNull);
        ASSERT_NOT_NULL(CS.GetSymbolName);
        ASSERT_NOT_NULL(CS.GetSymbolOwnerPath);
        ASSERT_NOT_NULL(CS.GetSymbolRange);
        ASSERT_NOT_NULL(CS.GetSymbolOwnerCountAtTime);
        ASSERT_NOT_NULL(CS.ForeachSymbolAtTime);
        ASSERT_NOT_NULL(CS.Retain);
        ASSERT_NOT_NULL(CS.Release);
    });
    
    return KERN_SUCCESS;
}
