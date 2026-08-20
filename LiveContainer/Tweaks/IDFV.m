//
//  IDFV.m
//  LiveContainer
//
//  Created by s s on 2026/4/25.
//
@import Foundation;
@import ObjectiveC;

NSUUID* idForVendorUUID = nil;

NSUUID* getIDFV_hook(NSObject* cur) {
    return idForVendorUUID;
}

void IDFVHookInit(NSUUID* uuid) {
    idForVendorUUID = uuid;
    Method getIDFVOrig = class_getInstanceMethod(objc_getClass("LSApplicationWorkspace"), @selector(deviceIdentifierForVendor));
    method_setImplementation(getIDFVOrig, (IMP)getIDFV_hook);
}

static id siriBypass_returnNil(id self, SEL _cmd) {
    return nil;
}

static void siriBypass_hookClassMethod(const char *className, SEL selector) {
    Class cls = objc_getClass(className);
    if (!cls) return;
    Method method = class_getClassMethod(cls, selector);
    if (!method) return;
    method_setImplementation(method, (IMP)siriBypass_returnNil);
}

static void siriBypass_hookInstanceMethod(const char *className, SEL selector) {
    Class cls = objc_getClass(className);
    if (!cls) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    method_setImplementation(method, (IMP)siriBypass_returnNil);
}

void SiriBypassHookInit(void) {
    // INVocabulary：App 用來向 Siri 註冊自訂語彙（聯絡人、群組名稱等）
    siriBypass_hookClassMethod("INVocabulary", @selector(sharedVocabulary));

    // INPreferences：查詢 / 請求 Siri 授權狀態，同樣需要 entitlement。
    // 回傳 nil 在 ABI 上等同 0，即 INSiriAuthorizationStatusNotDetermined。
    siriBypass_hookClassMethod("INPreferences", @selector(siriAuthorizationStatus));

    // INInteraction：部分 App 會直接建立互動物件回報給 Siri
    siriBypass_hookInstanceMethod("INInteraction", @selector(donateInteractionWithCompletion:));
}
