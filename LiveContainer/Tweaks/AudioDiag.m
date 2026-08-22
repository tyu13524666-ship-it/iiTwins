//
//  AudioDiag.m
//  LiveContainer
//
//  容器內的 app 無法錄音或錄影（皆停在 0 秒），但拍照可用。第一輪診斷已排除
//  下列可能：麥克風權限為已授權、音訊類別可設為 PlayAndRecord、工作階段可
//  成功啟用、系統回報有內建麥克風可用。實際失敗的是 AVAudioRecorder 的
//  record，它直接回傳 NO 而未提供任何錯誤。
//
//  後續以對照組確認：即使改在確定可寫的位置、用最單純的設定錄音，一樣被拒，
//  可見與寫入目的地無關，而是擴充功能取不到麥克風。對照組已完成任務並移除，
//  改由 AudioRelay 請主程式代錄。
//
//  此處僅記錄，不改變 app 的行為。
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
    }
    return ok;
}

@end

#pragma mark - 擷取工作階段（錄影）

// 錄影與錄音走的是兩條路：錄音用 AVAudioRecorder，錄影用相機的擷取工作階段。
// 拍照可用而錄影停在 0 秒，差別在於錄影要多接一個麥克風輸入，而擴充功能拿不到
// 麥克風。此處記錄輸入接得成不成、工作階段跑不跑得起來、以及錄製的結束原因，
// 以確定實際卡在哪一步。
@interface AVCaptureSession(LCAudioDiag)
@end

@implementation AVCaptureSession(LCAudioDiag)

- (BOOL)lcAudio_canAddInput:(AVCaptureInput*)input {
    BOOL ok = [self lcAudio_canAddInput:input];
    audioLog(@"擷取工作階段 canAddInput:%@ -> %d", input, (int)ok);
    return ok;
}

- (void)lcAudio_addInput:(AVCaptureInput*)input {
    [self lcAudio_addInput:input];
    NSString* kind = @"其他";
    if([input isKindOfClass:AVCaptureDeviceInput.class]) {
        AVCaptureDevice* device = [(AVCaptureDeviceInput *)input device];
        kind = [device hasMediaType:AVMediaTypeAudio] ? @"麥克風" : @"相機";
    }
    audioLog(@"擷取工作階段 addInput（%@）-> 目前輸入共 %lu 項", kind, (unsigned long)self.inputs.count);
}

- (void)lcAudio_startRunning {
    [self lcAudio_startRunning];
    audioLog(@"擷取工作階段 startRunning -> 執行中=%d 輸入 %lu 項 輸出 %lu 項",
             (int)self.isRunning, (unsigned long)self.inputs.count, (unsigned long)self.outputs.count);
    for(AVCaptureOutput* output in self.outputs) {
        audioLog(@"  輸出：%@", NSStringFromClass(output.class));
    }
}

@end

@interface AVCaptureMovieFileOutput(LCAudioDiag)
@end

@implementation AVCaptureMovieFileOutput(LCAudioDiag)

- (void)lcAudio_startRecordingToOutputFileURL:(NSURL*)url
                             recordingDelegate:(id<AVCaptureFileOutputRecordingDelegate>)delegate {
    audioLog(@"開始錄影 -> %@", url.lastPathComponent);
    audioLog(@"  目的地目錄 %@", describeDirectory(url));
    [self lcAudio_startRecordingToOutputFileURL:url recordingDelegate:delegate];
    audioLog(@"  錄製中=%d", (int)self.isRecording);
}

- (void)lcAudio_stopRecording {
    audioLog(@"停止錄影（已錄 %.2f 秒）", CMTimeGetSeconds(self.recordedDuration));
    [self lcAudio_stopRecording];
}

@end

// 擷取工作階段出錯時系統只發通知，不會有回傳值可看，因此另外聽一則。
static void observeCaptureErrors(void) {
    [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionRuntimeErrorNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification* note) {
        audioLog(@"擷取工作階段發生錯誤：%@", note.userInfo[AVCaptureSessionErrorKey]);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionWasInterruptedNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification* note) {
        audioLog(@"擷取工作階段被中斷，原因代碼=%@", note.userInfo[AVCaptureSessionInterruptionReasonKey]);
    }];
}

#pragma mark - 取得擷取裝置

// 實測顯示 app 錄影時只接了相機，從未詢問能否加上麥克風，也沒有用系統標準的
// 錄影輸出。那表示它在更早的一步就放棄了 —— 很可能是跟系統要麥克風裝置時
// 拿到空的。此處記錄要裝置與建立輸入的結果，確認是否如此。
@interface AVCaptureDevice(LCAudioDiag)
@end

@implementation AVCaptureDevice(LCAudioDiag)

+ (AVCaptureDevice*)lcAudio_defaultDeviceWithMediaType:(AVMediaType)mediaType {
    AVCaptureDevice* device = [self lcAudio_defaultDeviceWithMediaType:mediaType];
    audioLog(@"要求預設擷取裝置（%@）-> %@", mediaType, device.localizedName ?: @"(沒有)");
    return device;
}

+ (NSArray<AVCaptureDevice*>*)lcAudio_devicesWithMediaType:(AVMediaType)mediaType {
    NSArray* devices = [self lcAudio_devicesWithMediaType:mediaType];
    audioLog(@"列出擷取裝置（%@）-> %lu 項", mediaType, (unsigned long)devices.count);
    return devices;
}

@end

@interface AVCaptureDeviceInput(LCAudioDiag)
@end

@implementation AVCaptureDeviceInput(LCAudioDiag)

+ (instancetype)lcAudio_deviceInputWithDevice:(AVCaptureDevice*)device error:(NSError**)outError {
    id input = [self lcAudio_deviceInputWithDevice:device error:outError];
    audioLog(@"建立擷取輸入（%@）-> %@%@", device.localizedName ?: @"(空裝置)",
             input ? @"成功" : @"失敗",
             (!input && outError && *outError) ? [NSString stringWithFormat:@" 錯誤=%@", *outError] : @"");
    return input;
}

@end

// 探索工作階段是較新的取得方式，app 可能改用它而非上面那兩個。
@interface AVCaptureDeviceDiscoverySession(LCAudioDiag)
@end

@implementation AVCaptureDeviceDiscoverySession(LCAudioDiag)

+ (instancetype)lcAudio_discoverySessionWithDeviceTypes:(NSArray*)deviceTypes
                                              mediaType:(AVMediaType)mediaType
                                               position:(AVCaptureDevicePosition)position {
    id session = [self lcAudio_discoverySessionWithDeviceTypes:deviceTypes
                                                    mediaType:mediaType
                                                     position:position];
    audioLog(@"探索擷取裝置（%@）-> %lu 項", mediaType ?: @"未指定",
             (unsigned long)[[session devices] count]);
    return session;
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

    Class captureSession = AVCaptureSession.class;
    audioSafeSwizzle(captureSession, @selector(canAddInput:), @selector(lcAudio_canAddInput:));
    audioSafeSwizzle(captureSession, @selector(addInput:), @selector(lcAudio_addInput:));
    audioSafeSwizzle(captureSession, @selector(startRunning), @selector(lcAudio_startRunning));

    audioSafeSwizzle(object_getClass(AVCaptureDevice.class),
                     @selector(defaultDeviceWithMediaType:), @selector(lcAudio_defaultDeviceWithMediaType:));
    audioSafeSwizzle(object_getClass(AVCaptureDevice.class),
                     @selector(devicesWithMediaType:), @selector(lcAudio_devicesWithMediaType:));
    audioSafeSwizzle(object_getClass(AVCaptureDeviceInput.class),
                     @selector(deviceInputWithDevice:error:), @selector(lcAudio_deviceInputWithDevice:error:));
    audioSafeSwizzle(object_getClass(AVCaptureDeviceDiscoverySession.class),
                     @selector(discoverySessionWithDeviceTypes:mediaType:position:),
                     @selector(lcAudio_discoverySessionWithDeviceTypes:mediaType:position:));

    Class movieOutput = AVCaptureMovieFileOutput.class;
    audioSafeSwizzle(movieOutput, @selector(startRecordingToOutputFileURL:recordingDelegate:),
                     @selector(lcAudio_startRecordingToOutputFileURL:recordingDelegate:));
    audioSafeSwizzle(movieOutput, @selector(stopRecording), @selector(lcAudio_stopRecording));

    observeCaptureErrors();

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
