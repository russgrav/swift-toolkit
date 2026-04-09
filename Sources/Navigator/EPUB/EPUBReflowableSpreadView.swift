//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumInternal
import ReadiumShared
import UIKit
import WebKit

/// A view rendering a spread of resources with a reflowable layout.
final class EPUBReflowableSpreadView: EPUBSpreadView {
    private var topConstraint: NSLayoutConstraint!
    private var bottomConstraint: NSLayoutConstraint!

    private static let reflowableScript = loadScript(named: "readium-reflowable")

    required init(
        viewModel: EPUBNavigatorViewModel,
        spread: EPUBSpread,
        scripts: [WKUserScript],
        animatedLoad: Bool
    ) {
        super.init(
            viewModel: viewModel,
            spread: spread,
            scripts: [
                WKUserScript(source: Self.reflowableScript, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            ],
            animatedLoad: animatedLoad
        )
    }

    override func setupWebView() {
        super.setupWebView()

        scrollView.bounces = false
        // Since iOS 16, the default value of alwaysBounceX seems to be true
        // for web views.
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false

        scrollView.isPagingEnabled = !viewModel.scroll

        webView.translatesAutoresizingMaskIntoConstraints = false
        topConstraint = webView.topAnchor.constraint(equalTo: topAnchor)
        topConstraint.priority = .defaultHigh
        bottomConstraint = webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        bottomConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topConstraint, bottomConstraint,
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateContentInset()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateContentInset()
    }

    override func loadSpread() {
        guard spread.links.count == 1 else {
            log(.error, "Only one document at a time can be displayed in a reflowable spread")
            return
        }
        let link = spread.leading
        let url = viewModel.url(to: link)
        webView.load(URLRequest(url: url.url))
    }

    override func applySettings() {
        super.applySettings()

        let isVertical = viewModel.settings.verticalText
        let isPaginated = !viewModel.settings.scroll

        // Configure scroll view paging
        scrollView.isPagingEnabled = isPaginated

        if isPaginated {
            // Paginated mode: ALWAYS horizontal paging (both LTR and RTL/vertical)
            scrollView.alwaysBounceHorizontal = true
            scrollView.alwaysBounceVertical = false
        } else if isVertical {
            // Vertical text scroll mode: horizontal scrolling
            scrollView.alwaysBounceHorizontal = true
            scrollView.alwaysBounceVertical = false
        } else {
            // Horizontal text scroll mode: vertical scrolling (default)
            scrollView.alwaysBounceVertical = true
            scrollView.alwaysBounceHorizontal = false
        }

        updateContentInset()
    }

    private func updateContentInset() {
        if viewModel.scroll {
            topConstraint.constant = 0
            bottomConstraint.constant = 0
            scrollView.contentInset = UIEdgeInsets(top: notchAreaInsets.top, left: 0, bottom: notchAreaInsets.bottom, right: 0)

        } else {
            let contentInset = viewModel.config.contentInset
            var insets = contentInset[traitCollection.verticalSizeClass]
                ?? contentInset[.regular]
                ?? contentInset[.unspecified]
                ?? (top: 0, bottom: 0)

            // Increases the insets by the notch area (eg. iPhone X) to make sure that the content is not overlapped by the screen notch.
            insets.top += notchAreaInsets.top
            insets.bottom += notchAreaInsets.bottom

            topConstraint.constant = insets.top
            bottomConstraint.constant = -insets.bottom
            scrollView.contentInset = .zero
        }
    }

    override func convertPointToNavigatorSpace(_ point: CGPoint) -> CGPoint {
        var point = point
        if viewModel.scroll {
            // Starting from iOS 12, the contentInset are not taken into account in the JS touch event.
            if #available(iOS 12.0, *) {
                if scrollView.contentOffset.x < 0 {
                    point.x += abs(scrollView.contentOffset.x)
                }
                if scrollView.contentOffset.y < 0 {
                    point.y += abs(scrollView.contentOffset.y)
                }
            } else {
                point.x += scrollView.contentInset.left
                point.y += scrollView.contentInset.top
            }
        }
        point.x += webView.frame.minX
        point.y += webView.frame.minY
        return point
    }

    override func convertRectToNavigatorSpace(_ rect: CGRect) -> CGRect {
        var rect = rect
        rect.origin = convertPointToNavigatorSpace(rect.origin)
        return rect
    }

    // MARK: - Location and progression

    override func progression<T>(in href: T) -> Double where T: URLConvertible {
        guard
            spread.leading.url().isEquivalentTo(href),
            let progression = progression
        else {
            return 0
        }
        return progression
    }

    override func spreadDidLoad() {
        Task {
            if let linkJSON = serializeJSONString(spread.leading.json) {
                await evaluateScript("readium.link = \(linkJSON);")
            }

            // TODO: Better solution for delaying scrolling to pending location
            // This delay is used to wait for the web view pagination to settle and give the CSS and webview time to layout
            // correctly before attempting to scroll to the target progression, otherwise we might end up at the wrong spot.
            // 0.2 seconds seems like a good value for it to work on an iPhone 5s.
            try? await Task.sleep(seconds: 0.2)

            let location = pendingLocation
            await go(to: pendingLocation)

            // The rendering is sometimes very slow. So in case we don't show the first page of the resource, we add
            // a generous delay before showing the spread again.
            let delayed = !location.isStart
            try? await Task.sleep(seconds: delayed ? 0.3 : 0)

            self.showSpread()
        }
    }

    override func go(to direction: EPUBSpreadView.Direction, options: NavigatorGoOptions) async -> Bool {
        guard !viewModel.scroll else {
            return await super.go(to: direction, options: options)
        }

        let isVertical = viewModel.settings.verticalText

        // For vertical text (RTL), the scrolling direction is inverted
        // - Left swipe = next page (scroll more negative)
        // - Right swipe = previous page (scroll less negative)
        switch direction {
        case .left:
            let script = """
            (function() {
                const isVertical = readium.isVerticalWritingMode ? readium.isVerticalWritingMode() : false;
                const currentOffset = window.scrollX;
                const pageWidth = document.documentElement.clientWidth;
                const totalWidth = document.documentElement.scrollWidth;

                console.log('📘 [go.left] isVertical:', isVertical, 'currentOffset:', currentOffset, 'pageWidth:', pageWidth);

                if (isVertical) {
                    // RTL vertical text: left swipe = next page (scroll more negative)
                    const newOffset = currentOffset - pageWidth;
                    const minOffset = -(totalWidth - pageWidth);

                    console.log('📘 [go.left] RTL mode: newOffset:', newOffset, 'minOffset:', minOffset);

                    if (newOffset < minOffset) {
                        console.log('📘 [go.left] At end of chapter (RTL)');
                        return false;
                    }

                    window.scrollTo({ left: newOffset, behavior: 'smooth' });
                    return true;
                } else {
                    // LTR horizontal text: left swipe = previous page
                    const newOffset = currentOffset - pageWidth;

                    console.log('📘 [go.left] LTR mode: newOffset:', newOffset);

                    if (newOffset < 0) {
                        console.log('📘 [go.left] At start of chapter (LTR)');
                        return false;
                    }

                    window.scrollTo({ left: newOffset, behavior: 'smooth' });
                    return true;
                }
            })();
            """

            let result = await evaluateScript(script)
            switch result {
            case .success(let value):
                if let success = value as? Bool, !success {
                    return false
                }
                try? await Task.sleep(seconds: 0.3)
                return true

            case .failure(let error):
                log(.error, error)
                return false
            }

        case .right:
            let script = """
            (function() {
                const isVertical = readium.isVerticalWritingMode ? readium.isVerticalWritingMode() : false;
                const currentOffset = window.scrollX;
                const pageWidth = document.documentElement.clientWidth;
                const totalWidth = document.documentElement.scrollWidth;

                console.log('📘 [go.right] isVertical:', isVertical, 'currentOffset:', currentOffset, 'pageWidth:', pageWidth);

                if (isVertical) {
                    // RTL vertical text: right swipe = previous page (scroll less negative)
                    const newOffset = currentOffset + pageWidth;

                    console.log('📘 [go.right] RTL mode: newOffset:', newOffset);

                    if (newOffset > 0) {
                        console.log('📘 [go.right] At start of chapter (RTL)');
                        return false;
                    }

                    window.scrollTo({ left: newOffset, behavior: 'smooth' });
                    return true;
                } else {
                    // LTR horizontal text: right swipe = next page
                    const newOffset = currentOffset + pageWidth;

                    console.log('📘 [go.right] LTR mode: newOffset:', newOffset);

                    if (newOffset >= totalWidth) {
                        console.log('📘 [go.right] At end of chapter (LTR)');
                        return false;
                    }

                    window.scrollTo({ left: newOffset, behavior: 'smooth' });
                    return true;
                }
            })();
            """

            let result = await evaluateScript(script)
            switch result {
            case .success(let value):
                if let success = value as? Bool, !success {
                    return false
                }
                try? await Task.sleep(seconds: 0.3)
                return true

            case .failure(let error):
                log(.error, error)
                return false
            }
        }
    }

    // Location to scroll to in the resource once the page is loaded.
    private var pendingLocation: PageLocation = .start

    @MainActor
    override func go(to location: PageLocation) async {
        guard spreadLoaded else {
            // Delays moving to the location until the document is loaded.
            pendingLocation = location

            await waitGoToCompletion()
            return
        }

        switch location {
        case let .locator(locator):
            await go(to: locator)
        case .start:
            await scroll(toProgression: 0)
        case .end:
            await scroll(toProgression: 1)
        }

        await didCompleteGoTo()
    }

    @MainActor
    private func waitGoToCompletion() async {
        await withCheckedContinuation { continuation in
            goToContinuations.append(continuation)
        }
    }

    @MainActor
    private func didCompleteGoTo() async {
        for cont in goToContinuations {
            cont.resume()
        }
        goToContinuations.removeAll()
    }

    @MainActor
    private var goToContinuations: [CheckedContinuation<Void, Never>] = []

    @discardableResult
    private func go(to locator: Locator) async -> Bool {
        guard ["", "#"].contains(locator.href.string) || spread.contains(href: locator.href) else {
            log(.warning, "The locator's href is not in the spread")
            return false
        }

        if locator.text.highlight != nil {
            return await scroll(toLocator: locator)
            // TODO: find the first fragment matching a tag ID (need a regex)
        } else if let id = locator.locations.fragments.first, !id.isEmpty {
            return await scroll(toTagID: id)
        } else {
            let progression = locator.locations.progression ?? 0
            return await scroll(toProgression: progression)
        }
    }

    /// Scrolls at given progression (from 0.0 to 1.0)
    @discardableResult
    private func scroll(toProgression progression: Double) async -> Bool {
        let href = spread.leading.url().string
        print("🐾 [TempPos] scroll(toProgression: \(progression)) called for href: \(href)")
        
        // IMPORTANT: Only apply scroll positioning if this is the current visible page
        // Preloaded pages should not execute scroll positioning scripts
        guard let parentView = superview as? UIScrollView,
              let paginationView = parentView.superview as? PaginationView,
              let currentView = paginationView.currentView,
              currentView === self else {
            print("🐾 [TempPos] Skipping scroll positioning for non-current page: \(href)")
            return true // Return true but don't execute positioning
        }
        
        guard progression >= 0, progression <= 1 else {
            log(.warning, "Scrolling to invalid progression \(progression)")
            return false
        }

        if viewModel.scroll {
            // FIXED: For vertical scroll mode, save and restore vertical scroll position properly
            let script = """
            (function() {
                // In scroll mode, we need to save and restore Y position
                // Calculate the scroll position directly from the progression
                const maxScrollY = document.documentElement.scrollHeight - document.documentElement.clientHeight;
                const targetPositionY = Math.max(0, Math.min(maxScrollY, maxScrollY * \(progression)));
                
                // Scroll vertically to the saved position
                window.scrollTo({
                    left: 0,
                    top: targetPositionY,
                    behavior: 'auto'
                });
                
                // Make sure we trigger a progression update after scrolling
                if (window.reportProgression) {
                    setTimeout(window.reportProgression, 100);
                }
                
                return true;
            })();
            """
            
            await evaluateScript(script)
            return true
        } else {
            // For pagination mode, ensure we snap to page boundaries
            let script = """
            (function() {
                const isVertical = readium.isVerticalWritingMode ? readium.isVerticalWritingMode() : false;
                const pageWidth = document.documentElement.clientWidth;
                const totalWidth = document.documentElement.scrollWidth;
                const maxScroll = totalWidth - pageWidth;

                console.log('📘 [scroll] toProgression:', \(progression), 'isVertical:', isVertical, 'totalWidth:', totalWidth, 'pageWidth:', pageWidth);

                let targetPosition;

                if (isVertical) {
                    // RTL vertical text: progression 0 = rightmost (most negative)
                    // progression 1 = leftmost (scrollX = 0)
                    const pageNumber = Math.floor(\(progression) * (maxScroll / pageWidth));
                    // In RTL, we count from the right, so invert the position
                    targetPosition = -(maxScroll - (pageNumber * pageWidth));

                    console.log('📘 [scroll] RTL mode: pageNumber:', pageNumber, 'targetPosition:', targetPosition);
                } else {
                    // LTR horizontal text: progression 0 = leftmost (scrollX = 0)
                    const pageNumber = Math.floor(\(progression) * (maxScroll / pageWidth));
                    targetPosition = pageNumber * pageWidth;

                    console.log('📘 [scroll] LTR mode: pageNumber:', pageNumber, 'targetPosition:', targetPosition);
                }

                window.scrollTo({
                    left: targetPosition,
                    behavior: 'auto'
                });

                // Make sure we trigger a progression update after scrolling
                if (window.reportProgression) {
                    setTimeout(window.reportProgression, 100);
                }
                
                return true;
            })();
            """
            
            await evaluateScript(script)
            return true
        }
    }

    /// Scrolls at the tag with ID `tagID`.
    @discardableResult
    private func scroll(toTagID tagID: String) async -> Bool {
        // FIXED: Use direct element scrolling instead of readium function for consistent LTR behavior
        let script = """
        (function() {
            // Force LTR pagination regardless of document direction
            const element = document.getElementById('\(tagID)');
            if (!element) return false;
            
            // Get the element's position
            const rect = element.getBoundingClientRect();
            const scrollLeft = window.pageXOffset || document.documentElement.scrollLeft;
            const scrollTop = window.pageYOffset || document.documentElement.scrollTop;
            
            // Determine if we're in scroll mode
            const isVerticalScroll = \(viewModel.scroll);
            
            if (isVerticalScroll) {
                // Calculate position to scroll to vertically
                const targetPosition = scrollTop + rect.top;
                
                // Perform the scroll
                window.scrollTo({
                    left: 0,
                    top: targetPosition,
                    behavior: 'smooth'
                });
            } else {
                // Calculate position to scroll to horizontally
                // For pagination, snap to page boundary
                const pageWidth = document.documentElement.clientWidth;
                const targetPage = Math.floor((scrollLeft + rect.left) / pageWidth);
                const targetPosition = targetPage * pageWidth;
                
                // Perform the scroll
                window.scrollTo({
                    left: targetPosition,
                    behavior: 'smooth'
                });
            }
            
            return true;
        })();
        """
        
        let result = await evaluateScript(script)
        switch result {
        case let .success(value):
            return (value as? Bool) ?? false
        case let .failure(error):
            log(.error, error)
            return false
        }
    }

    /// Scrolls at the snippet matching the given text context.
    @discardableResult
    private func scroll(toLocator locator: Locator) async -> Bool {
        guard let json = locator.jsonString else {
            return false
        }
        // FIXED: Instead of relying on readium.scrollToLocator, we use our own implementation
        // First, let readium find the element, then we'll handle the scrolling ourselves
        let script = """
        (function() {
            // Force LTR pagination regardless of document direction
            const locator = \(json);
            
            // Use readium's helper function to find the element
            const element = readium.findLocator(locator);
            if (!element) return false;
            
            // Get the element's position
            const rect = element.getBoundingClientRect();
            const scrollLeft = window.pageXOffset || document.documentElement.scrollLeft;
            const scrollTop = window.pageYOffset || document.documentElement.scrollTop;
            
            // Determine if we're in scroll mode
            const isVerticalScroll = \(viewModel.scroll);
            
            if (isVerticalScroll) {
                // Calculate position to scroll to vertically
                const targetPosition = scrollTop + rect.top;
                
                // Perform the scroll
                window.scrollTo({
                    left: 0,
                    top: targetPosition,
                    behavior: 'smooth'
                });
            } else {
                // Calculate position to scroll to horizontally
                // For pagination, snap to page boundary
                const pageWidth = document.documentElement.clientWidth;
                const targetPage = Math.floor((scrollLeft + rect.left) / pageWidth);
                const targetPosition = targetPage * pageWidth;
                
                // Perform the scroll
                window.scrollTo({
                    left: targetPosition,
                    behavior: 'smooth'
                });
            }
            
            return true;
        })();
        """
        
        let result = await evaluateScript(script)
        switch result {
        case let .success(value):
            return (value as? Bool) ?? false
        case let .failure(error):
            log(.error, error)
            return false
        }
    }

    // MARK: - Progression

    // Current progression in the page.
    private var progression: Double?
    // To check if a progression change was cancelled or not.
    private var previousProgression: Double?

    // Called by the javascript code to notify that scrolling ended.
    private func progressionDidChange(_ body: Any) {
        guard spreadLoaded, let bodyString = body as? String, var newProgression = Double(bodyString) else {
            return
        }
        newProgression = min(max(newProgression, 0.0), 1.0)

        if previousProgression == nil {
            previousProgression = progression
        }
        progression = newProgression

        setNeedsNotifyPagesDidChange()
    }

    private func setNeedsNotifyPagesDidChange() {
        // Makes sure we always receive the "ending scroll" event.
        // ie. https://stackoverflow.com/a/1857162/1474476
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(notifyPagesDidChange), object: nil)
        perform(#selector(notifyPagesDidChange), with: nil, afterDelay: 0.3)
    }

    @objc private func notifyPagesDidChange() {
        guard previousProgression != progression else {
            return
        }
        previousProgression = nil
        delegate?.spreadViewPagesDidChange(self)
    }

    // MARK: - Scripts

    override func registerJSMessages() {
        super.registerJSMessages()
        registerJSMessage(named: "progressionChanged") { [weak self] in self?.progressionDidChange($0) }
    }

    // MARK: - WKNavigationDelegate

    override func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        super.webView(webView, didFinish: navigation)

        // Fixes https://github.com/readium/r2-navigator-swift/issues/141 by disabling the native
        // double-tap gesture.
        // It's an acceptable fix because reflowable resources are not supposed to handle double-tap
        // since there's no zooming capabilities. This doesn't prevent JavaScript to handle
        // double-tap manually.
        webView.removeDoubleTapGestureRecognizer()
        
        // FIXED: Configure the HTML content for horizontal pagination
        // This will help ensure consistent LTR behavior
        let configureScript = """
        (function() {
            // Force LTR text direction and horizontal writing mode on all content
            // This ensures consistent pagination for all Japanese content
            document.documentElement.style.direction = 'ltr';
            document.documentElement.style.writingMode = 'horizontal-tb';
            
            // Apply to body as well to ensure it cascades
            if (document.body) {
                document.body.style.direction = 'ltr';
                document.body.style.writingMode = 'horizontal-tb';
            }
            
            // Configure scroll behavior based on mode
            if (\(viewModel.scroll)) {
                // Vertical Scroll Mode
                document.documentElement.style.height = '100%';
                document.body.style.height = 'auto';
                document.body.style.margin = '0';
                document.body.style.padding = '0';
                
                // Enable vertical scrolling
                document.documentElement.style.overflowY = 'auto';
                document.documentElement.style.overflowX = 'hidden';
            } else {
                // Horizontal Pagination Mode
                document.documentElement.style.height = '100%';
                document.body.style.height = '100%';
                document.body.style.margin = '0';
                document.body.style.padding = '0';
                
                // Enable horizontal pagination
                document.documentElement.style.overflowY = 'hidden';
                document.documentElement.style.overflowX = 'auto';
            }
            
            // Set up improved progression tracking
            let lastScrollTime = 0;
            let scrollTimeoutId = null;
            const SCROLL_INTERVAL = 250; // ms between progression updates
            
            // Function to calculate and report progression
            function reportProgression() {
                let progression;
                const isVerticalScroll = \(viewModel.scroll);
                
                if (isVerticalScroll) {
                    // Vertical scroll mode - track Y position
                    const maxScrollY = document.documentElement.scrollHeight - document.documentElement.clientHeight;
                    if (maxScrollY <= 0) {
                        progression = 0;
                    } else {
                        progression = window.scrollY / maxScrollY;
                    }
                } else {
                    // Horizontal pagination mode - track X position
                    const maxScrollX = document.documentElement.scrollWidth - document.documentElement.clientWidth;
                    if (maxScrollX <= 0) {
                        progression = 0;
                    } else {
                        progression = window.scrollX / maxScrollX;
                    }
                }
                
                // Clamp progression between 0 and 1
                progression = Math.max(0, Math.min(1, progression));
                
                // Report progression to native code
                window.webkit.messageHandlers.progressionChanged.postMessage(progression.toString());
            }
            
            // Throttled scroll event handler
            function onScroll() {
                const now = Date.now();
                
                // Avoid too frequent updates
                if (now - lastScrollTime < SCROLL_INTERVAL) {
                    if (scrollTimeoutId) {
                        clearTimeout(scrollTimeoutId);
                    }
                    
                    scrollTimeoutId = setTimeout(function() {
                        lastScrollTime = now;
                        reportProgression();
                        scrollTimeoutId = null;
                    }, SCROLL_INTERVAL);
                    
                    return;
                }
                
                lastScrollTime = now;
                reportProgression();
            }
            
            // Register event listeners
            window.addEventListener('scroll', onScroll, { passive: true });
            window.addEventListener('resize', reportProgression, { passive: true });
            
            // Initial report of progression
            setTimeout(reportProgression, 200);
            
            // Make the function available globally to call when needed
            window.reportProgression = reportProgression;
            
            return true;
        })();
        """
        
        // Execute the configuration script when page loads
        webView.evaluateJavaScript(configureScript)
    }

    // MARK: - UIScrollViewDelegate

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        super.scrollViewDidScroll(scrollView)
        setNeedsNotifyPagesDidChange()
    }
}
