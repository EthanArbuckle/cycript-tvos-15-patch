//
//  cycript-wrapper.m
//  cycript-patcher
//
//  Created by user on 5/27/23.
//

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <spawn.h>
#import "dylib_unpacker.h"
#import "dylib_injector.h"


pid_t pid_from_hint(const char *hint) {
    if (hint == NULL) {
        return -1;
    }
    
    static dispatch_once_t onceToken;
    static void *pidFromHint = NULL;
    dispatch_once(&onceToken, ^{
        void *symbolication_handle = dlopen("/System/Library/PrivateFrameworks/Symbolication.framework/Symbolication", 9);
        if (symbolication_handle) {
            pidFromHint = dlsym(symbolication_handle, "pidFromHint");
        }
    });
    
    if (pidFromHint == NULL) {
        printf("Failed to resolve pidFromHint()\n");
        return -1;
    }
    
    return ((pid_t (*)(NSString *))pidFromHint)([NSString stringWithUTF8String:hint]);
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        printf("Usage: cycript -p <pid/process_name>\n");
        return -1;
    }
    
    const char *hint = NULL;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-p") == 0) {
            hint = argv[i + 1];
            break;
        }
    }
    
    pid_t pid = pid_from_hint(hint);
    if (pid == -1) {
        printf("Failed to get pid from hint\n");
        return -1;
    }
        
    const char *cycript_server_dylib_path = "/tmp/cycript-server-host.dylib";
    if (unpack_dylib_to_path(cycript_server_dylib_path) != KERN_SUCCESS) {
        printf("failed to unpack cycript dylib\n");
        return -1;
    }
    
    printf("Attaching to process %s/%d", hint, pid);
    if (inject_dylib_into_pid(cycript_server_dylib_path, pid) != 0) {
        printf("failed to inject dylib into target task\n");
        return KERN_FAILURE;
    }

    NSString *serviceName = [NSString stringWithFormat:@"com.ethanarbuckle.cycript-wrapper.%d", pid];
    CFMessagePortRef port = NULL;
    for (int attempt = 0; attempt < 5; attempt++) {
        port = CFMessagePortCreateRemote(kCFAllocatorDefault, (CFStringRef)serviceName);
        if (port && CFMessagePortIsValid(port)) {
            break;
        }
        else {
            sleep(1);
        }
    }
    
    if (port == NULL || !CFMessagePortIsValid(port)) {
        printf("Failed to connect to the target process\n");
        return KERN_FAILURE;
    }
    
    CFDataRef server_port_data = NULL;
    if (CFMessagePortSendRequest(port, 0, NULL, 0, 5, kCFRunLoopDefaultMode, &server_port_data) != kCFMessagePortSuccess) {
        printf("Failed to send message to target process\n");
        return KERN_FAILURE;
    }
    
    if (server_port_data == NULL) {
        printf("Process not responding\n");
        return KERN_FAILURE;
    }
    
    int cycript_server_port = -1;
    [(__bridge NSData *)server_port_data getBytes:&cycript_server_port length:sizeof(cycript_server_port)];
    
    char *host_and_port = malloc(20);
    sprintf(host_and_port, "127.0.0.1:%d", cycript_server_port);

    pid_t cycript_pid;
    char *cycript_argv[] = { "/var/jb/usr/bin/cycript", "-r", host_and_port, NULL };
    posix_spawn(&cycript_pid, "/var/jb/usr/bin/cycript-real", NULL, NULL, cycript_argv, NULL);
    
    int exit_code;
    waitpid(cycript_pid, &exit_code, 0);
    
    free(host_and_port);
    return exit_code;
}
