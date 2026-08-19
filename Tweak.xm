#import <Preferences/Preferences.h>
#import <substrate.h>
#import <dlfcn.h>
// jbroot(): see the note in prefs.xm. Resolves the install prefix at runtime, so the same build
// works on rootful, rootless and roothide.
#import <roothide.h>

#import "prefs.h"
#import "PLRootList.h"
#import "PLCrashLog.h"

#define DEBUG_TAG "PreferenceLoader"
#import "debug.h"

/* {{{ Imports (Preferences.framework) */
// Weak (3.2+, dlsym)
static NSString **pPSTableCellUseEtchedAppearanceKey = NULL;
/* }}} */

/* {{{ UIDevice 3.2 Additions */
@interface UIDevice (iPad)
- (BOOL)isWildcat;
@end
/* }}} */

/* {{{ Locals */
static BOOL _Firmware_lt_60 = NO;
/* }}} */

static NSMutableArray *_loadedSpecifiers = nil;
static NSInteger _extraPrefsGroupSectionID = 0;

/* {{{ iPad Hooks
   Declared as its own %group around a second %hook rather than as a %group nested inside
   one: current logos rejects the nested form. Both groups are initialised with the same
   class substitution, so they still target whichever root controller %ctor resolved. */
%group iPad
%hook PrefsListController
- (NSString *)tableView:(UITableView *)view titleForHeaderInSection:(NSInteger)section {
	if([_loadedSpecifiers count] == 0) return %orig;
	if(section == _extraPrefsGroupSectionID) return _Firmware_lt_60 ? @"Extensions" : NULL;
	return %orig;
}

- (CGFloat)tableView:(UITableView *)view heightForHeaderInSection:(NSInteger)section {
	if([_loadedSpecifiers count] == 0) return %orig;
	if(section == _extraPrefsGroupSectionID) return _Firmware_lt_60 ? 22.0f : 10.f;
	return %orig;
}
%end
%end
/* }}} */

static NSInteger PSSpecifierSort(PSSpecifier *a1, PSSpecifier *a2, void *context) {
	NSString *string1 = [a1 name];
	NSString *string2 = [a2 name];
	return [string1 localizedCaseInsensitiveCompare:string2];
}

%hook PrefsListController
- (id)specifiers {
	bool first = (MSHookIvar<id>(self, "_specifiers") == nil);
	if(first) {
		PLLog(@"initial invocation for -specifiers");
		%orig;
		[_loadedSpecifiers release];
		_loadedSpecifiers = [[NSMutableArray alloc] init];
		#if SIMULATOR
		NSString *preferencesDirectory = @"/opt/simject/PreferenceLoader/Preferences";
		#else
		NSString *preferencesDirectory = jbroot(@"/Library/PreferenceLoader/Preferences");
		#endif
		NSArray *subpaths = [[NSFileManager defaultManager] subpathsOfDirectoryAtPath:preferencesDirectory error:NULL];
		for(NSString *item in subpaths) {
			if(![[item pathExtension] isEqualToString:@"plist"]) continue;
			PLLog(@"processing %@", item);
			NSString *fullPath = [preferencesDirectory stringByAppendingPathComponent:item];
			NSDictionary *plPlist = [NSDictionary dictionaryWithContentsOfFile:fullPath];
			if(![PSSpecifier environmentPassesPreferenceLoaderFilter:[plPlist objectForKey:@"filter"] ?: [plPlist objectForKey:PLFilterKey]]) continue;

			NSDictionary *entry = [plPlist objectForKey:@"entry"];
			if(!entry) continue;
			PLLog(@"found an entry key for %@!", item);

			if(![PSSpecifier environmentPassesPreferenceLoaderFilter:[entry objectForKey:PLFilterKey]]) continue;

			NSArray *specs = [self specifiersFromEntry:entry sourcePreferenceLoaderBundlePath:[fullPath stringByDeletingLastPathComponent] title:[[item lastPathComponent] stringByDeletingPathExtension]];
			if(!specs) continue;

			// But it's possible for there to be more than one with an isController == 0 (PSBundleController) bundle.
			// so, set all the specifiers to etched mode (if necessary).
			if(pPSTableCellUseEtchedAppearanceKey && [UIDevice instancesRespondToSelector:@selector(isWildcat)] && [[UIDevice currentDevice] isWildcat])
				for(PSSpecifier *specifier in specs) {
					[specifier setProperty:[NSNumber numberWithBool:1] forKey:*pPSTableCellUseEtchedAppearanceKey];
				}

			PLLog(@"appending to the array!");
			[_loadedSpecifiers addObjectsFromArray:specs];
		}

		[_loadedSpecifiers sortUsingFunction:(NSInteger (*)(id, id, void *))&PSSpecifierSort context:NULL];

		if([_loadedSpecifiers count] > 0) {
			PLLog(@"so we gots us some specifiers! that's awesome! let's add them to the list...");
			PSSpecifier *groupSpecifier = [PSSpecifier groupSpecifierWithName:_Firmware_lt_60 ? @"Extensions" : nil];
			[_loadedSpecifiers insertObject:groupSpecifier atIndex:0];
			NSMutableArray *_specifiers = MSHookIvar<NSMutableArray *>(self, "_specifiers");
			PLLog(@"_specifiers = %@", _specifiers);
			NSInteger group, row;
			NSInteger firstindex;
			if ([self getGroup:&group row:&row ofSpecifierID:_Firmware_lt_60 ? @"General" : @"TWITTER"]) {
				firstindex = [self indexOfGroup:group] + [[self specifiersInGroup:group] count];
				PLLog(@"Adding to the end of group %ld at index %ld", (long)group, (long)firstindex);
			} else {
				firstindex = [_specifiers count];
				PLLog(@"Adding to the end of entire list");
			}
			NSIndexSet *indices = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(firstindex, [_loadedSpecifiers count])];
			[_specifiers insertObjects:_loadedSpecifiers atIndexes:indices];
			PLLog(@"getting group index");
			NSUInteger groupIndex = 0;
			for(PSSpecifier *spec in _specifiers) {
				if(MSHookIvar<NSInteger>(spec, "cellType") != PSGroupCell) continue;
				if(spec == groupSpecifier) break;
				++groupIndex;
			}
			_extraPrefsGroupSectionID = groupIndex;
			PLLog(@"group index is %ld", (long)_extraPrefsGroupSectionID);
		}
	}
	return MSHookIvar<id>(self, "_specifiers");
}
%end

/* {{{ iOS 18+ root list
   From iOS 18 the Settings root is a SwiftUI list and both classes hooked above are gone, so
   the specifier injection never runs. The entries are written into the SwiftUI model instead,
   as their own section at the bottom of the list. See PLRootList.h. */
%group RootList

%hook _TtC11SettingsApp24SettingsAppSceneDelegate

- (void)sceneDidBecomeActive:(id)scene {
	%orig;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		// The earliest point with a model worth watching: the section array is nil at scene
		// connect and keeps growing as the asynchronous providers report in. Installed without
		// a delay, because the rebuilds worth catching happen while the scene comes up.
		PLRootListInstallInjector();
	});
}

%end

%end
/* }}} */

/* {{{ Keeping the pushed pane on screen
   Settings pushes a container for the selected row, then decides that an identifier it does not
   know leads nowhere, clears the selection and takes the container away again. These hooks
   substitute the pane into that push and refuse the removal that follows, while leaving a pop
   the user asked for alone. */
%group Navigation

// A pop the user asked for goes through the navigation bar first: the back button offers the
// item up for popping, and the interactive gesture drives the same path. Settings' own
// housekeeping calls popViewControllerAnimated: directly. Telling the two apart matters in both
// directions -- refuse too much and the pane cannot be left, refuse too little and it is taken
// away as soon as it appears.
static BOOL gPLUserAskedToPop = NO;

// When the pane was put on screen. Settings removes it almost immediately, so a removal is only
// refused for a moment afterwards.
//
// The expiry is the important half: a refusal that cannot expire would wedge navigation for good
// if a removal ever arrived by a route that does not look user-initiated, leaving rows that
// highlight and never open until Settings is restarted.
static CFTimeInterval gPLPaneShownAt = 0;
static const CFTimeInterval kPLRefusalWindow = 2.0;

// The housekeeping pop does not only follow the push. Leaving Settings with a pane open and coming
// back rebuilds the model, Settings re-resolves the destination for the selected row, still does
// not recognise the identifier, and pops -- the same removal as at push time, arriving however long
// the app spent in the background later. Measured from when the pane appeared, that pop is always
// past the window and is always allowed, which is what takes the user out of the pane on return.
//
// Returning to the foreground therefore reopens the window. It is not an extension of the window's
// length: the deadlock the expiry guards against stays bounded, because each reopening lasts the
// same two seconds. A back the user asks for is recognised by the navigation bar and the pop
// gesture, so it is unaffected either way.
static void PLReopenRefusalWindowOnForeground(void) {
	[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification
	                                                object:nil
	                                                 queue:nil
	                                            usingBlock:^(NSNotification *notification) {
		gPLPaneShownAt = CACurrentMediaTime();
		PLRootListNoteForeground();
		PLRootListNote(@"[nav] foreground: reopened the refusal window");
	}];
}

#if DEBUG
// The stack as class names. A stack that keeps growing means the pushes land and something else
// hides them; one that never changes means the request never arrives.
static NSString *PLDescribeStack(UINavigationController *navigation) {
	NSMutableArray<NSString *> *names = [NSMutableArray array];
	for (UIViewController *controller in navigation.viewControllers) {
		[names addObject:NSStringFromClass(controller.class)];
	}
	return [names componentsJoinedByString:@" > "];
}
#endif

// An expanded split view fills its detail column by hosting the destination as a child view
// controller during SwiftUI's commit, so no UINavigationController method is called and none of
// the hooks below fire. The containment callback is the one UIKit event inside that commit, and
// the selection is already written by then, so reacting here swaps the column in the same frame
// rather than one frame late.
%hook UIViewController

- (void)didMoveToParentViewController:(UIViewController *)parent {
	%orig;
	if (parent) PLRootListFillDetailColumn();
}

%end

// Revealing a row is what moves the root list away from where the user left it, and it is animated,
// so the first frame is already wrong by the time anything outside CoreAnimation's commit could put
// it back. The scroll is dropped instead of corrected. Both entry points are guarded by a timestamp
// comparison that is false almost always, so this costs a load and a branch on an ordinary scroll.
%hook UIScrollView

- (void)setContentOffset:(CGPoint)offset animated:(BOOL)animated {
	if (PLRootListShouldRefuseScroll(self)) return;
	%orig;
}

- (void)scrollRectToVisible:(CGRect)rect animated:(BOOL)animated {
	if (PLRootListShouldRefuseScroll(self)) return;
	%orig;
}

%end

%hook UINavigationController

- (BOOL)navigationBar:(UINavigationBar *)bar shouldPopItem:(UINavigationItem *)item {
	gPLUserAskedToPop = YES;
	return %orig;
}

// Whether an object's class comes out of the SwiftUI framework. Matched by the class's home
// image rather than by name: the coordinator classes are generic Swift types whose mangled
// names shift between releases, while the framework they live in does not.
static BOOL PLIsSwiftUIObject(id object) {
	NSString *identifier = [NSBundle bundleForClass:[object class]].bundleIdentifier;
	return [identifier hasPrefix:@"com.apple.SwiftUI"];
}

// SwiftUI drives this stack through the UINavigationController delegate: its coordinator installs
// itself there and relies on the didShow callback to reconcile its record of the stack after each
// transition. A preference pane that makes itself the delegate and never restores it leaves
// SwiftUI waiting for a callback that never comes; from then on the model keeps resolving
// destinations while the stack no longer moves, and every row highlights without opening until
// Settings is relaunched. Hush's pane does this from its viewDidLoad. A delegate change that takes
// the slot from SwiftUI is therefore refused -- the pane loses transition callbacks it cannot be
// allowed to have.
- (void)setDelegate:(id)delegate {
	if (delegate && PLIsSwiftUIObject(self.delegate) && !PLIsSwiftUIObject(delegate)) {
		PLRootListNote([NSString stringWithFormat:@"[nav] refused delegate %@ over %@",
		                NSStringFromClass([delegate class]), NSStringFromClass([self.delegate class])]);
		return;
	}
	%orig;
}

- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated {
	// Substituted rather than filled afterwards: Settings builds an empty container with a
	// placeholder title for an identifier it cannot resolve, and swapping it for the real pane
	// here means one push with the right content and title from the first frame.
	//
	// Limited to the push that leaves the root list. The selection stays set while a pane is
	// open, so otherwise the hook fires again when that pane pushes a page of its own and
	// replaces it with a second copy of itself.
	UIViewController *pane = (self.viewControllers.count == 1)
		? PLRootListPaneForCurrentSelection() : nil;
	if (pane) {
		// UIKit raises if the same view controller is pushed twice, and an exception thrown out
		// of here lands in the middle of SwiftUI's update, leaving the stack half-changed.
		if ([self.viewControllers containsObject:pane]) {
			PLRootListNote([NSString stringWithFormat:@"[nav] pane %p is already on the stack; not substituting", pane]);
			pane = nil;
		} else {
			gPLPaneShownAt = CACurrentMediaTime();
			// A preference controller reaches its navigation stack through its root controller,
			// which in Settings is a PSRootController and therefore a navigation controller. A
			// pane built outside that hierarchy has none, and the messages it sends looking for
			// one arrive back at itself. Handing it the controller it is about to be pushed onto
			// gives it what Settings would have.
			[(PSViewController *)pane setRootController:(id)self];
			PLRootListNote([NSString stringWithFormat:@"[nav] substituting %@ %p (stack %lu)",
			                NSStringFromClass(pane.class), pane,
			                (unsigned long)self.viewControllers.count]);
		}
	}
	// Every push, not only the substituted ones: when navigation stops working, what Settings
	// still attempts is the part that cannot be seen from the tweak's own actions.
	PLRootListNote([NSString stringWithFormat:@"[nav] push %@%@ onto [%@]",
	                NSStringFromClass(controller.class),
	                pane ? @" [substituted]" : @"",
	                PLDescribeStack(self)]);
	@try {
		%orig(pane ?: controller, animated);
	} @catch (NSException *exception) {
		PLRootListNote([NSString stringWithFormat:@"[nav] push raised %@: %@",
		                exception.name, exception.reason]);
	}
}

- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
	PLRootListNote([NSString stringWithFormat:@"[nav] pop (ours %d) from [%@]",
	                PLRootListIsFilledContainer(self.topViewController),
	                PLDescribeStack(self)]);
	if (!PLRootListIsFilledContainer(self.topViewController)) return %orig;

	BOOL interactive = self.interactivePopGestureRecognizer.state == UIGestureRecognizerStateBegan ||
	                   self.interactivePopGestureRecognizer.state == UIGestureRecognizerStateChanged;
	BOOL expired = CACurrentMediaTime() - gPLPaneShownAt > kPLRefusalWindow;
	if (gPLUserAskedToPop || interactive || expired) {
		gPLUserAskedToPop = NO;
		// The pane is not released here: that would run the tweak's own teardown, which not
		// every tweak survives. Panes are kept for the life of the process instead.
		return %orig;
	}

	PLRootListNote(@"[nav] refused to drop the filled pane");
	// SwiftUI treats the pop as done regardless, and rebuilding the root list scrolls it back to
	// the top. Taken here, while the list is still behind the pane, and written back over the next
	// few turns.
	PLRootListHoldRootScroll();
	return nil;
}

%end

%end
/* }}} */

%ctor {
	PLCrashLogInstall();
	PLRootListNote([NSString stringWithFormat:@"ctor in %@", NSBundle.mainBundle.bundleIdentifier]);

	// Only the two real root list controllers. Upstream also falls back to PSGGeneralController,
	// which on iOS 18 and later is every launch, and puts the entries inside General; the root
	// list injector places them at the bottom of the base Settings list instead.
	Class targetRootClass = objc_getClass("PSUIPrefsListController");
	if (targetRootClass == Nil) {
		targetRootClass = objc_getClass("PrefsListController");
	}
	PLLog(@"targetRootClass = %s", targetRootClass ? class_getName(targetRootClass) : "(none)");
	// Nothing to substitute when the class is gone, and %init on Nil would register hooks that
	// can never fire.
	if (targetRootClass != Nil) {
		%init(PrefsListController = targetRootClass);
	}

	// Gated on the class rather than on a version number: a version check cannot notice Apple
	// moving or renaming the scene delegate, an objc_getClass probe can.
	PLRootListNote([NSString stringWithFormat:@"targetRootClass = %s",
	               targetRootClass ? class_getName(targetRootClass) : "(none)"]);
	if (objc_getClass("_TtC11SettingsApp24SettingsAppSceneDelegate")) {
		%init(RootList);
		%init(Navigation);
		PLReopenRefusalWindowOnForeground();
		PLRootListNote(@"root list injector installed");
	}

	_Firmware_lt_60 = kCFCoreFoundationVersionNumber < 793.00;
	if(targetRootClass != Nil && [UIDevice instancesRespondToSelector:@selector(isWildcat)] && [[UIDevice currentDevice] isWildcat])
		%init(iPad, PrefsListController = targetRootClass);

	void *preferencesHandle = dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_LAZY | RTLD_NOLOAD);
	if(preferencesHandle) {
		pPSTableCellUseEtchedAppearanceKey = (NSString **)dlsym(preferencesHandle, "PSTableCellUseEtchedAppearanceKey");
		dlclose(preferencesHandle);
	}
}
