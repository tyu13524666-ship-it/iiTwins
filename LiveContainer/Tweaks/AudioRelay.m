//
//  AudioRelay.m
//  LiveContainer
//
//  多工模式下 app 跑在擴充功能中，系統不給麥克風：診斷顯示音訊類別設得起來、
//  工作階段啟用得了、權限也顯示已授權，連在確定可寫的位置錄音都一樣被拒，
//  且不附任何錯誤。主程式本身不受此限（設定頁的自測可證），因此在錄音被拒時
//  改請主程式代錄，錄完把成品放回 app 原本要寫入的位置。
//
//  只在原本就會失敗的情況介入：record 先照常呼叫，成功就完全不經過此處。
//
@import UIKit;
@import AVFoundation;
#import <objc/runtime.h>
#import "utils.h"
#import "Tweaks.h"
#import "LCSharedUtils.h"

// 與主程式端共用的通知名稱與檔案配置，兩邊必須一致。
static NSString* const kStartNotification = @"com.tyu.iitwins.audio.start";
static NSString* const kStopNotification  = @"com.tyu.iitwins.audio.stop";

static const void* kRelayStateKey = &kRelayStateKey;

#pragma mark - 每個錄音器的代理狀態

@interface LCRelayState : NSObject
@property(nonatomic) BOOL active;
@property(nonatomic, strong) NSDate* startedAt;
@property(nonatomic) float averagePower;
@property(nonatomic) float peakPower;
// 每次代錄各有識別碼，成品與狀態都以它命名，同時有多個錄音器時才不會互相覆蓋。
@property(nonatomic, copy) NSString* sessionID;
// app 可能在停止之後才詢問長度，屆時已無從計算，因此先留下來。
@property(nonatomic) NSTimeInterval lastDuration;
@end

@implementation LCRelayState
@end

static LCRelayState* relayStateFor(id recorder, BOOL create) {
    LCRelayState* state = objc_getAssociatedObject(recorder, kRelayStateKey);
    if(!state && create) {
        state = [LCRelayState new];
        objc_setAssociatedObject(recorder, kRelayStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

#pragma mark - 共享區

static NSString* relayPath(NSString* name) {
    NSURL* group = [LCSharedUtils appGroupPath];
    if(!group) return nil;
    NSString* dir = [group.path stringByAppendingPathComponent:@"AudioRelay"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
    return [dir stringByAppendingPathComponent:name];
}

static NSDictionary* readRelayState(NSString* sessionID) {
    NSString* path = relayPath([NSString stringWithFormat:@"state_%@.plist", sessionID]);
    if(!path) return nil;
    return [NSDictionary dictionaryWithContentsOfURL:[NSURL fileURLWithPath:path]];
}

static BOOL relayDisabled(void) {
    return [[[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]]
            boolForKey:@"LCDisableAudioRelay"];
}

static void relayLog(NSString* format, ...) {
    if(![[[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]]
         boolForKey:@"LCKeychainDiagnostics"]) return;

    va_list args;
    va_start(args, format);
    NSString* message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    const char* home = getenv("HOME");
    if(!home) return;
    NSString* dir = [[NSString stringWithUTF8String:home] stringByAppendingPathComponent:@"Documents"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    static NSDateFormatter* fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString* line = [NSString stringWithFormat:@"%@ [代錄] %@\n", [fmt stringFromDate:[NSDate date]], message];
    FILE* f = fopen([dir stringByAppendingPathComponent:@"LCAudioDiag.log"].UTF8String, "a");
    if(!f) return;
    fputs(line.UTF8String, f);
    fclose(f);
}

#pragma mark - AVAudioRecorder

@interface AVAudioRecorder(LCAudioRelay)
@end

@implementation AVAudioRecorder(LCAudioRelay)

- (BOOL)lcRelay_record {
    if([self lcRelay_record]) return YES;
    if(relayDisabled()) return NO;

    // 把識別碼與格式設定交給主程式，讓成品盡量貼近 app 的預期。
    NSString* sessionID = [[NSUUID UUID] UUIDString];
    NSString* requestPath = relayPath(@"request.plist");
    if(!requestPath) return NO;
    NSDictionary* request = @{
        @"sessionID": sessionID,
        @"settings": self.settings ?: @{},
    };
    if(![request writeToURL:[NSURL fileURLWithPath:requestPath] error:nil]) return NO;

    LCRelayState* state = relayStateFor(self, YES);
    state.active = YES;
    state.sessionID = sessionID;
    state.startedAt = [NSDate date];
    state.averagePower = -160.0f;
    state.peakPower = -160.0f;

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kStartNotification, NULL, NULL, YES);
    relayLog(@"錄音被系統拒絕，已請主程式代錄（%@）", self.url.lastPathComponent);
    return YES;
}

- (void)lcRelay_stop {
    LCRelayState* state = relayStateFor(self, NO);
    if(!state.active) {
        [self lcRelay_stop];
        return;
    }
    state.active = NO;
    state.lastDuration = [[NSDate date] timeIntervalSinceDate:state.startedAt];
    NSString* sessionID = state.sessionID;

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kStopNotification, NULL, NULL, YES);

    // 等主程式收尾。錄音檔通常在數十毫秒內寫好，這裡最多等一秒半；
    // 期間必須讓執行緒短暫讓出，否則同一輪迴圈內收不到對方的寫入結果。
    NSDictionary* relayState = nil;
    for(int i = 0; i < 150; i++) {
        relayState = readRelayState(sessionID);
        if([relayState[@"state"] isEqualToString:@"done"] ||
           [relayState[@"state"] isEqualToString:@"failed"]) break;
        [NSThread sleepForTimeInterval:0.01];
    }

    NSString* outputPath = relayPath([NSString stringWithFormat:@"out_%@.m4a", sessionID]);
    NSString* statePath = relayPath([NSString stringWithFormat:@"state_%@.plist", sessionID]);
    if(![relayState[@"state"] isEqualToString:@"done"] ||
       ![NSFileManager.defaultManager fileExistsAtPath:outputPath]) {
        relayLog(@"主程式未能完成錄音：%@（app 端按住 %.2f 秒）",
                 relayState[@"error"] ?: relayState[@"state"] ?: @"逾時", state.lastDuration);
        [NSFileManager.defaultManager removeItemAtPath:statePath error:nil];
        [self lcRelay_notifyFinished:NO];
        return;
    }

    NSError* error = nil;
    [NSFileManager.defaultManager removeItemAtURL:self.url error:nil];
    BOOL moved = [NSFileManager.defaultManager copyItemAtPath:outputPath toPath:self.url.path error:&error];

    // 成品與狀態都以識別碼命名，取走後隨即清掉，避免在共用區持續堆積。
    [NSFileManager.defaultManager removeItemAtPath:outputPath error:nil];
    [NSFileManager.defaultManager removeItemAtPath:statePath error:nil];

    if(!moved) {
        relayLog(@"成品搬回失敗：%@", error.localizedDescription);
        [self lcRelay_notifyFinished:NO];
        return;
    }

    relayLog(@"代錄完成，已放回 %@（%@ 位元組，主程式錄了 %@ 秒，app 端按住 %.2f 秒）",
             self.url.lastPathComponent, relayState[@"size"], relayState[@"duration"], state.lastDuration);
    [self lcRelay_notifyFinished:YES];
}

// 結束通知是選擇性實作的，未實作時直接呼叫會當掉。
- (void)lcRelay_notifyFinished:(BOOL)success {
    id<AVAudioRecorderDelegate> delegate = self.delegate;
    if([delegate respondsToSelector:@selector(audioRecorderDidFinishRecording:successfully:)]) {
        [delegate audioRecorderDidFinishRecording:self successfully:success];
    }
}

- (BOOL)lcRelay_isRecording {
    LCRelayState* state = relayStateFor(self, NO);
    return state.active ? YES : [self lcRelay_isRecording];
}

- (NSTimeInterval)lcRelay_currentTime {
    LCRelayState* state = relayStateFor(self, NO);
    if(state.active) return [[NSDate date] timeIntervalSinceDate:state.startedAt];
    if(state.lastDuration > 0) return state.lastDuration;
    return [self lcRelay_currentTime];
}

- (void)lcRelay_updateMeters {
    LCRelayState* state = relayStateFor(self, NO);
    if(!state.active) {
        [self lcRelay_updateMeters];
        return;
    }
    NSDictionary* relayState = readRelayState(state.sessionID);
    NSNumber* average = relayState[@"averagePower"];
    NSNumber* peak = relayState[@"peakPower"];
    if(average) state.averagePower = average.floatValue;
    if(peak) state.peakPower = peak.floatValue;
}

- (float)lcRelay_averagePowerForChannel:(NSUInteger)channel {
    LCRelayState* state = relayStateFor(self, NO);
    return state.active ? state.averagePower : [self lcRelay_averagePowerForChannel:channel];
}

- (float)lcRelay_peakPowerForChannel:(NSUInteger)channel {
    LCRelayState* state = relayStateFor(self, NO);
    return state.active ? state.peakPower : [self lcRelay_peakPowerForChannel:channel];
}

@end

#pragma mark - 掛載

// 與其他 hook 相同的安全做法：該類別自身沒有實作時先以原名加上，
// 避免交換到父類別的實作而波及所有子類。
static void relaySafeSwizzle(Class cls, SEL originalSel, SEL replacementSel) {
    if(!cls) return;
    Method original = class_getInstanceMethod(cls, originalSel);
    Method replacement = class_getInstanceMethod(cls, replacementSel);
    if(!original || !replacement) return;

    if(class_addMethod(cls, originalSel,
                       method_getImplementation(replacement),
                       method_getTypeEncoding(replacement))) {
        class_replaceMethod(cls, replacementSel,
                            method_getImplementation(original),
                            method_getTypeEncoding(original));
    } else {
        method_exchangeImplementations(original, replacement);
    }
}

void AudioRelayHookInit(void) {
    // 掛載本身即受開關控制。若只在動作發生時才檢查，一旦掛載方式有誤便無從
    // 關閉，使用者只能眼看 app 反覆出錯。
    if(relayDisabled()) return;

    Class cls = AVAudioRecorder.class;
    relaySafeSwizzle(cls, @selector(record), @selector(lcRelay_record));
    relaySafeSwizzle(cls, @selector(stop), @selector(lcRelay_stop));
    relaySafeSwizzle(cls, @selector(isRecording), @selector(lcRelay_isRecording));
    relaySafeSwizzle(cls, @selector(currentTime), @selector(lcRelay_currentTime));
    relaySafeSwizzle(cls, @selector(updateMeters), @selector(lcRelay_updateMeters));
    relaySafeSwizzle(cls, @selector(averagePowerForChannel:), @selector(lcRelay_averagePowerForChannel:));
    relaySafeSwizzle(cls, @selector(peakPowerForChannel:), @selector(lcRelay_peakPowerForChannel:));

    relayLog(@"===== 錄音代理已掛上 =====");
}
