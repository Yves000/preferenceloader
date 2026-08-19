// Navigation trace, DEBUG builds only.
//
// The Makefile adds this file to the target under the DEBUG schema alone, so nothing here
// reaches a release package. It is a separate file rather than an #if inside Tweak.xm because
// logos generates its hook registration ahead of the C preprocessor: a %hook cannot be
// conditionally compiled out of a file that is being built.
//
// Nothing here alters behaviour. SwiftUI does not always navigate by pushing -- it sometimes
// replaces the whole set of view controllers -- so a trace watching only pushes would show
// nothing at all for those transitions.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "PLRootList.h"

static NSString *PLTraceStack(UINavigationController *navigation) {
	NSMutableArray<NSString *> *names = [NSMutableArray array];
	for (UIViewController *controller in navigation.viewControllers) {
		[names addObject:NSStringFromClass(controller.class)];
	}
	return [names componentsJoinedByString:@" > "];
}

// --- scroll position watch ----------------------------------------------------------------
//
// The root list jumps back to the top after a background cycle, and the events that could cause
// it -- Apple's rebuild, our injection into it, the refused pop, the user's own back -- all land
// within a few runloop turns of each other. Sampling the offset every turn and reporting it when
// it moves puts it in order with the rest of the log, which is what tells them apart.

static void PLSampleScrollOffset(CFRunLoopObserverRef observer, CFRunLoopActivity activity, void *info) {
	static CGFloat last = -1;
	UIScrollView *scroll = PLRootListRootScrollView();
	if (!scroll) return;
	CGFloat offset = scroll.contentOffset.y;
	// Ordinary scrolling would otherwise fill the log; only a jump is worth a line.
	if (fabs(offset - last) < 200) return;
	last = offset;
	PLRootListNote([NSString stringWithFormat:@"[scroll] root list at y=%.0f", offset]);
}

static void PLWatchScrollOffset(void) {
	CFRunLoopObserverRef observer =
		CFRunLoopObserverCreate(kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, 3000000,
		                        PLSampleScrollOffset, NULL);
	if (observer) CFRunLoopAddObserver(CFRunLoopGetMain(), observer, kCFRunLoopCommonModes);
}

%group Trace

%hook UINavigationController

- (void)setViewControllers:(NSArray *)controllers animated:(BOOL)animated {
	NSMutableArray<NSString *> *names = [NSMutableArray array];
	for (UIViewController *controller in controllers) {
		[names addObject:NSStringFromClass(controller.class)];
	}
	PLRootListNote([NSString stringWithFormat:@"[nav] setViewControllers [%@] -> [%@]",
	                PLTraceStack(self), [names componentsJoinedByString:@" > "]]);
	%orig;
}

%end

%end

%ctor {
	// The same gate the navigation hooks in Tweak.xm use: only the SwiftUI root list is worth
	// tracing.
	if (objc_getClass("_TtC11SettingsApp24SettingsAppSceneDelegate")) {
		%init(Trace);
		PLWatchScrollOffset();
	}
}
