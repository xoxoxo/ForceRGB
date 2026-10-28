#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <ServiceManagement/ServiceManagement.h>
#import <dlfcn.h>
#import <math.h>
#import <unistd.h>

// Apple Silicon does not honor /Library/Displays EDID overrides. The DCP
// accepts a runtime EDID through the private IOAVService user client, which
// is what actually makes an HDMI sink stop advertising YCbCr (shown as YPbPr).
// The override lasts until the display service is torn down, so the app
// reapplies it after login, wake, and reconnect.

typedef CFTypeRef IOAVServiceRef;
typedef IOAVServiceRef (*IOAVCreateFn)(CFAllocatorRef, io_service_t);
typedef IOReturn (*IOAVCopyEDIDFn)(IOAVServiceRef, CFDataRef *);
typedef IOReturn (*IOAVSetEDIDFn)(IOAVServiceRef, uint32_t, CFDataRef);
typedef IOReturn (*IOAVLinkFn)(IOAVServiceRef, uint32_t, void *);
typedef const char *(*IOAVEncodingNameFn)(uint32_t);

enum {
    kSetVirtualEDID = 1,
    kClearVirtualEDID = 0,
    kVideoLinkCommand = 1,
    kLinkDataSize = 0x110,
    kBitDepthOffset = 0x18,
    kEncodingOffset = 0x1C,
};
static NSString *const kForceKey = @"ForceRGBEnabled";
static NSString *const kAppName = @"Rads macOS Mini Toolbox";
static NSString *const kConfirmedKey = @"ConfirmedRGBDisplays";
static const NSInteger kConfirmSeconds = 15;

static IOAVCreateFn gCreate;
static IOAVCopyEDIDFn gCopyEDID;
static IOAVSetEDIDFn gSetEDID;
static IOAVLinkFn gLinkData;
static IOAVEncodingNameFn gEncodingName;

static void loadPrivateAPI(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        gCreate = dlsym(iokit, "IOAVServiceCreateWithService");
        gCopyEDID = dlsym(iokit, "IOAVServiceCopyEDID");
        gSetEDID = dlsym(iokit, "IOAVServiceSetVirtualEDIDMode");
        gLinkData = dlsym(iokit, "IOAVServiceGetLinkData");
        gEncodingName = dlsym(iokit, "IOAVVideoPixelEncodingString");
    });
}

static void edidChecksum(uint8_t *block) {
    unsigned sum = 0;
    for (int i = 0; i < 127; i++) sum += block[i];
    block[127] = (uint8_t)((0x100 - (sum & 0xff)) & 0xff);
}

// Clear CTA-861 YCbCr 4:4:4 / 4:2:2 (and HDMI deep-color YCbCr) while keeping
// the extension block, so 1440p high-refresh timings stay advertised.
static BOOL patchEDIDForceRGB(uint8_t *edid, size_t length) {
    if (length < 128 || edid[0] != 0x00 || edid[1] != 0xff) return NO;
    BOOL changed = NO;
    // EDID 1.4 stores YCbCr support in byte 0x18. On 1.3 those same bits are the
    // display type, and this Dell is 1.3 with them already meaning "RGB color".
    BOOL edid14 = edid[0x12] == 1 && edid[0x13] >= 4 && (edid[0x14] & 0x80);
    if (edid14 && (edid[0x18] & 0x18)) {
        edid[0x18] &= (uint8_t)~0x18;
        changed = YES;
    }
    int extensions = edid[126];
    for (int extension = 0; extension < extensions; extension++) {
        size_t offset = (size_t)(extension + 1) * 128;
        if (offset + 128 > length) break;
        uint8_t *block = edid + offset;
        if (block[0] != 0x02 || block[1] < 3) continue;
        if (block[3] & 0x30) {
            block[3] &= (uint8_t)~0x30;
            changed = YES;
        }
        int end = block[2];
        if (end < 4 || end > 127) {
            edidChecksum(block);
            continue;
        }
        for (int i = 4; i < end;) {
            int tag = block[i] >> 5;
            int payloadLength = block[i] & 0x1f;
            if (i + 1 + payloadLength > end) break;
            uint8_t *payload = &block[i + 1];
            BOOL hdmiVSDB = tag == 3 && payloadLength >= 6 &&
                payload[0] == 0x03 && payload[1] == 0x0c && payload[2] == 0x00;
            if (hdmiVSDB && (payload[5] & 0x08)) {
                payload[5] &= (uint8_t)~0x08;
                changed = YES;
            }
            BOOL ycc420 = tag == 7 && payloadLength >= 2 && (payload[0] == 14 || payload[0] == 15);
            if (ycc420) {
                for (int k = 1; k < payloadLength; k++) {
                    if (payload[k]) {
                        payload[k] = 0;
                        changed = YES;
                    }
                }
            }
            i += 1 + payloadLength;
        }
        edidChecksum(block);
    }
    edidChecksum(edid);
    return changed;
}

static BOOL edidAdvertisesYCbCr(NSData *edid) {
    const uint8_t *bytes = edid.bytes;
    if (edid.length < 128 || bytes[0] != 0x00) return NO;
    int extensions = bytes[126];
    for (int extension = 0; extension < extensions; extension++) {
        size_t offset = (size_t)(extension + 1) * 128;
        if (offset + 4 > edid.length) break;
        if (bytes[offset] == 0x02 && (bytes[offset + 3] & 0x30)) return YES;
    }
    return NO;
}

static NSString *edidProductName(NSData *edid) {
    const uint8_t *bytes = edid.bytes;
    if (edid.length < 128) return @"External display";
    for (int descriptor = 0; descriptor < 4; descriptor++) {
        const uint8_t *block = bytes + 54 + descriptor * 18;
        if (block[0] == 0 && block[1] == 0 && block[2] == 0 && block[3] == 0xfc) {
            NSData *raw = [NSData dataWithBytes:block + 5 length:13];
            NSString *name = [[NSString alloc] initWithData:raw encoding:NSASCIIStringEncoding];
            name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (name.length) return name;
        }
    }
    return @"External display";
}

// Manufacturer, product code and serial number. The RGB patch never touches
// these bytes, so a monitor keeps the same identifier with the override on.
static NSString *edidIdentifier(NSData *edid) {
    if (edid.length < 18) return nil;
    const uint8_t *bytes = edid.bytes;
    NSMutableString *identifier = [NSMutableString string];
    for (int i = 8; i < 18; i++) [identifier appendFormat:@"%02x", bytes[i]];
    return identifier;
}

@interface DisplayState : NSObject
@property(copy) NSString *name;
@property(copy) NSString *identifier;
@property(copy) NSString *format;
@property uint32_t encoding;
@property uint32_t bitDepth;
@property BOOL rgb;
@property BOOL overrideActive;
@property IOReturn lastError;
@end

@implementation DisplayState
@end

static DisplayState *stateFromService(io_service_t service) {
    loadPrivateAPI();
    if (!gCreate || !gCopyEDID || !gSetEDID || !gLinkData) return nil;

    CFTypeRef location = IORegistryEntrySearchCFProperty(
        service, kIOServicePlane, CFSTR("Location"), kCFAllocatorDefault, kIORegistryIterateRecursively);
    BOOL embedded = location && CFEqual(location, CFSTR("Embedded"));
    if (location) CFRelease(location);
    if (embedded) return nil;

    IOAVServiceRef av = gCreate(kCFAllocatorDefault, service);
    if (!av) return nil;

    DisplayState *state = [DisplayState new];
    state.lastError = kIOReturnSuccess;
    CFDataRef edidRef = NULL;
    IOReturn copyResult = gCopyEDID(av, &edidRef);
    if (copyResult == kIOReturnSuccess && edidRef) {
        NSData *edid = CFBridgingRelease(edidRef);
        state.name = edidProductName(edid);
        state.identifier = edidIdentifier(edid) ?: state.name;
        state.overrideActive = !edidAdvertisesYCbCr(edid);
    } else {
        state.name = @"External display";
        state.identifier = state.name;
        state.lastError = copyResult;
    }

    uint8_t link[kLinkDataSize];
    memset(link, 0, sizeof link);
    if (gLinkData(av, kVideoLinkCommand, link) == kIOReturnSuccess) {
        uint32_t bitDepth = 0;
        uint32_t encoding = 0;
        memcpy(&bitDepth, link + kBitDepthOffset, sizeof bitDepth);
        memcpy(&encoding, link + kEncodingOffset, sizeof encoding);
        state.bitDepth = bitDepth;
        state.encoding = encoding;
        state.rgb = encoding == 0;
        const char *name = gEncodingName ? gEncodingName(encoding) : NULL;
        NSString *format = name ? [NSString stringWithUTF8String:name] : @"Unknown";
        if (bitDepth >= 8 && bitDepth <= 16) {
            format = [NSString stringWithFormat:@"%@ · %u-bit", format, bitDepth];
        }
        state.format = format;
    } else {
        state.format = @"Unknown link";
    }
    CFRelease(av);
    return state;
}

static NSArray<DisplayState *> *externalDisplays(void) {
    io_iterator_t iterator = 0;
    kern_return_t result = IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator);
    if (result != KERN_SUCCESS) return @[];
    NSMutableArray<DisplayState *> *displays = [NSMutableArray array];
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        DisplayState *state = stateFromService(service);
        if (state) [displays addObject:state];
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return displays;
}

static IOReturn applyToExternalDisplays(BOOL forceRGB) {
    loadPrivateAPI();
    io_iterator_t iterator = 0;
    kern_return_t match = IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator);
    if (match != KERN_SUCCESS) return match;
    IOReturn status = kIOReturnNotFound;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef location = IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, CFSTR("Location"), kCFAllocatorDefault, kIORegistryIterateRecursively);
        BOOL embedded = location && CFEqual(location, CFSTR("Embedded"));
        if (location) CFRelease(location);
        if (embedded) {
            IOObjectRelease(service);
            continue;
        }
        IOAVServiceRef av = gCreate(kCFAllocatorDefault, service);
        IOObjectRelease(service);
        if (!av) continue;
        if (!forceRGB) {
            status = gSetEDID(av, kClearVirtualEDID, NULL);
            CFRelease(av);
            continue;
        }
        CFDataRef edidRef = NULL;
        IOReturn copyResult = gCopyEDID(av, &edidRef);
        if (copyResult != kIOReturnSuccess || !edidRef) {
            status = copyResult;
            CFRelease(av);
            continue;
        }
        NSMutableData *edid = [CFBridgingRelease(edidRef) mutableCopy];
        BOOL linkIsRGB = NO;
        uint8_t link[kLinkDataSize];
        memset(link, 0, sizeof link);
        if (gLinkData(av, kVideoLinkCommand, link) == kIOReturnSuccess) {
            uint32_t encoding = 0;
            memcpy(&encoding, link + kEncodingOffset, sizeof encoding);
            linkIsRGB = encoding == 0;
        }
        if (!edidAdvertisesYCbCr(edid) && linkIsRGB) {
            status = kIOReturnSuccess;
            CFRelease(av);
            continue;
        }
        patchEDIDForceRGB(edid.mutableBytes, edid.length);
        status = gSetEDID(av, kSetVirtualEDID, (__bridge CFDataRef)edid);
        CFRelease(av);
    }
    IOObjectRelease(iterator);
    return status;
}

static int printStatus(void) {
    NSArray<DisplayState *> *displays = externalDisplays();
    if (displays.count == 0) {
        printf("No external display.\n");
        return 1;
    }
    for (DisplayState *display in displays) {
        printf("%s: %s%s\n",
               display.name.UTF8String,
               display.format.UTF8String,
               display.overrideActive ? " (RGB override active)" : "");
    }
    return 0;
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property NSStatusItem *statusItem;
@property BOOL applying;
@property BOOL confirming;
@property(strong) NSObject *windowMover;
- (void)scheduleRefresh;
@end

// Accessibility window coordinates start at the top-left of the primary display
// and grow downward. AppKit screen coordinates start at the bottom-left.
static CGPoint axPositionForCocoaFrame(CGRect frame) {
    NSRect primary = NSScreen.screens.firstObject.frame;
    return CGPointMake(frame.origin.x, NSMaxY(primary) - NSMaxY(frame));
}

static CGRect cocoaFrameForAX(CGPoint position, CGSize size) {
    NSRect primary = NSScreen.screens.firstObject.frame;
    return CGRectMake(position.x, NSMaxY(primary) - position.y - size.height, size.width, size.height);
}

static NSString *axCopyString(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) return nil;
    if (CFGetTypeID(value) != CFStringGetTypeID()) {
        CFRelease(value);
        return nil;
    }
    return CFBridgingRelease(value);
}

static BOOL axCopyBool(AXUIElementRef element, CFStringRef attribute) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, attribute, &value) != kAXErrorSuccess || !value) return NO;
    BOOL result = CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue(value);
    CFRelease(value);
    return result;
}

static BOOL axCopyPosition(AXUIElementRef element, CGPoint *position) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXPositionAttribute, &value) != kAXErrorSuccess || !value) return NO;
    BOOL ok = CFGetTypeID(value) == AXValueGetTypeID() &&
        AXValueGetValue((AXValueRef)value, kAXValueCGPointType, position);
    CFRelease(value);
    return ok;
}

static BOOL axCopySize(AXUIElementRef element, CGSize *size) {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(element, kAXSizeAttribute, &value) != kAXErrorSuccess || !value) return NO;
    BOOL ok = CFGetTypeID(value) == AXValueGetTypeID() &&
        AXValueGetValue((AXValueRef)value, kAXValueCGSizeType, size);
    CFRelease(value);
    return ok && size->width >= 1 && size->height >= 1;
}

static BOOL axSetSize(AXUIElementRef element, CGSize size) {
    AXValueRef value = AXValueCreate(kAXValueCGSizeType, &size);
    BOOL ok = AXUIElementSetAttributeValue(element, kAXSizeAttribute, value) == kAXErrorSuccess;
    CFRelease(value);
    return ok;
}

static BOOL axSetPosition(AXUIElementRef element, CGPoint position) {
    AXValueRef value = AXValueCreate(kAXValueCGPointType, &position);
    BOOL ok = AXUIElementSetAttributeValue(element, kAXPositionAttribute, value) == kAXErrorSuccess;
    CFRelease(value);
    return ok;
}

static void axUnminimize(AXUIElementRef window) {
    if (axCopyBool(window, kAXMinimizedAttribute)) {
        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute, kCFBooleanFalse);
    }
}

// Size before and after the move, because apps clamp a window's size to the
// display it is currently on.
static BOOL setWindowFrame(AXUIElementRef window, CGRect frame) {
    axSetSize(window, frame.size);
    BOOL moved = axSetPosition(window, axPositionForCocoaFrame(frame));
    axSetSize(window, frame.size);
    return moved;
}

// Keep the window's size when it already fits. Shrink it to the visible area
// when it is stretched across two displays, then center that rect. A window
// that refuses to shrink is parked so its title bar stays on the display.
static BOOL centerWindowInRect(AXUIElementRef window, NSRect visible) {
    CGSize size;
    if (!axCopySize(window, &size)) return NO;
    if (NSWidth(visible) < 1 || NSHeight(visible) < 1) return NO;

    CGSize original = size;
    CGSize fitted = size;
    if (fitted.width > NSWidth(visible)) fitted.width = NSWidth(visible);
    if (fitted.height > NSHeight(visible)) fitted.height = NSHeight(visible);
    BOOL needsShrink = fitted.width + 0.5 < original.width || fitted.height + 0.5 < original.height;
    if (needsShrink) {
        axSetSize(window, fitted);
        CGSize reported = original;
        if (axCopySize(window, &reported) &&
            reported.width <= fitted.width + 2 &&
            reported.height <= fitted.height + 2) {
            size = reported;
        }
    }

    CGRect frame = CGRectMake(
        round(NSMidX(visible) - size.width / 2.0),
        round(NSMidY(visible) - size.height / 2.0),
        size.width,
        size.height);
    if (size.width > NSWidth(visible)) frame.origin.x = NSMinX(visible);
    if (size.height > NSHeight(visible)) frame.origin.y = NSMaxY(visible) - size.height;
    BOOL moved = axSetPosition(window, axPositionForCocoaFrame(frame));
    AXUIElementPerformAction(window, kAXRaiseAction);
    return moved;
}

static void presentAlert(NSString *message, NSString *detail) {
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = message;
    alert.informativeText = detail;
    [alert runModal];
}

static BOOL ensureAccessibility(void) {
    if (AXIsProcessTrusted()) return YES;
    [NSApp activateIgnoringOtherApps:YES];
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Accessibility Access Needed";
    alert.informativeText = [NSString stringWithFormat:
        @"Turn on %1$@ in Privacy & Security → Accessibility, then choose App Window Fixer again.\n\n"
        @"If %1$@ is already on, that entry is from an older copy of the app. Select it, click −, then click + and add %1$@ from Applications.",
        kAppName];
    [alert addButtonWithTitle:@"Open System Settings"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSURL *url = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"];
        [NSWorkspace.sharedWorkspace openURL:url];
    }
    return NO;
}

static CGDirectDisplayID screenID(NSScreen *screen) {
    return [screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
}

static NSString *screenName(NSScreen *screen) {
    NSString *name = screen.localizedName.length ? screen.localizedName : @"Display";
    return screen == NSScreen.screens.firstObject ? [name stringByAppendingString:@" (main)"] : name;
}

@interface WindowEntry : NSObject
@property(strong) id element;
@property(strong) NSRunningApplication *app;
@property(copy) NSString *title;
@property CGRect frame;
@property BOOL minimized;
@property(copy) NSString *location;
@property BOOL misplaced;
@end

@implementation WindowEntry
- (AXUIElementRef)ref {
    return (__bridge AXUIElementRef)self.element;
}
@end

static void describeLocation(WindowEntry *entry) {
    entry.misplaced = NO;
    if (entry.app.hidden) {
        entry.location = @"Hidden";
        return;
    }
    if (entry.minimized) {
        entry.location = @"Minimized";
        return;
    }
    CGFloat area = NSWidth(entry.frame) * NSHeight(entry.frame);
    CGFloat covered = 0;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        NSRect overlap = NSIntersectionRect(screen.frame, entry.frame);
        CGFloat overlapArea = NSWidth(overlap) * NSHeight(overlap);
        covered += overlapArea;
        if (overlapArea > area * 0.02) [names addObject:screenName(screen)];
    }
    if (names.count == 0) {
        entry.location = @"Off screen";
        entry.misplaced = YES;
    } else if (names.count > 1) {
        entry.location = [@"Between " stringByAppendingString:[names componentsJoinedByString:@" and "]];
        entry.misplaced = YES;
    } else if (covered < area * 0.95) {
        entry.location = [@"Partly off " stringByAppendingString:names.firstObject];
        entry.misplaced = YES;
    } else {
        entry.location = names.firstObject;
    }
}

static NSArray<WindowEntry *> *listWindows(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5);
    });
    NSMutableArray<WindowEntry *> *entries = [NSMutableArray array];
    NSString *standard = (__bridge NSString *)kAXStandardWindowSubrole;
    NSString *dialog = (__bridge NSString *)kAXDialogSubrole;
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.processIdentifier == getpid() || app.activationPolicy == NSApplicationActivationPolicyProhibited) continue;
        AXUIElementRef appElement = AXUIElementCreateApplication(app.processIdentifier);
        if (!appElement) continue;
        CFTypeRef windows = NULL;
        AXError error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute, &windows);
        CFRelease(appElement);
        if (error != kAXErrorSuccess || !windows) continue;
        if (CFGetTypeID(windows) == CFArrayGetTypeID()) {
            for (id object in (__bridge NSArray *)windows) {
                AXUIElementRef window = (__bridge AXUIElementRef)object;
                NSString *subrole = axCopyString(window, kAXSubroleAttribute);
                if (subrole && ![subrole isEqualToString:standard] && ![subrole isEqualToString:dialog]) continue;
                if (axCopyBool(window, CFSTR("AXFullScreen"))) continue;
                CGPoint position;
                CGSize size;
                if (!axCopyPosition(window, &position) || !axCopySize(window, &size)) continue;
                if (size.width < 40 || size.height < 40) continue;
                WindowEntry *entry = [WindowEntry new];
                entry.element = object;
                entry.app = app;
                entry.title = axCopyString(window, kAXTitleAttribute) ?: @"";
                entry.frame = cocoaFrameForAX(position, size);
                entry.minimized = axCopyBool(window, kAXMinimizedAttribute);
                describeLocation(entry);
                [entries addObject:entry];
            }
        }
        CFRelease(windows);
    }
    [entries sortUsingComparator:^NSComparisonResult(WindowEntry *a, WindowEntry *b) {
        if (a.misplaced != b.misplaced) return a.misplaced ? NSOrderedAscending : NSOrderedDescending;
        NSComparisonResult byApp = [a.app.localizedName ?: @"" localizedCaseInsensitiveCompare:b.app.localizedName ?: @""];
        return byApp != NSOrderedSame ? byApp : [a.title localizedCaseInsensitiveCompare:b.title];
    }];
    return entries;
}

static NSColor *screenColor(NSUInteger index) {
    NSArray<NSColor *> *colors = @[
        NSColor.systemBlueColor, NSColor.systemPurpleColor, NSColor.systemGreenColor,
        NSColor.systemOrangeColor, NSColor.systemPinkColor, NSColor.systemTealColor,
    ];
    return colors[index % colors.count];
}

static NSImage *colorDot(NSColor *color) {
    return [NSImage imageWithSize:NSMakeSize(10, 10) flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [color setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(rect, 1, 1)] fill];
        return YES;
    }];
}

static NSScreen *screenUnderFrame(CGRect frame) {
    NSScreen *best = nil;
    CGFloat bestArea = 0;
    for (NSScreen *screen in NSScreen.screens) {
        NSRect overlap = NSIntersectionRect(screen.frame, frame);
        CGFloat area = NSWidth(overlap) * NSHeight(overlap);
        if (area > bestArea) {
            best = screen;
            bestArea = area;
        }
    }
    return best;
}

// A scaled map of every display showing only the window selected in the list,
// so a busy desktop stays readable. That window can be dragged to move it
// and resized from its bottom-right corner. Edges snap to each display's usable
// area unless Option is held.
@interface ScreenMapView : NSView
@property(strong) WindowEntry *selected;
@property CGRect draft;
@property(copy) void (^onDrag)(CGRect frame);
@property(copy) void (^onDrop)(CGRect frame);
@property(copy) void (^onClick)(WindowEntry *entry);
@property(copy) void (^onDoubleClick)(WindowEntry *entry);
- (void)showSelected:(WindowEntry *)selected;
- (void)showDraft:(CGRect)frame;
@end

@implementation ScreenMapView {
    CGFloat _scale;
    NSPoint _offset;
    BOOL _dragging;
    BOOL _resizing;
    NSPoint _dragStart;
    CGRect _frameAtStart;
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (void)showSelected:(WindowEntry *)selected {
    self.selected = selected;
    self.draft = selected ? selected.frame : CGRectZero;
    [self changed];
}

- (void)showDraft:(CGRect)frame {
    if (!self.selected || _dragging) return;
    self.draft = frame;
    [self changed];
}

- (void)changed {
    self.needsDisplay = YES;
    [self.window invalidateCursorRectsForView:self];
}

// The map is laid out from the displays alone, so it never shifts when a
// window is selected or moved.
- (void)updateMapping {
    NSRect world = NSZeroRect;
    for (NSScreen *screen in NSScreen.screens) {
        world = NSIsEmptyRect(world) ? screen.frame : NSUnionRect(world, screen.frame);
    }
    if (NSWidth(world) < 1 || NSHeight(world) < 1) world = NSMakeRect(0, 0, 1, 1);
    world = NSInsetRect(world, -NSWidth(world) * 0.02, -NSHeight(world) * 0.03);
    NSRect area = NSInsetRect(self.bounds, 8, 8);
    _scale = MAX(MIN(NSWidth(area) / NSWidth(world), NSHeight(area) / NSHeight(world)), 0.0001);
    _offset = NSMakePoint(NSMidX(area) - NSMidX(world) * _scale, NSMidY(area) - NSMidY(world) * _scale);
}

- (NSRect)toView:(NSRect)rect {
    return NSMakeRect(rect.origin.x * _scale + _offset.x, rect.origin.y * _scale + _offset.y,
                      rect.size.width * _scale, rect.size.height * _scale);
}

- (NSRect)handleRect {
    NSRect rect = [self toView:self.draft];
    return NSMakeRect(NSMaxX(rect) - 11, NSMinY(rect), 11, 11);
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [self updateMapping];
    [[NSColor.labelColor colorWithAlphaComponent:0.04] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];

    NSArray<NSScreen *> *screens = NSScreen.screens;
    NSScreen *target = self.selected ? screenUnderFrame(self.draft) : nil;
    NSMutableParagraphStyle *centered = [NSMutableParagraphStyle new];
    centered.alignment = NSTextAlignmentCenter;
    centered.lineBreakMode = NSLineBreakByTruncatingTail;

    for (NSUInteger i = 0; i < screens.count; i++) {
        NSScreen *screen = screens[i];
        NSColor *color = screenColor(i);
        BOOL isTarget = screen == target;
        NSRect rect = NSInsetRect([self toView:screen.frame], 2, 2);
        NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:5 yRadius:5];
        [[color colorWithAlphaComponent:isTarget ? 0.32 : 0.18] setFill];
        [path fill];
        NSRect menuBar = NSIntersectionRect(rect, [self toView:NSMakeRect(
            NSMinX(screen.frame), NSMaxY(screen.visibleFrame),
            NSWidth(screen.frame), NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame))]);
        [[color colorWithAlphaComponent:0.35] setFill];
        NSRectFillUsingOperation(menuBar, NSCompositingOperationSourceOver);
        path.lineWidth = isTarget ? 3 : 1.5;
        [[color colorWithAlphaComponent:isTarget ? 1 : 0.75] setStroke];
        [path stroke];

        CGFloat nameSize = MAX(MIN(NSHeight(rect) * 0.09, 24), 11);
        NSDictionary *nameText = @{
            NSFontAttributeName: [NSFont systemFontOfSize:nameSize weight:NSFontWeightBold],
            NSForegroundColorAttributeName: [color colorWithAlphaComponent:0.55],
            NSParagraphStyleAttributeName: centered,
        };
        NSDictionary *sizeText = @{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:MAX(nameSize * 0.55, 10) weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: [color colorWithAlphaComponent:0.5],
            NSParagraphStyleAttributeName: centered,
        };
        NSString *size = [NSString stringWithFormat:@"%.0f × %.0f", NSWidth(screen.frame), NSHeight(screen.frame)];
        CGFloat sizeHeight = MAX(nameSize * 0.55, 10) + 4;
        [screenName(screen) drawInRect:NSMakeRect(NSMinX(rect) + 6, NSMidY(rect), NSWidth(rect) - 12, nameSize + 6)
                        withAttributes:nameText];
        [size drawInRect:NSMakeRect(NSMinX(rect) + 6, NSMidY(rect) - sizeHeight, NSWidth(rect) - 12, sizeHeight)
          withAttributes:sizeText];
    }

    if (!self.selected) return;
    NSRect rect = NSInsetRect([self toView:self.draft], 1, 1);
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowBlurRadius = 6;
    shadow.shadowOffset = NSMakeSize(0, -2);
    shadow.shadowColor = [NSColor.blackColor colorWithAlphaComponent:0.35];
    [shadow set];
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(rect);
    [NSGraphicsContext restoreGraphicsState];
    NSBezierPath *outline = [NSBezierPath bezierPathWithRect:rect];
    outline.lineWidth = 2;
    [NSColor.labelColor setStroke];
    [outline stroke];
    [NSColor.labelColor setFill];
    NSRectFill([self handleRect]);

    NSDictionary *titleText = @{
        NSFontAttributeName: [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: NSColor.labelColor,
        NSParagraphStyleAttributeName: centered,
    };
    NSDictionary *detailText = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
        NSParagraphStyleAttributeName: centered,
    };
    NSString *title = self.selected.app.localizedName ?: @"";
    NSString *size = [NSString stringWithFormat:@"%.0f × %.0f", NSWidth(self.draft), NSHeight(self.draft)];
    if (NSHeight(rect) > 34) {
        [title drawInRect:NSMakeRect(NSMinX(rect) + 2, NSMidY(rect), NSWidth(rect) - 4, 16) withAttributes:titleText];
        [size drawInRect:NSMakeRect(NSMinX(rect) + 2, NSMidY(rect) - 15, NSWidth(rect) - 4, 14) withAttributes:detailText];
    } else if (NSHeight(rect) > 16) {
        [title drawInRect:NSMakeRect(NSMinX(rect) + 2, NSMidY(rect) - 8, NSWidth(rect) - 4, 16) withAttributes:titleText];
    }
}

- (void)resetCursorRects {
    if (!self.selected) return;
    [self updateMapping];
    [self addCursorRect:[self toView:self.draft] cursor:NSCursor.openHandCursor];
    [self addCursorRect:NSInsetRect([self handleRect], -4, -4) cursor:NSCursor.crosshairCursor];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    [self updateMapping];
    if (event.clickCount == 2 && self.selected && NSPointInRect(point, [self toView:self.draft])) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(sendClick) object:nil];
        if (self.onDoubleClick) self.onDoubleClick(self.selected);
        return;
    }
    if (self.selected && NSPointInRect(point, NSInsetRect([self handleRect], -4, -4))) {
        _resizing = YES;
    } else if (self.selected && NSPointInRect(point, [self toView:self.draft])) {
        _resizing = NO;
    } else {
        return;
    }
    _dragging = YES;
    _dragStart = point;
    _frameAtStart = self.draft;
    if (!_resizing) [NSCursor.closedHandCursor push];
}

- (CGRect)snapMove:(CGRect)frame {
    CGFloat threshold = 8 / _scale;
    CGFloat bestX = threshold, bestY = threshold, shiftX = 0, shiftY = 0;
    for (NSScreen *screen in NSScreen.screens) {
        NSRect visible = screen.visibleFrame;
        CGFloat xs[] = {NSMinX(visible) - NSMinX(frame), NSMaxX(visible) - NSMaxX(frame), NSMidX(visible) - NSMidX(frame)};
        CGFloat ys[] = {NSMinY(visible) - NSMinY(frame), NSMaxY(visible) - NSMaxY(frame), NSMidY(visible) - NSMidY(frame)};
        for (int i = 0; i < 3; i++) {
            if (fabs(xs[i]) < bestX) {
                bestX = fabs(xs[i]);
                shiftX = xs[i];
            }
            if (fabs(ys[i]) < bestY) {
                bestY = fabs(ys[i]);
                shiftY = ys[i];
            }
        }
    }
    return CGRectOffset(frame, shiftX, shiftY);
}

- (CGRect)snapResize:(CGRect)frame {
    CGFloat threshold = 8 / _scale;
    CGFloat bestRight = threshold, bestBottom = threshold, right = 0, bottom = 0;
    for (NSScreen *screen in NSScreen.screens) {
        NSRect visible = screen.visibleFrame;
        CGFloat toRight = NSMaxX(visible) - NSMaxX(frame);
        CGFloat toBottom = NSMinY(visible) - NSMinY(frame);
        if (fabs(toRight) < bestRight) {
            bestRight = fabs(toRight);
            right = toRight;
        }
        if (fabs(toBottom) < bestBottom) {
            bestBottom = fabs(toBottom);
            bottom = toBottom;
        }
    }
    frame.size.width += right;
    frame.origin.y += bottom;
    frame.size.height -= bottom;
    return frame;
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_dragging) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat dx = (point.x - _dragStart.x) / _scale;
    CGFloat dy = (point.y - _dragStart.y) / _scale;
    BOOL snap = !(event.modifierFlags & NSEventModifierFlagOption);
    CGRect frame = _frameAtStart;
    if (_resizing) {
        CGFloat top = NSMaxY(frame);
        frame.size.width = MAX(frame.size.width + dx, 120);
        frame.origin.y = MIN(frame.origin.y + dy, top - 80);
        frame.size.height = top - frame.origin.y;
        if (snap) frame = [self snapResize:frame];
    } else {
        frame = CGRectOffset(frame, dx, dy);
        if (snap) frame = [self snapMove:frame];
    }
    frame = CGRectMake(round(frame.origin.x), round(frame.origin.y), round(frame.size.width), round(frame.size.height));
    self.draft = frame;
    self.needsDisplay = YES;
    if (self.onDrag) self.onDrag(frame);
}

- (void)mouseUp:(NSEvent *)event {
    (void)event;
    if (!_dragging) return;
    _dragging = NO;
    if (!_resizing) [NSCursor pop];
    [self changed];
    if (!CGRectEqualToRect(self.draft, _frameAtStart)) {
        if (self.onDrop) self.onDrop(self.draft);
    } else {
        // Wait out the double-click interval, since bringing the window
        // forward switches apps and would swallow a second click.
        [self performSelector:@selector(sendClick) withObject:nil afterDelay:NSEvent.doubleClickInterval];
    }
}

- (void)sendClick {
    if (self.onClick && self.selected) self.onClick(self.selected);
}

@end

@interface WindowMover : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate, NSTextFieldDelegate>
@property NSWindow *window;
@property NSTableView *table;
@property NSScrollView *listScroll;
@property ScreenMapView *map;
@property pid_t raisedPID;
@property BOOL dragPrepared;
@property(strong) id unfilledElement;
@property CGRect unfilledFrame;
@property CFTimeInterval lastLiveMove;
@property NSPopUpButton *screenPopup;
@property NSTextField *xField;
@property NSTextField *yField;
@property NSTextField *widthField;
@property NSTextField *heightField;
@property NSArray<NSControl *> *selectionControls;
@property NSArray<WindowEntry *> *entries;
- (void)show;
@end

@implementation WindowMover

- (void)show {
    if (!ensureAccessibility()) return;
    if (!self.window) {
        [self buildWindow];
        [self.window center];
    }
    if (self.window.isKeyWindow) [self refresh:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:nil];
}

- (NSTextField *)addLabel:(NSString *)text frame:(NSRect)frame {
    NSTextField *label = [NSTextField labelWithString:text];
    label.frame = frame;
    [self.window.contentView addSubview:label];
    return label;
}

- (NSButton *)addButton:(NSString *)title action:(SEL)action frame:(NSRect)frame {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:action];
    button.frame = frame;
    [self.window.contentView addSubview:button];
    return button;
}

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 820, 820)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    self.window.title = @"App Window Fixer";
    self.window.releasedWhenClosed = NO;
    self.window.contentMinSize = NSMakeSize(680, 600);
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
                                                       selector:@selector(otherAppActivated:)
                                                           name:NSWorkspaceDidActivateApplicationNotification
                                                         object:nil];
    self.window.delegate = self;
    NSView *content = self.window.contentView;

    NSTableView *table = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSArray *columns = @[@[@"app", @"App", @170], @[@"title", @"Window", @270], @[@"where", @"Where", @190]];
    for (NSArray *spec in columns) {
        NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:spec[0]];
        column.title = spec[1];
        column.width = [spec[2] doubleValue];
        [table addTableColumn:column];
    }
    table.style = NSTableViewStyleFullWidth;
    table.usesAlternatingRowBackgroundColors = YES;
    table.rowHeight = 22;
    table.dataSource = self;
    table.delegate = self;
    table.target = self;
    table.action = @selector(rowClicked:);
    table.doubleAction = @selector(center:);
    self.table = table;

    self.listScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.listScroll.documentView = table;
    self.listScroll.hasVerticalScroller = YES;
    self.listScroll.borderType = NSBezelBorder;
    [content addSubview:self.listScroll];

    self.map = [[ScreenMapView alloc] initWithFrame:NSZeroRect];
    self.map.toolTip = @"Click a window to bring it forward. Drag it to move it, or drag its corner to resize. Hold Option to turn off snapping.";
    [content addSubview:self.map];
    NSTextField *hint = [self addLabel:@"Pick a window above, then drag it onto any display, or drag its corner to resize. Double-click it to fill its display. Hold Option to stop snapping."
                                 frame:NSMakeRect(16, 90, NSWidth(content.bounds) - 32, 16)];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.autoresizingMask = NSViewWidthSizable;
    [self layoutPanes];

    __weak WindowMover *weakSelf = self;
    self.map.onClick = ^(WindowEntry *entry) {
        [weakSelf bringForward:entry];
    };
    self.map.onDoubleClick = ^(WindowEntry *entry) {
        (void)entry;
        [weakSelf toggleFillSelected];
    };
    self.map.onDrag = ^(CGRect frame) {
        [weakSelf dragSelectedTo:frame];
    };
    self.map.onDrop = ^(CGRect frame) {
        [weakSelf moveSelectedTo:frame];
    };

    [self addLabel:@"Display" frame:NSMakeRect(16, 59, 52, 17)];
    self.screenPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(68, 53, 204, 26) pullsDown:NO];
    self.screenPopup.target = self;
    self.screenPopup.action = @selector(screenChanged:);
    [content addSubview:self.screenPopup];

    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.allowsFloats = NO;
    NSArray *fieldSpecs = @[
        @[@"X", @"Distance from the left edge of the display’s usable area, in points"],
        @[@"Y", @"Distance from the top of the display’s usable area, below the menu bar, in points"],
        @[@"W", @"Width in points"],
        @[@"H", @"Height in points"],
    ];
    NSMutableArray<NSTextField *> *fields = [NSMutableArray array];
    CGFloat x = 288;
    for (NSArray *spec in fieldSpecs) {
        [self addLabel:spec[0] frame:NSMakeRect(x, 59, 14, 17)];
        NSTextField *field = [NSTextField textFieldWithString:@""];
        field.frame = NSMakeRect(x + 16, 56, 58, 22);
        field.formatter = formatter;
        field.alignment = NSTextAlignmentRight;
        field.toolTip = spec[1];
        field.delegate = self;
        [content addSubview:field];
        [fields addObject:field];
        x += 92;
    }
    self.xField = fields[0];
    self.yField = fields[1];
    self.widthField = fields[2];
    self.heightField = fields[3];

    [self addButton:@"Refresh" action:@selector(refresh:) frame:NSMakeRect(10, 12, 96, 32)];
    NSButton *center = [self addButton:@"Center" action:@selector(center:) frame:NSMakeRect(380, 12, 96, 32)];
    NSButton *fill = [self addButton:@"Fill" action:@selector(fill:) frame:NSMakeRect(476, 12, 96, 32)];
    NSButton *apply = [self addButton:@"Apply" action:@selector(apply:) frame:NSMakeRect(572, 12, 96, 32)];
    apply.keyEquivalent = @"\r";
    for (NSButton *button in @[center, fill, apply]) button.autoresizingMask = NSViewMinXMargin;
    center.toolTip = @"Center the window on the chosen display";
    fill.toolTip = @"Fill the chosen display, leaving the menu bar and Dock visible";
    apply.toolTip = @"Move the window to the position and size above";
    self.selectionControls = @[fields[0], fields[1], fields[2], fields[3], center, fill, apply];
}

// The map gets 60% of the space left above the controls, the list the rest.
- (void)layoutPanes {
    NSRect bounds = self.window.contentView.bounds;
    CGFloat width = NSWidth(bounds) - 32;
    CGFloat bottom = 112;
    CGFloat gap = 12;
    CGFloat available = MAX(NSHeight(bounds) - 16 - bottom - gap, 200);
    CGFloat mapHeight = round(available * 0.6);
    self.map.frame = NSMakeRect(16, bottom, width, mapHeight);
    self.listScroll.frame = NSMakeRect(16, bottom + mapHeight + gap, width, available - mapHeight);
}

- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    [self layoutPanes];
}

// The panel floats while it is in use, so a window brought forward from it
// lands behind the panel. Switching to another app on your own drops it back
// to a normal window.
- (void)windowDidBecomeKey:(NSNotification *)notification {
    (void)notification;
    self.window.level = NSFloatingWindowLevel;
    [self refresh:nil];
}

- (void)otherAppActivated:(NSNotification *)notification {
    NSRunningApplication *app = notification.userInfo[NSWorkspaceApplicationKey];
    if (!app || app.processIdentifier == getpid() || app.processIdentifier == self.raisedPID) return;
    self.raisedPID = 0;
    self.window.level = NSNormalWindowLevel;
}

- (void)rowClicked:(id)sender {
    (void)sender;
    NSInteger row = self.table.clickedRow;
    if (row >= 0 && row < (NSInteger)self.entries.count) [self bringForward:self.entries[row]];
}

- (void)bringForward:(WindowEntry *)entry {
    if (entry.app.hidden) [entry.app unhide];
    axUnminimize(entry.ref);
    [self raise:entry];
}

- (void)raise:(WindowEntry *)entry {
    self.raisedPID = entry.app.processIdentifier;
    self.window.level = NSFloatingWindowLevel;
    AXUIElementSetAttributeValue(entry.ref, kAXMainAttribute, kCFBooleanTrue);
    AXUIElementPerformAction(entry.ref, kAXRaiseAction);
    [entry.app activateWithOptions:0];
}

- (WindowEntry *)selectedEntry {
    NSInteger row = self.table.selectedRow;
    return row >= 0 && row < (NSInteger)self.entries.count ? self.entries[row] : nil;
}

- (NSScreen *)selectedScreen {
    CGDirectDisplayID wanted = [self.screenPopup.selectedItem.representedObject unsignedIntValue];
    for (NSScreen *screen in NSScreen.screens) {
        if (screenID(screen) == wanted) return screen;
    }
    return NSScreen.screens.firstObject;
}

- (void)rebuildScreens {
    CGDirectDisplayID previous = [self.screenPopup.selectedItem.representedObject unsignedIntValue];
    [self.screenPopup removeAllItems];
    NSArray<NSScreen *> *screens = NSScreen.screens;
    for (NSUInteger i = 0; i < screens.count; i++) {
        NSScreen *screen = screens[i];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:screenName(screen) action:nil keyEquivalent:@""];
        item.representedObject = @(screenID(screen));
        item.image = colorDot(screenColor(i));
        [self.screenPopup.menu addItem:item];
        if (screenID(screen) == previous) [self.screenPopup selectItem:item];
    }
}

- (void)refresh:(id)sender {
    (void)sender;
    WindowEntry *selected = self.selectedEntry;
    [self rebuildScreens];
    self.entries = listWindows();
    [self.table reloadData];
    NSInteger row = -1;
    for (NSInteger i = 0; selected && i < (NSInteger)self.entries.count; i++) {
        if (CFEqual(self.entries[i].ref, selected.ref)) row = i;
    }
    if (row >= 0) {
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    } else {
        [self.table deselectAll:nil];
    }
    [self selectionChanged];
}

- (void)selectionChanged {
    WindowEntry *entry = self.selectedEntry;
    for (NSControl *control in self.selectionControls) control.enabled = entry != nil;
    [self.map showSelected:entry];
    if (!entry) {
        for (NSTextField *field in @[self.xField, self.yField, self.widthField, self.heightField]) field.stringValue = @"";
        return;
    }
    [self fillFields:entry.frame];
}

- (void)fillFields:(CGRect)frame {
    NSRect visible = self.selectedScreen.visibleFrame;
    self.xField.integerValue = lround(NSMinX(frame) - NSMinX(visible));
    self.yField.integerValue = lround(NSMaxY(visible) - NSMaxY(frame));
    self.widthField.integerValue = lround(NSWidth(frame));
    self.heightField.integerValue = lround(NSHeight(frame));
}

- (CGRect)frameFromFields {
    NSRect visible = self.selectedScreen.visibleFrame;
    CGFloat width = MAX(self.widthField.stringValue.doubleValue, 1);
    CGFloat height = MAX(self.heightField.stringValue.doubleValue, 1);
    return CGRectMake(NSMinX(visible) + self.xField.stringValue.doubleValue,
                      NSMaxY(visible) - self.yField.stringValue.doubleValue - height,
                      width,
                      height);
}

- (void)controlTextDidChange:(NSNotification *)notification {
    (void)notification;
    [self.map showDraft:[self frameFromFields]];
}

- (void)selectScreenUnder:(CGRect)frame {
    NSScreen *screen = screenUnderFrame(frame);
    if (!screen) return;
    NSInteger index = [self.screenPopup indexOfItemWithRepresentedObject:@(screenID(screen))];
    if (index >= 0) [self.screenPopup selectItemAtIndex:index];
}

// The real window follows the drag, at most 60 times a second so slow apps
// do not fall behind the pointer.
- (void)dragSelectedTo:(CGRect)frame {
    WindowEntry *entry = self.selectedEntry;
    if (!entry) return;
    if (!self.dragPrepared) {
        [self prepareSelected];
        self.dragPrepared = YES;
    }
    [self selectScreenUnder:frame];
    [self fillFields:frame];
    CFTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (now - self.lastLiveMove < 1.0 / 60) return;
    self.lastLiveMove = now;
    if (CGSizeEqualToSize(frame.size, entry.frame.size)) {
        axSetPosition(entry.ref, axPositionForCocoaFrame(frame));
    } else {
        setWindowFrame(entry.ref, frame);
    }
}

// Fill the display the window is mostly on. If it already fills it, put back
// the frame it had before the last fill.
- (void)toggleFillSelected {
    WindowEntry *entry = [self prepareSelected];
    if (!entry) return;
    NSScreen *screen = screenUnderFrame(entry.frame) ?: self.selectedScreen;
    NSRect visible = screen.visibleFrame;
    BOOL filled = fabs(NSMinX(entry.frame) - NSMinX(visible)) < 3 && fabs(NSMinY(entry.frame) - NSMinY(visible)) < 3 &&
        fabs(NSWidth(entry.frame) - NSWidth(visible)) < 3 && fabs(NSHeight(entry.frame) - NSHeight(visible)) < 3;
    BOOL canRestore = filled && self.unfilledElement && CFEqual((__bridge CFTypeRef)self.unfilledElement, entry.ref);
    CGRect target = visible;
    if (canRestore) {
        target = self.unfilledFrame;
        self.unfilledElement = nil;
    } else if (!filled) {
        self.unfilledElement = entry.element;
        self.unfilledFrame = entry.frame;
    }
    [self moveSelectedTo:target];
}

- (void)moveSelectedTo:(CGRect)frame {
    self.dragPrepared = NO;
    WindowEntry *entry = self.selectedEntry;
    if (!entry) return;
    BOOL moved = setWindowFrame(entry.ref, frame);
    if (!moved) {
        [self finishMove:entry moved:NO];
        return;
    }
    AXUIElementPerformAction(entry.ref, kAXRaiseAction);
    entry.frame = frame;
    describeLocation(entry);
    [self selectScreenUnder:frame];
    NSInteger row = self.table.selectedRow;
    if (row >= 0) {
        [self.table reloadDataForRowIndexes:[NSIndexSet indexSetWithIndex:row]
                              columnIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, self.table.numberOfColumns)]];
    }
    [self fillFields:frame];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(refresh:) object:nil];
    [self performSelector:@selector(refresh:) withObject:nil afterDelay:0.4];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    [self selectionChanged];
}

- (void)screenChanged:(id)sender {
    (void)sender;
    [self selectionChanged];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return (NSInteger)self.entries.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSTableCellView *cell = [tableView makeViewWithIdentifier:column.identifier owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, column.width, 22)];
        cell.identifier = column.identifier;
        NSTextField *text = [NSTextField labelWithString:@""];
        text.lineBreakMode = NSLineBreakByTruncatingTail;
        text.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:text];
        cell.textField = text;
        NSLayoutXAxisAnchor *leading = cell.leadingAnchor;
        CGFloat inset = 4;
        if ([column.identifier isEqualToString:@"app"]) {
            NSImageView *icon = [NSImageView new];
            icon.translatesAutoresizingMaskIntoConstraints = NO;
            [cell addSubview:icon];
            cell.imageView = icon;
            [NSLayoutConstraint activateConstraints:@[
                [icon.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
                [icon.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
                [icon.widthAnchor constraintEqualToConstant:16],
                [icon.heightAnchor constraintEqualToConstant:16],
            ]];
            leading = icon.trailingAnchor;
            inset = 6;
        }
        [NSLayoutConstraint activateConstraints:@[
            [text.leadingAnchor constraintEqualToAnchor:leading constant:inset],
            [text.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [text.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        ]];
    }
    WindowEntry *entry = self.entries[row];
    NSTextField *text = cell.textField;
    text.textColor = NSColor.labelColor;
    if ([column.identifier isEqualToString:@"app"]) {
        text.stringValue = entry.app.localizedName ?: @"App";
        cell.imageView.image = entry.app.icon;
    } else if ([column.identifier isEqualToString:@"title"]) {
        text.stringValue = entry.title.length ? entry.title : @"Untitled window";
        if (!entry.title.length) text.textColor = NSColor.secondaryLabelColor;
    } else {
        text.stringValue = entry.location;
        text.textColor = entry.misplaced ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    }
    return cell;
}

- (WindowEntry *)prepareSelected {
    WindowEntry *entry = self.selectedEntry;
    if (!entry) return nil;
    if (entry.app.hidden) [entry.app unhide];
    axUnminimize(entry.ref);
    return entry;
}

- (void)finishMove:(WindowEntry *)entry moved:(BOOL)moved {
    if (!moved) {
        NSString *name = entry.app.localizedName ?: @"That app";
        presentAlert(@"Could not move the window",
                     [NSString stringWithFormat:@"%@ did not let %@ move this window. It may have closed, or it may be in full screen.", name, kAppName]);
    } else {
        AXUIElementPerformAction(entry.ref, kAXRaiseAction);
    }
    [self refresh:nil];
}

- (void)center:(id)sender {
    (void)sender;
    WindowEntry *entry = [self prepareSelected];
    if (!entry) return;
    [self finishMove:entry moved:centerWindowInRect(entry.ref, self.selectedScreen.visibleFrame)];
}

- (void)fill:(id)sender {
    (void)sender;
    WindowEntry *entry = [self prepareSelected];
    if (!entry) return;
    [self finishMove:entry moved:setWindowFrame(entry.ref, self.selectedScreen.visibleFrame)];
}

- (void)apply:(id)sender {
    (void)sender;
    if (![self.window makeFirstResponder:nil]) return;
    WindowEntry *entry = [self prepareSelected];
    if (!entry) return;
    [self finishMove:entry moved:setWindowFrame(entry.ref, [self frameFromFields])];
}

@end

static void displayReconfigured(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *user) {
    (void)display;
    (void)flags;
    AppDelegate *delegate = (__bridge AppDelegate *)user;
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate scheduleRefresh];
    });
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:kForceKey] == nil) {
        [defaults setBool:YES forKey:kForceKey];
    }
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium];
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;
    menu.delegate = self;
    self.statusItem.menu = menu;
    [self refreshTitle];
    CGDisplayRegisterReconfigurationCallback(displayReconfigured, (__bridge void *)self);
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
                                                       selector:@selector(scheduleRefresh)
                                                           name:NSWorkspaceDidWakeNotification
                                                         object:nil];
    if ([defaults boolForKey:kForceKey]) {
        [self forceAndConfirm];
    }
}

- (void)scheduleRefresh {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(refreshAfterChange) object:nil];
    [self performSelector:@selector(refreshAfterChange) withObject:nil afterDelay:1.2];
}

- (void)refreshAfterChange {
    if ([NSUserDefaults.standardUserDefaults boolForKey:kForceKey]) {
        BOOL needsApply = NO;
        for (DisplayState *display in externalDisplays()) {
            if (!display.overrideActive) needsApply = YES;
        }
        if (needsApply) [self forceAndConfirm];
    }
    [self refreshTitle];
}

- (void)refreshTitle {
    NSArray<DisplayState *> *displays = externalDisplays();
    BOOL rgb = displays.count > 0;
    for (DisplayState *display in displays) {
        if (!display.rgb) rgb = NO;
    }
    self.statusItem.button.title = displays.count == 0 ? @"RGB" : (rgb ? @"RGB" : @"YPbPr");
    self.statusItem.button.toolTip = rgb ? @"HDMI output is RGB" : @"HDMI output is YPbPr";
}

- (void)menuWillOpen:(NSMenu *)menu {
    [menu removeAllItems];
    NSArray<DisplayState *> *displays = externalDisplays();
    if (displays.count == 0) {
        NSMenuItem *empty = [menu addItemWithTitle:@"No external display" action:nil keyEquivalent:@""];
        empty.enabled = NO;
    }
    BOOL anyYCbCr = NO;
    for (DisplayState *display in displays) {
        NSMenuItem *name = [menu addItemWithTitle:display.name action:nil keyEquivalent:@""];
        name.enabled = NO;
        NSString *detail = display.overrideActive && display.rgb
            ? [display.format stringByAppendingString:@" · override on"]
            : display.format;
        NSMenuItem *format = [menu addItemWithTitle:detail action:nil keyEquivalent:@""];
        format.enabled = NO;
        if (!display.rgb) anyYCbCr = YES;
    }
    if (displays.count) [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *force = [menu addItemWithTitle:@"Force RGB" action:@selector(forceRGB:) keyEquivalent:@""];
    force.target = self;
    force.enabled = anyYCbCr || displays.count == 0;

    NSMenuItem *restore = [menu addItemWithTitle:@"Restore Original" action:@selector(restore:) keyEquivalent:@""];
    restore.target = self;
    restore.enabled = displays.count > 0;

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *move = [menu addItemWithTitle:@"App Window Fixer…" action:@selector(openWindowMover:) keyEquivalent:@""];
    move.target = self;

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *keep = [menu addItemWithTitle:@"Keep Forcing RGB" action:@selector(toggleKeep:) keyEquivalent:@""];
    keep.target = self;
    keep.state = [NSUserDefaults.standardUserDefaults boolForKey:kForceKey] ? NSControlStateValueOn : NSControlStateValueOff;

    NSMenuItem *login = [menu addItemWithTitle:@"Open at Login" action:@selector(toggleLogin:) keyEquivalent:@""];
    login.target = self;
    SMAppServiceStatus loginStatus = SMAppService.mainAppService.status;
    login.state = (loginStatus == SMAppServiceStatusEnabled || loginStatus == SMAppServiceStatusRequiresApproval)
        ? NSControlStateValueOn : NSControlStateValueOff;

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [menu addItemWithTitle:[@"Quit " stringByAppendingString:kAppName] action:@selector(terminate:) keyEquivalent:@"q"];
    quit.target = NSApp;
}

- (void)applyForce:(BOOL)force {
    if (self.applying) return;
    self.applying = YES;
    IOReturn result = applyToExternalDisplays(force);
    self.applying = NO;
    if (result != kIOReturnSuccess && result != kIOReturnNotFound) {
        NSLog(@"Force RGB %@ failed: 0x%x", force ? @"apply" : @"reset", result);
    }
    [self refreshTitle];
}

- (void)forceRGB:(id)sender {
    (void)sender;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:kForceKey];
    [self forceAndConfirm];
}

// A monitor is asked about once. Displays already sending RGB count as
// confirmed, since that picture is what is on screen now.
- (void)forceAndConfirm {
    if (self.confirming) return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSMutableSet<NSString *> *confirmed = [NSMutableSet setWithArray:[defaults stringArrayForKey:kConfirmedKey] ?: @[]];
    NSMutableArray<NSString *> *pendingNames = [NSMutableArray array];
    NSMutableArray<NSString *> *pendingIDs = [NSMutableArray array];
    for (DisplayState *display in externalDisplays()) {
        if (display.rgb) {
            [confirmed addObject:display.identifier];
        } else if (![confirmed containsObject:display.identifier]) {
            [pendingNames addObject:display.name];
            [pendingIDs addObject:display.identifier];
        }
    }
    [defaults setObject:confirmed.allObjects forKey:kConfirmedKey];

    [self applyForce:YES];
    if (pendingIDs.count == 0) return;

    self.confirming = YES;
    BOOL keep = [self confirmKeepRGB:pendingNames];
    self.confirming = NO;
    if (keep) {
        [confirmed addObjectsFromArray:pendingIDs];
        [defaults setObject:confirmed.allObjects forKey:kConfirmedKey];
    } else {
        [defaults setBool:NO forKey:kForceKey];
        [self applyForce:NO];
    }
}

- (BOOL)confirmKeepRGB:(NSArray<NSString *> *)names {
    [NSApp activateIgnoringOtherApps:YES];
    NSString *list = [[NSOrderedSet orderedSetWithArray:names].array componentsJoinedByString:@" and "];
    __block NSInteger remaining = kConfirmSeconds;
    NSString *(^detail)(void) = ^NSString *{
        return [NSString stringWithFormat:@"%@ now receives RGB. If the picture looks right, click Keep.\n\n"
                                          @"Otherwise the original signal comes back in %ld second%@.",
                                          list, (long)remaining, remaining == 1 ? @"" : @"s"];
    };
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Keep RGB Output?";
    alert.informativeText = detail();
    NSButton *keep = [alert addButtonWithTitle:@"Keep"];
    NSButton *revert = [alert addButtonWithTitle:@"Revert"];
    // Return must not confirm a picture nobody can see.
    keep.keyEquivalent = @"";
    revert.keyEquivalent = @"\r";

    NSTimer *timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        remaining--;
        if (remaining <= 0) {
            [t invalidate];
            [NSApp stopModalWithCode:NSAlertSecondButtonReturn];
            return;
        }
        alert.informativeText = detail();
    }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSModalPanelRunLoopMode];
    NSModalResponse response = [alert runModal];
    [timer invalidate];
    return response == NSAlertFirstButtonReturn;
}

- (void)restore:(id)sender {
    (void)sender;
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:kForceKey];
    [self applyForce:NO];
}

- (void)openWindowMover:(id)sender {
    (void)sender;
    if (!self.windowMover) self.windowMover = [WindowMover new];
    [(WindowMover *)self.windowMover show];
}

- (void)toggleKeep:(id)sender {
    (void)sender;
    BOOL on = ![NSUserDefaults.standardUserDefaults boolForKey:kForceKey];
    [NSUserDefaults.standardUserDefaults setBool:on forKey:kForceKey];
    if (on) [self forceAndConfirm];
}

- (void)toggleLogin:(id)sender {
    (void)sender;
    NSError *error = nil;
    SMAppService *service = SMAppService.mainAppService;
    BOOL enabled = service.status == SMAppServiceStatusEnabled || service.status == SMAppServiceStatusRequiresApproval;
    BOOL ok = enabled ? [service unregisterAndReturnError:&error] : [service registerAndReturnError:&error];
    if (!ok) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Could not change Open at Login";
        alert.informativeText = error.localizedDescription ?: [NSString stringWithFormat:@"Move %@ into Applications and try again.", kAppName];
        [alert runModal];
    }
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1) {
            NSString *command = [NSString stringWithUTF8String:argv[1]];
            if ([command isEqualToString:@"--status"]) return printStatus();
            if ([command isEqualToString:@"--apply"]) {
                IOReturn result = applyToExternalDisplays(YES);
                printStatus();
                return result == kIOReturnSuccess ? 0 : 1;
            }
            if ([command isEqualToString:@"--reset"]) {
                IOReturn result = applyToExternalDisplays(NO);
                printStatus();
                return result == kIOReturnSuccess ? 0 : 1;
            }
            fprintf(stderr, "usage: RadsMiniToolbox [--status | --apply | --reset]\n");
            return 2;
        }
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
