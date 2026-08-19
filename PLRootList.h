#import <UIKit/UIKit.h>

// Puts the PreferenceLoader entries into the Settings root list on iOS 18 and later.
//
// From iOS 18 the root is a SwiftUI list driven by SettingsApp.PrimarySettingsListModel.
// PSUIPrefsListController and PrefsListController are gone, so the specifier injection in
// Tweak.xm has nothing left to hook. The entries are written into that model instead, as
// their own section at the bottom of the list -- where they also sit on iOS 17 and earlier.
//
// Offsets and enum tags are resolved through the Swift runtime rather than written down, so
// a layout change in a future release fails to resolve instead of corrupting the model. See
// PLSwiftMeta.h.

#ifdef __cplusplus
extern "C" {
#endif

// Installs a runloop observer that appends the section to each snapshot Apple publishes.
//
// The model is rebuilt several times while Settings launches, and every rebuild is published
// through the observation machinery that makes SwiftUI evaluate the list. Injecting into a new
// snapshot before that evaluation needs no redraw trigger of its own; injecting afterwards
// would need a way to make SwiftUI look again, and there is none reachable from here.
void PLRootListInstallInjector(void);

// Appends the section to the current snapshot. Called by the observer. Nothing is written to
// disk and nothing survives a relaunch of Settings.
void PLRootListInjectTweakSection(void);

// The pane for the row selected right now, or nil if the selection is not one of ours.
//
// Read at the moment Settings pushes rather than prepared in advance: the push happens in the
// same pass as the tap, while the runloop observer only sees the selection afterwards.
UIViewController *PLRootListPaneForCurrentSelection(void);

// Whether this is a pane the tweak built. Lets the navigation hooks tell Settings' own
// housekeeping apart from the user leaving a pane.
BOOL PLRootListIsFilledContainer(UIViewController *controller);

// Puts the selected tweak's pane in the split view's detail column, or restores SwiftUI's own
// detail host once the selection is no longer one of ours.
//
// Does nothing unless the split view is expanded. A collapsed one -- any phone, and an iPad in
// a Stage Manager or resized window -- receives its panes by push instead, and filling its
// off-screen secondary column would take the pane back out of the pushed stack.
//
// Called from the runloop observer and from the containment hook in Tweak.xm; the hook exists
// because the observer alone is one frame late on the first selection, where Apple's own
// destination would flash.
void PLRootListFillDetailColumn(void);

// Takes the root list's current scroll position and holds it for a moment.
//
// Called wherever returning from the background costs the list its position: on a phone, SwiftUI
// records the pop it asked for even though it was refused, and rebuilding the root list scrolls it
// to the top; on an expanded split view, Settings selects a row of its own near the top and
// SwiftUI scrolls there to reveal it. A hold already running keeps its original offset.
void PLRootListHoldRootScroll(void);

// Whether a programmatic scroll of this view should be dropped, because it would move the root
// list away from a position being held. Only ever true for the root list's own scroll view.
BOOL PLRootListShouldRefuseScroll(UIScrollView *scroll);

// The root list's scroll view, or nil. Exposed for the navigation trace.
UIScrollView *PLRootListRootScrollView(void);

// Records that the app has just returned to the foreground.
//
// Settings rewrites its selection on the way back in. On an expanded split view that would
// otherwise deselect an open tweak pane and put an Apple page in its place, so for a moment
// afterwards the selection is put back rather than followed.
void PLRootListNoteForeground(void);

// Appends a line to the tweak's log. DEBUG builds only: NSLog is not readable from a shell on
// the device, so PLRootLog also writes to /var/mobile/pl/rootlist.log. In release builds this
// expands to nothing, which drops the arguments at each call site as well.
#if DEBUG
void PLRootListNote(NSString *message);
#else
// Variadic so a call whose argument contains commas -- +stringWithFormat: with parameters, as
// most of them are -- still parses once this expands to nothing.
#define PLRootListNote(...) ((void)0)
#endif

#ifdef __cplusplus
}
#endif
