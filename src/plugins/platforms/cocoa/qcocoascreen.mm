/****************************************************************************
**
** Copyright (C) 2017 The Qt Company Ltd.
** Contact: https://www.qt.io/licensing/
**
** This file is part of the plugins of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:LGPL$
** Commercial License Usage
** Licensees holding valid commercial Qt licenses may use this file in
** accordance with the commercial license agreement provided with the
** Software or, alternatively, in accordance with the terms contained in
** a written agreement between you and The Qt Company. For licensing terms
** and conditions see https://www.qt.io/terms-conditions. For further
** information use the contact form at https://www.qt.io/contact-us.
**
** GNU Lesser General Public License Usage
** Alternatively, this file may be used under the terms of the GNU Lesser
** General Public License version 3 as published by the Free Software
** Foundation and appearing in the file LICENSE.LGPL3 included in the
** packaging of this file. Please review the following information to
** ensure the GNU Lesser General Public License version 3 requirements
** will be met: https://www.gnu.org/licenses/lgpl-3.0.html.
**
** GNU General Public License Usage
** Alternatively, this file may be used under the terms of the GNU
** General Public License version 2.0 or (at your option) the GNU General
** Public license version 3 or any later version approved by the KDE Free
** Qt Foundation. The licenses are as published by the Free Software
** Foundation and appearing in the file LICENSE.GPL2 and LICENSE.GPL3
** included in the packaging of this file. Please review the following
** information to ensure the GNU General Public License requirements will
** be met: https://www.gnu.org/licenses/gpl-2.0.html and
** https://www.gnu.org/licenses/gpl-3.0.html.
**
** $QT_END_LICENSE$
**
****************************************************************************/

#include "qcocoascreen.h"

#include "qcocoawindow.h"
#include "qcocoahelpers.h"

#include <QtCore/qcoreapplication.h>
#include <QtGui/private/qcoregraphics_p.h>

#include <IOKit/graphics/IOGraphicsLib.h>

#include <QtGui/private/qwindow_p.h>

#include <QtCore/private/qeventdispatcher_cf_p.h>

QT_BEGIN_NAMESPACE

class QCoreTextFontEngine;
class QFontEngineFT;

QCocoaScreen::QCocoaScreen(int screenIndex)
    : QPlatformScreen(), m_screenIndex(screenIndex), m_refreshRate(60.0)
{
    updateGeometry();
    m_cursor = new QCocoaCursor;
}

QCocoaScreen::~QCocoaScreen()
{
    delete m_cursor;

    CVDisplayLinkRelease(m_displayLink);
    if (m_displayLinkSource)
         dispatch_release(m_displayLinkSource);
}

NSScreen *QCocoaScreen::nativeScreen() const
{
    NSArray<NSScreen *> *screens = [NSScreen screens];

    // Stale reference, screen configuration has changed
    if (m_screenIndex < 0 || (NSUInteger)m_screenIndex >= [screens count])
        return nil;

    return [screens objectAtIndex:m_screenIndex];
}

static QString displayName(CGDirectDisplayID displayID)
{
    QIOType<io_iterator_t> iterator;
    if (IOServiceGetMatchingServices(kIOMasterPortDefault,
        IOServiceMatching("IODisplayConnect"), &iterator))
        return QString();

    QIOType<io_service_t> display;
    while ((display = IOIteratorNext(iterator)) != 0)
    {
        NSDictionary *info = [(__bridge NSDictionary*)IODisplayCreateInfoDictionary(
            display, kIODisplayOnlyPreferredName) autorelease];

        if ([[info objectForKey:@kDisplayVendorID] longValue] != CGDisplayVendorNumber(displayID))
            continue;

        if ([[info objectForKey:@kDisplayProductID] longValue] != CGDisplayModelNumber(displayID))
            continue;

        if ([[info objectForKey:@kDisplaySerialNumber] longValue] != CGDisplaySerialNumber(displayID))
            continue;

        NSDictionary *localizedNames = [info objectForKey:@kDisplayProductName];
        if (![localizedNames count])
            break; // Correct screen, but no name in dictionary

        return QString::fromNSString([localizedNames objectForKey:[[localizedNames allKeys] objectAtIndex:0]]);
    }

    return QString();
}

void QCocoaScreen::updateGeometry()
{
    NSScreen *nsScreen = nativeScreen();
    if (!nsScreen)
        return;

    // The reference screen for the geometry is always the primary screen
    QRectF primaryScreenGeometry = QRectF::fromCGRect([[NSScreen screens] firstObject].frame);
    m_geometry = qt_mac_flip(QRectF::fromCGRect(nsScreen.frame), primaryScreenGeometry).toRect();
    m_availableGeometry = qt_mac_flip(QRectF::fromCGRect(nsScreen.visibleFrame), primaryScreenGeometry).toRect();

    m_format = QImage::Format_RGB32;
    m_depth = NSBitsPerPixelFromDepth([nsScreen depth]);

    CGDirectDisplayID dpy = nsScreen.qt_displayId;
    CGSize size = CGDisplayScreenSize(dpy);
    m_physicalSize = QSizeF(size.width, size.height);
    m_logicalDpi.first = 72;
    m_logicalDpi.second = 72;
    CGDisplayModeRef displayMode = CGDisplayCopyDisplayMode(dpy);
    float refresh = CGDisplayModeGetRefreshRate(displayMode);
    CGDisplayModeRelease(displayMode);
    if (refresh > 0)
        m_refreshRate = refresh;

    m_name = displayName(dpy);

    QWindowSystemInterface::handleScreenGeometryChange(screen(), geometry(), availableGeometry());
    QWindowSystemInterface::handleScreenLogicalDotsPerInchChange(screen(), m_logicalDpi.first, m_logicalDpi.second);
    QWindowSystemInterface::handleScreenRefreshRateChange(screen(), m_refreshRate);
}

// ----------------------- Display link -----------------------

Q_LOGGING_CATEGORY(lcQpaScreenUpdates, "qt.qpa.screen.updates", QtCriticalMsg);

void QCocoaScreen::requestUpdate()
{
    if (!m_displayLink) {
        CVDisplayLinkCreateWithCGDisplay(nativeScreen().qt_displayId, &m_displayLink);
        CVDisplayLinkSetOutputCallback(m_displayLink, [](CVDisplayLinkRef, const CVTimeStamp*,
            const CVTimeStamp*, CVOptionFlags, CVOptionFlags*, void* displayLinkContext) -> int {
                // FIXME: It would be nice if update requests would include timing info
                static_cast<QCocoaScreen*>(displayLinkContext)->deliverUpdateRequests();
                return kCVReturnSuccess;
        }, this);
        qCDebug(lcQpaScreenUpdates) << "Display link created for" << this;

        // During live window resizing -[NSWindow _resizeWithEvent:] will spin a local event loop
        // in event-tracking mode, dequeuing only the mouse drag events needed to update the window's
        // frame. It will repeatedly spin this loop until no longer receiving any mouse drag events,
        // and will then update the frame (effectively coalescing/compressing the events). Unfortunately
        // the events are pulled out using -[NSApplication nextEventMatchingEventMask:untilDate:inMode:dequeue:]
        // which internally uses CFRunLoopRunSpecific, so the event loop will also process GCD queues and other
        // runloop sources that have been added to the tracking mode. This includes the GCD display-link
        // source that we use to marshal the display-link callback over to the main thread. If the
        // subsequent delivery of the update-request on the main thread stalls due to inefficient
        // user code, the NSEventThread will have had time to deliver additional mouse drag events,
        // and the logic in -[NSWindow _resizeWithEvent:] will keep on compressing events and never
        // get to the point of actually updating the window frame, making it seem like the window
        // is stuck in its original size. Only when the user stops moving their mouse, and the event
        // queue is completely drained of drag events, will the window frame be updated.

        // By keeping an event tap listening for drag events, registered as a version 1 runloop source,
        // we prevent the GCD source from being prioritized, giving the resize logic enough time
        // to finish coalescing the events. This is incidental, but conveniently gives us the behavior
        // we are looking for, interleaving display-link updates and resize events.
        static CFMachPortRef eventTap = []() {
            CFMachPortRef eventTap = CGEventTapCreateForPid(getpid(), kCGTailAppendEventTap,
                kCGEventTapOptionListenOnly, NSEventMaskLeftMouseDragged,
                [](CGEventTapProxy, CGEventType type, CGEventRef event, void *) -> CGEventRef {
                    if (type == kCGEventTapDisabledByTimeout)
                        qCWarning(lcQpaScreenUpdates) << "Event tap disabled due to timeout!";
                    return event; // Listen only tap, so what we return doesn't really matter
                }, nullptr);
            CGEventTapEnable(eventTap, false); // Event taps are normally enabled when created
            static CFRunLoopSourceRef runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);

            NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
            [center addObserverForName:NSWindowWillStartLiveResizeNotification object:nil queue:nil
                usingBlock:^(NSNotification *notification) {
                    qCDebug(lcQpaScreenUpdates) << "Live resize of" << notification.object
                        << "started. Enabling event tap";
                    CGEventTapEnable(eventTap, true);
                }];
            [center addObserverForName:NSWindowDidEndLiveResizeNotification object:nil queue:nil
                usingBlock:^(NSNotification *notification) {
                    qCDebug(lcQpaScreenUpdates) << "Live resize of" << notification.object
                        << "ended. Disabling event tap";
                    CGEventTapEnable(eventTap, false);
                }];
            return eventTap;
        }();
        Q_UNUSED(eventTap);
    }

    if (!CVDisplayLinkIsRunning(m_displayLink)) {
        qCDebug(lcQpaScreenUpdates) << "Starting display link for" << this;
        CVDisplayLinkStart(m_displayLink);
    }
}

// Helper to allow building up debug output in multiple steps
struct DeferredDebugHelper
{
    DeferredDebugHelper(const QLoggingCategory &cat) {
        if (cat.isDebugEnabled())
            debug = new QDebug(QMessageLogger().debug(cat).nospace());
    }
    ~DeferredDebugHelper() {
        flushOutput();
    }
    void flushOutput() {
        if (debug) {
            delete debug;
            debug = nullptr;
        }
    }
    QDebug *debug = nullptr;
};

#define qDeferredDebug(helper) if (Q_UNLIKELY(helper.debug)) *helper.debug

void QCocoaScreen::deliverUpdateRequests()
{
    if (!QGuiApplication::instance())
        return;

    // The CVDisplayLink callback is a notification that it's a good time to produce a new frame.
    // Since the callback is delivered on a separate thread we have to marshal it over to the
    // main thread, as Qt requires update requests to be delivered there. This needs to happen
    // asynchronously, as otherwise we may end up deadlocking if the main thread calls back
    // into any of the CVDisplayLink APIs.
    if (QThread::currentThread() != QGuiApplication::instance()->thread()) {
        // We're explicitly not using the data of the GCD source to track the pending updates,
        // as the data isn't reset to 0 until after the event handler, and also doesn't update
        // during the event handler, both of which we need to track late frames.
        const int pendingUpdates = ++m_pendingUpdates;

        DeferredDebugHelper screenUpdates(lcQpaScreenUpdates());
        qDeferredDebug(screenUpdates) << "display link callback for screen " << m_screenIndex;

        if (const int framesAheadOfDelivery = pendingUpdates - 1) {
            // If we have more than one update pending it means that a previous display link callback
            // has not been fully processed on the main thread, either because GCD hasn't delivered
            // it on the main thread yet, because the processing of the update request is taking
            // too long, or because the update request was deferred due to window live resizing.
            qDeferredDebug(screenUpdates) << ", " << framesAheadOfDelivery << " frame(s) ahead";

            // We skip the frame completely if we're live-resizing, to not put any extra
            // strain on the main thread runloop. Otherwise we assume we should push frames
            // as fast as possible, and hopefully the callback will be delivered on the
            // main thread just when the previous finished.
            if (qt_apple_sharedApplication().keyWindow.inLiveResize) {
                qDeferredDebug(screenUpdates) << "; waiting for main thread to catch up";
                return;
            }
        }

        qDeferredDebug(screenUpdates) << "; signaling dispatch source";

        if (!m_displayLinkSource) {
            m_displayLinkSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_DATA_ADD, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_event_handler(m_displayLinkSource, ^{
                deliverUpdateRequests();
            });
            dispatch_resume(m_displayLinkSource);
        }

        dispatch_source_merge_data(m_displayLinkSource, 1);

    } else {
        DeferredDebugHelper screenUpdates(lcQpaScreenUpdates());
        qDeferredDebug(screenUpdates) << "gcd event handler on main thread";

        const int pendingUpdates = m_pendingUpdates;
        if (pendingUpdates > 1)
            qDeferredDebug(screenUpdates) << ", " << (pendingUpdates - 1) << " frame(s) behind display link";

        screenUpdates.flushOutput();

        bool pauseUpdates = true;

        auto windows = QGuiApplication::allWindows();
        for (int i = 0; i < windows.size(); ++i) {
            QWindow *window = windows.at(i);
            QPlatformWindow *platformWindow = window->handle();
            if (!platformWindow)
                continue;

            if (!platformWindow->hasPendingUpdateRequest())
                continue;

            if (window->screen() != screen())
                continue;

            // Skip windows that are not doing update requests via display link
            if (!(window->format().swapInterval() > 0))
                continue;

            platformWindow->deliverUpdateRequest();

            // Another update request was triggered, keep the display link running
            if (platformWindow->hasPendingUpdateRequest())
                pauseUpdates = false;
        }

        if (pauseUpdates) {
            // Pause the display link if there are no pending update requests
            qCDebug(lcQpaScreenUpdates) << "Stopping display link for" << this;
            CVDisplayLinkStop(m_displayLink);
        }

        if (const int missedUpdates = m_pendingUpdates.fetchAndStoreRelaxed(0) - pendingUpdates) {
            qCWarning(lcQpaScreenUpdates) << "main thread missed" << missedUpdates
                << "update(s) from display link during update request delivery";
        }
    }
}

bool QCocoaScreen::isRunningDisplayLink() const
{
    return m_displayLink && CVDisplayLinkIsRunning(m_displayLink);
}

// -----------------------------------------------------------

qreal QCocoaScreen::devicePixelRatio() const
{
    QMacAutoReleasePool pool;
    NSScreen *nsScreen = nativeScreen();
    return qreal(nsScreen ? [nsScreen backingScaleFactor] : 1.0);
}

QPlatformScreen::SubpixelAntialiasingType QCocoaScreen::subpixelAntialiasingTypeHint() const
{
    QPlatformScreen::SubpixelAntialiasingType type = QPlatformScreen::subpixelAntialiasingTypeHint();
    if (type == QPlatformScreen::Subpixel_None) {
        // Every OSX machine has RGB pixels unless a peculiar or rotated non-Apple screen is attached
        type = QPlatformScreen::Subpixel_RGB;
    }
    return type;
}

QWindow *QCocoaScreen::topLevelAt(const QPoint &point) const
{
    NSPoint screenPoint = mapToNative(point);

    // Search (hit test) for the top-level window. [NSWidow windowNumberAtPoint:
    // belowWindowWithWindowNumber] may return windows that are not interesting
    // to Qt. The search iterates until a suitable window or no window is found.
    NSInteger topWindowNumber = 0;
    QWindow *window = nullptr;
    do {
        // Get the top-most window, below any previously rejected window.
        topWindowNumber = [NSWindow windowNumberAtPoint:screenPoint
                                    belowWindowWithWindowNumber:topWindowNumber];

        // Continue the search if the window does not belong to this process.
        NSWindow *nsWindow = [NSApp windowWithWindowNumber:topWindowNumber];
        if (!nsWindow)
            continue;

        // Continue the search if the window does not belong to Qt.
        if (![nsWindow conformsToProtocol:@protocol(QNSWindowProtocol)])
            continue;

        id<QNSWindowProtocol> proto = static_cast<id<QNSWindowProtocol> >(nsWindow);
        QCocoaWindow *cocoaWindow = proto.platformWindow;
        if (!cocoaWindow)
            continue;
        window = cocoaWindow->window();

        // Continue the search if the window is not a top-level window.
        if (!window->isTopLevel())
             continue;

        // Stop searching. The current window is the correct window.
        break;
    } while (topWindowNumber > 0);

    return window;
}

QPixmap QCocoaScreen::grabWindow(WId window, int x, int y, int width, int height) const
{
    // TODO window should be handled
    Q_UNUSED(window)

    const int maxDisplays = 128; // 128 displays should be enough for everyone.
    CGDirectDisplayID displays[maxDisplays];
    CGDisplayCount displayCount;
    CGRect cgRect;

    if (width < 0 || height < 0) {
        // get all displays
        cgRect = CGRectInfinite;
    } else {
        cgRect = CGRectMake(x, y, width, height);
    }
    const CGDisplayErr err = CGGetDisplaysWithRect(cgRect, maxDisplays, displays, &displayCount);

    if (err && displayCount == 0)
        return QPixmap();

    // calculate pixmap size
    QSize windowSize(width, height);
    if (width < 0 || height < 0) {
        QRect windowRect;
        for (uint i = 0; i < displayCount; ++i) {
            const CGRect cgRect = CGDisplayBounds(displays[i]);
            QRect qRect(cgRect.origin.x, cgRect.origin.y, cgRect.size.width, cgRect.size.height);
            windowRect = windowRect.united(qRect);
        }
        if (width < 0)
            windowSize.setWidth(windowRect.width());
        if (height < 0)
            windowSize.setHeight(windowRect.height());
    }

    const qreal dpr = devicePixelRatio();
    QPixmap windowPixmap(windowSize * dpr);
    windowPixmap.fill(Qt::transparent);

    for (uint i = 0; i < displayCount; ++i) {
        const CGRect bounds = CGDisplayBounds(displays[i]);

        // Calculate the position and size of the requested area
        QPoint pos(qAbs(bounds.origin.x - x), qAbs(bounds.origin.y - y));
        QSize size(qMin(pos.x() + width, qRound(bounds.size.width)),
                   qMin(pos.y() + height, qRound(bounds.size.height)));
        pos *= dpr;
        size *= dpr;

        // Take the whole screen and crop it afterwards, because CGDisplayCreateImageForRect
        // has a strange behavior when mixing highDPI and non-highDPI displays
        QCFType<CGImageRef> cgImage = CGDisplayCreateImage(displays[i]);
        const QImage image = qt_mac_toQImage(cgImage);

        // Draw into windowPixmap only the requested size
        QPainter painter(&windowPixmap);
        painter.drawImage(windowPixmap.rect(), image, QRect(pos, size));
    }
    return windowPixmap;
}

/*!
    The screen used as a reference for global window geometry
*/
QCocoaScreen *QCocoaScreen::primaryScreen()
{
    return static_cast<QCocoaScreen *>(QGuiApplication::primaryScreen()->handle());
}

CGPoint QCocoaScreen::mapToNative(const QPointF &pos, QCocoaScreen *screen)
{
    Q_ASSERT(screen);
    return qt_mac_flip(pos, screen->geometry()).toCGPoint();
}

CGRect QCocoaScreen::mapToNative(const QRectF &rect, QCocoaScreen *screen)
{
    Q_ASSERT(screen);
    return qt_mac_flip(rect, screen->geometry()).toCGRect();
}

QPointF QCocoaScreen::mapFromNative(CGPoint pos, QCocoaScreen *screen)
{
    Q_ASSERT(screen);
    return qt_mac_flip(QPointF::fromCGPoint(pos), screen->geometry());
}

QRectF QCocoaScreen::mapFromNative(CGRect rect, QCocoaScreen *screen)
{
    Q_ASSERT(screen);
    return qt_mac_flip(QRectF::fromCGRect(rect), screen->geometry());
}

#ifndef QT_NO_DEBUG_STREAM
QDebug operator<<(QDebug debug, const QCocoaScreen *screen)
{
    QDebugStateSaver saver(debug);
    debug.nospace();
    debug << "QCocoaScreen(" << (const void *)screen;
    if (screen) {
        debug << ", index=" << screen->m_screenIndex;
        debug << ", native=" << screen->nativeScreen();
        debug << ", geometry=" << screen->geometry();
        debug << ", dpr=" << screen->devicePixelRatio();
        debug << ", name=" << screen->name();
    }
    debug << ')';
    return debug;
}
#endif // !QT_NO_DEBUG_STREAM

QT_END_NAMESPACE

@implementation NSScreen (QtExtras)

- (CGDirectDisplayID)qt_displayId
{
    return [self.deviceDescription[@"NSScreenNumber"] unsignedIntValue];
}

@end