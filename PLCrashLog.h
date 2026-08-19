#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// DEBUG builds only. Records an uncaught ObjC exception or a fatal signal into the tweak's own
// log, so a failure appears in order with what led up to it instead of only in a .ips report
// that has to be fetched and decoded.
//
// Neither handler makes the process survive: both log and then let the crash proceed, so
// Apple's own report is still written.
#if DEBUG
void PLCrashLogInstall(void);
#else
#define PLCrashLogInstall(...) ((void)0)
#endif

#ifdef __cplusplus
}
#endif
