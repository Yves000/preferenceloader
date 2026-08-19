#import "PLRootList.h"
#import "PLSwiftMeta.h"
#import "PLHeap.h"
#import <UIKit/UIKit.h>
#import <roothide.h>
#import "prefs.h"

// Present at runtime but absent from the headers theos ships, so they are declared here rather
// than reached for through performSelector.
@interface PSListController (PLResolution)
- (PSViewController *)controllerForSpecifier:(PSSpecifier *)specifier;
@end

@interface PSViewController (PLParenting)
- (void)setRootController:(id)controller;
- (void)setParentController:(id)controller;
@end
#import <objc/runtime.h>
#import <objc/message.h>

#define DEBUG_TAG "PreferenceLoader"
#import "debug.h"

// DEBUG builds only. NSLog is not reachable from a shell on the device, so lines are also
// appended to a file. /var/mobile is identical on rootful, rootless and roothide, so the path
// carries no package-scheme prefix; the directory has to exist and be writable before first
// launch, because Preferences' sandbox will not create it.
#if DEBUG
static void PLRootLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void PLRootLog(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *body = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"PreferenceLoader! %@", body);

    NSString *path = @"/var/mobile/pl/rootlist.log";
    NSData *data = [[body stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:data attributes:nil];
        [body release];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:data];
    [fh closeFile];
    [body release];
}
#else
#define PLRootLog(...)
#endif

// Mangled Swift type names, minus the "$s" prefix. The leading digits are identifier lengths,
// so a rename in a future release makes the lookup fail outright rather than resolve to
// something else.
static const char *const kPLSectionModelType = "11SettingsApp31PrimarySettingsListSectionModelV";
static const char *const kPLItemModelType    = "11SettingsApp28PrimarySettingsListItemModelV";
static const char *const kPLSectionIDType    = "11SettingsApp36PrimarySettingsListSectionIdentifierO";
static const char *const kPLItemIDType       = "11SettingsApp33PrimarySettingsListItemIdentifierO";
static const char *const kPLItemViewType     = "11SettingsApp31PrimarySettingsListItemViewTypeO";
static const char *const kPLLinkModelType    = "11SettingsApp28PrimarySettingsListLinkModelV";
static const char *const kPLIconTypeType     = "11SettingsApp4IconV8IconTypeO";

// Tag of Icon.IconType.image(uiImage:), the first of its payload cases.
enum { kPLIconImageTag = 0 };

static NSString *const kPLListModelClass = @"_TtC11SettingsApp24PrimarySettingsListModel";

// The count field inside a native Swift array buffer, after its object header.
enum { kPLArrayCountOffset = 16 };

// Everything needed to walk the live root list. Resolved fresh on each use: the model is rebuilt
// whenever one of its asynchronous providers reports in, so a cached snapshot pointer goes
// stale.
typedef struct {
    const void *sectionMeta;
    const void *itemMeta;
    const void *sectionIDMeta;
    const void *itemIDMeta;
    const void *viewTypeMeta;
    const void *linkMeta;

    size_t sectionStride;
    size_t itemStride;

    int32_t sectionID;
    int32_t sectionHeader;
    int32_t sectionItems;
    int32_t itemID;
    int32_t itemViewType;
    int32_t linkTitle;

    const void *snapshot;   // the section array field inside _cachedDataModel
    NSInteger sectionCount;
    __unsafe_unretained id model;
} PLRootContext;

static BOOL PLResolve(PLRootContext *ctx) {
    memset(ctx, 0, sizeof(*ctx));

    ctx->sectionMeta   = PLSwiftTypeByMangledName(kPLSectionModelType);
    ctx->itemMeta      = PLSwiftTypeByMangledName(kPLItemModelType);
    ctx->sectionIDMeta = PLSwiftTypeByMangledName(kPLSectionIDType);
    ctx->itemIDMeta    = PLSwiftTypeByMangledName(kPLItemIDType);
    ctx->viewTypeMeta  = PLSwiftTypeByMangledName(kPLItemViewType);
    ctx->linkMeta      = PLSwiftTypeByMangledName(kPLLinkModelType);
    if (!ctx->sectionMeta || !ctx->itemMeta) return NO;

    ctx->sectionStride = PLSwiftTypeStride(ctx->sectionMeta);
    ctx->itemStride    = PLSwiftTypeStride(ctx->itemMeta);
    if (ctx->sectionStride == 0 || ctx->itemStride == 0) return NO;

    ctx->sectionID     = PLSwiftStructOffsetOfField(ctx->sectionMeta, "id");
    ctx->sectionHeader = PLSwiftStructOffsetOfField(ctx->sectionMeta, "headerText");
    ctx->sectionItems  = PLSwiftStructOffsetOfField(ctx->sectionMeta, "items");
    ctx->itemID        = PLSwiftStructOffsetOfField(ctx->itemMeta, "id");
    ctx->itemViewType  = PLSwiftStructOffsetOfField(ctx->itemMeta, "viewType");
    ctx->linkTitle     = ctx->linkMeta ? PLSwiftStructOffsetOfField(ctx->linkMeta, "primaryText") : -1;
    if (ctx->sectionItems < 0 || ctx->itemViewType < 0) return NO;

    Class listModel = objc_getClass(kPLListModelClass.UTF8String);
    if (!listModel) return NO;

    // Walking the malloc zones is the only way to reach the model (see PLHeap.h), and far too
    // expensive to repeat, so the instance is remembered. It lives as long as the scene does,
    // and a stale one simply fails to resolve a snapshot.
    static __unsafe_unretained id sModel = nil;
    if (!sModel) {
        __unsafe_unretained id instances[8];
        if (PLHeapFindInstances(listModel, instances, 8) == 0) return NO;
        sModel = instances[0];
    }
    __unsafe_unretained id instances[1] = { sModel };

    Ivar cached = class_getInstanceVariable(listModel, "_cachedDataModel");
    if (!cached) return NO;

    // The snapshot's first stored property is the section array, and the Optional wrapping it
    // rides in that array pointer's spare bits, so a nil snapshot reads as a null buffer.
    ctx->model = instances[0];
    ctx->snapshot = (__bridge void *)instances[0] + ivar_getOffset(cached);
    ctx->sectionCount = PLSwiftArrayCount(ctx->snapshot);
    return ctx->sectionCount > 0;
}

#if DEBUG
void PLRootListNote(NSString *message) {
    PLRootLog(@"[note] %@", message);
}
#endif

// --- injection --------------------------------------------------------------------------

// PrimarySettingsListItemIdentifier.connectedHeadphone(identifier:) carries a String, which
// gives every injected row a distinct identity without spending one of the enum's finite empty
// cases. SwiftUI needs those identities to tell the rows apart.
static const char *const kPLIdentifierCarrierCase = "connectedHeadphone";

// PrimarySettingsListSectionIdentifier.connectedHeadphones, an ordinary section that is absent
// unless headphones are paired. The section needs an identity of its own: a copy that kept the
// template's would be a duplicate, and SwiftUI reuses the existing view for a duplicate identity
// instead of building the new one. One identity is enough for a section, so spending an empty
// case costs nothing; the cases that carry a String are "NoGroup" variants with a different
// layout.
static const char *const kPLSectionIdentityCase = "connectedHeadphones";

// Where PreferenceLoader keeps its entries, resolved at runtime rather than written down.
//
// The prefix differs per jailbreak: none on rootful, /var/jb on rootless, and a per-install
// random path under roothide, which cannot be hardcoded at all. jbroot() answers for all three --
// it is roothide's own function under that scheme, and falls back to libroot's runtime lookup
// otherwise, so one build is correct wherever it is installed.
static NSString *PLPreferencesDirectory(void) {
    return jbroot(@"/Library/PreferenceLoader/Preferences");
}

static NSString *PLPreferenceBundlesDirectory(void) {
    return jbroot(@"/Library/PreferenceBundles");
}

// Marks a row as ours. Written into the carrier case's String, and read back both to resolve a
// tap and to recognise a section this tweak has already injected.
static const char *const kPLIdentityPrefix = "PLTweak:";

static NSString *PLIdentityKeyForTitle(NSString *title) {
    return [@(kPLIdentityPrefix) stringByAppendingString:title];
}

// Title -> the PreferenceLoader entry it came from. The injected row carries only a string
// identity, so this is what turns a tap back into a pane.
static NSMutableDictionary<NSString *, NSDictionary *> *PLEntriesByTitle(void) {
    static NSMutableDictionary *entries;
    static dispatch_once_t once;
    // Owned, not autoreleased: this file is compiled without ARC, so a convenience constructor
    // stored in a static dangles once the runloop turn drains.
    dispatch_once(&once, ^{ entries = [[NSMutableDictionary alloc] init]; });
    return entries;
}

// Read once per launch, not on every rebuild.
//
// Settings rebuilds its model while a push is in flight, which runs the injector again. Rebuilding
// the table there releases entry dictionaries a pane still being built is reading, and the
// specifier machinery keeps a pointer to the freed memory. The set of installed tweaks does not
// change while Settings runs, so reading it once is both correct and cheaper.
static NSArray<NSString *> *PLTweakTitles(void) {
    static NSArray *titles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *directory = PLPreferencesDirectory();
        NSMutableArray<NSString *> *found = [NSMutableArray array];
        for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL]) {
            if (![name.pathExtension isEqualToString:@"plist"]) continue;
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:
                                      [directory stringByAppendingPathComponent:name]];
            // Same shape PreferenceLoader itself reads, so the two agree on what a tweak is.
            NSDictionary *entry = [plist isKindOfClass:NSDictionary.class] ? plist[@"entry"] : nil;
            NSString *label = [entry isKindOfClass:NSDictionary.class] ? entry[@"label"] : nil;
            if (![label isKindOfClass:NSString.class] || !label.length) continue;

            [found addObject:label];
            // The plist's own name is kept: libprefs takes it as the title argument when it
            // turns an entry into specifiers, and a bundle without an explicit label falls back
            // to it.
            PLEntriesByTitle()[label] = @{ @"entry": entry,
                                          @"name": name.stringByDeletingPathExtension };
        }
        [found sortUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
        titles = [found copy];
    });
    return titles;
}

// The image a PreferenceLoader entry names, looked up the way PreferenceLoader looks it up.
static UIImage *PLIconForEntry(NSDictionary *entry) {
    NSString *name = entry[@"icon"];
    NSString *bundleName = entry[@"bundle"];
    if (![name isKindOfClass:NSString.class] || !name.length) return nil;

    NSMutableArray<NSString *> *directories = [NSMutableArray array];
    if ([bundleName isKindOfClass:NSString.class] && bundleName.length) {
        [directories addObject:[PLPreferenceBundlesDirectory()
                                stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"%@.bundle", bundleName]]];
    }
    [directories addObject:PLPreferencesDirectory()];

    for (NSString *directory in directories) {
        NSString *path = [directory stringByAppendingPathComponent:name];
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (image) return image;
        // Icons are usually shipped without the scale suffix in the entry.
        for (NSString *suffix in @[@"@3x", @"@2x"]) {
            NSString *scaled = [[[path stringByDeletingPathExtension] stringByAppendingString:suffix]
                                stringByAppendingPathExtension:path.pathExtension ?: @"png"];
            image = [UIImage imageWithContentsOfFile:scaled];
            if (image) return image;
        }
    }
    return nil;
}

static BOOL PLSetItemAppearance(PLRootContext *ctx, void *item, NSString *title, UIImage *icon) {
    if (ctx->linkTitle < 0) return NO;
    void *viewType = (uint8_t *)item + ctx->itemViewType;
    uint32_t tag = PLSwiftEnumTag(viewType, ctx->viewTypeMeta);
    const char *caseName = PLSwiftEnumCaseName(ctx->viewTypeMeta, tag);
    if (!caseName || strcmp(caseName, "link") != 0) return NO;

    PLSwiftEnumProject(viewType, ctx->viewTypeMeta);
    PLSwiftStringAssign((uint8_t *)viewType + ctx->linkTitle, title.UTF8String);

    // Icon.IconType.image carries a UIImage, so the row shows the tweak's own artwork rather
    // than the template's. The old value owns a reference and is destroyed before being
    // overwritten; the new one is retained by hand, because the field is written as raw memory.
    const void *iconMeta = PLSwiftTypeByMangledName(kPLIconTypeType);
    int32_t iconOffset = ctx->linkMeta ? PLSwiftStructOffsetOfField(ctx->linkMeta, "icon") : -1;
    if (icon && iconMeta && iconOffset >= 0) {
        void *field = (uint8_t *)viewType + iconOffset;
        PLSwiftValueDestroy(field, iconMeta);
        memset(field, 0, PLSwiftTypeSize(iconMeta));
        *(void **)field = (void *)[icon retain];
        PLSwiftEnumInject(field, kPLIconImageTag, iconMeta);
    }

    PLSwiftEnumInject(viewType, tag, ctx->viewTypeMeta);
    return YES;
}

// Gives an item its own identity. The template's identifier is an empty case, so it holds no
// references and can be overwritten before the carrier tag is injected.
static void PLSetItemIdentity(PLRootContext *ctx, void *item, NSString *key) {
    uint32_t tag = PLSwiftEnumTagNamed(ctx->itemIDMeta, kPLIdentifierCarrierCase);
    if (tag == UINT32_MAX) return;
    void *identifier = (uint8_t *)item + ctx->itemID;
    size_t size = PLSwiftTypeSize(ctx->itemIDMeta);
    if (size == 0) return;
    memset(identifier, 0, size);
    PLSwiftStringInitialize(key.UTF8String, identifier);
    PLSwiftEnumInject(identifier, tag, ctx->itemIDMeta);
}

void PLRootListInjectTweakSection(void) {
    PLRootContext ctx;
    if (!PLResolve(&ctx)) { PLRootLog(@"[inject] model not reachable"); return; }

#if DEBUG
    PLRootLog(@"[inject] sections: count %td capacity %td",
              ctx.sectionCount, PLSwiftArrayCapacity(ctx.snapshot));
    for (NSInteger i = 0; i < ctx.sectionCount; i++) {
        const void *sec = PLSwiftArrayElement(ctx.snapshot, i, ctx.sectionStride);
        if (!sec) continue;
        const void *items = (const uint8_t *)sec + ctx.sectionItems;
        PLRootLog(@"[inject]   section %td items: count %td capacity %td",
                  i, PLSwiftArrayCount(items), PLSwiftArrayCapacity(items));
    }
#endif

    NSArray<NSString *> *titles = PLTweakTitles();
    PLRootLog(@"[inject] %lu tweak(s): %@", (unsigned long)titles.count,
              [titles componentsJoinedByString:@", "]);
    if (titles.count == 0) return;

    // The last section serves as the template: a plain one-row link section, the shape the
    // injected rows need. Copying it avoids constructing a Swift value from nothing.
    const void *templateSection = PLSwiftArrayElement(ctx.snapshot, ctx.sectionCount - 1, ctx.sectionStride);
    if (!templateSection) return;
    const void *templateItems = (const uint8_t *)templateSection + ctx.sectionItems;
    const void *templateItem = PLSwiftArrayElement(templateItems, 0, ctx.itemStride);
    if (!templateItem) return;

    void *items = PLSwiftArrayAllocate(templateItems, (NSInteger)titles.count, ctx.itemStride, 7);
    if (!items) { PLRootLog(@"[inject] item array allocation failed"); return; }
    uint8_t *itemBase = (uint8_t *)items + PLSwiftArrayElementOffset();
    for (NSUInteger i = 0; i < titles.count; i++) {
        void *item = itemBase + i * ctx.itemStride;
        PLSwiftValueInitializeWithCopy(item, templateItem, ctx.itemMeta);
        PLSetItemIdentity(&ctx, item, PLIdentityKeyForTitle(titles[i]));
        NSDictionary *record = PLEntriesByTitle()[titles[i]];
        if (!PLSetItemAppearance(&ctx, item, titles[i], PLIconForEntry(record[@"entry"]))) {
            PLRootLog(@"[inject] row %lu is not a link; aborting", (unsigned long)i);
            return;
        }
    }

    // Written into the array's spare capacity where there is any, into a larger buffer where
    // there is not.
    //
    // The root array is grown by appends and so usually carries slack, but not always: some
    // layouts arrive with capacity exactly one above the count, Apple's next rebuild fills that
    // slot, and the injected section appears for one frame and then vanishes.
    //
    // Replacing the buffer is safe only because this runs before the evaluation that follows
    // Apple's rebuild: SwiftUI has not read the model yet and picks up whichever buffer it finds.
    // The same replacement after a frame had been drawn would be invisible, because the copy
    // SwiftUI holds shares the old buffer.
    NSInteger capacity = PLSwiftArrayCapacity(ctx.snapshot);
    uintptr_t storage = *(const uintptr_t *)ctx.snapshot;

    if (capacity <= ctx.sectionCount) {
        void *grown = PLSwiftArrayAllocate(ctx.snapshot, ctx.sectionCount + 1, ctx.sectionStride, 7);
        if (!grown) {
            PLRootLog(@"[inject] could not grow the section array past %td", capacity);
            return;
        }
        uint8_t *base = (uint8_t *)grown + PLSwiftArrayElementOffset();
        for (NSInteger i = 0; i < ctx.sectionCount; i++) {
            PLSwiftValueInitializeWithCopy(base + i * ctx.sectionStride,
                                           PLSwiftArrayElement(ctx.snapshot, i, ctx.sectionStride),
                                           ctx.sectionMeta);
        }
        // The old buffer keeps one retain nobody drops. Releasing it would assert that nothing
        // else holds the array, which is not a claim this code can make about Apple's model.
        *(void **)ctx.snapshot = grown;
        storage = (uintptr_t)grown;
        capacity = ctx.sectionCount + 1;
        PLRootLog(@"[inject] grew the section array to %td", capacity);
    }

    void *slot = (void *)(storage + PLSwiftArrayElementOffset() + (size_t)ctx.sectionCount * ctx.sectionStride);
    PLSwiftValueInitializeWithCopy(slot, templateSection, ctx.sectionMeta);
    uint32_t sectionTag = PLSwiftEnumTagNamed(ctx.sectionIDMeta, kPLSectionIdentityCase);
    if (ctx.sectionID >= 0 && sectionTag != UINT32_MAX) {
        // The template's identifier is an empty case, so it holds nothing to release.
        void *identifier = (uint8_t *)slot + ctx.sectionID;
        memset(identifier, 0, PLSwiftTypeSize(ctx.sectionIDMeta));
        PLSwiftEnumInject(identifier, sectionTag, ctx.sectionIDMeta);
        PLRootLog(@"[inject] section identity set to %s (tag %u)",
                  PLSwiftEnumCaseName(ctx.sectionIDMeta,
                                      PLSwiftEnumTag(identifier, ctx.sectionIDMeta)) ?: "?",
                  sectionTag);
    }
    // The copy retained the template's item array; overwriting the field drops that reference
    // without releasing it, for the same reason as above.
    *(void **)((uint8_t *)slot + ctx.sectionItems) = items;

    // Raising the count is the last step, so the slot is complete before the list can see it.
    *(NSInteger *)(storage + kPLArrayCountOffset) = ctx.sectionCount + 1;
    PLRootLog(@"[inject] appended section %td of %td with %lu row(s)",
              ctx.sectionCount, capacity, (unsigned long)titles.count);
}

// When the app last came back to the foreground. Settings rewrites its selection on the way back
// in, which on an expanded split view has to be told apart from the user picking another row.
static CFTimeInterval gPLForegroundAt = 0;
static const CFTimeInterval kPLForegroundGrace = 2.0;

// Whether the re-assertion below has already been logged for this return to the foreground.
static BOOL gPLReassertLogged = NO;

void PLRootListNoteForeground(void) {
    gPLForegroundAt = CACurrentMediaTime();
    gPLReassertLogged = NO;
}

// Puts the selection back on the row whose pane the detail column is showing. Defined further
// down, beside the pane cache it reads.
static void PLReassertSelectionForPane(UIViewController *pane);

// --- holding the root list's scroll position -------------------------------------------------
//
// Refusing a removal has a side effect. SwiftUI has already recorded the pop it asked for, and
// putting the root list back together resets its scroll offset to the top. Nothing of that is
// visible at the time -- the list is behind the pushed pane -- but the user navigating back later
// finds Settings at the very top instead of where they left it.
//
// So the offset is taken at the moment a removal is refused and written back over the next few
// runloop turns, while the list is still off screen.

static UIView *PLFirstScrollView(UIView *view, int depth) {
    if (!view || depth > 40) return nil;
    if ([view isKindOfClass:UIScrollView.class]) return view;
    for (UIView *subview in view.subviews) {
        UIView *found = PLFirstScrollView(subview, depth + 1);
        if (found) return found;
    }
    return nil;
}

UIScrollView *PLRootListRootScrollView(void) {
    UIWindow *key = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) key = window;
    }
    // The bottom of the navigation stack, not whatever pane is pushed on top of it.
    UINavigationController *navigation = nil;
    for (UIViewController *controller = key.rootViewController; controller; ) {
        if ([controller isKindOfClass:UINavigationController.class]) {
            navigation = (UINavigationController *)controller;
            break;
        }
        controller = controller.childViewControllers.firstObject;
    }
    UIViewController *root = navigation.viewControllers.firstObject;
    return (UIScrollView *)PLFirstScrollView(root.viewIfLoaded, 0);
}

static CGFloat gPLHeldOffset = 0;
static CFTimeInterval gPLHoldScrollUntil = 0;
static const CFTimeInterval kPLScrollHold = 1.0;

void PLRootListHoldRootScroll(void) {
    CFTimeInterval now = CACurrentMediaTime();
    // A hold already running keeps the offset it started with, and only has its deadline pushed
    // out. By the time a second call arrives the list is often already moving, and capturing again
    // would pin it wherever it happened to be.
    if (now < gPLHoldScrollUntil) {
        gPLHoldScrollUntil = now + kPLScrollHold;
        return;
    }
    UIScrollView *scroll = PLRootListRootScrollView();
    if (!scroll) return;
    gPLHeldOffset = scroll.contentOffset.y;
    gPLHoldScrollUntil = now + kPLScrollHold;
    PLRootLog(@"[scroll] holding the root list at y=%.0f", gPLHeldOffset);
}

// Whether a programmatic scroll of the root list should be dropped.
//
// Correcting the offset afterwards is always one drawn frame late: the reveal is set inside
// CoreAnimation's commit, so the frame carrying it reaches the screen before anything outside that
// commit can run. That frame is the flicker. Refusing the scroll while the hold is running means
// there is nothing to correct and nothing to draw.
//
// Only the root list, only while a hold is running, and never while the user has the list in their
// hands. Dragging sets the offset through the property, which is a different entry point and stays
// untouched either way.
BOOL PLRootListShouldRefuseScroll(UIScrollView *scroll) {
    if (CACurrentMediaTime() > gPLHoldScrollUntil) return NO;
    if (!scroll || scroll.isTracking || scroll.isDragging) return NO;
    return scroll == PLRootListRootScrollView();
}

// Reapplied for a moment rather than once: the movement does not always arrive in the same runloop
// turn as the event that causes it.
static void PLApplyHeldScroll(void) {
    if (CACurrentMediaTime() > gPLHoldScrollUntil) return;
    UIScrollView *scroll = PLRootListRootScrollView();
    // Never against the user: a list being dragged is one that is on screen and in their hands.
    if (!scroll || scroll.isTracking || scroll.isDragging) return;
    if (fabs(scroll.contentOffset.y - gPLHeldOffset) < 1) return;

    // Taken off the layer before the offset is written back. Revealing a row is an animation, and
    // writing the offset underneath one that keeps running is a tug of war the user can watch:
    // the list travels most of the way to the top and is then dragged back. Removing the animation
    // first turns that into no movement at all. Bounded to the hold, so nothing else the scroll
    // view animates is affected outside it.
    if (scroll.layer.animationKeys.count) [scroll.layer removeAllAnimations];
    // Assigned through the property rather than -setContentOffset:animated:, which is refused for
    // this scroll view while the hold is running.
    scroll.contentOffset = CGPointMake(scroll.contentOffset.x, gPLHeldOffset);
}

// --- filling the detail column -------------------------------------------------------------
//
// An expanded split view does not push its destination: SwiftUI hosts it as a child view
// controller of the detail column's NavigationStack during its own commit, so no navigation
// method is called and the push substitution in Tweak.xm never runs. The column is filled
// directly instead.
//
// The detail hierarchy, as observed on 18.7.9:
//
//   UIKitSplitViewController
//     UIKitNavigationController (sidebar)  -> NavigationStackHostingController -> the list
//     UIKitNavigationController (detail)   -> NavigationStackHostingController -> <destination>
//
// What is filled is the split view's secondary column, not the NavigationStackHostingController
// one level down: SwiftUI rewrites the inner host's content at every commit, so a controller set
// there does not survive, while the column's own stack is left alone once set.

// The split view backing NavigationSplitView, wherever it sits in the hierarchy. A collapsed
// layout has one too, so finding it says nothing about which path applies; PLDetailColumn
// decides that.
static UISplitViewController *PLFindSplitViewController(UIViewController *controller, int depth) {
    if (!controller || depth > 30) return nil;
    if ([controller isKindOfClass:UISplitViewController.class]) return (UISplitViewController *)controller;
    UISplitViewController *found = PLFindSplitViewController(controller.presentedViewController, depth + 1);
    if (found) return found;
    for (UIViewController *child in controller.childViewControllers) {
        found = PLFindSplitViewController(child, depth + 1);
        if (found) return found;
    }
    return nil;
}

// SwiftUI's own detail root (a NavigationStackHostingController). Held while a tweak pane
// occupies the column and put back once a non-tweak row is selected: filling the column evicts
// the host, and SwiftUI never restores a host it did not remove itself, so an evicted one has to
// be returned or Apple's own rows stop rendering. Retained by hand, because setting the column's
// stack releases the column's reference and nothing else here owns it.
static UIViewController *gPLSavedHost = nil;

static UINavigationController *PLDetailColumn(void) {
    UIWindow *key = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) key = window;
    }
    UISplitViewController *split = PLFindSplitViewController(key.rootViewController, 0);
    if (!split) return nil;

    // A collapsed split view has no detail column on screen: the sidebar's navigation stack is
    // what the user sees, the destination arrives by push, and the secondary column sits off
    // screen. Filling it there would take the pane back out of the stack the push hook just put
    // it on, leaving a row that opens to nothing.
    //
    // This is a question about the window, not about the device, so it is asked of the split view
    // rather than of the idiom or the iOS version: a Stage Manager or resized window makes an iPad
    // collapse, and a phone wide enough to stay expanded wants the column filled. It is also not
    // settled once -- the window can be dragged between the two while Settings runs -- so it is
    // asked again on every pass.
    BOOL collapsed = split.isCollapsed;

    static int lastCollapsed = -1;
    if (lastCollapsed != (int)collapsed) {
        lastCollapsed = (int)collapsed;
        PLRootLog(@"[open] split view is %s", collapsed ? "collapsed -- panes arrive by push"
                                                        : "expanded -- panes go in the detail column");

        // The saved host does not survive the change in either direction: it is the root of a
        // column that has just been collapsed away, or of the one that stood there before the
        // window was widened and SwiftUI built a fresh host. Restoring a stale host would show a
        // detail view belonging to a layout that no longer exists.
        [gPLSavedHost release];
        gPLSavedHost = nil;
    }
    if (collapsed) return nil;

    UIViewController *column = [split viewControllerForColumn:UISplitViewControllerColumnSecondary];
    return [column isKindOfClass:UINavigationController.class] ? (UINavigationController *)column : nil;
}

// Idempotent: acts only when the column is not already showing the right thing, so it can be
// called on every runloop turn and from the containment hook without redundant work.
void PLRootListFillDetailColumn(void) {
    // Setting the column's stack re-enters this through the containment callbacks of the
    // controllers going in and out; acting on that half-applied stack would swap again.
    static BOOL busy = NO;
    if (busy) return;

    UINavigationController *column = PLDetailColumn();
    if (!column) return;

    UIViewController *pane = PLRootListPaneForCurrentSelection();
    if (!pane) {
        // Coming back from the background, Settings rewrites the selection onto a row of its own
        // while one of our panes is still in the column. Restoring the host here is what deselects
        // the tweak and puts an Apple page back -- the split view's equivalent of the pop the phone
        // refuses. So for a moment after the app returns, the selection is put back instead.
        //
        // Bounded by the same kind of window as the pop refusal, and for the same reason: outside
        // it, a selection that is no longer ours is the user picking another row, and forcing ours
        // back would leave Apple's rows unopenable.
        if (PLRootListIsFilledContainer(column.viewControllers.firstObject) &&
            CACurrentMediaTime() - gPLForegroundAt < kPLForegroundGrace) {
            // Before the selection is put back, not after: the row Settings selected in our place
            // sits near the top of the list, SwiftUI scrolls there to reveal it, and by the time
            // the selection is ours again that scroll is already under way. Taken here, the offset
            // is still the one the user left behind.
            PLRootListHoldRootScroll();
            PLReassertSelectionForPane(column.viewControllers.firstObject);
            return;
        }
        if (gPLSavedHost && column.viewControllers.firstObject != gPLSavedHost) {
            busy = YES;
            @try { [column setViewControllers:@[gPLSavedHost] animated:NO]; }
            @catch (NSException *exception) {
                PLRootLog(@"[open] restore raised %@: %@", exception.name, exception.reason);
            }
            busy = NO;
        }
        return;
    }

    if (column.viewControllers.count == 1 && column.viewControllers.firstObject == pane) return;

    // Remember the host for the later restore, but never one of our own panes: with one pane
    // already in the column and another tweak selected, the column's root is that first pane, and
    // saving it would put a tweak pane where Apple's page belongs on every restore afterwards.
    UIViewController *root = column.viewControllers.firstObject;
    if (root && root != pane && root != gPLSavedHost && !PLRootListIsFilledContainer(root)) {
        [gPLSavedHost release];
        gPLSavedHost = [root retain];
    }

    // A tweak pane reaches its navigation stack through its root controller, and the column is a
    // navigation controller, so it is what the pane is given -- as on the push path.
    [(PSViewController *)pane setRootController:(id)column];
    busy = YES;
    @try { [column setViewControllers:@[pane] animated:NO]; }
    @catch (NSException *exception) {
        PLRootLog(@"[open] detail fill raised %@: %@", exception.name, exception.reason);
    }
    busy = NO;
}

// --- injecting into Apple's own rebuild --------------------------------------------------

// The snapshot last injected into: its buffer address and the section count left behind.
//
// The address alone is not an identity. Apple frees a snapshot buffer and later allocates another
// at the same address -- 0x5e4fc8a00 served two different snapshots within one launch here -- and
// a fresh list mistaken for the one already handled is skipped, so it reaches the screen without
// any of the tweak rows in it. Carrying the count as well costs nothing, since both words are
// loaded anyway, and the pair only matches when the array really is the one left behind; anything
// else is treated as a rebuild and injected into.
static const void *gPLInjectedInto = NULL;
static NSInteger gPLInjectedCount = -1;

static void PLInjectOnNewSnapshot(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
    // Ahead of everything else, and ahead of the model resolving: the scroll position has to be
    // put back whether or not the list is reachable this turn.
    PLApplyHeldScroll();

    PLRootContext ctx;
    if (!PLResolve(&ctx)) return;

    // The containment hook lands the first fill in the commit that would otherwise flash Apple's
    // own destination; this turn-by-turn pass covers restoring the host and any selection the
    // hook does not witness.
    PLRootListFillDetailColumn();

    // Keeps almost every runloop turn to a couple of loads.
    const void *storage = *(const void *const *)ctx.snapshot;
    if (!storage || (storage == gPLInjectedInto && ctx.sectionCount == gPLInjectedCount)) return;

    PLRootLog(@"[injector] new snapshot %p with %td sections", storage, ctx.sectionCount);
    PLRootListInjectTweakSection();

    // Read back afterwards rather than remembered from before: when the array has to be grown, the
    // injection replaces this very pointer, and recording the old one would make the next turn
    // mistake the new buffer for Apple's next rebuild.
    gPLInjectedInto = *(const void *const *)ctx.snapshot;
    gPLInjectedCount = PLSwiftArrayCount(ctx.snapshot);
}

// The held position is written back twice per runloop pass, from either side of CoreAnimation's
// commit. The pass that starts a reveal sets the offset inside that commit, so a correction only
// at the top of the next pass arrives a drawn frame late -- which is exactly the flicker this is
// meant to remove.
static void PLApplyHeldScrollAfterCommit(CFRunLoopObserverRef observer,
                                         CFRunLoopActivity activity, void *info) {
    PLApplyHeldScroll();
}

void PLRootListInstallInjector(void) {
    static CFRunLoopObserverRef afterCommit;
    if (!afterCommit) {
        afterCommit = CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true,
                                              3000000, PLApplyHeldScrollAfterCommit, NULL);
        if (afterCommit) CFRunLoopAddObserver(CFRunLoopGetMain(), afterCommit, kCFRunLoopCommonModes);
    }

    static CFRunLoopObserverRef observer;
    if (observer) return;
    // Ahead of CoreAnimation, whose commit observer sits at order 2000000 and is where SwiftUI
    // evaluates.
    observer = CFRunLoopObserverCreate(kCFAllocatorDefault,
                                       kCFRunLoopBeforeTimers | kCFRunLoopBeforeWaiting,
                                       true, -2000000, PLInjectOnNewSnapshot, NULL);
    if (!observer) return;
    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
    PLRootLog(@"[injector] installed");
}

// --- opening a row ------------------------------------------------------------------------

// Builds the controller a PreferenceLoader entry points at.
//
// Instantiating the entry's class directly is not enough: a preference controller is configured
// by its PSSpecifier and comes up empty without one. libprefs already turns an entry into
// specifiers and resolves a specifier into a controller, loading the bundle lazily, so both steps
// go through it.
static UIViewController *PLControllerForEntry(NSDictionary *record) {
    // Held for the duration: the specifier machinery reads from these long after this function
    // has handed them over.
    NSDictionary *entry = [[record[@"entry"] retain] autorelease];
    NSString *name = [[record[@"name"] retain] autorelease];
    if (![entry isKindOfClass:NSDictionary.class]) return nil;

    // A fresh host per pane. The specifier machinery writes through the target it is given, so
    // one controller serving every pane in turn accumulates state from panes that are gone. It
    // cannot be autoreleased either, because the pane it produces refers back to it; it is owned
    // by the pane instead, which is exactly as long as it is needed.
    PSListController *host = [[objc_getClass("PSListController") alloc] init];
    if (![host respondsToSelector:@selector(specifiersFromEntry:sourcePreferenceLoaderBundlePath:title:)]) {
        PLRootLog(@"[open] libprefs entry point missing");
        [host release];
        return nil;
    }

    NSArray *specifiers = [host specifiersFromEntry:entry
                   sourcePreferenceLoaderBundlePath:PLPreferencesDirectory()
                                              title:name];
    PSSpecifier *specifier = specifiers.firstObject;
    if (!specifier) {
        PLRootLog(@"[open] no specifier for %@", name);
        [host release];
        return nil;
    }

    UIViewController *controller = (UIViewController *)[host controllerForSpecifier:specifier];
    if (![controller isKindOfClass:UIViewController.class]) {
        PLRootLog(@"[open] controllerForSpecifier gave %@", controller);
        [host release];
        return nil;
    }
    // Parented to itself rather than to the throwaway host. Opened from a real list, a pane's
    // parentController and rootController are controllers that are in the hierarchy and on
    // screen; the host here exists only to resolve the specifier and is attached to nothing, so
    // pointing the pane at it would hand it a parent that is in no hierarchy.
    if ([controller respondsToSelector:@selector(setRootController:)]) {
        [(PSViewController *)controller setRootController:(id)controller];
    }
    if ([controller respondsToSelector:@selector(setParentController:)]) {
        [(PSViewController *)controller setParentController:nil];
    }

    static const void *kPLSpecifiersKey = &kPLSpecifiersKey;
    static const void *kPLHostKey = &kPLHostKey;
    objc_setAssociatedObject(controller, kPLSpecifiersKey, specifiers, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(controller, kPLHostKey, host, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host release];
    return controller;
}

static const void *kPLFilledKey = &kPLFilledKey;

BOOL PLRootListIsFilledContainer(UIViewController *controller) {
    return controller && objc_getAssociatedObject(controller, kPLFilledKey) != nil;
}

// The row's identifier is one Apple does not know, but it still resolves to the legacy hosting
// path, so Settings pushes the right kind of container and simply has nothing to put in it.
// Substituting the pane into that push keeps the transition, the back button and the title bar
// Apple's own.

static NSString *PLSelectedTweakTitle(PLRootContext *ctx);

// One pane per tweak, kept for the life of the process. Building a new one on every tap releases
// the previous one while its navigation transition is still running, and the layout engine goes
// on touching its views. Keeping them also avoids running the specifier machinery twice for the
// same pane. Settings reuses its own controllers the same way.
static NSMutableDictionary<NSString *, UIViewController *> *PLPaneCache(void) {
    static NSMutableDictionary *panes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ panes = [[NSMutableDictionary alloc] init]; });
    return panes;
}

UIViewController *PLRootListPaneForCurrentSelection(void) {
    PLRootContext ctx;
    if (!PLResolve(&ctx)) return nil;

    NSString *title = PLSelectedTweakTitle(&ctx);
    if (!title) return nil;

    UIViewController *pane = PLPaneCache()[title];
    if (!pane) {
        NSDictionary *record = PLEntriesByTitle()[title];
        pane = record ? PLControllerForEntry(record) : nil;
        if (!pane) { PLRootLog(@"[open] no controller for %@", title); return nil; }
        PLPaneCache()[title] = pane;

        // Set once at build time, not on every lookup: the detail path asks for the pane on every
        // runloop turn, and a tweak that manages navigationItem.title itself -- hiding it at the
        // top of its scroll and revealing it further down -- would have it pinned visible.
        pane.title = title;
        pane.navigationItem.title = title;
        // Marked so the pop refusal can tell this pane apart from anything else on the stack.
        objc_setAssociatedObject(pane, kPLFilledKey, pane, OBJC_ASSOCIATION_ASSIGN);
        PLRootLog(@"[open] built the pane for %@", title);
    }
    return pane;
}

// Defined below, with the rest of the selection reading.
static uint8_t *PLSelectionField(PLRootContext *ctx);

static NSString *PLTitleForPane(UIViewController *pane) {
    for (NSString *title in PLPaneCache()) {
        if (PLPaneCache()[title] == pane) return title;
    }
    return nil;
}

static void PLReassertSelectionForPane(UIViewController *pane) {
    NSString *title = PLTitleForPane(pane);
    if (!title) return;

    PLRootContext ctx;
    if (!PLResolve(&ctx)) return;
    uint8_t *selection = PLSelectionField(&ctx);
    size_t size = PLSwiftTypeSize(ctx.itemIDMeta);
    uint32_t tag = PLSwiftEnumTagNamed(ctx.itemIDMeta, kPLIdentifierCarrierCase);
    if (!selection || size == 0 || tag == UINT32_MAX) return;
    // A real none is left alone: it means nothing is selected, not that something else was
    // selected in our place.
    if (selection[32] == 0xff) return;

    // The value being replaced is a live identifier that may own a String, so it is destroyed
    // through its own witness rather than overwritten -- what Swift itself does on assignment.
    PLSwiftValueDestroy(selection, ctx.itemIDMeta);
    memset(selection, 0, size);
    PLSwiftStringInitialize(PLIdentityKeyForTitle(title).UTF8String, selection);
    PLSwiftEnumInject(selection, tag, ctx.itemIDMeta);

    if (!gPLReassertLogged) {
        gPLReassertLogged = YES;
        PLRootLog(@"[open] selection put back on %@ after returning to the foreground", title);
    }
}

// The model's own selection field.
//
// Uses the instance the context already resolved: a heap walk on every runloop turn is enough to
// make Settings stop responding to the taps this is meant to notice.
//
// It holds an Optional<PrimarySettingsListItemIdentifier> whose discriminator rides in the
// payload's spare bits -- byte 32, where 0xff is none -- so the bytes at this address are the
// identifier itself, and a valid identifier written there reads back as .some of that value.
static uint8_t *PLSelectionField(PLRootContext *ctx) {
    Class listModel = object_getClass(ctx->model);
    Ivar ivar = listModel ? class_getInstanceVariable(listModel, "effectiveSelection") : NULL;
    if (!ivar || !ctx->model) return NULL;
    return (uint8_t *)(__bridge void *)ctx->model + ivar_getOffset(ivar);
}

// Reads the list's current selection and reports the tweak it names, or nil.
static NSString *PLSelectedTweakTitle(PLRootContext *ctx) {
    const uint8_t *selection = PLSelectionField(ctx);
    if (!selection) return nil;

    static uint8_t lastDiscriminator = 0xff;
    if (selection[32] != lastDiscriminator) {
        lastDiscriminator = selection[32];
        PLRootLog(@"[select] discriminator %u", selection[32]);
    }
    if (selection[32] == 0xff) return nil;

    // The identifier enum is a large multi-payload type -- 113 bytes on iOS 18, where a case ahead
    // of connectedHeadphone carries a wide struct -- so the buffer is sized from the stride the
    // runtime reports. The cap makes an unexpectedly huge type fail the guard rather than overrun
    // the stack.
    size_t size = PLSwiftTypeSize(ctx->itemIDMeta);
    uint8_t copy[256];
    if (size == 0 || size > sizeof(copy)) return nil;
    memcpy(copy, selection, size);
    if (PLSwiftEnumTag(copy, ctx->itemIDMeta)
        != PLSwiftEnumTagNamed(ctx->itemIDMeta, kPLIdentifierCarrierCase)) return nil;

    // Projected on the copy, never on the model's own value: projecting strips the tag.
    PLSwiftEnumProject(copy, ctx->itemIDMeta);
    char *key = PLSwiftStringCopyUTF8(copy);
    if (!key) return nil;
    NSString *identity = @(key);
    free(key);

    for (NSString *title in PLEntriesByTitle()) {
        if ([PLIdentityKeyForTitle(title) isEqualToString:identity]) return title;
    }
    return nil;
}

