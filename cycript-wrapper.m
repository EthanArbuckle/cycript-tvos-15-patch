//
//  cycript-wrapper.m
//  cycript-patcher
//
//  Created by user on 5/27/23.
//

#import <Foundation/Foundation.h>
#import <mach-o/dyld_images.h>
#import <mach-o/nlist.h>
#import <mach-o/dyld.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <spawn.h>

#define VM_READ(task, dst, len) ({ vm_offset_t buff = 0; mach_msg_type_number_t count = (mach_msg_type_number_t)*len; vm_read(task, dst, *len, &buff, &count); buff; })
extern kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_protect(vm_map_t target_task, mach_vm_address_t address, mach_vm_size_t size, boolean_t set_maximum, vm_prot_t new_protection);
extern kern_return_t mach_vm_write(vm_map_t target_task, mach_vm_address_t address, vm_offset_t data, mach_msg_type_number_t dataCnt);


static const struct mach_header *get_remote_cycript_mach_header(task_t target_task) {
    
    task_dyld_info_data_t dyld_info;
    uint32_t count = TASK_DYLD_INFO_COUNT;
    task_info(target_task, TASK_DYLD_INFO, (task_info_t)&dyld_info, &count);
    
    mach_msg_type_number_t imageInfosSize = sizeof(struct dyld_all_image_infos);
    struct dyld_all_image_infos *imageInfos = (struct dyld_all_image_infos *)VM_READ(target_task, dyld_info.all_image_info_addr, &imageInfosSize);
    if (imageInfos == NULL) {
        return NULL;
    }
    
    mach_msg_type_number_t infoArraySize = sizeof(struct dyld_image_info)*imageInfos->infoArrayCount;
    struct dyld_image_info *infoArray = (struct dyld_image_info *)VM_READ(target_task, (mach_vm_address_t)imageInfos->infoArray, &infoArraySize);
    if (infoArray == NULL) {
        return NULL;
    }
    
    const struct mach_header *libcycript_mh = NULL;
    for (int i = 0; i < imageInfos->infoArrayCount; i++) {
        
        mach_msg_type_number_t imagePathSize = 512;
        char *image_path = (char *)VM_READ(target_task, (mach_vm_address_t)infoArray[i].imageFilePath, &imagePathSize);
        if (image_path == NULL || strlen(image_path) < 2) {
            continue;
        }
        
        int is_libcycript = strstr(image_path, "libcycript.dylib") != NULL;
        vm_deallocate(mach_task_self(), (vm_address_t)image_path, imagePathSize);
        
        if (is_libcycript) {
            libcycript_mh = infoArray[i].imageLoadAddress;
            break;
        }
    }
    
    vm_deallocate(mach_task_self(), (vm_address_t)infoArray, infoArraySize);
    vm_deallocate(mach_task_self(), (vm_address_t)imageInfos, imageInfosSize);
    
    return libcycript_mh;
}

void *get_remote_symbol(task_t target_task, vm_address_t base_address, const char *target_symbol) {
    
    size_t mh_size = sizeof(struct mach_header_64);
    struct mach_header_64 *mh = (struct mach_header_64 *)VM_READ(target_task, base_address, &mh_size);
    vm_address_t current_address = base_address + sizeof(struct mach_header_64);
    vm_address_t end_address = current_address + mh->sizeofcmds;
    
    vm_address_t slide = -123;
    struct segment_command_64 *linkedit_cmd = NULL;
    struct symtab_command *symtab_cmd = NULL;
    
    for (int i = 0; i < mh->ncmds && current_address <= end_address; i++) {
        mach_msg_type_number_t cmd_size = sizeof(struct segment_command_64);
        struct segment_command_64 *cmd = (struct segment_command_64 *)VM_READ(target_task, current_address, &cmd_size);
        
        if (slide == -123) {
            slide = base_address - cmd->vmaddr;
        }
        
        if (cmd->cmd == LC_SEGMENT_64 && strncmp(SEG_LINKEDIT, cmd->segname, 16) == 0) {
            __unused mach_msg_type_number_t size = sizeof(struct segment_command_64);
            linkedit_cmd = (struct segment_command_64 *)VM_READ(target_task, current_address, &size);
        }
        else if (cmd->cmd == LC_SYMTAB) {
            __unused mach_msg_type_number_t size = sizeof(struct symtab_command);
            symtab_cmd = (struct symtab_command *)VM_READ(target_task, current_address, &size);
        }
        
        current_address += cmd->cmdsize;
        
        vm_deallocate(mach_task_self(), (vm_address_t)cmd, cmd_size);
        if (linkedit_cmd != NULL && symtab_cmd != NULL) {
            break;
        }
    }
    
    vm_address_t mh_base = linkedit_cmd->vmaddr + slide - linkedit_cmd->fileoff;
    uint32_t strsize = symtab_cmd->strsize;
    char *string_table = (char *)VM_READ(target_task, mh_base + symtab_cmd->stroff, &strsize);
    
    void *function_ptr = NULL;
    for (uint32_t i = 0; i < symtab_cmd->nsyms; i++) {
        
        vm_address_t entryAddr = mh_base + symtab_cmd->symoff + (sizeof(struct nlist_64) * i);
        mach_msg_type_number_t entry_size = sizeof(struct nlist_64);
        struct nlist_64* entry = (struct nlist_64 *)VM_READ(target_task, entryAddr, &entry_size);
        
        uint32_t off = entry->n_un.n_strx;
        if (off >= symtab_cmd->strsize || off == 0) {
            vm_deallocate(mach_task_self(), (vm_address_t)entry, entry_size);
            continue;
        }
        
        const char *symbol_name = &string_table[off];
        if ((entry->n_type & N_TYPE) != N_SECT || symbol_name[0] == '\x00') {
            vm_deallocate(mach_task_self(), (vm_address_t)entry, entry_size);
            continue;
        }
        
        if (strcmp(symbol_name, target_symbol) == 0) {
            function_ptr = (void *)entry->n_value + slide;
        }
        
        vm_deallocate(mach_task_self(), (vm_address_t)entry, entry_size);
        if (function_ptr != NULL) {
            break;
        }
    }
    
    vm_deallocate(mach_task_self(), (vm_address_t)mh, mh_size);
    vm_deallocate(mach_task_self(), (vm_address_t)linkedit_cmd, sizeof(struct segment_command_64));
    vm_deallocate(mach_task_self(), (vm_address_t)symtab_cmd, sizeof(struct symtab_command));
    vm_deallocate(mach_task_self(), (vm_address_t)string_table, strsize);
    
    return function_ptr;
}

static void inject_cycript_into_task(task_t target_task) {
    
    const char *dylib_path = "/fs/jb/usr/lib/libcycript.dylib";
    
    mach_vm_size_t stack_size = 0x4000;
    mach_port_insert_right(mach_task_self(), target_task, target_task, MACH_MSG_TYPE_COPY_SEND);
    
    mach_vm_address_t remote_stack;
    mach_vm_allocate(target_task, &remote_stack, stack_size, VM_FLAGS_ANYWHERE);
    mach_vm_protect(target_task, remote_stack, stack_size, 1, VM_PROT_READ | VM_PROT_WRITE);
    
    mach_vm_address_t remote_dylib_path_str;
    mach_vm_allocate(target_task, &remote_dylib_path_str, 0x100 + strlen(dylib_path) + 1, VM_FLAGS_ANYWHERE);
    mach_vm_write(target_task, 0x100 + remote_dylib_path_str, (vm_offset_t)dylib_path, (mach_msg_type_number_t)strlen(dylib_path) + 1);
    
    uint64_t *stack = malloc(stack_size);
    size_t sp = (stack_size / 8) - 2;
    
    mach_port_t remote_thread;
    if (thread_create(target_task, &remote_thread) != KERN_SUCCESS) {
        free(stack);
        printf("failed to create remote thread\n");
        return;
    }
    
    mach_vm_write(target_task, remote_stack, (vm_offset_t)stack, (mach_msg_type_number_t)stack_size);
    
    arm_thread_state64_t state = {};
    bzero(&state, sizeof(arm_thread_state64_t));
    
    state.__x[0] = (uint64_t)remote_stack;
    state.__x[2] = (uint64_t)dlsym(RTLD_NEXT, "dlopen");
    state.__x[3] = (uint64_t)(remote_dylib_path_str + 0x100);
    __darwin_arm_thread_state64_set_lr_fptr(state, (void *)0x7171717171717171);
    __darwin_arm_thread_state64_set_pc_fptr(state, dlsym(RTLD_NEXT, "pthread_create_from_mach_thread"));
    __darwin_arm_thread_state64_set_sp(state, (void *)(remote_stack + (sp * sizeof(uint64_t))));
    
    if (thread_set_state(remote_thread, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT) != KERN_SUCCESS) {
        free(stack);
        printf("failed to set remote thread state\n");
        return;
    }
    
    mach_port_t exc_handler;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &exc_handler);
    mach_port_insert_right(mach_task_self(), exc_handler, exc_handler, MACH_MSG_TYPE_MAKE_SEND);
    
    if (thread_set_exception_ports(remote_thread, EXC_MASK_BAD_ACCESS, exc_handler, EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES, ARM_THREAD_STATE64) != KERN_SUCCESS) {
        free(stack);
        printf("failed to set remote exception port\n");
        return;
    }
    thread_resume(remote_thread);
    
    mach_msg_header_t *msg = malloc(0x4000);
    mach_msg(msg, MACH_RCV_MSG | MACH_RCV_LARGE, 0, 0x4000, exc_handler, 0, MACH_PORT_NULL);
    free(msg);
    
    thread_terminate(remote_thread);
    free(stack);
}

static void *get_cycript_server_function_ptr(task_t target_task) {
    
    const struct mach_header *libcycript_handle = get_remote_cycript_mach_header(target_task);
    if (libcycript_handle == NULL) {
        return NULL;
    }
    
    void *_CYListenServer = get_remote_symbol(target_task, (vm_address_t)libcycript_handle, "_CYListenServer");
    return _CYListenServer;
}

static int get_next_available_port(void) {
    int port = 8100;
    int max_port = 65535;
    int sockfd;
    struct sockaddr_in addr;
    
    while (port <= max_port) {
        sockfd = socket(AF_INET, SOCK_STREAM, 0);
        if (sockfd < 0) {
            return -1;
        }
        
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        addr.sin_port = htons(port);
        
        if (bind(sockfd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
            if (errno == EADDRINUSE) {
                port++;
                close(sockfd);
                continue;
            } else {
                return -1;
            }
        }
        
        close(sockfd);
        return port;
    }
    
    return -1;
}

static int start_cycript_server_in_task(task_t target_task, void *remote_server_function) {
    
    int server_port = get_next_available_port();
    if (server_port < 8000) {
        return -1;
    }
    
    mach_vm_size_t stack_size = 0x4000;
    mach_port_insert_right(mach_task_self(), target_task, target_task, MACH_MSG_TYPE_COPY_SEND);
    
    mach_vm_address_t remote_stack;
    mach_vm_allocate(target_task, &remote_stack, stack_size, VM_FLAGS_ANYWHERE);
    mach_vm_protect(target_task, remote_stack, stack_size, 1, VM_PROT_READ | VM_PROT_WRITE);
    
    uint64_t *stack = malloc(stack_size);
    size_t sp = (stack_size / 8) - 2;
    
    mach_port_t remote_thread;
    if (thread_create(target_task, &remote_thread) != KERN_SUCCESS) {
        free(stack);
        printf("failed to create remote thread\n");
        return -1;
    }
    
    mach_vm_write(target_task, remote_stack, (vm_offset_t)stack, (mach_msg_type_number_t)stack_size);
    
    arm_thread_state64_t state = {};
    bzero(&state, sizeof(arm_thread_state64_t));
    
    state.__x[0] = (uint64_t)remote_stack;
    state.__x[2] = (uint64_t)remote_server_function;
    state.__x[3] = (uint64_t)server_port;
    __darwin_arm_thread_state64_set_lr_fptr(state, (void *)0x7171717171717171);
    __darwin_arm_thread_state64_set_pc_fptr(state, dlsym(RTLD_NEXT, "pthread_create_from_mach_thread"));
    __darwin_arm_thread_state64_set_sp(state, (void *)(remote_stack + (sp * sizeof(uint64_t))));
    
    if (thread_set_state(remote_thread, ARM_THREAD_STATE64, (thread_state_t)&state, ARM_THREAD_STATE64_COUNT) != KERN_SUCCESS) {
        free(stack);
        printf("failed to set remote thread state\n");
        return -1;
    }
    
    mach_port_t exc_handler;
    mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &exc_handler);
    mach_port_insert_right(mach_task_self(), exc_handler, exc_handler, MACH_MSG_TYPE_MAKE_SEND);
    
    if (thread_set_exception_ports(remote_thread, EXC_MASK_BAD_ACCESS, exc_handler, EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES, ARM_THREAD_STATE64) != KERN_SUCCESS) {
        free(stack);
        printf("failed to set remote exception port\n");
        return -1;
    }
    thread_resume(remote_thread);
    
    mach_msg_header_t *msg = malloc(0x4000);
    mach_msg(msg, MACH_RCV_MSG | MACH_RCV_LARGE, 0, 0x4000, exc_handler, 0, MACH_PORT_NULL);
    free(msg);
    
    thread_terminate(remote_thread);
    free(stack);
    
    return server_port;
}

int main(void) {
    
    // todo: need to hook cycript and catch the PID it will use. Or, reimplement the "-p $" cli args it supports
    pid_t pid = 33;
    
    task_t target_task;
    if (task_for_pid(mach_task_self(), pid, &target_task) != KERN_SUCCESS) {
        printf("failed to get task for pid %d\n", (int)pid);
        return KERN_FAILURE;
    }
    
    inject_cycript_into_task(target_task);
    
    void *_CYListenServer = NULL;
    for (int i = 0; i < 5; i++) {
        if ((_CYListenServer = get_cycript_server_function_ptr(target_task))) {
            break;
        }
        
        sleep(1);
    }
    
    if (_CYListenServer == NULL) {
        NSLog(@"failed to find CYListenServer in remote task");
        return KERN_FAILURE;
    }
    
    int server_port = start_cycript_server_in_task(target_task, _CYListenServer);
    char *host_and_port = malloc(20);
    sprintf(host_and_port, "127.0.0.1:%d", server_port);
    
    sleep(1);
    
    pid_t cycript_pid;
    char *argv[] = { "/fs/jb/usr/bin/cycript", "-r", host_and_port, NULL };
    posix_spawn(&cycript_pid, "/fs/jb/usr/bin/cycript", NULL, NULL, argv, NULL);
    
    int exit_code;
    waitpid(cycript_pid, &exit_code, 0);
    
    free(host_and_port);
    return KERN_SUCCESS;
}
