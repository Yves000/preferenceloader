#import "PLCrashLog.h"
#import "PLRootList.h"
#import <execinfo.h>
#import <signal.h>

#if DEBUG

enum { kPLMaxFrames = 24, kPLLoggedFrames = 18 };

static NSUncaughtExceptionHandler *gPLPreviousHandler = NULL;

// Only the top frames: the rest is UIKit and the runloop.
static void PLLogBacktrace(NSArray<NSString *> *symbols) {
    NSUInteger limit = MIN(symbols.count, (NSUInteger)kPLLoggedFrames);
    for (NSUInteger i = 0; i < limit; i++) {
        PLRootListNote([NSString stringWithFormat:@"[crash]   %@", symbols[i]]);
    }
}

static void PLHandleException(NSException *exception) {
    PLRootListNote([NSString stringWithFormat:@"[crash] %@: %@", exception.name, exception.reason]);
    PLLogBacktrace(exception.callStackSymbols);
    if (gPLPreviousHandler) gPLPreviousHandler(exception);
}

static void PLHandleSignal(int signal) {
    void *frames[kPLMaxFrames];
    int count = backtrace(frames, kPLMaxFrames);
    char **symbols = backtrace_symbols(frames, count);
    PLRootListNote([NSString stringWithFormat:@"[crash] signal %d", signal]);
    if (symbols) {
        // backtrace_symbols allocates, which is not async-signal-safe. Accepted here: the
        // process is going down either way and a readable trace is worth more on the way out.
        for (int i = 0; i < count && i < kPLLoggedFrames; i++) {
            PLRootListNote([NSString stringWithFormat:@"[crash]   %s", symbols[i]]);
        }
        free(symbols);
    }
    // Back to the default so the crash proceeds and Apple's own report is still produced.
    struct sigaction action = { 0 };
    action.sa_handler = SIG_DFL;
    sigaction(signal, &action, NULL);
    raise(signal);
}

void PLCrashLogInstall(void) {
    gPLPreviousHandler = NSGetUncaughtExceptionHandler();
    NSSetUncaughtExceptionHandler(&PLHandleException);

    struct sigaction action = { 0 };
    action.sa_handler = &PLHandleSignal;
    sigemptyset(&action.sa_mask);
    action.sa_flags = SA_RESETHAND;
    static const int kSignals[] = { SIGSEGV, SIGBUS, SIGABRT, SIGILL };
    for (size_t i = 0; i < sizeof(kSignals) / sizeof(kSignals[0]); i++) {
        sigaction(kSignals[i], &action, NULL);
    }
    PLRootListNote(@"[crash] handlers installed");
}

#endif
