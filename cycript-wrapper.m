//
//  cycript-wrapper.m
//  cycript-patcher
//
//  Created by user on 5/27/23.
//

#import <Foundation/Foundation.h>
#import <mach-o/dyld_images.h>
#import <mach-o/getsect.h>
#import <mach-o/dyld.h>
#import <sys/stat.h>
#import <dlfcn.h>
#import <spawn.h>

extern kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address, mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_protect(vm_map_t target_task, mach_vm_address_t address, mach_vm_size_t size, boolean_t set_maximum, vm_prot_t new_protection);
extern kern_return_t mach_vm_write(vm_map_t target_task, mach_vm_address_t address, vm_offset_t data, mach_msg_type_number_t dataCnt);

static void inject_dylib_into_task(task_t target_task, const char *dylib_path) {

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

int main(void) {
    
    const char *cycript_server_dylib_path = "/tmp/cycript-server-host.dylib";
    unlink(cycript_server_dylib_path);
    
    const struct section_64 *sect = getsectbyname("__CONST", "__server_dylib");
    if (sect == NULL) {
        return KERN_FAILURE;
    }
    
    int fd = open(cycript_server_dylib_path, O_RDWR | O_CREAT | O_TRUNC);
    if (fd < 1) {
        return KERN_FAILURE;
    }
    
    size_t bytes_written = write(fd, (void *)sect->addr + _dyld_get_image_vmaddr_slide(0), sect->size);
    chown(cycript_server_dylib_path, 501, 501);
    chmod(cycript_server_dylib_path, 777);
    close(fd);
    
    if (bytes_written != sect->size) {
        NSLog(@"error writing server host dylib to %s", cycript_server_dylib_path);
        return KERN_FAILURE;
    }
    
    pid_t pid = 1065;
    
    task_t target_task;
    if (task_for_pid(mach_task_self(), pid, &target_task) != KERN_SUCCESS) {
        printf("failed to get task for pid %d\n", (int)pid);
        return KERN_FAILURE;
    }
    
    inject_dylib_into_task(target_task, cycript_server_dylib_path);

    NSString *serviceName = [NSString stringWithFormat:@"com.ethanarbuckle.cycript-wrapper.%d", pid];
    CFMessagePortRef port = NULL;
    for (int attempt = 0; attempt < 5; attempt++) {
        port = CFMessagePortCreateRemote(kCFAllocatorDefault, (CFStringRef)serviceName);
        if (port && CFMessagePortIsValid(port)) {
            NSLog(@"got valid cycript server port: %@", CFMessagePortGetName(port));
            break;
        }
        else {
            NSLog(@"invalid cycript server port on attempt %d", attempt);
            sleep(1);
        }
    }
    
    if (port == NULL || !CFMessagePortIsValid(port)) {
        return KERN_FAILURE;
    }
    
    CFDataRef server_port_data = NULL;
    if (CFMessagePortSendRequest(port, 0, NULL, 0, 5, kCFRunLoopDefaultMode, &server_port_data) != kCFMessagePortSuccess) {
        NSLog(@"Failed to send message to the target process");
        return KERN_FAILURE;
    }
    
    if (server_port_data == NULL) {
        NSLog(@"sent a message to the remote process but didn't get a response back");
        return KERN_FAILURE;
    }
    
    int cycript_server_port = -1;
    [(__bridge NSData *)server_port_data getBytes:&cycript_server_port length:sizeof(cycript_server_port)];
    
    NSLog(@"received cycript server port from target process: %d", cycript_server_port);

    char *host_and_port = malloc(20);
    sprintf(host_and_port, "127.0.0.1:%d", cycript_server_port);

    pid_t cycript_pid;
    char *argv[] = { "/fs/jb/usr/bin/cycript", "-r", host_and_port, NULL };
    posix_spawn(&cycript_pid, "/fs/jb/usr/bin/cycript", NULL, NULL, argv, NULL);
    
    int exit_code;
    waitpid(cycript_pid, &exit_code, 0);
    
    free(host_and_port);
    return exit_code;
}
