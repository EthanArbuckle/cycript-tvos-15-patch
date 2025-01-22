//
//  symbolication.h
//  cli
//
//  Created by Ethan Arbuckle on 1/17/25.
//

#ifndef symbolication_h
#define symbolication_h

#include <CoreFoundation/CoreFoundation.h>

struct sCSTypeRef {
    void *csCppData;
    void *csCppObj;
};

typedef struct sCSTypeRef CSTypeRef;
typedef CSTypeRef CSSymbolicatorRef;
typedef CSTypeRef CSSymbolOwnerRef;
typedef CSTypeRef CSSymbolRef;

struct sCSRange {
    unsigned long long location;
    unsigned long long length;
};
typedef struct sCSRange CSRange;

CSSymbolicatorRef create_symbolicator_with_task(task_t task);
CSSymbolOwnerRef get_symbol_owner(CSSymbolicatorRef symbolicator, uint64_t address);
CSSymbolOwnerRef get_symbol_owner_for_name(CSSymbolicatorRef symbolicator, const char *name);
CSSymbolRef get_symbol_at_address(CSSymbolOwnerRef symbol_owner, uint64_t address);
CSRange get_range_for_symbol(CSSymbolRef symbol);
const char *get_image_path_for_symbol_owner(CSSymbolOwnerRef symbol_owner);
const char *get_name_for_symbol(CSSymbolRef symbol);
const char *get_name_for_symbol_at_address(CSSymbolicatorRef symbolicator, uint64_t address);
void foreach_symbol(CSSymbolicatorRef symbolicator, void (^handler)(CSSymbolRef));
int get_symbol_owner_count(CSSymbolicatorRef symbolicator);
bool cs_isnull(CSTypeRef ref);

kern_return_t init_core_symbolication(void);

#endif /* symbolication_h */
