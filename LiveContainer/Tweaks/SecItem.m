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

// 本程式的設定必須從 App Group 讀取。開啟多工時 guest app 跑在 LiveProcess
// 這個獨立的 app extension 裡，它有自己的 bundle identifier，因此
// standardUserDefaults 與 lcUserDefaults 讀到的都是該 extension 自己的設定，
// 看不到主程式寫入的值。App Group 是兩邊共用的唯一位置。
static NSUserDefaults* lcSettings(void) {
    static NSUserDefaults* defaults = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
    });
    return defaults;
}

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

#pragma mark - 移除外來 access group 的 hook

// 部分 app 會在鑰匙圈查詢中寫死自家開發者帳號的 access group（例如 LINE 26.x
// 指定 ZW4U99SQQ3.jp.naver.line）。以本程式的簽章執行時，該群組必然無權存取，
// 系統一律回 errSecMissingEntitlement，導致取不到金鑰而無法解密自身資料。
//
// 未寫死的版本（例如 LINE 15.x）帶的是本程式簽章對應的群組，可正常存取；
// 兩者的差異僅在這一個欄位。因此只要把不屬於本程式團隊的群組指定移除，
// 讓系統改用預設群組，寫死的版本就能取得與未寫死的版本相同的結果。
//
// 只移除「前綴不等於本程式團隊識別碼」的指定，屬於本程式的群組不動，
// 原本就能正常運作的 app 完全不受影響。
static NSString* gTeamPrefix = nil;
static NSString* gContainerTag = nil;

// 移除外來群組後，所有容器都會落在同一個預設群組，彼此的項目互相可見，
// 造成不同容器讀到對方的登入狀態。容器專屬的 access group 取不到權限，
// 無法用來隔離，因此改在項目名稱上加註容器識別碼達成區隔：名稱是 app
// 自行決定的字串，不受權限限制，且讀寫刪都經過同一套轉換，app 本身無感。
//
// 只有「指定了外來群組」的請求會被處理，因此帶著本程式群組、原本就正常
// 運作的 app（例如 LINE 15.x）完全不會被改寫，也不會與被改寫者互相干擾。
static NSString* taggedName(NSString* original) {
    if(!gContainerTag) return original;
    NSString* prefix = [gContainerTag stringByAppendingString:@"#"];
    if([original hasPrefix:prefix]) return original;
    return [prefix stringByAppendingString:original ?: @""];
}

// 需要改寫時回傳處理後的字典，否則回傳 nil 表示原樣使用。
static NSDictionary* queryWithoutForeignGroup(CFDictionaryRef dict) {
    if(!dict || !gTeamPrefix) return nil;
    NSDictionary* d = (__bridge NSDictionary *)dict;
    id group = d[(__bridge id)kSecAttrAccessGroup];
    if(![group isKindOfClass:[NSString class]]) return nil;
    if([(NSString *)group hasPrefix:gTeamPrefix]) return nil;

    NSMutableDictionary* copy = d.mutableCopy;
    [copy removeObjectForKey:(__bridge id)kSecAttrAccessGroup];

    // 優先加註在 service 上；沒有 service 的項目改用 account，兩者皆無則
    // 無從區隔，此時僅移除群組，至少讓存取本身能夠成功。
    id service = d[(__bridge id)kSecAttrService];
    id account = d[(__bridge id)kSecAttrAccount];
    if([service isKindOfClass:[NSString class]]) {
        copy[(__bridge id)kSecAttrService] = taggedName(service);
    } else if([account isKindOfClass:[NSString class]]) {
        copy[(__bridge id)kSecAttrAccount] = taggedName(account);
    }
    return copy;
}

static OSStatus remap_SecItemAdd(CFDictionaryRef attributes, CFTypeRef *result) {
    NSDictionary* fixed = queryWithoutForeignGroup(attributes);
    if(!fixed) {
        OSStatus s = orig_SecItemAdd(attributes, result);
        diagLogStatus(@"SecItemAdd", attributes, s, NO);
        return s;
    }
    OSStatus s = orig_SecItemAdd((__bridge CFDictionaryRef)fixed, result);
    diagLogStatus(@"SecItemAdd[已移除外來群組]", attributes, s, YES);
    return s;
}

static OSStatus remap_SecItemCopyMatching(CFDictionaryRef query, CFTypeRef *result) {
    NSDictionary* fixed = queryWithoutForeignGroup(query);
    if(!fixed) {
        OSStatus s = orig_SecItemCopyMatching(query, result);
        diagLogStatus(@"SecItemCopyMatching", query, s, NO);
        return s;
    }
    OSStatus s = orig_SecItemCopyMatching((__bridge CFDictionaryRef)fixed, result);
    diagLogStatus(@"SecItemCopyMatching[已移除外來群組]", query, s, YES);
    return s;
}

static OSStatus remap_SecItemUpdate(CFDictionaryRef query, CFDictionaryRef attributesToUpdate) {
    NSDictionary* fixedQuery = queryWithoutForeignGroup(query);
    NSDictionary* fixedAttrs = queryWithoutForeignGroup(attributesToUpdate);
    if(!fixedQuery && !fixedAttrs) {
        OSStatus s = orig_SecItemUpdate(query, attributesToUpdate);
        diagLogStatus(@"SecItemUpdate", query, s, NO);
        return s;
    }
    OSStatus s = orig_SecItemUpdate(fixedQuery ? (__bridge CFDictionaryRef)fixedQuery : query,
                                    fixedAttrs ? (__bridge CFDictionaryRef)fixedAttrs : attributesToUpdate);
    diagLogStatus(@"SecItemUpdate[已移除外來群組]", query, s, YES);
    return s;
}

static OSStatus remap_SecItemDelete(CFDictionaryRef query) {
    NSDictionary* fixed = queryWithoutForeignGroup(query);
    if(!fixed) {
        OSStatus s = orig_SecItemDelete(query);
        diagLogStatus(@"SecItemDelete", query, s, NO);
        return s;
    }
    OSStatus s = orig_SecItemDelete((__bridge CFDictionaryRef)fixed);
    diagLogStatus(@"SecItemDelete[已移除外來群組]", query, s, YES);
    return s;
}

static SecKeyRef remap_SecKeyCreateRandomKey(CFDictionaryRef parameters, CFErrorRef *error) {
    NSDictionary* fixed = queryWithoutForeignGroup(parameters);
    if(!fixed) {
        SecKeyRef k = orig_SecKeyCreateRandomKey(parameters, error);
        diagLogKey(@"SecKeyCreateRandomKey", parameters, k != NULL, (error ? *error : NULL), NO);
        return k;
    }
    SecKeyRef k = orig_SecKeyCreateRandomKey((__bridge CFDictionaryRef)fixed, error);
    diagLogKey(@"SecKeyCreateRandomKey[已移除外來群組]", parameters, k != NULL, (error ? *error : NULL), YES);
    return k;
}

static SecKeyRef remap_SecKeyCreateWithData(CFDataRef keyData, CFDictionaryRef parameters, CFErrorRef *error) {
    NSDictionary* fixed = queryWithoutForeignGroup(parameters);
    if(!fixed) {
        SecKeyRef k = orig_SecKeyCreateWithData(keyData, parameters, error);
        diagLogKey(@"SecKeyCreateWithData", parameters, k != NULL, (error ? *error : NULL), NO);
        return k;
    }
    SecKeyRef k = orig_SecKeyCreateWithData(keyData, (__bridge CFDictionaryRef)fixed, error);
    diagLogKey(@"SecKeyCreateWithData[已移除外來群組]", parameters, k != NULL, (error ? *error : NULL), YES);
    return k;
}

static OSStatus remap_SecKeyGeneratePair(CFDictionaryRef parameters, SecKeyRef *publicKey, SecKeyRef *privateKey) {
    NSDictionary* fixed = queryWithoutForeignGroup(parameters);
    if(!fixed) {
        OSStatus s = orig_SecKeyGeneratePair(parameters, publicKey, privateKey);
        diagLogStatus(@"SecKeyGeneratePair", parameters, s, NO);
        return s;
    }
    OSStatus s = orig_SecKeyGeneratePair((__bridge CFDictionaryRef)fixed, publicKey, privateKey);
    diagLogStatus(@"SecKeyGeneratePair[已移除外來群組]", parameters, s, YES);
    return s;
}

// 開啟診斷時建立 log 檔並寫入環境摘要。回傳是否成功啟用。
// 診斷開關容錯讀取：任一來源為開即啟用。設定值原本寫在主程式自己的偏好設定中，
// 修正後改寫入 App Group，兩處都要認得，才不會因為存放位置變更而失效。
// 僅限診斷開關使用；會改變行為的開關（例如停用隔離）仍只讀 App Group，
// 避免舊的殘留值意外生效導致已登入的 App 需要重新登入。
static BOOL diagFlagEnabled(void) {
    if([lcSettings() boolForKey:@"LCKeychainDiagnostics"]) return YES;
    if([NSUserDefaults.lcUserDefaults boolForKey:@"LCKeychainDiagnostics"]) return YES;
    if([NSUserDefaults.standardUserDefaults boolForKey:@"LCKeychainDiagnostics"]) return YES;
    return NO;
}

static BOOL diagSetup(BOOL isolationEnabled) {
    if(!diagFlagEnabled()) return NO;

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
               [lcSettings() boolForKey:@"LCIsolateSecKeys"] ? @"開啟" : @"關閉"]);
    if(isolationEnabled) {
        diagWrite([NSString stringWithFormat:@"改寫後的 accessGroup=%@", accessGroup ?: @"(nil)"]);
    }
    diagWrite([NSString stringWithFormat:@"設定來源檢查 appGroup=%d lc=%d standard=%d  appGroupID=%@",
               [lcSettings() boolForKey:@"LCKeychainDiagnostics"],
               [NSUserDefaults.lcUserDefaults boolForKey:@"LCKeychainDiagnostics"],
               [NSUserDefaults.standardUserDefaults boolForKey:@"LCKeychainDiagnostics"],
               [LCSharedUtils appGroupID] ?: @"(nil)"]);
    diagWrite([NSString stringWithFormat:@"log 路徑=%@", gDiagLogPath]);
    return YES;
}

// 掛上只記錄、不改寫任何參數的 hook。
// 凡是「不安裝隔離 hook 就直接返回」的路徑都必須呼叫，否則該情境下 guest app
// 的鑰匙圈操作完全觀察不到——而那些正是最需要被觀察的情境。
static void installDiagOnlyHooks(void) {
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemAdd, diag_SecItemAdd, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemCopyMatching, diag_SecItemCopyMatching, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemUpdate, diag_SecItemUpdate, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemDelete, diag_SecItemDelete, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateRandomKey, diag_SecKeyCreateRandomKey, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateWithData, diag_SecKeyCreateWithData, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyGeneratePair, diag_SecKeyGeneratePair, nil);
    diagWrite(@"已掛上純記錄 hook，以下為 guest app 實際的鑰匙圈操作");
}

// 掛上會移除外來 access group 的 hook（同時保留記錄）。
static void installRemapHooks(void) {
    NSString* team = [LCSharedUtils teamIdentifier];
    if(team.length == 0) {
        // 取不到團隊識別碼就無從判斷群組歸屬，此時不做任何改寫，退回純記錄
        diagWrite(@"無法取得團隊識別碼，改用純記錄 hook");
        installDiagOnlyHooks();
        return;
    }
    gTeamPrefix = [team stringByAppendingString:@"."];

    // 容器識別碼取自 guest app 的資料目錄名稱，各容器天然唯一。
    const char* home = getenv("HOME");
    if(home) {
        gContainerTag = [NSString stringWithUTF8String:home].lastPathComponent;
    }
    if(gContainerTag.length == 0) {
        // 無法識別容器就不做名稱加註，僅移除群組；此時多個容器會共用鑰匙圈
        gContainerTag = nil;
        diagWrite(@"警告：取不到容器識別碼，將無法區隔各容器的鑰匙圈項目");
    }

    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemAdd, remap_SecItemAdd, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemCopyMatching, remap_SecItemCopyMatching, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemUpdate, remap_SecItemUpdate, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemDelete, remap_SecItemDelete, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateRandomKey, remap_SecKeyCreateRandomKey, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyCreateWithData, remap_SecKeyCreateWithData, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecKeyGeneratePair, remap_SecKeyGeneratePair, nil);
    diagWrite([NSString stringWithFormat:@"已掛上外來群組移除 hook，保留前綴為 %@ 的群組；容器識別碼=%@",
               gTeamPrefix, gContainerTag ?: @"(無，不做區隔)"]);
}

// 探測各種 access group 的可用性，供判斷可行的替代方案。
// 「不指定 access group」使用的是系統配給本程式的預設群組，理論上必定可用；
// 若探測結果顯示連它都不可用，代表問題不在群組權限。
static void probeAccessGroups(void) {
    if(!gDiagEnabled) return;
    NSDictionary* base = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: @"LCProbeNonExistent",
        (__bridge id)kSecAttrService: @"LCProbeNonExistent",
        (__bridge id)kSecReturnData: @NO
    };
    OSStatus s = SecItemCopyMatching((__bridge CFDictionaryRef)base, NULL);
    diagWrite([NSString stringWithFormat:@"探測 不指定accessGroup -> %d %@（%@）",
               (int)s, diagStatusName(s),
               s == -34018 ? @"不可用" : @"可用"]);

    NSString* team = [LCSharedUtils teamIdentifier];
    NSArray* candidates = @[
        [NSString stringWithFormat:@"%@.com.tyu.cc886751.shared", team],
        [NSString stringWithFormat:@"%@.com.tyu.cc886751.shared.1", team],
        [NSString stringWithFormat:@"%@.com.tyu.cc886751", team],
        [NSString stringWithFormat:@"%@.com.tyu.cc886751.LiveProcess", team],
    ];
    for(NSString* g in candidates) {
        NSMutableDictionary* q = base.mutableCopy;
        q[(__bridge id)kSecAttrAccessGroup] = g;
        OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, NULL);
        diagWrite([NSString stringWithFormat:@"探測 %@ -> %d %@（%@）",
                   g, (int)st, diagStatusName(st),
                   st == -34018 ? @"不可用" : @"可用"]);
    }
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
    if([lcSettings() boolForKey:@"LCDisableKeychainIsolation"]) {
        NSLog(@"[LC] keychain isolation fully disabled by user setting");
        // 隔離關閉時原本完全不掛 hook。若使用者開了診斷，仍要掛上純記錄版本，
        // 否則「關閉隔離後為何還是失敗」這個情境永遠觀察不到。
        BOOL diagOn = diagSetup(NO);
        if(diagOn) probeAccessGroups();
        if(![lcSettings() boolForKey:@"LCDisableKeychainGroupRemap"]) {
            installRemapHooks();
        } else if(diagOn) {
            installDiagOnlyHooks();
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
        // 此處原本直接返回、不安裝任何 hook。實測顯示這正是最常走到的路徑
        // （免費開發者帳號簽名時取不到自訂的 keychain access group），
        // 因此同樣要掛上純記錄的 hook，才看得到 guest app 實際的操作與回傳碼。
        BOOL diagOn = diagSetup(YES);
        if(diagOn) {
            diagWrite(@"!!! 容器專屬 access group 不可用（errSecMissingEntitlement），隔離 hook 未安裝");
            probeAccessGroups();
        }
        // 隔離無法生效時，guest app 的請求會原封不動送給系統。若其中寫死了
        // 其他開發者帳號的 access group，必然失敗，因此改掛移除外來群組的 hook。
        if(![lcSettings() boolForKey:@"LCDisableKeychainGroupRemap"]) {
            installRemapHooks();
        } else if(diagOn) {
            installDiagOnlyHooks();
        }
        return;
    }

    if(diagSetup(YES)) {
        probeAccessGroups();
    }

    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemAdd, new_SecItemAdd, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemCopyMatching, new_SecItemCopyMatching, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemUpdate, new_SecItemUpdate, nil);
    litehook_rebind_symbol(LITEHOOK_REBIND_GLOBAL, SecItemDelete, new_SecItemDelete, nil);
    // 金鑰類操作預設不重導向。
    // Secure Enclave 產生的金鑰會綁定當下的 access group，一旦被導向容器專屬的
    // group，之後就可能無法取用，導致 LINE 這類 App 出現公鑰同步失敗與解密失敗
    // （NELO 記錄的 barrier_publicKeySynced / handleDecryptionFailure）。
    // 一般 keychain 項目（登入 token 等）仍維持隔離，多容器登入不同帳號不受影響。
    if([lcSettings() boolForKey:@"LCIsolateSecKeys"]) {
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
