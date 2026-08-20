//
//  SecItem.m
//  LiveContainer
//
//  Created by s s on 2024/11/29.
//
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import "utils.h"
#import <CommonCrypto/CommonDigest.h>
#import "../../litehook/src/litehook.h"
#import "LCSharedUtils.h"

extern void* (*msHookFunction)(void *symbol, void *hook, void **old);
OSStatus (*orig_SecItemAdd)(CFDictionaryRef attributes, CFTypeRef *result) = SecItemAdd;
OSStatus (*orig_SecItemCopyMatching)(CFDictionaryRef query, CFTypeRef *result) = SecItemCopyMatching;
OSStatus (*orig_SecItemUpdate)(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) = SecItemUpdate;
OSStatus (*orig_SecItemDelete)(CFDictionaryRef query) = SecItemDelete;
SecKeyRef (*orig_SecKeyCreateRandomKey)(CFDictionaryRef parameters, CFErrorRef *error) = SecKeyCreateRandomKey;
SecKeyRef (*orig_SecKeyCreateWithData)(CFDataRef keyData, CFDictionaryRef parameters, CFErrorRef *error) = SecKeyCreateWithData;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
OSStatus (*orig_SecKeyGeneratePair)(CFDictionaryRef query, SecKeyRef *publicKey, SecKeyRef *privateKey) = SecKeyGeneratePair;
#pragma clang diagnostic pop
NSString* accessGroup = nil;
NSString* containerId = nil;

#pragma mark - Keychain 診斷記錄

// 用途：診斷 guest app 的加密功能失效（例如 LINE 26.x 在容器內加密 UserDefaults
// 初始化失敗）。記錄每次 keychain / 金鑰操作的回傳碼與查詢條件，讓失敗的確切
// 原因（缺 entitlement？項目不存在？Secure Enclave 綁定？）能被看見。
//
// 由 LCKeychainDiagnostics 開關控制，預設關閉；開啟後不論 keychain 隔離是否
// 啟用都會記錄，因為隔離關閉時原本完全不掛 hook，那正是需要觀察的情境之一。
//
// 隱私：只記錄識別用的中繼資料（class / service / account / access group /
// 是否 Secure Enclave），絕不記錄 kSecValueData 等實際金鑰或密碼內容。

static BOOL gDiagEnabled = NO;
static NSString* gDiagLogPath = nil;

// 直接用數值比對，避免不同 SDK 版本對某些 errSec 常數的可見性差異造成編譯失敗
static NSString* diagStatusName(OSStatus s) {
    switch((int)s) {
        case 0:      return @"errSecSuccess";
        case -25300: return @"errSecItemNotFound(找不到項目)";
        case -25299: return @"errSecDuplicateItem(項目已存在)";
        case -34018: return @"errSecMissingEntitlement(缺少權限)";
        case -25308: return @"errSecInteractionNotAllowed(裝置鎖定中不可存取)";
        case -25291: return @"errSecNotAvailable(keychain 不可用)";
        case -50:    return @"errSecParam(參數不支援)";
        case -26275: return @"errSecDecode(解碼失敗)";
        case -25293: return @"errSecAuthFailed(驗證失敗)";
        case -25243: return @"errSecNoAccessForItem(無權存取)";
        case -25304: return @"errSecInvalidItemRef";
        case -4:     return @"errSecUnimplemented";
        default:     return @"";
    }
}

// 把查詢字典整理成一行安全摘要。只取識別用欄位，實際資料一律不碰。
static NSString* diagDescribeQuery(CFDictionaryRef dict) {
    if(!dict) return @"(null)";
    NSDictionary* d = (__bridge NSDictionary *)dict;
    NSMutableArray<NSString*>* parts = [NSMutableArray array];

    id cls = d[(__bridge id)kSecClass];
    if(cls) [parts addObject:[NSString stringWithFormat:@"class=%@", cls]];

    NSArray* shownKeys = @[(__bridge id)kSecAttrService,
                           (__bridge id)kSecAttrAccount,
                           (__bridge id)kSecAttrLabel,
                           (__bridge id)kSecAttrApplicationTag,
                           (__bridge id)kSecAttrAccessGroup,
                           (__bridge id)kSecAttrAccessible,
                           (__bridge id)kSecAttrKeyType,
                           (__bridge id)kSecAttrTokenID];
    for(id key in shownKeys) {
        id v = d[key];
        if(!v) continue;
        NSString* shown;
        if([v isKindOfClass:[NSData class]]) {
            shown = [NSString stringWithFormat:@"<data %lu bytes>", (unsigned long)((NSData*)v).length];
        } else {
            shown = [NSString stringWithFormat:@"%@", v];
            if(shown.length > 80) shown = [[shown substringToIndex:80] stringByAppendingString:@"..."];
        }
        [parts addObject:[NSString stringWithFormat:@"%@=%@", key, shown]];
    }

    // Secure Enclave 是最關鍵的懷疑對象，單獨標出來
    id tokenID = d[(__bridge id)kSecAttrTokenID];
    if(tokenID && [tokenID isEqual:(__bridge id)kSecAttrTokenIDSecureEnclave]) {
        [parts addObject:@"*** SECURE_ENCLAVE ***"];
    }
    if(d[(__bridge id)kSecAttrAccessControl]) {
        [parts addObject:@"hasAccessControl=YES"];
    }
    if(d[(__bridge id)kSecUseAuthenticationContext]) {
        [parts addObject:@"hasLAContext=YES"];
    }
    if(d[(__bridge id)kSecAttrSynchronizable]) {
        [parts addObject:[NSString stringWithFormat:@"sync=%@", d[(__bridge id)kSecAttrSynchronizable]]];
    }
    return [parts componentsJoinedByString:@" "];
}

static void diagWrite(NSString* line) {
    if(!gDiagEnabled || !gDiagLogPath) return;
    static dispatch_once_t onceToken;
    static NSDateFormatter* fmt = nil;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss.SSS";
    });
    NSString* full = [NSString stringWithFormat:@"%@ %@\n", [fmt stringFromDate:[NSDate date]], line];
    // 每次開關檔案，確保即使 app 被強制結束，已寫的內容也不會遺失
    FILE* f = fopen(gDiagLogPath.UTF8String, "a");
    if(!f) return;
    fputs(full.UTF8String, f);
    fclose(f);
}

static void diagLogStatus(NSString* api, CFDictionaryRef query, OSStatus status, BOOL redirected) {
    if(!gDiagEnabled) return;
    diagWrite([NSString stringWithFormat:@"%@ -> %d %@ %@| %@",
               api, (int)status, diagStatusName(status),
               redirected ? @"[已改寫accessGroup] " : @"",
               diagDescribeQuery(query)]);
}

static void diagLogKey(NSString* api, CFDictionaryRef params, BOOL success, CFErrorRef error, BOOL redirected) {
    if(!gDiagEnabled) return;
    NSString* errDesc = @"";
    if(!success && error) {
        NSError* e = (__bridge NSError *)error;
        errDesc = [NSString stringWithFormat:@" error=%@(%ld) %@", e.domain, (long)e.code, e.localizedDescription];
    }
    diagWrite([NSString stringWithFormat:@"%@ -> %@%@ %@| %@",
               api, success ? @"OK" : @"FAILED", errDesc,
               redirected ? @"[已改寫accessGroup] " : @"",
               diagDescribeQuery(params)]);
}

#pragma mark - 隔離 hook（會改寫 access group）

OSStatus new_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    NSMutableDictionary *attributesCopy = ((__bridge NSDictionary *)attributes).mutableCopy;
    attributesCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    // for keychain deletion in LCUI
    attributesCopy[@"alis"] = containerId;

    OSStatus status = orig_SecItemAdd((__bridge CFDictionaryRef)attributesCopy, result);
    if(status == errSecParam) {
        status = orig_SecItemAdd(attributes, result);
        diagLogStatus(@"SecItemAdd", attributes, status, NO);
        return status;
    }

    diagLogStatus(@"SecItemAdd", attributes, status, YES);
    return status;
}

OSStatus new_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSMutableDictionary *queryCopy = ((__bridge NSDictionary *)query).mutableCopy;
    queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    OSStatus status = orig_SecItemCopyMatching((__bridge CFDictionaryRef)queryCopy, result);
    if(status == errSecParam) {
        // if this search don't support kSecAttrAccessGroup, we just use the original search
        status = orig_SecItemCopyMatching(query, result);
        diagLogStatus(@"SecItemCopyMatching", query, status, NO);
        return status;
    }

    diagLogStatus(@"SecItemCopyMatching", query, status, YES);
    return status;
}

OSStatus new_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSMutableDictionary *queryCopy = ((__bridge NSDictionary *)query).mutableCopy;
    queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;

    NSMutableDictionary *attrCopy = ((__bridge NSDictionary *)attributesToUpdate).mutableCopy;
    attrCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;

    OSStatus status = orig_SecItemUpdate((__bridge CFDictionaryRef)queryCopy, (__bridge CFDictionaryRef)attrCopy);

    if(status == errSecParam) {
        status = orig_SecItemUpdate(query, attributesToUpdate);
        diagLogStatus(@"SecItemUpdate", query, status, NO);
        return status;
    }

    diagLogStatus(@"SecItemUpdate", query, status, YES);
    return status;
}

OSStatus new_SecItemDelete(CFDictionaryRef query){
    NSMutableDictionary *queryCopy = ((__bridge NSDictionary *)query).mutableCopy;
    queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    OSStatus status = orig_SecItemDelete((__bridge CFDictionaryRef)queryCopy);
    if(status == errSecParam) {
        status = orig_SecItemDelete(query);
        diagLogStatus(@"SecItemDelete", query, status, NO);
        return status;
    }

    diagLogStatus(@"SecItemDelete", query, status, YES);
    return status;
}

SecKeyRef new_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    NSMutableDictionary *paramsCopy = ((__bridge NSDictionary *)parameters).mutableCopy;
    paramsCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    SecKeyRef key = orig_SecKeyCreateRandomKey((__bridge CFDictionaryRef)paramsCopy, error);
    if(!key && error && *error) {
        diagLogKey(@"SecKeyCreateRandomKey(改寫後)", parameters, NO, *error, YES);
        CFRelease(*error);
        *error = NULL;
        key = orig_SecKeyCreateRandomKey(parameters, error);
        diagLogKey(@"SecKeyCreateRandomKey(退回原始)", parameters, key != NULL, (error ? *error : NULL), NO);
        return key;
    }

    diagLogKey(@"SecKeyCreateRandomKey", parameters, key != NULL, NULL, YES);
    return key;
}

SecKeyRef new_SecKeyCreateWithData(CFDataRef keyData, CFDictionaryRef parameters, CFErrorRef *error) {
    NSMutableDictionary *paramsCopy = ((__bridge NSDictionary *)parameters).mutableCopy;
    paramsCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    SecKeyRef key = orig_SecKeyCreateWithData(keyData, (__bridge CFDictionaryRef)paramsCopy, error);
    if(!key && error && *error) {
        diagLogKey(@"SecKeyCreateWithData(改寫後)", parameters, NO, *error, YES);
        CFRelease(*error);
        *error = NULL;
        key = orig_SecKeyCreateWithData(keyData, parameters, error);
        diagLogKey(@"SecKeyCreateWithData(退回原始)", parameters, key != NULL, (error ? *error : NULL), NO);
        return key;
    }

    diagLogKey(@"SecKeyCreateWithData", parameters, key != NULL, NULL, YES);
    return key;
}

OSStatus new_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    NSMutableDictionary *queryCopy = ((__bridge NSDictionary *)parameters).mutableCopy;
    queryCopy[(__bridge id)kSecAttrAccessGroup] = accessGroup;
    OSStatus status = orig_SecKeyGeneratePair((__bridge CFDictionaryRef)queryCopy, publicKey, privateKey);
    if(status == errSecParam) {
        status = orig_SecKeyGeneratePair(parameters, publicKey, privateKey);
        diagLogStatus(@"SecKeyGeneratePair", parameters, status, NO);
        return status;
    }

    diagLogStatus(@"SecKeyGeneratePair", parameters, status, YES);
    return status;
}

#pragma mark - 純記錄 hook（不改寫任何東西，隔離關閉時使用）

static OSStatus diag_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    OSStatus status = orig_SecItemAdd(attributes, result);
    diagLogStatus(@"SecItemAdd", attributes, status, NO);
    return status;
}

static OSStatus diag_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    OSStatus status = orig_SecItemCopyMatching(query, result);
    diagLogStatus(@"SecItemCopyMatching", query, status, NO);
    return status;
}

static OSStatus diag_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    OSStatus status = orig_SecItemUpdate(query, attributesToUpdate);
    diagLogStatus(@"SecItemUpdate", query, status, NO);
    return status;
}

static OSStatus diag_SecItemDelete(CFDictionaryRef query) {
    OSStatus status = orig_SecItemDelete(query);
    diagLogStatus(@"SecItemDelete", query, status, NO);
    return status;
}

static SecKeyRef diag_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    SecKeyRef key = orig_SecKeyCreateRandomKey(parameters, error);
    diagLogKey(@"SecKeyCreateRandomKey", parameters, key != NULL, (error ? *error : NULL), NO);
    return key;
}

static SecKeyRef diag_SecKeyCreateWithData(CFDataRef keyData, CFDictionaryRef parameters, CFErrorRef *error) {
    SecKeyRef key = orig_SecKeyCreateWithData(keyData, parameters, error);
    diagLogKey(@"SecKeyCreateWithData", parameters, key != NULL, (error ? *error : NULL), NO);
    return key;
}

static OSStatus diag_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    OSStatus status = orig_SecKeyGeneratePair(parameters, publicKey, privateKey);
    diagLogStatus(@"SecKeyGeneratePair", parameters, status, NO);
    return status;
}

// 開啟診斷時建立 log 檔並寫入環境摘要。回傳是否成功啟用。
static BOOL diagSetup(BOOL isolationEnabled) {
    if(![NSUserDefaults.lcUserDefaults boolForKey:@"LCKeychainDiagnostics"]) return NO;

    const char* home = getenv("HOME");
    if(!home) return NO;
    NSString* docs = [[NSString stringWithUTF8String:home] stringByAppendingPathComponent:@"Documents"];
    [NSFileManager.defaultManager createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
    gDiagLogPath = [docs stringByAppendingPathComponent:@"LCKeychainDiag.log"];
    gDiagEnabled = YES;

    NSDateFormatter* fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    diagWrite([NSString stringWithFormat:@"===== keychain 診斷開始 %@ =====", [fmt stringFromDate:[NSDate date]]]);
    diagWrite([NSString stringWithFormat:@"guest bundle=%@ version=%@",
               NSBundle.mainBundle.bundleIdentifier ?: @"?",
               [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?"]);
    diagWrite([NSString stringWithFormat:@"keychain 隔離=%@  金鑰隔離=%@",
               isolationEnabled ? @"開啟" : @"關閉",
               [NSUserDefaults.lcUserDefaults boolForKey:@"LCIsolateSecKeys"] ? @"開啟" : @"關閉"]);
    if(isolationEnabled) {
        diagWrite([NSString stringWithFormat:@"改寫後的 accessGroup=%@", accessGroup ?: @"(nil)"]);
    }
    return YES;
}

void SecItemGuestHooksInit(void)  {
    // keychain 隔離會把 guest app 的金鑰操作（含 SecKeyCreateRandomKey /
    // SecKeyGeneratePair）重導向到容器專屬的 access group。但 Secure Enclave
    // 產生的金鑰綁定特定 access group，group 一變就無法使用，導致像 LINE 這類
    // 重度依賴加密的 App 出現解密失敗、公鑰同步失敗，功能全面失效。
    //
    // 停用隔離後，guest app 直接使用宿主的 keychain。由於宿主與原生 App 的
    // bundle ID 不同，系統層級本來就是隔離的；只有「同一個 App 開多個容器」
    // 才需要這個機制。
    if([NSUserDefaults.lcUserDefaults boolForKey:@"LCDisableKeychainIsolation"]) {
        NSLog(@"[LC] keychain isolation fully disabled by user setting");
        // 隔離關閉時原本完全不掛 hook。若使用者開了診斷，仍要掛上純記錄版本，
        // 否則「關閉隔離後為何還是失敗」這個情境永遠觀察不到。
        if(diagSetup(NO)) {
            litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemAdd, diag_SecItemAdd, nil);
            litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemCopyMatching, diag_SecItemCopyMatching, nil);
            litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemUpdate, diag_SecItemUpdate, nil);
            litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemDelete, diag_SecItemDelete, nil);
            litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateRandomKey, diag_SecKeyCreateRandomKey, nil);
            litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateWithData, diag_SecKeyCreateWithData, nil);
            litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyGeneratePair, diag_SecKeyGeneratePair, nil);
        }
        return;
    }

    containerId = [NSString stringWithUTF8String:getenv("HOME")].lastPathComponent;
    NSDictionary* infoDict = [NSUserDefaults guestContainerInfo];
    int keychainGroupId = [infoDict[@"keychainGroupId"] intValue];
    NSString* groupId = [LCSharedUtils teamIdentifier];
    if(keychainGroupId == 0) {
        accessGroup = [NSString stringWithFormat:@"%@.com.tyu.cc886751.shared", groupId];
    } else {
        accessGroup = [NSString stringWithFormat:@"%@.com.tyu.cc886751.shared.%d", groupId, keychainGroupId];
    }

    // check if the keychain access group is available
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: @"NonExistentKey",
        (__bridge id)kSecAttrService: @"NonExistentService",
        (__bridge id)kSecAttrAccessGroup: accessGroup,
        (__bridge id)kSecReturnData: @NO
    };

    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, NULL);
    if(status == errSecMissingEntitlement) {
        NSLog(@"[LC] failed to access keychain access group %@", accessGroup);
        if(diagSetup(YES)) {
            diagWrite(@"!!! 容器專屬 access group 不可用（errSecMissingEntitlement），keychain hook 全數未安裝");
        }
        return;
    }

    diagSetup(YES);

    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemAdd, new_SecItemAdd, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemCopyMatching, new_SecItemCopyMatching, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemUpdate, new_SecItemUpdate, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemDelete, new_SecItemDelete, nil);
    // 金鑰類操作預設不重導向。
    // Secure Enclave 產生的金鑰會綁定當下的 access group，一旦被導向容器專屬的
    // group，之後就可能無法取用，導致 LINE 這類 App 出現公鑰同步失敗與解密失敗
    // （NELO 記錄的 barrier_publicKeySynced / handleDecryptionFailure）。
    // 一般 keychain 項目（登入 token 等）仍維持隔離，多容器登入不同帳號不受影響。
    if([NSUserDefaults.lcUserDefaults boolForKey:@"LCIsolateSecKeys"]) {
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateRandomKey, new_SecKeyCreateRandomKey, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateWithData, new_SecKeyCreateWithData, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyGeneratePair, new_SecKeyGeneratePair, nil);
    } else if(gDiagEnabled) {
        // 金鑰未隔離時也要看得到它們的回傳值，掛純記錄版本
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateRandomKey, diag_SecKeyCreateRandomKey, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateWithData, diag_SecKeyCreateWithData, nil);
        litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyGeneratePair, diag_SecKeyGeneratePair, nil);
    }
}
