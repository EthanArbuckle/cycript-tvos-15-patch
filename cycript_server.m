//
//  cycript_server_host.m
//  cycript-server-host
//
//  Created by user on 6/2/23.
//

#import <Foundation/Foundation.h>
#import <syslog.h>
#import <dlfcn.h>

static int cycript_server_port = -1;

static CFDataRef receive_msg_from_repl(CFMessagePortRef local, SInt32 msgid, CFDataRef data, void *info) {
    return (CFDataRef)CFBridgingRetain([NSData dataWithBytes:&cycript_server_port length:sizeof(cycript_server_port)]);
}

static void start_cycript_server(void) {
    
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        
        void *libcycript = dlopen("/var/jb/usr/lib/libcycript.dylib", RTLD_NOW);
        if (libcycript == NULL) {
            NSLog(@"failed to load libcycript.dylib %s", dlerror());
            return;
        }
        void *_CYListenServer = dlsym(libcycript, "CYListenServer");
        if (_CYListenServer) {
            
            cycript_server_port = (9973 * getpid()) % 49901 + 8100;
            NSLog(@"launching cycript server on port %d", cycript_server_port);

            NSString *serviceName = [NSString stringWithFormat:@"com.ethanarbuckle.cycript-wrapper.%d", getpid()];
            CFMessagePortRef port = CFMessagePortCreateLocal(kCFAllocatorDefault, (CFStringRef)serviceName, &receive_msg_from_repl, NULL, NULL);
            CFMessagePortSetDispatchQueue(port, dispatch_get_main_queue());

            ((void (*)(short))_CYListenServer)(cycript_server_port);
        }
    });
}

static void __attribute__((constructor)) init_cycript_server_host(void) {
    
    NSLog(@"starting cycript server host");
    start_cycript_server();
}
