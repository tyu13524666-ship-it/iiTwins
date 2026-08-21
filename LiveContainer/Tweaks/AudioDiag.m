//
//  AudioDiag.m
//  LiveContainer
//
//  容器內的 app 無法錄音或錄影（皆停在 0 秒），但拍照可用。第一輪診斷已排除
//  下列可能：麥克風權限為已授權、音訊類別可設為 PlayAndRecord、工作階段可
//  成功啟用、系統回報有內建麥克風可用。實際失敗的是 AVAudioRecorder 的
//  record，它直接回傳 NO 而未提供任何錯誤。
//
//  record 回傳 NO 只有兩種來源：寫入目的地不可用，或系統不允許此進程取得
//  麥克風輸入。多工模式下 app 跑在 extension 中，後者確有可能。此處在 app
//  自己的錄音失敗當下，立即以確定可寫的位置自行錄一次作為對照，藉此分辨兩者。
//
//  僅記錄與自測，不改變 app 的行為。
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

// 錄音權限與擷取授權都以四字元碼表示，直接印出數值無從辨識，轉成文字。
static NSString* permissionName(NSInteger value) {
    switch(value) {
        case AVAudioSessionRecordPermissionUndetermined: return @"未詢問";
        case AVAudioSessionRecordPermissionDenied:       return @"已拒絕";
        case AVAudioSessionRecordPermissionGranted:      return @"已授權";
        default: return [NSString stringWithFormat:@"不明(%ld)", (long)value];
    }
}

static NSString* authorizationName(AVAuthorizationStatus status) {
    switch(status) {
        case AVAuthorizationStatusNotDetermined: return @"未詢問";
        case AVAuthorizationStatusRestricted:    return @"受限制";
        case AVAuthorizationStatusDenied:        return @"已拒絕";
        case AVAuthorizationStatusAuthorized:    return @"已授權";
        default: return [NSString stringWithFormat:@"不明(%ld)", (long)status];
    }
}

static NSString* describeDirectory(NSURL* url) {
    NSString* dir = url.URLByDeletingLastPathComponent.path;
    if(!dir) return @"(無路徑)";
    NSFileManager* fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    BOOL exists = [fm fileExistsAtPath:dir isDirectory:&isDir];
    return [NSString stringWithFormat:@"%@（存在=%d 是目錄=%d 可寫=%d）",
            dir, (int)exists, (int)isDir, (int)[fm isWritableFileAtPath:dir]];
}

#pragma mark - 對照組自測

// 在 app 錄音失敗的同一刻，以同樣的方式寫到確定可寫的位置。若這裡也失敗，
// 表示此進程根本取不到麥克風輸入；若成功，則問題出在 app 選用的寫入位置。
static void audioSelfTest(void) {
    // 自測本身會呼叫 record，失敗時會再繞回這裡。此處不能用 dispatch_once，
    // 那會在同一執行緒重入時卡死；改用單純的旗標，在呼叫前就先立起來。
    static BOOL done = NO;
    if(done) return;
    done = YES;

    @autoreleasepool {
        const char* home = getenv("HOME");
        if(!home) return;
        NSString* dir = [[NSString stringWithUTF8String:home] stringByAppendingPathComponent:@"Documents"];
        NSURL* url = [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:@"lc_audio_selftest.m4a"]];
        [NSFileManager.defaultManager removeItemAtURL:url error:nil];

        NSDictionary* settings = @{
            AVFormatIDKey:            @(kAudioFormatMPEG4AAC),
            AVSampleRateKey:          @44100.0,
            AVNumberOfChannelsKey:    @1,
            AVEncoderAudioQualityKey: @(AVAudioQualityMedium),
        };
        NSError* error = nil;
        AVAudioRecorder* recorder = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:&error];
        if(!recorder) {
            audioLog(@"[自測] 無法建立錄音器：%@", error);
            return;
        }
        BOOL prepared = [recorder prepareToRecord];
        BOOL started = [recorder record];
        audioLog(@"[自測] 寫入自己的 Documents：prepare=%d record=%d", (int)prepared, (int)started);
        if(!started) {
            audioLog(@"[自測] 連確定可寫的位置都無法開始錄音，問題不在寫入路徑");
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [recorder stop];
            NSNumber* size = nil;
            [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
            audioLog(@"[自測] 錄 1.2 秒後停止，檔案大小=%@ 位元組（數千以上才是真的收到聲音）", size ?: @"(讀不到)");
        });
    }
}

#pragma mark - AVAudioSession

// 取得目前實際接上的輸入來源描述；沒有任何輸入正是「取不到麥克風」的樣子。
static NSString* session_inputsDescription(AVAudioSession* session) {
    NSArray* inputs = session.currentRoute.inputs;
    return inputs.count ? [inputs description] : @"(沒有任何輸入來源)";
}


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
    audioLog(@"setActive:%d -> %d%@ | 類別=%@ 可錄音=%d 錄音權限=%@",
             (int)active, (int)ok,
             (!ok && outError && *outError) ? [NSString stringWithFormat:@" 錯誤=%@", *outError] : @"",
             self.category, (int)self.isInputAvailable, permissionName(self.recordPermission));
    if(active && ok) {
        audioLog(@"  目前輸入來源=%@", session_inputsDescription(self));
    }
    return ok;
}

@end

#pragma mark - AVAudioRecorder

@interface AVAudioRecorder(LCAudioDiag)
@end

@implementation AVAudioRecorder(LCAudioDiag)

- (instancetype)lcAudio_initWithURL:(NSURL*)url settings:(NSDictionary*)settings error:(NSError**)outError {
    id result = [self lcAudio_initWithURL:url settings:settings error:outError];
    audioLog(@"建立錄音器 -> %@ 檔案=%@", result ? @"成功" : @"失敗", url.path);
    audioLog(@"  目的地目錄 %@", describeDirectory(url));
    audioLog(@"  格式設定=%@", settings);
    if(!result && outError && *outError) audioLog(@"  錯誤=%@", *outError);
    return result;
}

- (BOOL)lcAudio_prepareToRecord {
    BOOL ok = [self lcAudio_prepareToRecord];
    audioLog(@"prepareToRecord -> %d（檔案 %@）", (int)ok, self.url.lastPathComponent);
    if(!ok) audioLog(@"  目的地目錄 %@", describeDirectory(self.url));
    return ok;
}

- (BOOL)lcAudio_record {
    BOOL ok = [self lcAudio_record];
    audioLog(@"record -> %d（檔案 %@）", (int)ok, self.url.lastPathComponent);
    if(!ok) {
        AVAudioSession* session = AVAudioSession.sharedInstance;
        audioLog(@"  失敗當下：類別=%@ 模式=%@ 可錄音=%d 權限=%@",
                 session.category, session.mode, (int)session.isInputAvailable,
                 permissionName(session.recordPermission));
        audioLog(@"  輸入來源=%@", session_inputsDescription(session));
        audioLog(@"  麥克風擷取授權=%@",
                 authorizationName([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]));
        audioLog(@"  目的地目錄 %@", describeDirectory(self.url));
        audioSelfTest();
    }
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
    audioSafeSwizzle(recorderClass, @selector(initWithURL:settings:error:), @selector(lcAudio_initWithURL:settings:error:));
    audioSafeSwizzle(recorderClass, @selector(prepareToRecord), @selector(lcAudio_prepareToRecord));
    audioSafeSwizzle(recorderClass, @selector(record), @selector(lcAudio_record));

    AVAudioSession* session = AVAudioSession.sharedInstance;
    audioLog(@"===== 音訊診斷已掛上 =====");
    audioLog(@"  目前類別=%@ 模式=%@ 可錄音=%d 錄音權限=%@",
             session.category, session.mode, (int)session.isInputAvailable,
             permissionName(session.recordPermission));
    audioLog(@"  麥克風擷取授權=%@ 相機擷取授權=%@",
             authorizationName([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]),
             authorizationName([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]));
    audioLog(@"  可用輸入裝置=%@", session.availableInputs ?: @"(無)");
}

#pragma clang diagnostic pop
