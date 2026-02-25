#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Create the application and assign our delegate before running.
        // Do NOT call NSApplicationMain() — it would re-initialise NSApp
        // and ignore the delegate we set here.
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
