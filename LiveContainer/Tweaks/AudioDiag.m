//
//  AudioDiag.m
//  LiveContainer
//
//  容器內的 app 無法錄音（例如 LINE 的語音訊息），但拍照與錄影可用。麥克風
//  用途說明與背景音訊模式在主程式與 LiveProcess 的 Info.plist 中均已宣告，
//  因此問題不在權限宣告本身。
//
//  錄音是否成功取決於音訊工作階段的設定與啟用結果，這些呼叫的回傳值目前無從
//  得知。此處記錄相關呼叫的參數與錯誤，以便判斷是權限未授予、類別設定被拒、
//  工作階段無法啟用，或是其他原因。
//
//  僅記錄，不改變任何行為。
//
@import UIKit;
@import AVFoundation;
#import <objc/runtime.h>
#import "utils.h"
#import "Tweaks.h"
#import "LCSharedUtils.h"

// recordPermission 於較新的系統版本標示為過時，此處僅用於記錄現況，
// 沿用即可，抑制相關警告以免因警告視為錯誤而無法建置。
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static void audioLog(NSString* format, ...) {
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
    NSString* line = [NSString stringWithFormat:@"%@ %@\n", [fmt stringFromDate:[NSDate date]], message];
    FILE* f = fopen([dir stringByAppendingPathComponent:@"LCAudioDiag.log"].UTF8String, "a");
    if(!f) return;
    fputs(line.UTF8String, f);
    fclose(f);
}

#pragma mark - AVAudioSession

@interface AVAudioSession(LCAudioDiag)
@end

@implementation AVAudioSession(LCAudioDiag)

- (BOOL)lcAudio_setCategory:(AVAudioSessionCategory)category error:(NSError**)outError {
    BOOL ok = [self lcAudio_setCategory:category error:outError];
    audioLog(@"setCategory:%@ -> %d%@", category, (int)ok,
             (!ok && outError && *outError) ? [NSString stringWithFormat:@" 錯誤=%@", *outError] : @"");
    return ok;
}

- (BOOL)lcAudio_setCategory:(AVAudioSessionCategory)category
                       mode:(AVAudioSessionMode)mode
                    options:(AVAudioSessionCategoryOptions)options
                      error:(NSError**)outError {
    BOOL ok = [self lcAudio_setCategory:category mode:mode options:options error:outError];
    audioLog(@"setCategory:%@ mode:%@ options:%lu -> %d%@", category, mode, (unsigned long)options, (int)ok,
             (!ok && outError && *outError) ? [NSString stringWithFormat:@" 錯誤=%@", *outError] : @"");
    return ok;
}

- (BOOL)lcAudio_setActive:(BOOL)active error:(NSError**)outError {
    BOOL ok = [self lcAudio_setActive:active error:outError];
    audioLog(@"setActive:%d -> %d%@ | 類別=%@ 可錄音=%d 錄音權限=%ld",
             (int)active, (int)ok,
             (!ok && outError && *outError) ? [NSString stringWithFormat:@" 錯誤=%@", *outError] : @"",
             self.category, (int)self.isInputAvailable, (long)self.recordPermission);
    return ok;
}

@end

#pragma mark - AVAudioRecorder

@interface AVAudioRecorder(LCAudioDiag)
@end

@implementation AVAudioRecorder(LCAudioDiag)

- (BOOL)lcAudio_prepareToRecord {
    BOOL ok = [self lcAudio_prepareToRecord];
    audioLog(@"AVAudioRecorder prepareToRecord -> %d（檔案 %@）", (int)ok, self.url.lastPathComponent);
    return ok;
}

- (BOOL)lcAudio_record {
    BOOL ok = [self lcAudio_record];
    audioLog(@"AVAudioRecorder record -> %d（檔案 %@）", (int)ok, self.url.lastPathComponent);
    return ok;
}

@end

#pragma mark - 掛載

// 與 KeyboardRelayout 相同的安全做法：若該類別自身沒有實作，先以原名加上，
// 避免交換到父類別的實作而波及所有子類。
static void audioSafeSwizzle(Class cls, SEL originalSel, SEL replacementSel) {
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

void AudioDiagHookInit(void) {
    if(![[[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]]
         boolForKey:@"LCKeychainDiagnostics"]) return;

    Class sessionClass = AVAudioSession.class;
    audioSafeSwizzle(sessionClass, @selector(setCategory:error:), @selector(lcAudio_setCategory:error:));
    audioSafeSwizzle(sessionClass, @selector(setCategory:mode:options:error:), @selector(lcAudio_setCategory:mode:options:error:));
    audioSafeSwizzle(sessionClass, @selector(setActive:error:), @selector(lcAudio_setActive:error:));

    Class recorderClass = AVAudioRecorder.class;
    audioSafeSwizzle(recorderClass, @selector(prepareToRecord), @selector(lcAudio_prepareToRecord));
    audioSafeSwizzle(recorderClass, @selector(record), @selector(lcAudio_record));

    AVAudioSession* session = AVAudioSession.sharedInstance;
    audioLog(@"===== 音訊診斷已掛上 =====");
    audioLog(@"  目前類別=%@ 模式=%@ 可錄音=%d 錄音權限=%ld（0=未定 1=拒絕 2=允許）",
             session.category, session.mode, (int)session.isInputAvailable, (long)session.recordPermission);
    audioLog(@"  可用輸入裝置=%@", session.availableInputs ?: @"(無)");
}

#pragma clang diagnostic pop
