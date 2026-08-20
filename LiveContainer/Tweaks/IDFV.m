//
//  IDFV.m
//  LiveContainer
//
//  Created by s s on 2026/4/25.
//
@import Foundation;
@import ObjectiveC;
#include <dlfcn.h>

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

// Intents.framework 通常要等 guest app 真的用到才會被載入，
// 那時我們的 hook 早就跑完了（objc_getClass 會回傳 nil 而直接跳過）。
// 因此先主動載入，確保類別存在後再抽換方法。
static void siriBypass_loadIntentsFramework(void) {
    static const char *paths[] = {
        "/System/Library/Frameworks/Intents.framework/Intents",
        "/System/Library/Frameworks/IntentsUI.framework/IntentsUI",
    };
    for (int i = 0; i < 2; i++) {
        if (!objc_getClass("INVocabulary")) {
            dlopen(paths[i], RTLD_LAZY | RTLD_GLOBAL);
        }
    }
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
    siriBypass_loadIntentsFramework();

    // INVocabulary：App 用來向 Siri 註冊自訂語彙（聯絡人、群組名稱等）
    siriBypass_hookClassMethod("INVocabulary", @selector(sharedVocabulary));

    // INPreferences：查詢 / 請求 Siri 授權狀態，同樣需要 entitlement。
    // 回傳 nil 在 ABI 上等同 0，即 INSiriAuthorizationStatusNotDetermined。
    siriBypass_hookClassMethod("INPreferences", @selector(siriAuthorizationStatus));

    // INInteraction：部分 App 會直接建立互動物件回報給 Siri
    siriBypass_hookInstanceMethod("INInteraction", @selector(donateInteractionWithCompletion:));
}
