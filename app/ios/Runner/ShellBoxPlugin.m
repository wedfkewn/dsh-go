#import "ShellBoxPlugin.h"
#import <UIKit/UIKit.h>
#import <BackgroundTasks/BackgroundTasks.h>
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdlib.h>
#include <CommonCrypto/CommonDigest.h>
#include "tools/fakefs.h"
#include "ShellBoxKernel.h"
#include "ShellBoxSession.h"
#include <errno.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <netinet/in.h>
#include <unistd.h>

// Channel state and history live on main; blocking installation runs on one worker.
@interface ShellBoxPlugin ()
- (void)receiveOutput:(NSData *)data stream:(int)stream;
- (NSDictionary *)statusMap;
- (NSDictionary *)backgroundExecutionSnapshot;
- (void)publishBackground:(NSString *)state;
- (void)finishBackground:(BOOL)success state:(NSString *)state cancelTask:(BOOL)cancel;
@end

@implementation ShellBoxPlugin

// Process-lifetime history, shared even if Flutter registers another engine.
// Guest lines are assembled and redacted before entering the ring.
static NSMutableArray<NSDictionary *> *shellBoxEntries;
static unsigned long long shellBoxSequence;
static const NSUInteger ShellBoxLogCapacity = 2000;
// Shared across Flutter engines. Set on main before dispatch, cleared on main
// after the worker completes. A second install cannot race the activation.
static BOOL shellBoxInstalling;
static NSString * const ShellBoxPayloadName =
    @"rootfs-ubuntu24.04.5-node24.22.3-dsh0.2.2-rc.1-arm64.tar.gz";

// Platform-thread state shared by Flutter engines. Kernel handles are only
// touched on kernelQueue; an operation retains ownership through a UI timeout.
static enum sb_phase sessionPhase;
static NSString *SBPhase(void) { return sessionPhase == SB_IDLE ? nil : [NSString stringWithUTF8String:sb_phase_name(sessionPhase)]; }
static NSDictionary *lifecycleFailure;
static dispatch_queue_t kernelQueue;
static struct guest_service *service;
static BOOL operationPending, bootFailed, nodeVerified;
static NSString *endpoint, *launchToken;
static NSDictionary *lastStart;
static NSMutableSet<NSString *> *secrets;
static NSMutableData *pendingOutput[2];
static BOOL droppingOutput[2], privateOutput[2];
static unsigned expectedPort;
static NSUInteger startGeneration;
static BOOL deepSeekHostProbed;
static NSString *runtimeInstanceID, *runtimeStartedAt, *requestSource, *transitionSource;
static NSString *flutterLifecycle = @"unknown";
// Authorization state is independent of sessionPhase and guest ownership.
// Main-thread authorization bookkeeping; never owns guest resources.
static NSString *backgroundExecutionState = @"suspendedOrUnknown";
static NSString *backgroundRuntimeInstanceID;
static NSString *backgroundNativeEvent;
static FlutterMethodChannel *backgroundChannel;
static NSDictionary *backgroundTaskInfo;
static NSString *backgroundRequestID, *backgroundError;
static NSMutableSet<NSString *> *backgroundAttemptKeys;
static dispatch_queue_t checkpointQueue;
static BGTask *backgroundSystemTask;
static UIBackgroundTaskIdentifier backgroundGrace;
static NSUInteger checkpointGeneration;
static BOOL checkpointDirty, backgroundTaskVerified, backgroundCancellationRequested;
static NSDictionary *backgroundRecovery;

static NSString *BackgroundIdentifier(void) {
    return [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".dsh.continued"];
}
static BOOL BackgroundEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"dsh.background.enabled"];
}
static NSString *BackgroundKey(NSDictionary *task) {
    return task ? [NSString stringWithFormat:@"%@/%@/%@", task[@"runtimeInstanceId"], task[@"sessionId"], task[@"taskId"]] : nil;
}



static ShellBoxPlugin *runtimeOwner;
static const NSTimeInterval ShellBoxStopSeconds = 5;
static const NSTimeInterval ShellBoxReadySeconds = 180;

static NSData *ShellBoxEnvironment(NSDictionary *extra) {
    NSMutableDictionary *env = [@{@"HOME": @"/root", @"PATH": @"/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        @"LANG": @"C.UTF-8", @"TERM": @"dumb"} mutableCopy];
    [env addEntriesFromDictionary:extra ?: @{}];
    NSMutableData *packed = [NSMutableData data];
    for (NSString *key in env) {
        NSData *entry = [[NSString stringWithFormat:@"%@=%@", key, env[key]] dataUsingEncoding:NSUTF8StringEncoding];
        [packed appendData:entry]; [packed appendBytes:"\0" length:1];
    }
    [packed appendBytes:"\0" length:1];
    return packed;
}
static void ShellBoxOutput(const void *bytes, size_t size, int stream) {
    @autoreleasepool {
        NSData *copy = [NSData dataWithBytes:bytes length:size];
        dispatch_async(dispatch_get_main_queue(), ^{
            [runtimeOwner receiveOutput:copy stream:stream];
        });
    }
}

static NSURL *ShellBoxHome(void) {
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
                                                        inDomains:NSUserDomainMask].firstObject;
    return [support URLByAppendingPathComponent:@"ShellBox" isDirectory:YES];
}

static NSDictionary *ShellBoxInstalled(void) {
    NSURL *active = [ShellBoxHome() URLByAppendingPathComponent:@"active" isDirectory:YES];
    NSDictionary *marker = [NSDictionary dictionaryWithContentsOfURL:
        [active URLByAppendingPathComponent:@"installed.plist"]];
    BOOL directory = NO;
    if (![marker[@"sha256"] isKindOfClass:NSString.class] ||
        ![NSFileManager.defaultManager fileExistsAtPath:
            [active URLByAppendingPathComponent:@"data"].path isDirectory:&directory] || !directory ||
        ![NSFileManager.defaultManager fileExistsAtPath:
            [active URLByAppendingPathComponent:@"meta.db"].path]) return nil;
    return marker;
}

// Return only fixed error codes. Never expose paths, importer errors or env.
static NSString *ShellBoxInstallPayload(void) {
    NSBundle *bundle = NSBundle.mainBundle;
    NSURL *manifestURL = [bundle URLForResource:@"MANIFEST" withExtension:@"json"];
    NSURL *archiveURL = [bundle URLForResource:ShellBoxPayloadName withExtension:nil];
    if (!manifestURL || !archiveURL) return @"shellbox_payload_missing";
    NSData *data = [NSData dataWithContentsOfURL:manifestURL];
    id manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![manifest isKindOfClass:NSDictionary.class] || ![manifest[@"schema"] isEqual:@1] ||
        ![manifest[@"payloadArchives"] isKindOfClass:NSArray.class] ||
        [manifest[@"payloadArchives"] count] != 1) return @"shellbox_manifest_invalid";
    id archive = manifest[@"payloadArchives"][0];
    if (![archive isKindOfClass:NSDictionary.class]) return @"shellbox_manifest_invalid";
    NSString *expected = archive[@"sha256"];
    NSNumber *size = archive[@"sizeBytes"];
    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    if (![expected isKindOfClass:NSString.class] || expected.length != 64 ||
        [expected rangeOfCharacterFromSet:nonHex].location != NSNotFound ||
        ![size isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)size) == CFBooleanGetTypeID() ||
        !isfinite(size.doubleValue) || size.doubleValue <= 0 ||
        floor(size.doubleValue) != size.doubleValue) return @"shellbox_manifest_invalid";
    // The manifest's absolute archive path is provenance, never a runtime URL.
    NSInputStream *input = [NSInputStream inputStreamWithURL:archiveURL];
    [input open];
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    uint8_t buffer[65536];
    uint64_t total = 0;
    NSInteger count;
    while ((count = [input read:buffer maxLength:sizeof(buffer)]) > 0) {
        total += (uint64_t)count;
        CC_SHA256_Update(&context, buffer, (CC_LONG)count);
    }
    [input close];
    if (count < 0) return @"shellbox_payload_read_failed";
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *actual = [NSMutableString string];
    for (NSUInteger i = 0; i < sizeof(digest); i++) [actual appendFormat:@"%02x", digest[i]];
    if (total != size.unsignedLongLongValue || ![actual isEqualToString:expected])
        return @"shellbox_payload_integrity_failed";
    NSDictionary *installed = ShellBoxInstalled();
    if (installed) return [installed[@"sha256"] isEqual:actual] ? nil : @"shellbox_upgrade_requires_reset";
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *home = ShellBoxHome();
    NSURL *active = [home URLByAppendingPathComponent:@"active" isDirectory:YES];
    // An unrecognized installation is user data, never disposable staging.
    if ([files fileExistsAtPath:active.path]) return @"shellbox_installation_invalid";
    if (![files createDirectoryAtURL:home withIntermediateDirectories:YES attributes:nil error:nil])
        return @"shellbox_install_storage_failed";
    NSURL *stage = [home URLByAppendingPathComponent:
        [@"prepare-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
    struct fakefsify_error importError = {0};
    BOOL imported = fakefs_import(archiveURL.fileSystemRepresentation,
                                 stage.fileSystemRepresentation, &importError, (struct progress){0});
    free(importError.message);
    NSString *failure = nil;
    if (!imported) failure = @"shellbox_import_failed";
    if (!failure && ![@{@"schema": @1, @"sha256": actual, @"sizeBytes": @(total)}
        writeToURL:[stage URLByAppendingPathComponent:@"installed.plist"] atomically:YES])
        failure = @"shellbox_install_marker_failed";
    // Same-volume rename publishes data, metadata and marker together. No active
    // tree is removed or replaced; failed import/activation leaves it untouched.
    if (!failure && ![files moveItemAtURL:stage toURL:active error:nil])
        failure = @"shellbox_install_activation_failed";
    if (failure && ![files removeItemAtURL:stage error:nil] && [files fileExistsAtPath:stage.path])
        return @"shellbox_install_cleanup_failed";
    return failure;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *channel = [FlutterMethodChannel
        methodChannelWithName:@"dsh/shellbox"
        binaryMessenger:registrar.messenger];
    ShellBoxPlugin *instance = [[ShellBoxPlugin alloc] init];
    if (!runtimeOwner) {
        backgroundGrace = UIBackgroundTaskInvalid;
        runtimeOwner = instance;
        kernelQueue = dispatch_queue_create("dsh.shellbox.kernel", DISPATCH_QUEUE_SERIAL);
        secrets = [NSMutableSet set];
        backgroundAttemptKeys = [NSMutableSet set];
        checkpointQueue = dispatch_queue_create("dsh.background.checkpoint", DISPATCH_QUEUE_SERIAL);
        NSURL *recoveryDirectory = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
            inDomains:NSUserDomainMask].firstObject;
        backgroundRecovery = [NSDictionary dictionaryWithContentsOfURL:
            [recoveryDirectory URLByAppendingPathComponent:@"dsh-background-recovery.plist"]];
        pendingOutput[0] = [NSMutableData data]; pendingOutput[1] = [NSMutableData data];
    }
    backgroundChannel = channel;
    [registrar addMethodCallDelegate:instance channel:channel];
    // The process-lifetime owner survives Flutter engine/page recreation.
    if (runtimeOwner == instance) {
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserver:instance selector:@selector(backgroundLifecycle:)
                       name:UIApplicationDidEnterBackgroundNotification object:nil];
        [center addObserver:instance selector:@selector(backgroundLifecycle:)
                       name:UIApplicationDidBecomeActiveNotification object:nil];
        backgroundExecutionState = [UIApplication sharedApplication].applicationState == UIApplicationStateActive
            ? @"foreground" : @"suspendedOrUnknown";
        [instance publishBackground:backgroundExecutionState];
    }
}

// Continued-processing handlers may register dynamically (Apple WWDC25/227).
// A unique request ID and captured task identity reject late launches from old turns.
- (BOOL)registerBackgroundRequest:(NSString *)identifier {
    NSDictionary *identity = backgroundTaskInfo;
    if (@available(iOS 26.0, *)) {
        return [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:identifier
            usingQueue:dispatch_get_main_queue() launchHandler:^(BGTask *task) {
                if (![BackgroundKey(identity) isEqual:BackgroundKey(backgroundTaskInfo)] || ![task.identifier isEqual:backgroundRequestID] ||
                    ![backgroundTaskInfo[@"runtimeInstanceId"] isEqual:runtimeInstanceID]) {
                    [task setTaskCompletedWithSuccess:NO]; return;
                }
                backgroundSystemTask = task;
                BGContinuedProcessingTask *continued = (BGContinuedProcessingTask *)task;
                // NSProgress total <= 0 is indeterminate. Never count tokens/ticks as completion.
                continued.progress.totalUnitCount = -1;
                continued.progress.completedUnitCount = 0;
                [continued updateTitle:NSLocalizedString(@"DSH task", nil)
                    subtitle:NSLocalizedString(@"Working · progress unknown", nil)];
                dispatch_block_t endAuthorization = ^{
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (backgroundSystemTask != task ||
                            ![identity[@"runtimeInstanceId"] isEqual:runtimeInstanceID]) return;
                        [runtimeOwner finishBackground:NO state:@"expired" cancelTask:YES];
                    });
                };
                task.expirationHandler = endAuthorization;
                continued.progress.cancellable = YES;
                continued.progress.cancellationHandler = endAuthorization;
                [runtimeOwner publishBackground:@"continuedProcessing"];
            }];
    }
    return NO;
}

- (void)publishBackground:(NSString *)state {
    backgroundExecutionState = state;
    backgroundRuntimeInstanceID = [runtimeInstanceID copy];
    NSDictionary *snapshot = [self backgroundExecutionSnapshot];
    if (backgroundError) [self recordSystemMessage:[@"background.reason " stringByAppendingString:backgroundError]];
    [backgroundChannel invokeMethod:@"backgroundExecutionChanged" arguments:snapshot];
    [NSNotificationCenter.defaultCenter postNotificationName:@"DshBackgroundExecutionChanged"
        object:nil userInfo:snapshot];
    [self recordLifecycle:[@"background." stringByAppendingString:state] source:@"native.backgroundExecution"];
}

- (void)endBackgroundGrace {
    if (backgroundGrace == UIBackgroundTaskInvalid) return;
    UIBackgroundTaskIdentifier identifier = backgroundGrace;
    backgroundGrace = UIBackgroundTaskInvalid;
    [UIApplication.sharedApplication endBackgroundTask:identifier];
}

// A checkpoint is only recovery metadata, not a guest-memory snapshot. No prompts,
// titles, credentials, or runtime URLs are written. Disk work is off the kernel queue.
- (void)checkpointBackground {
    if (!checkpointDirty || !backgroundTaskInfo) return;
    checkpointDirty = NO;
    NSUInteger generation = ++checkpointGeneration;
    NSDictionary *saved = @{ @"runtimeInstanceId": backgroundTaskInfo[@"runtimeInstanceId"],
        @"sessionId": backgroundTaskInfo[@"sessionId"], @"taskId": backgroundTaskInfo[@"taskId"],
        @"state": backgroundExecutionState, @"savedAt": NSDate.date };
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground &&
        backgroundGrace == UIBackgroundTaskInvalid) {
        backgroundGrace = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"DSH recovery metadata"
            expirationHandler:^{
                [self endBackgroundGrace];
                [self publishBackground:@"expired"];
            }];
        if (backgroundGrace != UIBackgroundTaskInvalid && !backgroundSystemTask &&
            [backgroundExecutionState isEqual:@"suspendedOrUnknown"])
            [self publishBackground:@"backgroundGrace"];
    }
    dispatch_async(checkpointQueue, ^{
        NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory
            inDomains:NSUserDomainMask].firstObject;
        NSError *error;
        BOOL ok = [NSFileManager.defaultManager createDirectoryAtURL:directory
            withIntermediateDirectories:YES attributes:nil error:&error] &&
            [saved writeToURL:[directory URLByAppendingPathComponent:@"dsh-background-recovery.plist"] atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != checkpointGeneration) return;
            if (ok) backgroundRecovery = saved;
            [self endBackgroundGrace];
            if (!ok) { backgroundError = @"checkpoint_write_failed"; checkpointDirty = YES; }
            if ([backgroundExecutionState isEqual:@"backgroundGrace"])
                [self publishBackground:ok ? @"suspendedOrUnknown" : @"failed"];
        });
    });
    // A slow filesystem must never hold a UIKit grant indefinitely.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (generation != checkpointGeneration || backgroundGrace == UIBackgroundTaskInvalid) return;
        [self endBackgroundGrace];
        backgroundError = @"checkpoint_deadline_exceeded";
        [self publishBackground:@"suspendedOrUnknown"];
    });
}

- (void)finishBackground:(BOOL)success state:(NSString *)state cancelTask:(BOOL)cancel {
    NSDictionary *task = backgroundTaskInfo;
    BGTask *system = backgroundSystemTask;
    backgroundSystemTask = nil;
    if (backgroundRequestID) [BGTaskScheduler.sharedScheduler cancelTaskRequestWithIdentifier:backgroundRequestID];
    backgroundRequestID = nil;
    system.expirationHandler = nil;
    if (@available(iOS 26.0, *)) {
        if ([system isKindOfClass:BGContinuedProcessingTask.class])
            ((BGContinuedProcessingTask *)system).progress.cancellationHandler = nil;
        if (success && [system isKindOfClass:BGContinuedProcessingTask.class]) {
            ((BGContinuedProcessingTask *)system).progress.totalUnitCount = 1;
            ((BGContinuedProcessingTask *)system).progress.completedUnitCount = 1;
        }
    }
    [system setTaskCompletedWithSuccess:success];
    [self publishBackground:state];
    checkpointDirty = task != nil;
    [self checkpointBackground];
    if (cancel && !backgroundCancellationRequested && task && [task[@"runtimeInstanceId"] isEqual:runtimeInstanceID]) {
        backgroundCancellationRequested = YES;
        backgroundError = @"cancellation_unconfirmed";
        // Session-level cancellation only. Flutter must revalidate the turn before RPC.
        [backgroundChannel invokeMethod:@"cancelBackgroundTask" arguments:task result:^(id reply) {
            if (![BackgroundKey(task) isEqual:BackgroundKey(backgroundTaskInfo)]) return;
            backgroundError = [reply isEqual:@"accepted"] ? @"cancellation_requested" : @"cancellation_unconfirmed";
        }];
    }
}

- (void)backgroundLifecycle:(NSNotification *)notification {
    NSAssert(NSThread.isMainThread, @"Background state requires the platform thread");
    if ([backgroundNativeEvent isEqual:notification.name] &&
        (backgroundRuntimeInstanceID == runtimeInstanceID || [backgroundRuntimeInstanceID isEqual:runtimeInstanceID])) return;
    backgroundNativeEvent = notification.name;
    if ([notification.name isEqual:UIApplicationDidBecomeActiveNotification]) {
        [self endBackgroundGrace];
        backgroundTaskVerified = NO;
        [self publishBackground:@"resuming"];
        // The existing status path reconciles confirmed command exit.
        // Background expiry itself is never evidence of guest exit.
        [self statusMap];
        [self publishBackground:@"foreground"];
    } else {
        [self publishBackground:backgroundSystemTask ? @"continuedProcessing" : @"suspendedOrUnknown"];
        [self checkpointBackground];
    }
}

- (NSDictionary *)backgroundExecutionSnapshot {
    return @{@"state": backgroundExecutionState,
        @"runtimeInstanceId": runtimeInstanceID ?: (id)NSNull.null,
        @"observedRuntimeInstanceId": backgroundRuntimeInstanceID ?: (id)NSNull.null,
        @"runtimePhase": SBPhase() ?: @"idle", @"appPid": @(getpid()),
        @"dshPid": @(dsh_shellbox_command_pid()),
        @"authorizationActive": @(backgroundSystemTask != nil || backgroundGrace != UIBackgroundTaskInvalid),
        @"sessionId": backgroundTaskInfo[@"sessionId"] ?: (id)NSNull.null,
        @"taskId": backgroundTaskInfo[@"taskId"] ?: (id)NSNull.null,
        @"taskState": backgroundTaskInfo[@"status"] ?: @"unknown",
        @"taskVerified": @(backgroundTaskVerified),
        @"reason": backgroundError ?: @"", @"enabled": @(BackgroundEnabled()),
        // Saved identifiers are navigation/reconciliation hints, never active tasks.
        @"recoveryAvailable": @(backgroundRecovery != nil)};
}

- (id)requestBackground {
    if (!BackgroundEnabled()) return @"disabled";
    if (@available(iOS 26.0, *)) {
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return @"requires_foreground";
        if (!backgroundTaskInfo || ![backgroundTaskInfo[@"status"] isEqual:@"running"] ||
            ![backgroundTaskInfo[@"runtimeInstanceId"] isEqual:runtimeInstanceID] || sessionPhase != SB_RUNNING)
            return @"no_active_user_task";
        NSString *key = BackgroundKey(backgroundTaskInfo);
        if ([backgroundAttemptKeys containsObject:key]) return @"already_attempted";
        [backgroundAttemptKeys addObject:key]; // Not cleared by lifecycle, settings, or a network bounce.
        backgroundRequestID = [BackgroundIdentifier() stringByAppendingFormat:@".%@", NSUUID.UUID.UUIDString];
        if (![self registerBackgroundRequest:backgroundRequestID]) {
            backgroundRequestID = nil;
            backgroundError = @"registration_failed";
            [self publishBackground:@"failed"];
            return backgroundError;
        }
        BGContinuedProcessingTaskRequest *request = [[BGContinuedProcessingTaskRequest alloc]
            initWithIdentifier:backgroundRequestID title:NSLocalizedString(@"DSH task", nil)
            subtitle:NSLocalizedString(@"Working · progress unknown", nil)];
        request.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyFail;
        NSError *error;
        if (![BGTaskScheduler.sharedScheduler submitTaskRequest:request error:&error]) {
            backgroundRequestID = nil;
            backgroundError = [NSString stringWithFormat:@"scheduler_rejected_%ld", (long)error.code];
            [self publishBackground:@"failed"];
            return backgroundError;
        }
        backgroundError = nil;
        return @"submitted";
    }
    return @"requires_ios_26";
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

// Fixed metadata only; never serialize channel arguments or runtime URLs.
- (void)recordLifecycle:(NSString *)event {
    [self recordLifecycle:event source:requestSource];
}
- (void)recordLifecycle:(NSString *)event source:(NSString *)source {
    NSMutableDictionary *fields = [@{@"event": event, @"timestamp": [NSISO8601DateFormatter.new stringFromDate:NSDate.date], @"appPid": @(getpid()),
        @"runtimeInstanceId": runtimeInstanceID ?: (id)NSNull.null,
        @"dshPid": @(dsh_shellbox_command_pid()), @"guestInitPid": @1,
        @"webPort": @(expectedPort), @"startedAt": runtimeStartedAt ?: (id)NSNull.null,
        @"flutterLifecycle": flutterLifecycle, @"source": source ?: @"native.internal",
        @"phase": shellBoxInstalling ? @"installing" :
            (SBPhase() ?: (lifecycleFailure ? @"error" : (ShellBoxInstalled() ? @"installed" : @"notInstalled")))} mutableCopy];
    if ([source isEqual:@"native.backgroundExecution"] && backgroundError) fields[@"reason"] = backgroundError;
    NSData *json = [NSJSONSerialization dataWithJSONObject:fields options:NSJSONWritingSortedKeys error:nil];
    [self recordSystemMessage:[@"shellbox.lifecycle " stringByAppendingString:
        [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]]];
}
- (void)setPhase:(enum sb_phase)phase {
    sessionPhase = phase;
    [self recordLifecycle:@"transition" source:transitionSource];
}

- (FlutterError *)unsupported:(NSString *)code message:(NSString *)message {
    lifecycleFailure = @{@"code": code, @"message": message};
    [self recordSystemMessage:message];
    [self recordLifecycle:code];
    return [FlutterError errorWithCode:code message:message details:nil];
}

- (NSDictionary *)statusMap {
    if (sessionPhase == SB_RUNNING) {
        int status = dsh_shellbox_command_status();
        if (status != -1) {
            NSString *message = WIFSIGNALED(status)
                ? [NSString stringWithFormat:@"Local DSH exited unexpectedly (signal %d).", WTERMSIG(status)]
                : [NSString stringWithFormat:@"Local DSH exited unexpectedly (exit code %d).", WEXITSTATUS(status)];
            [self recordSystemMessage:message];
            [self recordLifecycle:@"shellbox_command_exited" source:@"runtime.commandExit"];
            [self stop:^(id reply) {
                if (reply) return;
                lifecycleFailure = @{@"code": @"shellbox_command_exited", @"message": message};
                transitionSource = @"runtime.commandExit";
                [self setPhase:SB_ERROR];
            }];
        }
    }
    NSMutableDictionary *status = [@{@"phase": shellBoxInstalling ? @"installing" :
        (SBPhase() ?: (lifecycleFailure ? @"error" : (ShellBoxInstalled() ? @"installed" : @"notInstalled"))),
        @"abi": @"arm64"} mutableCopy];
    NSDictionary *installed = ShellBoxInstalled();
    if (installed) status[@"installedVersion"] = installed[@"sha256"];
    NSURL *manifestURL = [NSBundle.mainBundle URLForResource:@"MANIFEST" withExtension:@"json"];
    NSData *manifestData = manifestURL ? [NSData dataWithContentsOfURL:manifestURL] : nil;
    id manifest = manifestData ? [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil] : nil;
    id archives = [manifest isKindOfClass:NSDictionary.class] ? manifest[@"payloadArchives"] : nil;
    id archive = [archives isKindOfClass:NSArray.class] && [archives count] == 1 ? archives[0] : nil;
    id digest = [archive isKindOfClass:NSDictionary.class] ? archive[@"sha256"] : nil;
    if ([digest isKindOfClass:NSString.class]) status[@"bundledVersion"] = digest;
    if (lifecycleFailure) status[@"error"] = lifecycleFailure;
    if ([SBPhase() isEqual:@"running"]) { status[@"baseUrl"] = endpoint; status[@"token"] = launchToken; }
    if (nodeVerified) status[@"nodeVersion"] = @"24.22.3";
    return status;
}
- (FlutterError *)rejection:(NSString *)code {
    [self recordLifecycle:code];
    NSMutableDictionary *status = [[self statusMap] mutableCopy];
    [status removeObjectForKey:@"token"]; // errors may be written to diagnostics
    return [FlutterError errorWithCode:code message:code details:status];
}
- (void)blocked {
    [self setPhase:sb_stop_result(false)]; endpoint = nil; launchToken = nil;
    lifecycleFailure = @{@"code": @"shellbox_stop_blocked", @"message":
        @"Service completion is unconfirmed. Retry stop or close the app from the app switcher. The guest and resources remain alive."};
    [self recordSystemMessage:@"StopBlocked: service completion unconfirmed; resources retained. Retry stop or close the app."];
}
// The guest already reported a model-list transport failure. Probe the same
// endpoint once from iOS without forwarding a key, cookies, or response data.
- (void)probeDeepSeekFromHost {
    if (deepSeekHostProbed) return;
    deepSeekHostProbed = YES;
    NSUInteger generation = startGeneration;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 8;
    configuration.timeoutIntervalForResource = 10;
    configuration.HTTPCookieStorage = nil;
    configuration.URLCredentialStorage = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSURL *url = [NSURL URLWithString:@"https://api.deepseek.com/models"];
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [session finishTasksAndInvalidate];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != startGeneration) return;
            NSString *outcome = error
                ? [NSString stringWithFormat:@"error=%@/%ld", error.domain, (long)error.code]
                : [NSString stringWithFormat:@"http=%ld", (long)[(NSHTTPURLResponse *)response statusCode]];
            [self recordSystemMessage:[@"shellbox.network deepseek host " stringByAppendingString:outcome]];
        });
    }] resume];
}

- (void)receiveOutput:(NSData *)data stream:(int)stream {
    NSUInteger index = stream == 2 ? 1 : 0;
    if (!data.length) {
        if (pendingOutput[index].length || droppingOutput[index]) [self receiveOutput:[NSData dataWithBytes:"\n" length:1] stream:stream];
        privateOutput[index] = NO;
        return;
    }
    // Keep UTF-8 and secrets intact across arbitrary pipe chunks. Oversized lines
    // are dropped through newline, never emitted in partially redacted chunks.
    const uint8_t *bytes = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) {
        if (bytes[i] != '\n') {
            if (!droppingOutput[index]) [pendingOutput[index] appendBytes:bytes + i length:1];
            if (pendingOutput[index].length > 65536) {
                [pendingOutput[index] setLength:0]; droppingOutput[index] = YES;
            }
            continue;
        }
        NSString *line = droppingOutput[index] ? @"[oversized guest line omitted]" :
            [[NSString alloc] initWithData:pendingOutput[index] encoding:NSUTF8StringEncoding];
        [pendingOutput[index] setLength:0]; droppingOutput[index] = NO;
        if (!line) continue;
        NSRegularExpression *ansi = [NSRegularExpression regularExpressionWithPattern:@"\\x1b\\[[0-9;?]*[ -/]*[@-~]" options:0 error:nil];
        line = [ansi stringByReplacingMatchesInString:line options:0 range:NSMakeRange(0, line.length) withTemplate:@""];
        if ([line containsString:@"-----BEGIN "] && [line containsString:@"PRIVATE KEY-----"]) privateOutput[index] = YES;
        if (privateOutput[index]) {
            BOOL end = [line containsString:@"-----END "] && [line containsString:@"PRIVATE KEY-----"];
            line = @"[REDACTED private key]";
            if (end) privateOutput[index] = NO;
        }

        if ([SBPhase() isEqual:@"starting"]) {
            if ([line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length &&
                [[line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqual:@"DSH_GO_NODE=v24.22.3"])
                nodeVerified = YES;
            NSRegularExpression *urlPattern = [NSRegularExpression regularExpressionWithPattern:
                @"http://127\\.0\\.0\\.1:[0-9]+[^\\s\"']*[?&#]token=([A-Za-z0-9._~%+-]+)" options:0 error:nil];
            NSTextCheckingResult *match = [urlPattern firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (match) {
                NSURLComponents *url = [NSURLComponents componentsWithString:[line substringWithRange:match.range]];
                if ([url.host isEqual:@"127.0.0.1"] && url.port.unsignedIntValue == expectedPort) {
                    endpoint = [NSString stringWithFormat:@"http://127.0.0.1:%@", url.port];
                    NSString *observed = [line substringWithRange:[match rangeAtIndex:1]];
                    launchToken = observed.stringByRemovingPercentEncoding ?: observed;
                    [secrets addObject:launchToken];
                }
            }
        }
        if ([line containsString:@"[llm-deepseek-api-key] model listing from https://api.deepseek.com/models failed"] &&
            [line containsString:@"could not reach https://api.deepseek.com/models"]) {
            [self recordSystemMessage:@"shellbox.network deepseek guest transport_failed"];
            [self probeDeepSeekFromHost];
        }
        for (NSString *secret in secrets) if (secret.length) line = [line stringByReplacingOccurrencesOfString:secret withString:@"[REDACTED]"];
        for (NSString *pattern in @[@"(?i)(?:bearer|basic)\\s+[^\\s]+", @"(?i)[A-Za-z0-9_.-]*(?:token|api[_-]?key|secret|password|cookie|authorization|credential|passphrase)[A-Za-z0-9_.-]*[\"']?\\s*[:=].*", @"(?:sk-|glpat-|gh[pousr]_|github_pat_|npm_|hf_|xox[baprs]-)[A-Za-z0-9_-]+", @"eyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+", @"[a-z][a-z0-9+.-]*://[^/\\s:@]+:[^/\\s@]+@"] ) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
            line = [regex stringByReplacingMatchesInString:line options:0 range:NSMakeRange(0, line.length) withTemplate:@"[REDACTED]"];
        }
        if (shellBoxEntries == nil) shellBoxEntries = [NSMutableArray array];
        [shellBoxEntries addObject:@{@"seq": @(++shellBoxSequence), @"line": line,
            @"stream": stream == 2 ? @"stderr" : @"stdout"}];
        if (shellBoxEntries.count > ShellBoxLogCapacity) [shellBoxEntries removeObjectAtIndex:0];
    }
}
- (void)start:(id)arguments result:(FlutterResult)result {
    [self recordLifecycle:@"start.request"];
    Class nativeRuntime = NSClassFromString(@"DshNativeNodeRuntime");
    if (nativeRuntime && [[nativeRuntime valueForKey:@"selectedForSmoke"] boolValue]) {
        result([FlutterError errorWithCode:@"native_node_selected" message:@"The native runtime owns this launch." details:nil]);
        return;
    }

    if (bootFailed) { result([self rejection:@"shellbox_boot_failed"]); return; }
    if (!sb_can_initialize(sessionPhase, operationPending) || service) {
        result([self rejection:[SBPhase() isEqual:@"stopBlocked"] ? @"shellbox_stop_blocked" : @"shellbox_already_active"]); return;
    }
    if (!ShellBoxInstalled()) { result([self rejection:@"shellbox_not_installed"]); return; }
    if (arguments && arguments != NSNull.null && ![arguments isKindOfClass:NSDictionary.class]) {
        result([self rejection:@"shellbox_invalid_arguments"]); return;
    }
    NSDictionary *args = [arguments isKindOfClass:NSDictionary.class] ? arguments : @{};
    id extra = args[@"env"] ?: @{};
    if (![extra isKindOfClass:NSDictionary.class]) { result([self rejection:@"shellbox_invalid_arguments"]); return; }
    NSRegularExpression *keyPattern = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z_][A-Za-z0-9_]*$" options:0 error:nil];
    for (id key in extra) {
        id value = extra[key];
        if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class] ||
            ![keyPattern numberOfMatchesInString:key options:0 range:NSMakeRange(0, [key length])] ||
            [value rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound ||
            [@[@"HOME", @"PATH", @"LD_PRELOAD", @"NODE_OPTIONS"] containsObject:key]) {
            result([self rejection:@"shellbox_invalid_arguments"]); return;
        }
    }
    for (NSString *option in @[@"phoneStorage", @"visualReplies"]) {
        id value = args[option];
        if (value && (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID())) {
            result([self rejection:@"shellbox_invalid_arguments"]); return;
        }
    }
    if ([args[@"phoneStorage"] boolValue] || ([args[@"mode"] isKindOfClass:NSString.class] && ![args[@"mode"] isEqual:@"normal"]) ||
        (args[@"visualReplies"] && ![args[@"visualReplies"] boolValue])) {
        result([self rejection:@"shellbox_start_options_unsupported"]); return;
    }
    // This point is after sb_can_initialize and service ownership checks.
    // Retire authorization for the previous instance, never its Linux resources.
    if (backgroundSystemTask || backgroundRequestID)
        [self finishBackground:NO state:@"suspendedOrUnknown" cancelTask:NO];
    ++checkpointGeneration;
    [self endBackgroundGrace];
    backgroundTaskInfo = nil;
    checkpointDirty = NO;
    backgroundTaskVerified = NO;
    backgroundCancellationRequested = NO;
    backgroundError = nil;
    [backgroundAttemptKeys removeAllObjects];
    runtimeInstanceID = NSUUID.UUID.UUIDString;
    runtimeStartedAt = [NSISO8601DateFormatter.new stringFromDate:NSDate.date];
    NSUInteger generation = ++startGeneration;
    NSString *caller = requestSource ?: @"runtime.direct";
    transitionSource = caller;
    lastStart = args; // in memory only, needed for same-session restart
    [secrets removeAllObjects];
    for (NSString *value in [extra allValues]) {
        for (NSString *part in [value componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet])
            if (part.length) [secrets addObject:part];
    }
    expectedPort = 0;
    [self setPhase:SB_STARTING]; lifecycleFailure = nil; operationPending = YES;
    nodeVerified = NO; deepSeekHostProbed = NO; endpoint = nil; launchToken = nil;
    NSData *environment = ShellBoxEnvironment(extra);
    NSString *root = [[ShellBoxHome() URLByAppendingPathComponent:@"active/data"] path];
    // Ask the OS for an available loopback port; readiness uses the observed DSH URL.
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {.sin_family = AF_INET, .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
    socklen_t addressSize = sizeof(address);
    if (sock < 0 || bind(sock, (struct sockaddr *)&address, addressSize) || getsockname(sock, (struct sockaddr *)&address, &addressSize)) {
        if (sock >= 0) close(sock); [self setPhase:SB_ERROR]; operationPending = NO;
        result([self unsupported:@"shellbox_port_failed" message:@"Could not select a loopback port."]); return;
    }
    unsigned port = ntohs(address.sin_port); expectedPort = port; close(sock);
    [self recordLifecycle:@"start.port_selected"];
    NSString *command = [NSString stringWithFormat:
        @"cd /root && /opt/node/bin/node -e 'if(process.version!==\"v24.22.3\")process.exit(70);const fs=require(\"fs\");for(const [p,v] of [[\"/etc/resolv.conf\",\"nameserver 1.1.1.1\\nnameserver 8.8.8.8\\n\"],[\"/etc/hosts\",\"127.0.0.1 localhost\\n::1 localhost\\n\"]]){if(!fs.existsSync(p)||fs.statSync(p).size===0)fs.writeFileSync(p,v)}fs.mkdirSync(\"/etc/ssl/certs\",{recursive:true});const ca=\"/etc/ssl/certs/ca-certificates.crt\";if(!fs.existsSync(ca)||fs.statSync(ca).size===0)fs.writeFileSync(ca,require(\"tls\").rootCertificates.join(\"\\n\")+\"\\n\");console.log(\"DSH_GO_NETWORK_CONFIG=ready\");console.log(\"DSH_GO_NODE=\"+process.version)' && exec /usr/local/bin/dsh web --host 127.0.0.1 --port %u --no-open", port];
    dispatch_async(kernelQueue, ^{
        int err = dsh_shellbox_boot(root.fileSystemRepresentation);
        BOOL failedBoot = err != 0;
        if (!err) err = dsh_shellbox_launch(command.UTF8String, environment.bytes, ShellBoxOutput, &service);
        dispatch_async(dispatch_get_main_queue(), ^{
            operationPending = NO;
            [self recordLifecycle:@"start.launch_completed" source:caller];
            if (err) {
                bootFailed = failedBoot; [self setPhase:SB_ERROR];
                result([self unsupported:failedBoot ? @"shellbox_boot_failed" : @"shellbox_launch_failed" message:@"Guest boot or service launch failed. No readiness claimed."]);
            } else [self awaitReady:(NSProcessInfo.processInfo.systemUptime + ShellBoxReadySeconds) generation:generation source:caller result:result];
        });
    });
}
- (void)awaitReady:(NSTimeInterval)deadline generation:(NSUInteger)generation source:(NSString *)caller result:(FlutterResult)result {
    if (generation != startGeneration || ![SBPhase() isEqual:@"starting"]) { [self recordLifecycle:@"start.interrupted" source:caller]; result([self rejection:@"shellbox_start_interrupted"]); return; }
    if (NSProcessInfo.processInfo.systemUptime >= deadline) {
        [self stop:^(id reply) {
            result(reply ?: [self unsupported:@"shellbox_readiness_failed" message:@"Node version and DSH loopback readiness were not confirmed."]);
        }]; return;
    }
    if (nodeVerified && endpoint && launchToken) {
        // The pinned DSH index returns 401 without a launch-token exchange.
        // Ephemeral cookies permit its authenticated redirect, without disk state.
        NSURLComponents *probeURL = [NSURLComponents componentsWithString:endpoint];
        probeURL.path = @"/";
        probeURL.queryItems = @[[NSURLQueryItem queryItemWithName:@"token" value:launchToken]];
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:probeURL.URL];
        request.timeoutInterval = 2;
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
        [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            [session finishTasksAndInvalidate];
            dispatch_async(dispatch_get_main_queue(), ^{
                NSInteger code = [(NSHTTPURLResponse *)response statusCode];
                if (generation == startGeneration && [SBPhase() isEqual:@"starting"] && !error && code >= 200 && code < 400 && dsh_shellbox_command_status() == -1) {
                    [self setPhase:SB_RUNNING]; lifecycleFailure = nil; result(nil);
                } else [self scheduleReady:deadline generation:generation source:caller result:result];
            });
        }] resume];
    } else [self scheduleReady:deadline generation:generation source:caller result:result];
}
- (void)scheduleReady:(NSTimeInterval)deadline generation:(NSUInteger)generation source:(NSString *)caller result:(FlutterResult)result {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self awaitReady:deadline generation:generation source:caller result:result]; });
}
- (void)stop:(FlutterResult)result {
    [self recordLifecycle:@"stop.request"];
    if (operationPending || shellBoxInstalling) { result([self rejection:sessionPhase == SB_STOP_BLOCKED ? @"shellbox_stop_blocked" : @"shellbox_busy"]); return; }
    if ([SBPhase() isEqual:@"stopping"]) { result([self rejection:@"shellbox_busy"]); return; }
    if (!sb_can_stop(sessionPhase, operationPending)) {
        if (sessionPhase == SB_RESETTING) result([self rejection:@"shellbox_busy"]);
        else result(nil);
        return;
    }
    ++startGeneration;
    transitionSource = requestSource ?: @"native.stop";
    [self setPhase:SB_STOPPING]; endpoint = nil; launchToken = nil; operationPending = YES;
    NSTimeInterval deadline = (NSProcessInfo.processInfo.systemUptime + ShellBoxStopSeconds);
    __block BOOL replied = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(ShellBoxStopSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!replied) { replied = YES; [self blocked]; result([self rejection:@"shellbox_stop_blocked"]); }
    });
    dispatch_async(kernelQueue, ^{
        int err = dsh_shellbox_request_stop(service);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (err) {
                operationPending = NO;
                if (!replied) { replied = YES; [self blocked]; result([self rejection:@"shellbox_stop_request_failed"]); }
                return;
            }
            [self pollStop:deadline completion:^(id reply) {
                if (!replied) { replied = YES; result(reply); }
            }];
        });
    });
}
- (void)pollStop:(NSTimeInterval)deadline completion:(FlutterResult)completion {
    operationPending = YES;
    dispatch_async(kernelQueue, ^{
        int err = dsh_shellbox_finish_stop(service);
        if (!err) service = NULL;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!err) { operationPending = NO; [self setPhase:sb_stop_result(true)]; lifecycleFailure = nil; completion(nil); }
            else if (err != EBUSY || NSProcessInfo.processInfo.systemUptime >= deadline) {
                operationPending = NO; [self blocked]; completion([self rejection:@"shellbox_stop_blocked"]);
            } else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                [self pollStop:deadline completion:completion];
            });
        });
    });
}
- (void)reset:(id)arguments result:(FlutterResult)result {
    if (!sb_can_initialize(sessionPhase, operationPending) || service) {
        result([self rejection:[SBPhase() isEqual:@"stopBlocked"] ? @"shellbox_stop_blocked" : @"shellbox_reset_active"]); return;
    }
    if (bootFailed || !ShellBoxInstalled()) { result([self rejection:@"shellbox_reset_unavailable"]); return; }
    id keep = [arguments isKindOfClass:NSDictionary.class] ? arguments[@"keep"] : nil;
    if (![keep isKindOfClass:NSArray.class]) { result([self rejection:@"shellbox_invalid_arguments"]); return; }
    for (id group in keep) if (![@[@"uiAndSkills", @"pluginsAndSettings"] containsObject:group]) {
        result([self rejection:@"shellbox_invalid_arguments"]); return;
    }
    // Traverse only /root, using lstat/scandir without following symlinks. Guest
    // unlink/rmdir update fakefs metadata. Keep ancestors are traversed, roots
    // retained in place. A failure can leave a partially cleared data tree.
    NSString *command = [NSString stringWithUTF8String:sb_reset_command(
        [keep containsObject:@"uiAndSkills"], [keep containsObject:@"pluginsAndSettings"])];
    // GNU find is present in the pinned payload; -delete reports partial failure.
    lastStart = nil;
    NSData *environment = ShellBoxEnvironment(@{});
    NSString *root = [[ShellBoxHome() URLByAppendingPathComponent:@"active/data"] path];
    if (backgroundSystemTask || backgroundRequestID)
        [self finishBackground:NO state:@"suspendedOrUnknown" cancelTask:NO];
    ++checkpointGeneration;
    [self endBackgroundGrace];
    backgroundTaskInfo = nil;
    checkpointDirty = NO;
    backgroundTaskVerified = NO;
    backgroundCancellationRequested = NO;
    [backgroundAttemptKeys removeAllObjects];
    runtimeInstanceID = NSUUID.UUID.UUIDString;
    transitionSource = @"runtime.reset";
    operationPending = YES; [self setPhase:SB_RESETTING];
    dispatch_async(kernelQueue, ^{
        int err = dsh_shellbox_boot(root.fileSystemRepresentation);
        if (!err) err = dsh_shellbox_launch(command.UTF8String, environment.bytes, ShellBoxOutput, &service);
        dispatch_async(dispatch_get_main_queue(), ^{
            operationPending = NO;
            if (err) { [self setPhase:SB_ERROR]; result([self unsupported:@"shellbox_reset_failed" message:@"Data reset failed; data may be partially cleared."]); }
            else [self awaitReset:(NSProcessInfo.processInfo.systemUptime + ShellBoxReadySeconds) result:result];
        });
    });
}
- (void)awaitReset:(NSTimeInterval)deadline result:(FlutterResult)result {
    if (dsh_shellbox_command_status() != -1) {
        int status = dsh_shellbox_command_status();
        [self setPhase:SB_RUNNING]; // internal cleanup path owns the same service handle
        [self stop:^(id reply) {
            if (reply) result(reply);
            else if (status != 0) { [self setPhase:SB_ERROR]; result([self unsupported:@"shellbox_reset_failed" message:@"Data reset failed; data may be partially cleared."]); }
            else { [self setPhase:sb_stop_result(true)]; result(nil); }
        }];
    } else if (NSProcessInfo.processInfo.systemUptime >= deadline) {
        [self setPhase:SB_RUNNING];
        [self stop:^(id reply) { result(reply ?: [self unsupported:@"shellbox_reset_failed" message:@"Data reset timed out; data may be partially cleared."]); }];
    } else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self awaitReset:deadline result:result]; });
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    NSAssert(NSThread.isMainThread, @"ShellBox channel requires the platform thread");
    NSDictionary *metadata = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
    if ([call.method isEqual:@"getBackgroundExecutionState"]) {
        result([self backgroundExecutionSnapshot]); return;
    }
    if ([call.method isEqual:@"getBackgroundCapabilities"]) {
        BOOL supported = NO;
        if (@available(iOS 26.0, *)) supported = YES;
        result(@{@"continuedProcessingOSSupported": @(supported),
            @"continuedProcessingEnabled": @(BackgroundEnabled()),
            @"reason": !supported ? @"requires_ios_26" : @"system_may_decline",
            @"backgroundGraceEnabled": @YES, @"permanentBackgroundExecution": @NO}); return;
    }
    if ([call.method isEqual:@"setBackgroundEnabled"]) {
        if (![metadata[@"enabled"] isKindOfClass:NSNumber.class]) {
            result([FlutterError errorWithCode:@"background_invalid_arguments" message:nil details:nil]); return;
        }
        [NSUserDefaults.standardUserDefaults setBool:[metadata[@"enabled"] boolValue] forKey:@"dsh.background.enabled"];
        if (!BackgroundEnabled()) [self finishBackground:NO state:@"suspendedOrUnknown" cancelTask:NO];
        result(nil); return;
    }
    if ([call.method isEqual:@"updateActiveTasks"]) {
        NSString *instance = metadata[@"runtimeInstanceId"];
        NSString *session = metadata[@"sessionId"], *taskID = metadata[@"taskId"], *status = metadata[@"status"];
        if (![instance isKindOfClass:NSString.class] || ![instance isEqual:runtimeInstanceID] ||
            ![session isKindOfClass:NSString.class] || !session.length || session.length > 256 ||
            ![taskID isKindOfClass:NSString.class] || !taskID.length || taskID.length > 256 ||
            ![@[@"running", @"waitingApproval", @"completed", @"error", @"unknown"] containsObject:status]) {
            result([FlutterError errorWithCode:@"background_stale_or_invalid_task" message:nil details:nil]); return;
        }
        NSDictionary *next = @{ @"runtimeInstanceId": instance, @"sessionId": session, @"taskId": taskID, @"status": status };
        BOOL same = [BackgroundKey(next) isEqual:BackgroundKey(backgroundTaskInfo)];
        if (backgroundTaskInfo && !same && ![@[@"running", @"waitingApproval"] containsObject:status]) {
            result([FlutterError errorWithCode:@"background_stale_or_invalid_task" message:nil details:nil]); return;
        }
        if (backgroundTaskInfo && !same && (backgroundSystemTask || backgroundRequestID)) {
            result([FlutterError errorWithCode:@"background_task_busy" message:nil details:nil]); return;
        }
        if (same && [backgroundTaskInfo isEqual:next] && backgroundTaskVerified) { result(nil); return; }
        if (!same) {
            backgroundCancellationRequested = NO;
            backgroundError = nil;
        }
        backgroundTaskInfo = next;
        backgroundTaskVerified = ![status isEqual:@"unknown"];
        if (!same) backgroundExecutionState = UIApplication.sharedApplication.applicationState == UIApplicationStateActive
            ? @"foreground" : @"suspendedOrUnknown";
        checkpointDirty = YES;
        if ([@[@"completed", @"error"] containsObject:status]) {
            if ([status isEqual:@"error"]) backgroundError = @"chat_task_failed";
            [self finishBackground:[status isEqual:@"completed"] state:status cancelTask:NO];
        } else if (![@"running" isEqual:status] && (backgroundSystemTask || backgroundRequestID)) {
            [self finishBackground:NO state:@"suspendedOrUnknown" cancelTask:NO];
        } else {
            [self publishBackground:backgroundExecutionState];
        }
        result(nil); return;
    }
    if ([call.method isEqual:@"requestContinuedProcessing"]) { result([self requestBackground]); return; }
    if ([call.method isEqual:@"cancelContinuedProcessing"]) {
        [self finishBackground:NO state:@"expired" cancelTask:YES]; result(nil); return;
    }
    if ([@[@"start", @"stop", @"restart", @"lifecycleRequest"] containsObject:call.method]) {
        NSString *source = metadata[@"source"];
        NSRegularExpression *tag = [NSRegularExpression regularExpressionWithPattern:@"^[a-zA-Z0-9_.]{1,64}$" options:0 error:nil];
        requestSource = [source isKindOfClass:NSString.class] &&
            [tag numberOfMatchesInString:source options:0 range:NSMakeRange(0, source.length)] ? source : @"runtime.direct";
    }
    if ([call.method isEqualToString:@"lifecycleRequest"]) {
        NSString *action = metadata[@"action"];
        [self recordLifecycle:[@[@"restart", @"ensureStarted"] containsObject:action] ?
            [action stringByAppendingString:@".request"] : @"control.request"]; result(nil);
    } else if ([call.method isEqualToString:@"appLifecycle"]) {
        NSString *event = metadata[@"event"];
        if ([@[@"paused", @"resumed", @"inactive", @"hidden", @"detached"] containsObject:event]) {
            flutterLifecycle = event; [self recordLifecycle:@"flutter.lifecycle"];
        }
        result([self statusMap]);
    } else if ([call.method isEqualToString:@"status"]) {
        result([self statusMap]);
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
        [runtimeOwner start:call.arguments result:result];
    } else if ([call.method isEqualToString:@"install"]) {
        if (!sb_can_initialize(sessionPhase, operationPending) || service) {
            result([self rejection:@"shellbox_busy"]); return;
        }
        transitionSource = @"runtime.install";
        shellBoxInstalling = YES; operationPending = YES;
        [self recordLifecycle:@"install.request"];
        [self recordLifecycle:@"transition"];
        lifecycleFailure = nil;
        [self recordSystemMessage:@"Verifying bundled payload and preparing guest filesystem."];
        dispatch_async(kernelQueue, ^{
            NSString *code = ShellBoxInstallPayload();
            dispatch_async(dispatch_get_main_queue(), ^{
                shellBoxInstalling = NO; operationPending = NO;
                if (code) result([self unsupported:code message:@"Guest installation failed; prior installation was retained."]);
                else { lifecycleFailure = nil; [self setPhase:SB_INSTALLED]; result(nil); }
            });
        });
    } else if ([call.method isEqualToString:@"stop"]) {
        [runtimeOwner stop:result];
    } else if ([call.method isEqualToString:@"restart"]) {
        [self recordLifecycle:@"restart.request"];
        if ([SBPhase() isEqual:@"stopBlocked"]) { result([self rejection:@"shellbox_stop_blocked"]); return; }
        [runtimeOwner stop:^(id reply) {
            if (reply) result(reply);
            else [runtimeOwner start:lastStart result:result];
        }];
    } else if ([call.method isEqualToString:@"reset"]) {
        [runtimeOwner reset:call.arguments result:result];
    } else {
        result(FlutterMethodNotImplemented);
    }
}

@end
