#import "ShellBoxPlugin.h"
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>

// All channel state is confined to the platform (main) thread. Never infer an
// installation from the old directory scaffold or readiness from mount_root.
@interface ShellBoxPlugin ()
@property(nonatomic, copy) NSDictionary *failure;
@end

@implementation ShellBoxPlugin

// Process-lifetime history, shared even if Flutter registers another engine.
// Only fixed native diagnostic messages enter this buffer today: channel
// arguments (especially env), NSError descriptions and guest output do not.
// A future stdio pump MUST redact and frame output before appending it here.
static NSMutableArray<NSDictionary *> *shellBoxEntries;
static unsigned long long shellBoxSequence;
static const NSUInteger ShellBoxLogCapacity = 2000;

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *channel = [FlutterMethodChannel
        methodChannelWithName:@"dsh/shellbox"
        binaryMessenger:registrar.messenger];
    ShellBoxPlugin *instance = [[ShellBoxPlugin alloc] init];
    [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)recordSystemMessage:(NSString *)message {
    NSAssert(NSThread.isMainThread, @"ShellBox history requires the platform thread");
    if (shellBoxEntries == nil) shellBoxEntries = [NSMutableArray array];
    [shellBoxEntries addObject:@{@"seq": @(++shellBoxSequence),
                                @"line": message, @"stream": @"system"}];
    if (shellBoxEntries.count > ShellBoxLogCapacity) {
        [shellBoxEntries removeObjectsInRange:
            NSMakeRange(0, shellBoxEntries.count - ShellBoxLogCapacity)];
    }
}

- (FlutterError *)unsupported:(NSString *)code message:(NSString *)message {
    self.failure = @{@"code": code, @"message": message};
    [self recordSystemMessage:message];
    return [FlutterError errorWithCode:code message:message details:nil];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSAssert(NSThread.isMainThread, @"ShellBox channel requires the platform thread");
    if ([call.method isEqualToString:@"status"]) {
        // There is no iOS payload installer or committed installation marker.
        // Failed attempts are errors, not an installed/running runtime. Do not
        // publish Node/DSH versions merely copied from the Android manifest.
        NSMutableDictionary *status = [@{@"phase": self.failure ? @"error" : @"notInstalled",
                                         @"abi": @"arm64"} mutableCopy];
        if (self.failure) status[@"error"] = self.failure;
        result(status);
    } else if ([call.method isEqualToString:@"logs"] ||
               [call.method isEqualToString:@"logSnapshot"]) {
        BOOL snapshot = [call.method isEqualToString:@"logSnapshot"];
        NSDictionary *arguments = [call.arguments isKindOfClass:NSDictionary.class]
            ? call.arguments : nil;
        id lines = arguments[@"lines"];
        if ((call.arguments != nil && call.arguments != NSNull.null && arguments == nil) ||
            (lines != nil && (![lines isKindOfClass:NSNumber.class] ||
             CFGetTypeID((__bridge CFTypeRef)lines) == CFBooleanGetTypeID() ||
             !isfinite([lines doubleValue]) || [lines doubleValue] < 0 ||
             floor([lines doubleValue]) != [lines doubleValue]))) {
            result([FlutterError errorWithCode:@"shellbox_invalid_arguments"
                message:@"lines must be a nonnegative integer." details:nil]);
            return;
        }
        NSUInteger count = lines == nil ? (snapshot ? 300 : 500) :
            (NSUInteger)MIN([lines doubleValue], (double)ShellBoxLogCapacity);
        count = MIN(count, shellBoxEntries.count);
        NSArray *entries = count == 0 ? @[] : [shellBoxEntries subarrayWithRange:
            NSMakeRange(shellBoxEntries.count - count, count)];
        // Capture watermark even for an empty snapshot; never reset on failure.
        if (snapshot) {
            result(@{@"entries": entries, @"throughSeq": @(shellBoxSequence)});
        } else {
            NSMutableArray *tail = [NSMutableArray arrayWithCapacity:count];
            for (NSDictionary *entry in entries) [tail addObject:entry[@"line"]];
            result(tail);
        }
    } else if ([call.method isEqualToString:@"start"]) {
        // Do not call become_first_process on a dispatch worker. At the pinned
        // upstream revision PID 1 exit calls halt_system -> _exit(0), killing
        // Runner; returning from exit_hook does not prevent that. Boot needs
        // an embedding shutdown API as well as a prepared, verified payload.
        result([self unsupported:@"shellbox_start_rootfs_unimplemented"
            message:@"No iOS rootfs payload installer or safe embedded kernel lifecycle is implemented."]);
    } else if ([call.method isEqualToString:@"install"]) {
        // Neither null nor dropKept authorizes deleting user data before a
        // payload exists. Android assets are not packaged in the iOS bundle.
        result([self unsupported:@"shellbox_install_unimplemented"
            message:@"iOS rootfs payload delivery, verification and fakefs preparation are not implemented; retained data was not changed."]);
    } else if ([call.method isEqualToString:@"reset"]) {
        // keep refers to guest paths with fakefs metadata, not host directory
        // copies. Refuse before changing anything, including for keep: [].
        result([self unsupported:@"shellbox_reset_unimplemented"
            message:@"Guest reset and preservation of kept fakefs data are not implemented; no data was changed."]);
    } else if ([call.method isEqualToString:@"stop"]) {
        result([self unsupported:@"shellbox_stop_unimplemented"
            message:@"ShellBox guest shutdown, thread joining and kernel teardown are not implemented."]);
    } else if ([call.method isEqualToString:@"restart"]) {
        result([self unsupported:@"shellbox_restart_unimplemented"
            message:@"ShellBox shutdown and subsequent boot are not implemented."]);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

@end
