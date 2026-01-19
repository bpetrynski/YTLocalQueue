// Tweaks/YTLocalQueue/Settings.xm
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "LocalQueueManager.h"
#import "LocalQueueViewController.h"

static const NSInteger YTLocalQueueSection = 931; // unique tweak section id
static NSString *const kYTLPVersion = @"0.0.1+build22";

static BOOL YTLP_AutoAdvanceEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"ytlp_queue_auto_advance_enabled"];
}

static BOOL YTLP_ShowPlayNextButton(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"ytlp_show_play_next_button"] == nil) {
        return YES; // Default: on
    }
    return [defaults boolForKey:@"ytlp_show_play_next_button"];
}

static BOOL YTLP_ShowQueueButton(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:@"ytlp_show_queue_button"] == nil) {
        return YES; // Default: on
    }
    return [defaults boolForKey:@"ytlp_show_queue_button"];
}

// Build section items via runtime to avoid hard dependencies
static NSArray *ytlp_buildSectionItems(void) {
    NSMutableArray *items = [NSMutableArray array];
    Class SectionItemClass = objc_getClass("YTSettingsSectionItem");
    if (!SectionItemClass) return items;

    SEL selSwitch = sel_getUid("switchItemWithTitle:titleDescription:accessibilityIdentifier:switchOn:switchBlock:settingItemId:");
    
    // Auto advance toggle
    id enableAuto = ((id (*)(id, SEL, id, id, id, BOOL, BOOL(^)(id, BOOL), NSInteger))objc_msgSend)(
        SectionItemClass, selSwitch,
        @"Auto advance",
        @"Automatically play next item from local queue when video ends",
        nil,
        YTLP_AutoAdvanceEnabled(),
        ^BOOL(id cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"ytlp_queue_auto_advance_enabled"];
            return YES;
        },
        0
    );
    if (enableAuto) [items addObject:enableAuto];

    // Show Play Next button toggle
    id showPlayNext = ((id (*)(id, SEL, id, id, id, BOOL, BOOL(^)(id, BOOL), NSInteger))objc_msgSend)(
        SectionItemClass, selSwitch,
        @"Show Play Next button",
        @"Show the Play Next button in the video player overlay",
        nil,
        YTLP_ShowPlayNextButton(),
        ^BOOL(id cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"ytlp_show_play_next_button"];
            return YES;
        },
        0
    );
    if (showPlayNext) [items addObject:showPlayNext];

    // Show Queue button toggle
    id showQueue = ((id (*)(id, SEL, id, id, id, BOOL, BOOL(^)(id, BOOL), NSInteger))objc_msgSend)(
        SectionItemClass, selSwitch,
        @"Show Queue button",
        @"Show the Queue button in the video player overlay",
        nil,
        YTLP_ShowQueueButton(),
        ^BOOL(id cell, BOOL enabled) {
            [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"ytlp_show_queue_button"];
            return YES;
        },
        0
    );
    if (showQueue) [items addObject:showQueue];

    SEL selItem = sel_getUid("itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:selectBlock:");
    id openUI = ((id (*)(id, SEL, id, id, id, id, BOOL(^)(id, NSUInteger)))objc_msgSend)(
        SectionItemClass, selItem,
        @"Open Local Queue",
        nil,
        nil,
        nil,
        ^BOOL(id cell, NSUInteger arg1) {
            Class UIUtils = objc_getClass("YTUIUtils");
            id presenting = (UIUtils && class_respondsToSelector(object_getClass((id)UIUtils), sel_getUid("topViewControllerForPresenting")))
                ? ((id (*)(id, SEL))objc_msgSend)(UIUtils, sel_getUid("topViewControllerForPresenting"))
                : nil;
            if (!presenting) return NO;
            YTLPLocalQueueViewController *vc = [[YTLPLocalQueueViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
            ((void (*)(id, SEL, id, BOOL, id))objc_msgSend)(presenting, sel_getUid("presentViewController:animated:completion:"), nav, YES, nil);
            return YES;
        }
    );
    if (openUI) [items addObject:openUI];

    id clear = ((id (*)(id, SEL, id, id, id, id, BOOL(^)(id, NSUInteger)))objc_msgSend)(
        SectionItemClass, selItem,
        @"Clear Local Queue",
        nil,
        nil,
        nil,
        ^BOOL(id cell, NSUInteger arg1) {
            NSInteger count = [[YTLPLocalQueueManager shared] allItems].count;
            [[YTLPLocalQueueManager shared] clear];
            // Show confirmation toast
            Class HUD = objc_getClass("GOOHUDManagerInternal");
            Class HUDMsg = objc_getClass("YTHUDMessage");
            if (HUD && HUDMsg) {
                NSString *message = (count > 0) 
                    ? [NSString stringWithFormat:@"Cleared %ld video%@", (long)count, count == 1 ? @"" : @"s"]
                    : @"Queue is empty";
                id hudInstance = ((id (*)(id, SEL))objc_msgSend)(HUD, sel_getUid("sharedInstance"));
                id hudMsg = ((id (*)(id, SEL, id))objc_msgSend)(HUDMsg, sel_getUid("messageWithText:"), message);
                if (hudInstance && hudMsg) {
                    ((void (*)(id, SEL, id))objc_msgSend)(hudInstance, sel_getUid("showMessageMainThread:"), hudMsg);
                }
            }
            return YES;
        }
    );
    if (clear) [items addObject:clear];

    // Version info - use title description to show version
    id versionItem = ((id (*)(id, SEL, id, id, id, id, BOOL(^)(id, NSUInteger)))objc_msgSend)(
        SectionItemClass, selItem,
        [NSString stringWithFormat:@"Version %@", kYTLPVersion],
        nil,
        nil,
        nil,
        ^BOOL(id cell, NSUInteger arg1) { return NO; }
    );
    if (versionItem) [items addObject:versionItem];

    return items;
}

// Originals
typedef NSArray* (*SettingsCategoryOrderIMP)(id, SEL);
static SettingsCategoryOrderIMP origSettingsCategoryOrder = NULL;

typedef NSArray* (*OrderedCategoriesIMP)(id, SEL);
static OrderedCategoriesIMP origOrderedCategories = NULL;

typedef NSMutableArray* (*TweaksClassIMP)(id, SEL);
static TweaksClassIMP origTweaksList = NULL;

typedef void (*UpdateSectionIMP)(id, SEL, NSUInteger, id);
static UpdateSectionIMP origUpdateSection = NULL;

// Replacements
static NSArray* ytlp_settingsCategoryOrder(id self, SEL _cmd) {
    NSArray *order = origSettingsCategoryOrder ? origSettingsCategoryOrder(self, _cmd) : nil;
    if (![order isKindOfClass:[NSArray class]]) return order;
    NSUInteger insertIndex = [order indexOfObject:@(1)];
    if (insertIndex != NSNotFound) {
        NSMutableArray *mut = [order mutableCopy];
        [mut insertObject:@(YTLocalQueueSection) atIndex:insertIndex + 1];
        order = [mut copy];
    }
    return order;
}

static NSArray* ytlp_orderedCategories(id self, SEL _cmd) {
    BOOL isType1 = NO;
    SEL selType = sel_getUid("type");
    if ([self respondsToSelector:selType]) {
        int (*typeCall)(id, SEL) = (int (*)(id, SEL))objc_msgSend;
        isType1 = (typeCall(self, selType) == 1);
    }
    NSArray *orig = origOrderedCategories ? origOrderedCategories(self, _cmd) : nil;
    if (!isType1) return orig;
    Class GroupData = objc_getClass("YTSettingsGroupData");
    if (GroupData && class_getClassMethod(GroupData, sel_getUid("tweaks"))) return orig;
    NSMutableArray *mutArr = [orig isKindOfClass:[NSArray class]] ? [orig mutableCopy] : [NSMutableArray array];
    [mutArr insertObject:@(YTLocalQueueSection) atIndex:0];
    return [mutArr copy];
}

static NSMutableArray* ytlp_tweaksList(id cls, SEL _cmd) {
    NSMutableArray *arr = origTweaksList ? origTweaksList(cls, _cmd) : [NSMutableArray array];
    if ([arr isKindOfClass:[NSMutableArray class]]) {
        NSNumber *cat = @(YTLocalQueueSection);
        if (![arr containsObject:cat]) [arr addObject:cat];
    }
    return arr;
}

static void ytlp_updateSection(id self, SEL _cmd, NSUInteger category, id entry) {
    if (category == (NSUInteger)YTLocalQueueSection) {
        id delegate = nil;
        @try { delegate = [self valueForKey:@"_dataDelegate"]; } @catch (__unused NSException *e) {}
        NSArray *items = ytlp_buildSectionItems();
        SEL selWithIcon = sel_getUid("setSectionItems:forCategory:title:icon:titleDescription:headerHidden:");
        SEL selNoIcon   = sel_getUid("setSectionItems:forCategory:title:titleDescription:headerHidden:");
        if (delegate && [delegate respondsToSelector:selWithIcon]) {
            ((void (*)(id, SEL, id, NSUInteger, id, id, id, BOOL))objc_msgSend)(delegate, selWithIcon, items, (NSUInteger)YTLocalQueueSection, @"Local Queue", nil, nil, NO);
        } else if (delegate && [delegate respondsToSelector:selNoIcon]) {
            ((void (*)(id, SEL, id, NSUInteger, id, id, BOOL))objc_msgSend)(delegate, selNoIcon, items, (NSUInteger)YTLocalQueueSection, @"Local Queue", nil, NO);
        }
        return;
    }
    if (origUpdateSection) origUpdateSection(self, _cmd, category, entry);
}

__attribute__((constructor)) static void YTLP_InstallSettingsHooks(void) {
    // Install only settings-related hooks
    dispatch_async(dispatch_get_main_queue(), ^{
        __block int attemptsRemaining = 20; // ~10s max with 0.5s intervals
        __block void (^ __weak weakTryInstall)(void);
        void (^tryInstall)(void);
        weakTryInstall = tryInstall = ^{
            BOOL allInstalled = YES;

            Class Class1 = objc_getClass("YTAppSettingsPresentationData");
            if (Class1) {
                Method m = class_getClassMethod(Class1, sel_getUid("settingsCategoryOrder"));
                if (m && !origSettingsCategoryOrder) {
                    origSettingsCategoryOrder = (SettingsCategoryOrderIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_settingsCategoryOrder);
                }
                if (!origSettingsCategoryOrder) allInstalled = NO;
            } else {
                allInstalled = NO;
            }

            Class Class2 = objc_getClass("YTSettingsGroupData");
            if (Class2) {
                Method m = class_getInstanceMethod(Class2, sel_getUid("orderedCategories"));
                if (m && !origOrderedCategories) {
                    origOrderedCategories = (OrderedCategoriesIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_orderedCategories);
                }
                Method mt = class_getClassMethod(Class2, sel_getUid("tweaks"));
                if (mt && !origTweaksList) {
                    origTweaksList = (TweaksClassIMP)method_getImplementation(mt);
                    method_setImplementation(mt, (IMP)ytlp_tweaksList);
                }
                if (!origOrderedCategories) allInstalled = NO;
            } else {
                allInstalled = NO;
            }

            Class Class3 = objc_getClass("YTSettingsSectionItemManager");
            if (Class3) {
                Method m = class_getInstanceMethod(Class3, sel_getUid("updateSectionForCategory:withEntry:"));
                if (m && !origUpdateSection) {
                    origUpdateSection = (UpdateSectionIMP)method_getImplementation(m);
                    method_setImplementation(m, (IMP)ytlp_updateSection);
                }
                if (!origUpdateSection) allInstalled = NO;
            } else {
                allInstalled = NO;
            }

            if (allInstalled) {
                return;
            }
            if (--attemptsRemaining <= 0) {
                return;
            }
            void (^strongTryInstall)(void) = weakTryInstall;
            if (strongTryInstall) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), strongTryInstall);
            }
        };
        tryInstall();
    });
}