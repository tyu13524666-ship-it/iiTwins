//
//  KeyboardRelayout.m
//  LiveContainer
//
//  多工模式下，本程式會在鍵盤出現時把視窗底部縮到鍵盤上方。實測顯示容器內的
//  app 收到這個尺寸變動後並不會重新排版，畫面因而留白，直到使用者觸碰螢幕才
//  恢復；由視窗端送出設定、調整安全區域、乃至讓尺寸抖動，均無法促成重排。
//
//  原因在於這類 app 只依系統鍵盤事件決定輸入列的位置，不理會視窗本身的變化。
//  由於這段程式與 app 同處一個進程，可直接補送一則「鍵盤已離開畫面」的通知：
//  此時視窗底部已經停在鍵盤上方，對 app 而言確實不再有鍵盤遮擋，輸入列排回
//  視窗底部即為正確位置，且無須自行換算被虛擬視窗偏移過的座標。
//
//  註：同樣的內容先前寫在 TweakLoader 中，但該模組在多工模式下不會載入，
//  完全沒有留下任何記錄。此處與鑰匙圈的處理同一位置，由 LCBootstrap 呼叫，
//  該路徑已確認必定執行。
//
@import UIKit;
#import <objc/runtime.h>
#import "utils.h"
#import "Tweaks.h"
#import "LCSharedUtils.h"

#pragma mark - 診斷記錄

// 寫入本容器的 Documents，匯出容器即可取得。與其他診斷共用同一個開關。
static void kbLog(NSString* format, ...) {
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
    FILE* f = fopen([dir stringByAppendingPathComponent:@"LCGuestRelayout.log"].UTF8String, "a");
    if(!f) return;
    fputs(line.UTF8String, f);
    fclose(f);
}

#pragma mark - 補送鍵盤事件

static BOOL kbDisabled(void) {
    NSUserDefaults* defaults = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
    return [defaults boolForKey:@"LCDisableKeyboardAvoidance"] ||
           [defaults boolForKey:@"LCDisableGuestRelayout"];
}

// 聊天列表這類可捲動的元件，內容範圍是自己算的，僅讓視窗重新排版並不會使其
// 重算，畫面因而留白。此處以極小幅度改變捲動位置再還原，等同代替使用者輕碰
// 一下，促使其重新計算內容範圍。限制搜尋深度，避免走遍整個畫面結構。
static void kbNudgeScrollViews(UIView* view, int depth) {
    if(!view || depth > 6) return;
    if([view isKindOfClass:UIScrollView.class]) {
        UIScrollView* scrollView = (UIScrollView*)view;
        if(!CGRectIsEmpty(scrollView.bounds)) {
            CGPoint offset = scrollView.contentOffset;
            [scrollView setContentOffset:CGPointMake(offset.x, offset.y + 0.5) animated:NO];
            [scrollView setContentOffset:offset animated:NO];
            [scrollView setNeedsLayout];
        }
    }
    for(UIView* subview in view.subviews) {
        kbNudgeScrollViews(subview, depth + 1);
    }
}

static void kbPostSyntheticDismissal(UIWindow* window) {
    if(!window || CGRectIsEmpty(window.bounds)) return;
    // 鍵盤與各式浮層自身的視窗不需要處理，補送通知反而可能造成干擾
    UIViewController* rootVC = window.rootViewController;
    if(!rootVC || [rootVC isKindOfClass:NSClassFromString(@"UIInputWindowController")]) return;

    UIViewController* root = window.rootViewController;
    kbLog(@"  視窗=%@ rootVC=%@ rootView=%@ 安全區下緣=%.1f",
          NSStringFromCGRect(window.bounds),
          root ? NSStringFromClass(root.class) : @"(nil)",
          NSStringFromCGRect(root.view.frame),
          window.safeAreaInsets.bottom);

    [window setNeedsLayout];
    [window layoutIfNeeded];

    CGRect offscreen = CGRectMake(0, CGRectGetHeight(window.bounds), CGRectGetWidth(window.bounds), 0);
    NSValue* frameValue = [NSValue valueWithCGRect:offscreen];
    NSDictionary* userInfo = @{
        UIKeyboardFrameBeginUserInfoKey: frameValue,
        UIKeyboardFrameEndUserInfoKey: frameValue,
        UIKeyboardAnimationDurationUserInfoKey: @(0.0),
        UIKeyboardAnimationCurveUserInfoKey: @(UIViewAnimationCurveEaseInOut),
        UIKeyboardIsLocalUserInfoKey: @(YES),
    };
    NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
    [center postNotificationName:UIKeyboardWillChangeFrameNotification object:nil userInfo:userInfo];
    [center postNotificationName:UIKeyboardDidChangeFrameNotification object:nil userInfo:userInfo];

    // 通知只會讓 app 重排輸入列，可捲動元件的內容範圍仍需另行促使重算
    kbNudgeScrollViews(window, 0);
    kbLog(@"  已補送鍵盤離開通知並促使捲動元件重算 frame=%@", NSStringFromCGRect(offscreen));
}

// 三個 hook 共用：高度確有變動時記錄並補送鍵盤事件。
static void kbHandleHeightChange(UIWindow* window, NSString* via, CGFloat before, CGFloat after) {
    // 雙重保險：即使掛載方式有誤而波及其他視圖，也只處理真正的 UIWindow
    if(![window isKindOfClass:UIWindow.class]) return;
    if(fabs(before - after) < 1.0) return;
    kbLog(@"視窗高度變動 %.1f -> %.1f（來源 %@）", before, after, via);
    if(kbDisabled()) {
        kbLog(@"  （使用者已停用，不處理）");
        return;
    }
    // setFrame 與 layoutSubviews 會就同一次變動各觸發一次，短時間內合併處理
    static NSMutableSet* pending = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pending = [NSMutableSet set]; });

    NSValue* key = [NSValue valueWithNonretainedObject:window];
    if([pending containsObject:key]) return;
    [pending addObject:key];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [pending removeObject:key];
        kbPostSyntheticDismissal(window);
    });
}

#pragma mark - Hook

@interface UIWindow(LCKeyboardRelayout)
@end

@implementation UIWindow(LCKeyboardRelayout)

- (void)lcKB_setBounds:(CGRect)bounds {
    CGFloat previous = self.bounds.size.height;
    [self lcKB_setBounds:bounds];
    kbHandleHeightChange(self, @"setBounds", previous, bounds.size.height);
}

- (void)lcKB_setFrame:(CGRect)frame {
    CGFloat previous = self.bounds.size.height;
    [self lcKB_setFrame:frame];
    kbHandleHeightChange(self, @"setFrame", previous, frame.size.height);
}

- (void)lcKB_layoutSubviews {
    // layoutSubviews 呼叫頻繁，以關聯物件保存前次高度，僅在高度確有變動時處理
    static const void* kLastHeightKey = &kLastHeightKey;
    NSNumber* stored = objc_getAssociatedObject(self, kLastHeightKey);
    CGFloat previous = stored ? stored.doubleValue : self.bounds.size.height;

    [self lcKB_layoutSubviews];

    CGFloat current = self.bounds.size.height;
    if(!stored || fabs(previous - current) >= 1.0) {
        objc_setAssociatedObject(self, kLastHeightKey, @(current), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if(stored) {
        kbHandleHeightChange(self, @"layoutSubviews", previous, current);
    }
}

@end

// layoutSubviews、setFrame:、setBounds: 三者 UIWindow 均未自行實作，
// class_getInstanceMethod 取得的是繼承自 UIView 的方法。若直接交換實作，
// 等同替換 UIView 全體的行為，app 會在啟動階段崩潰。
//
// 因此先嘗試將替代實作以原名加到 UIWindow 自身：若成功，代表該類別原本
// 沒有自己的實作，此時只需把父類別的實作登記到替代名稱下即可，UIView
// 完全不受影響；若失敗，代表該類別確實有自己的實作，才進行交換。
static void kbSafeSwizzle(Class cls, SEL originalSel, SEL replacementSel) {
    Method original = class_getInstanceMethod(cls, originalSel);
    Method replacement = class_getInstanceMethod(cls, replacementSel);
    if(!original || !replacement) {
        kbLog(@"  略過 %@：取不到方法", NSStringFromSelector(originalSel));
        return;
    }

    if(class_addMethod(cls, originalSel,
                       method_getImplementation(replacement),
                       method_getTypeEncoding(replacement))) {
        class_replaceMethod(cls, replacementSel,
                            method_getImplementation(original),
                            method_getTypeEncoding(original));
        kbLog(@"  已掛上 %@（原先繼承自父類別，未影響父類別）", NSStringFromSelector(originalSel));
    } else {
        method_exchangeImplementations(original, replacement);
        kbLog(@"  已掛上 %@（該類別自有實作，直接交換）", NSStringFromSelector(originalSel));
    }
}

void KeyboardRelayoutHookInit(void) {
    // 掛載本身即受開關控制。先前僅在處理階段檢查開關，一旦掛載方式有誤便
    // 無從關閉，使用者只能眼看 app 反覆崩潰。
    if(kbDisabled()) {
        kbLog(@"===== 使用者已停用，未掛上任何監看 =====");
        return;
    }

    kbLog(@"===== 鍵盤重排監看開始掛載 =====");
    // 視窗尺寸未必經由 setBounds: 變更，三條路徑一併掛上，由記錄判斷實際經過何者
    kbSafeSwizzle(UIWindow.class, @selector(setBounds:), @selector(lcKB_setBounds:));
    kbSafeSwizzle(UIWindow.class, @selector(setFrame:), @selector(lcKB_setFrame:));
    kbSafeSwizzle(UIWindow.class, @selector(layoutSubviews), @selector(lcKB_layoutSubviews));

    // 延後再記一次，確認 app 啟動後的視窗狀態
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        for(UIWindow* w in UIApplication.sharedApplication.windows) {
            kbLog(@"  現有視窗 %@ bounds=%@", NSStringFromClass(w.class), NSStringFromCGRect(w.bounds));
        }
    });
}
