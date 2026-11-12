#import "ShellBoxPlugin.h"

@implementation ShellBoxPlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *channel = [FlutterMethodChannel
        methodChannelWithName:@"dsh/shellbox"
        binaryMessenger:registrar.messenger];
    ShellBoxPlugin *instance = [[ShellBoxPlugin alloc] init];
    [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"status"]) {
        result(@{
            @"phase": @"unimplemented",
            @"error": @{
                @"code": @"shellbox_start_rootfs_unimplemented",
                @"message": @"Rootfs payload preparation and DSH launch are not implemented."
            }
        });
    } else if ([call.method isEqualToString:@"start"]) {
        NSError *error = nil;
        if (![self prepareDirectories:&error]) {
            result([FlutterError errorWithCode:@"shellbox_rootfs_scaffold_failed"
                message:error.localizedDescription details:nil]);
            return;
        }
        // Directories alone are not a bootable rootfs. Do not mount or create
        // PID 1 until payload preparation and kernel teardown are implemented.
        result([FlutterError errorWithCode:@"shellbox_start_rootfs_unimplemented"
            message:@"Sandbox directories exist; rootfs payload preparation and DSH launch are not implemented."
            details:nil]);
    } else if ([call.method isEqualToString:@"stop"]) {
        result([FlutterError errorWithCode:@"shellbox_stop_unimplemented"
            message:@"ShellBox process shutdown and kernel teardown are not implemented."
            details:nil]);
    } else if ([call.method isEqualToString:@"restart"]) {
        result([FlutterError errorWithCode:@"shellbox_restart_unimplemented"
            message:@"ShellBox shutdown and subsequent boot are not implemented."
            details:nil]);
    } else {
        result(FlutterMethodNotImplemented);
    }
}

- (BOOL)prepareDirectories:(NSError **)error {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *support = [manager URLForDirectory:NSApplicationSupportDirectory
        inDomain:NSUserDomainMask appropriateForURL:nil create:YES error:error];
    if (support == nil) return NO;
    NSURL *root = [support URLByAppendingPathComponent:@"ShellBox/rootfs" isDirectory:YES];
    // Structure only. No fakefs metadata database, binaries or ready marker.
    for (NSString *path in @[@"", @"bin", @"dev/pts", @"etc", @"proc", @"root",
                             @"sys", @"tmp", @"usr/bin", @"var/lib"]) {
        NSURL *directory = path.length == 0 ? root :
            [root URLByAppendingPathComponent:path isDirectory:YES];
        if (![manager createDirectoryAtURL:directory withIntermediateDirectories:YES
                               attributes:nil error:error]) return NO;
    }
    return YES;
}

@end
