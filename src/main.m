#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOKitLib.h>
#import <ServiceManagement/ServiceManagement.h>
#import <dlfcn.h>

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

@interface DisplayState : NSObject
@property(copy) NSString *name;
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
        state.overrideActive = !edidAdvertisesYCbCr(edid);
    } else {
        state.name = @"External display";
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
- (void)scheduleRefresh;
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
    menu.delegate = self;
    self.statusItem.menu = menu;
    [self refreshTitle];
    CGDisplayRegisterReconfigurationCallback(displayReconfigured, (__bridge void *)self);
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self
                                                       selector:@selector(scheduleRefresh)
                                                           name:NSWorkspaceDidWakeNotification
                                                         object:nil];
    if ([defaults boolForKey:kForceKey]) {
        [self applyForce:YES];
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
            if (!display.rgb || !display.overrideActive) needsApply = YES;
        }
        if (needsApply) [self applyForce:YES];
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
    NSMenuItem *keep = [menu addItemWithTitle:@"Keep Forcing RGB" action:@selector(toggleKeep:) keyEquivalent:@""];
    keep.target = self;
    keep.state = [NSUserDefaults.standardUserDefaults boolForKey:kForceKey] ? NSControlStateValueOn : NSControlStateValueOff;

    NSMenuItem *login = [menu addItemWithTitle:@"Open at Login" action:@selector(toggleLogin:) keyEquivalent:@""];
    login.target = self;
    SMAppServiceStatus loginStatus = SMAppService.mainAppService.status;
    login.state = (loginStatus == SMAppServiceStatusEnabled || loginStatus == SMAppServiceStatusRequiresApproval)
        ? NSControlStateValueOn : NSControlStateValueOff;

    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quit = [menu addItemWithTitle:@"Quit Force RGB" action:@selector(terminate:) keyEquivalent:@"q"];
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
    [self applyForce:YES];
}

- (void)restore:(id)sender {
    (void)sender;
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:kForceKey];
    [self applyForce:NO];
}

- (void)toggleKeep:(id)sender {
    (void)sender;
    BOOL on = ![NSUserDefaults.standardUserDefaults boolForKey:kForceKey];
    [NSUserDefaults.standardUserDefaults setBool:on forKey:kForceKey];
    if (on) [self applyForce:YES];
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
        alert.informativeText = error.localizedDescription ?: @"Move Force RGB into Applications and try again.";
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
            fprintf(stderr, "usage: ForceRGB [--status | --apply | --reset]\n");
            return 2;
        }
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
