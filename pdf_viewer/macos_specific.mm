#include <AppKit/AppKit.h>
#include <QWidget>
#import <Cocoa/Cocoa.h>

extern "C" void showLookupForString(WId winId, const char* text, double x, double y) {
    if (winId == 0 || text == nullptr) return;

    NSView* view = (NSView*)winId;
    NSString* nsText = [NSString stringWithUTF8String:text];

    NSPoint point = NSMakePoint(x, y);

    [view showDefinitionForAttributedString:[[NSAttributedString alloc] initWithString:nsText]
                                    atPoint:point];
}

// writes a link titled `text` which points to `url` to the pasteboard as rich text (RTF and HTML) so that
// apps like Apple Notes paste it as a hyperlink, with `url` as the plain text fallback
extern "C" void copyRichLinkToPasteboard(const char* text, const char* url, const char* html) {
    if (text == nullptr || url == nullptr || html == nullptr) return;

    NSString* nsText = [NSString stringWithUTF8String:text];
    NSString* nsUrl = [NSString stringWithUTF8String:url];
    NSString* nsHtml = [NSString stringWithUTF8String:html];
    NSURL* link = [NSURL URLWithString:nsUrl];
    if (nsText == nil || nsUrl == nil || nsHtml == nil || link == nil) return;

    NSAttributedString* attributed = [[NSAttributedString alloc] initWithString:nsText
                                                                     attributes:@{NSLinkAttributeName: link}];
    NSData* rtf = [attributed dataFromRange:NSMakeRange(0, attributed.length)
                         documentAttributes:@{NSDocumentTypeDocumentAttribute: NSRTFTextDocumentType}
                                      error:nil];

    NSPasteboard* pasteboard = [NSPasteboard generalPasteboard];
    [pasteboard clearContents];
    if (rtf != nil) {
        [pasteboard setData:rtf forType:NSPasteboardTypeRTF];
    }
    [pasteboard setString:nsHtml forType:NSPasteboardTypeHTML];
    [pasteboard setString:nsUrl forType:NSPasteboardTypeString];
}

extern "C" void changeTitlebarColor(WId winId, double red, double green, double blue, double alpha){
    if (winId == 0) return;
    NSView* view = (NSView*)winId;
    NSWindow* window = [view window];
    window.titlebarAppearsTransparent = YES;
    window.backgroundColor = [NSColor colorWithRed:red green:green blue:blue alpha: alpha];
}

@interface DraggableTitleView : NSView
@end

@implementation DraggableTitleView

// Handle mouse click events
- (void)mouseDown:(NSEvent *)event {
    // double-click to zoom
    if ([event clickCount] == 2) {
        [self.window zoom:nil];
    } else {
        // drag Window
        [self.window performWindowDragWithEvent:event];
    }
}

- (void)updateTrackingAreas {
    [self initTrackingArea];
}

-(void) initTrackingArea {
    NSTrackingAreaOptions options = (NSTrackingActiveAlways | NSTrackingInVisibleRect |
            NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved);

    NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:[self bounds]
        options:options
        owner:self
        userInfo:nil];

    [self addTrackingArea:area];
}
-(void)mouseEntered:(NSEvent *)event {
    if((self.window.styleMask & NSWindowStyleMaskFullScreen) == 0) {
        [[self.window standardWindowButton: NSWindowCloseButton] setHidden:NO];
        [[self.window standardWindowButton: NSWindowMiniaturizeButton] setHidden:NO];
        [[self.window standardWindowButton: NSWindowZoomButton] setHidden:NO];
    }
}

-(void)mouseExited:(NSEvent *)event {
    if((self.window.styleMask & NSWindowStyleMaskFullScreen) == 0) {
        [[self.window standardWindowButton: NSWindowCloseButton] setHidden:YES];
        [[self.window standardWindowButton: NSWindowMiniaturizeButton] setHidden:YES];
        [[self.window standardWindowButton: NSWindowZoomButton] setHidden:YES];
    }
}

@end

extern "C" void hideWindowTitleBar(WId winId) {
    if (winId == 0) return;

    NSView* nativeView = reinterpret_cast<NSView*>(winId);
    NSWindow* nativeWindow = [nativeView window];

    if(nativeWindow.titleVisibility == NSWindowTitleHidden){
        return;
    }

    [[nativeWindow standardWindowButton: NSWindowCloseButton] setHidden:YES];
    [[nativeWindow standardWindowButton: NSWindowMiniaturizeButton] setHidden:YES];
    [[nativeWindow standardWindowButton: NSWindowZoomButton] setHidden:YES];
    NSRect contentViewBounds = nativeWindow.contentView.bounds;

    DraggableTitleView *titleBarView = [[DraggableTitleView alloc] initWithFrame:NSMakeRect(0, 0, contentViewBounds.size.width, 22)];
    titleBarView.autoresizingMask = NSViewWidthSizable;
    titleBarView.wantsLayer = YES;
    titleBarView.layer.backgroundColor = [[NSColor clearColor] CGColor];

    [nativeWindow.contentView addSubview:titleBarView];

    [nativeWindow setTitleVisibility:NSWindowTitleHidden];
    [nativeWindow setStyleMask:[nativeWindow styleMask] | NSWindowStyleMaskFullSizeContentView];
    [nativeWindow setTitlebarAppearsTransparent:YES];
}
