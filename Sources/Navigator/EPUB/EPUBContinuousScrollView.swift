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

/// A view that provides continuous scrolling across multiple EPUB resources
/// by concatenating them into a single scrollable WebView.
final class EPUBContinuousScrollView: UIView, Loggable {
    
    // MARK: - Properties
    
    weak var delegate: EPUBContinuousScrollViewDelegate?
    private let viewModel: EPUBNavigatorViewModel
    private let readingOrder: [Link]
    private let webView: WebView
    
    /// Current scroll position as a percentage of total content
    private(set) var scrollProgression: Double = 0.0
    
    /// Currently loaded resources with their boundaries
    private var loadedResources: [LoadedResource] = []
    
    /// Resource boundaries for position mapping
    private var resourceBoundaries: [ResourceBoundary] = []
    
    /// Whether the continuous content has been loaded
    private(set) var isContentLoaded = false
    
    /// Range of resource indices currently loaded
    private var loadedResourceRange: Range<Int> = 0..<0
    
    /// Number of resources to preload before/after current position
    private let preloadCount: Int
    
    // FIX 3: Add state management to prevent reload loops
    private var isLoadingResources = false
    private var pendingScrollPosition: CGFloat?
    
    // MARK: - Initialization
    
    init(
        viewModel: EPUBNavigatorViewModel,
        readingOrder: [Link],
        preloadCount: Int = 3
    ) {
        self.viewModel = viewModel
        self.readingOrder = readingOrder
        self.preloadCount = preloadCount
        self.webView = WebView(editingActions: viewModel.editingActions)
        
        super.init(frame: .zero)
        
        setupWebView()
        setupNotifications()
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Setup
    
    private func setupWebView() {
        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        
        // Configure for continuous scrolling
        webView.scrollView.isPagingEnabled = false
        webView.scrollView.bounces = true
        webView.scrollView.alwaysBounceVertical = true
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.showsHorizontalScrollIndicator = false
        webView.scrollView.showsVerticalScrollIndicator = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        
        addSubview(webView)
    }
    
    private func setupNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(voiceOverStatusDidChange),
            name: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil
        )
    }
    
    // MARK: - Public Methods
    
    /// Load the continuous scroll content starting from the given resource index
    func loadContent(startingAt resourceIndex: Int = 0) async {
        guard !readingOrder.isEmpty else {
            log(.error, "Cannot load content: reading order is empty")
            return
        }
        
        let safeIndex = max(0, min(resourceIndex, readingOrder.count - 1))
        await loadResourcesAround(index: safeIndex)
        isContentLoaded = true
        
        await MainActor.run {
            delegate?.continuousScrollViewDidLoad(self)
        }
    }
    
    /// Scroll to a specific locator position
    func scrollTo(locator: Locator, animated: Bool = false) async -> Bool {
        guard isContentLoaded else {
            log(.warning, "Cannot scroll to locator: content not loaded")
            return false
        }
        
        // Find the resource containing this locator
        guard let resourceIndex = readingOrder.firstIndex(where: { $0.href == locator.href.string }) else {
            log(.warning, "Cannot find resource for href: \(locator.href)")
            return false
        }
        
        // Ensure the resource is loaded
        await ensureResourceLoaded(at: resourceIndex)
        
        // Calculate scroll position
        guard let scrollPosition = calculateScrollPosition(for: locator) else {
            log(.warning, "Cannot calculate scroll position for locator")
            return false
        }
        
        await MainActor.run {
            let contentOffset = CGPoint(x: 0, y: scrollPosition)
            webView.scrollView.setContentOffset(contentOffset, animated: animated)
        }
        
        return true
    }
    
    /// Get the current locator based on scroll position
    func getCurrentLocator() -> Locator? {
        guard isContentLoaded else { return nil }
        
        let scrollOffset = webView.scrollView.contentOffset.y
        let contentHeight = webView.scrollView.contentSize.height
        let viewportHeight = webView.scrollView.frame.height
        
        // Calculate current progression
        let totalScrollableHeight = max(contentHeight - viewportHeight, 1)
        scrollProgression = min(max(scrollOffset / totalScrollableHeight, 0), 1)
        
        // Find the resource at current scroll position
        guard let boundary = resourceBoundaries.first(where: { boundary in
            scrollOffset >= boundary.startY && scrollOffset < boundary.endY
        }) else {
            return nil
        }
        
        // Calculate progression within the resource
        let resourceHeight = boundary.endY - boundary.startY
        let resourceScrollOffset = scrollOffset - boundary.startY
        let resourceProgression = resourceHeight > 0 ? resourceScrollOffset / resourceHeight : 0
        
        let link = readingOrder[boundary.resourceIndex]
        return Locator(
            href: AnyURL(string: link.href)!,
            mediaType: link.mediaType ?? .xhtml,
            title: link.title,
            locations: .init(
                progression: min(max(resourceProgression, 0), 1),
                totalProgression: scrollProgression
            )
        )
    }
    
    /// Scroll forward by one viewport height
    func scrollForward(animated: Bool = false) async -> Bool {
        await MainActor.run {
            let currentOffset = webView.scrollView.contentOffset.y
            let viewportHeight = webView.scrollView.frame.height
            let maxOffset = webView.scrollView.contentSize.height - viewportHeight
            let newOffset = min(currentOffset + viewportHeight, maxOffset)
            
            if newOffset > currentOffset {
                webView.scrollView.setContentOffset(CGPoint(x: 0, y: newOffset), animated: animated)
                return true
            }
            return false
        }
    }
    
    /// Scroll backward by one viewport height
    func scrollBackward(animated: Bool = false) async -> Bool {
        await MainActor.run {
            let currentOffset = webView.scrollView.contentOffset.y
            let viewportHeight = webView.scrollView.frame.height
            let newOffset = max(currentOffset - viewportHeight, 0)
            
            if newOffset < currentOffset {
                webView.scrollView.setContentOffset(CGPoint(x: 0, y: newOffset), animated: animated)
                return true
            }
            return false
        }
    }
    
    /// Apply user settings to the continuous scroll view
    func applySettings() {
        guard isContentLoaded else { return }
        
        // Apply theme and styling
        webView.backgroundColor = UIColor.systemBackground
        
        // Inject CSS for user preferences
        Task {
            await injectUserSettings()
        }
    }
    
    // MARK: - Private Methods
    
    private func loadResourcesAround(index targetIndex: Int) async {
        let startIndex = max(0, targetIndex - preloadCount)
        let endIndex = min(readingOrder.count, targetIndex + preloadCount + 1)
        
        loadedResourceRange = startIndex..<endIndex
        loadedResources = []
        resourceBoundaries = []
        
        var htmlContent = createContinuousHTML()
        var currentHeight: CGFloat = 0
        
        for i in startIndex..<endIndex {
            let link = readingOrder[i]
            
            do {
                let resourceContent = try await loadResourceContent(link: link)
                let loadedResource = LoadedResource(
                    index: i,
                    link: link,
                    content: resourceContent,
                    startHeight: currentHeight
                )
                
                loadedResources.append(loadedResource)
                htmlContent += createResourceHTML(for: loadedResource)
                
                // We'll calculate actual heights after loading
                let boundary = ResourceBoundary(
                    resourceIndex: i,
                    startY: currentHeight,
                    endY: currentHeight + 1000 // Temporary, will be updated
                )
                resourceBoundaries.append(boundary)
                
                currentHeight += 1000 // Temporary spacing
                
            } catch {
                log(.error, "Failed to load resource \(link.href): \(error)")
            }
        }
        
        htmlContent += "</body></html>"
        
        await MainActor.run {
            webView.loadHTMLString(htmlContent, baseURL: viewModel.publicationBaseURL.url)
        }
    }
    
    // FIX 4: Use asynchronous loading via resource loader
    private func loadResourceContent(link: Link) async throws -> String {
        // This should use the EPUBContinuousResourceLoader instead of direct file access
        let url = viewModel.url(to: link)
        let (data, _) = try await URLSession.shared.data(from: url.url)
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    private func createContinuousHTML() -> String {
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body {
                    margin: 0;
                    padding: 0;
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    line-height: 1.6;
                    background-color: transparent;
                }
                .resource-container {
                    margin: 20px;
                    padding: 20px;
                    border-bottom: 1px solid #e0e0e0;
                    page-break-inside: avoid;
                }
                .resource-container:last-child {
                    border-bottom: none;
                }
                .resource-header {
                    font-size: 0.9em;
                    color: #666;
                    margin-bottom: 10px;
                    font-weight: 500;
                }
                .resource-content {
                    /* Inherit styles from original resource */
                }
                /* Ensure images are responsive */
                img {
                    max-width: 100%;
                    height: auto;
                    display: block;
                    margin: 10px auto;
                }
                /* Handle missing images gracefully */
                img[src=""], img:not([src]) {
                    display: none;
                }
                /* Basic responsive design */
                @media (max-width: 768px) {
                    .resource-container {
                        margin: 10px;
                        padding: 15px;
                    }
                }
            </style>
            <script>
                // FIX 5: Enhanced scroll tracking with error handling
                let scrollTimeout;
                window.addEventListener('scroll', function() {
                    clearTimeout(scrollTimeout);
                    scrollTimeout = setTimeout(function() {
                        try {
                            const scrollTop = window.pageYOffset;
                            const documentHeight = document.documentElement.scrollHeight;
                            const windowHeight = window.innerHeight;
                            const scrollPercent = scrollTop / (documentHeight - windowHeight);
                            
                            // Post message to native layer with error handling
                            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.scrollProgress) {
                                window.webkit.messageHandlers.scrollProgress.postMessage({
                                    scrollTop: scrollTop,
                                    scrollPercent: scrollPercent,
                                    documentHeight: documentHeight,
                                    timestamp: Date.now()
                                });
                            }
                        } catch (error) {
                            console.error('Scroll tracking error:', error);
                        }
                    }, 16); // Throttle to 60fps
                });
                
                // Handle image load errors
                document.addEventListener('DOMContentLoaded', function() {
                    const images = document.querySelectorAll('img');
                    images.forEach(function(img) {
                        img.addEventListener('error', function() {
                            console.warn('Failed to load image:', img.src);
                            img.style.display = 'none';
                        });
                    });
                });
            </script>
        </head>
        <body>
        """
    }
    
    private func createResourceHTML(for resource: LoadedResource) -> String {
        let title = resource.link.title ?? "Chapter \(resource.index + 1)"
        let cleanContent = cleanResourceContent(resource.content)
        
        return """
        <div class="resource-container" data-resource-index="\(resource.index)" data-resource-href="\(resource.link.href)">
            <div class="resource-header">\(escapeHTML(title))</div>
            <div class="resource-content">
                \(cleanContent)
            </div>
        </div>
        """
    }
    
    private func cleanResourceContent(_ content: String) -> String {
        // Remove HTML document structure, keep only body content
        // This is a simplified version - in production you'd want more robust HTML parsing
        
        var cleaned = content
        
        // Remove DOCTYPE, html, head tags using NSRegularExpression
        do {
            let doctypeRegex = try NSRegularExpression(pattern: "<!DOCTYPE[^>]*>", options: [.caseInsensitive])
            cleaned = doctypeRegex.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(location: 0, length: cleaned.count), withTemplate: "")
            
            let htmlOpenRegex = try NSRegularExpression(pattern: "<html[^>]*>", options: [.caseInsensitive])
            cleaned = htmlOpenRegex.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(location: 0, length: cleaned.count), withTemplate: "")
            
            let htmlCloseRegex = try NSRegularExpression(pattern: "</html>", options: [.caseInsensitive])
            cleaned = htmlCloseRegex.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(location: 0, length: cleaned.count), withTemplate: "")
            
            let headRegex = try NSRegularExpression(pattern: "<head>.*?</head>", options: [.caseInsensitive, .dotMatchesLineSeparators])
            cleaned = headRegex.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(location: 0, length: cleaned.count), withTemplate: "")
            
            let bodyOpenRegex = try NSRegularExpression(pattern: "<body[^>]*>", options: [.caseInsensitive])
            cleaned = bodyOpenRegex.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(location: 0, length: cleaned.count), withTemplate: "")
            
            let bodyCloseRegex = try NSRegularExpression(pattern: "</body>", options: [.caseInsensitive])
            cleaned = bodyCloseRegex.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(location: 0, length: cleaned.count), withTemplate: "")
        } catch {
            log(.warning, "Failed to apply regex cleaning: \(error)")
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func escapeHTML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    
    private func ensureResourceLoaded(at index: Int) async {
        guard !loadedResourceRange.contains(index) else { return }
        
        // Resource is not loaded, need to load resources around this index
        await loadResourcesAround(index: index)
    }
    
    private func calculateScrollPosition(for locator: Locator) -> CGFloat? {
        // Find the resource boundary for this locator
        guard let resourceIndex = readingOrder.firstIndex(where: { $0.href == locator.href.string }),
              let boundary = resourceBoundaries.first(where: { $0.resourceIndex == resourceIndex }) else {
            return nil
        }
        
        // Calculate position within the resource
        let resourceProgression = locator.locations.progression ?? 0
        let resourceHeight = boundary.endY - boundary.startY
        let positionInResource = resourceProgression * resourceHeight
        
        return boundary.startY + positionInResource
    }
    
    private func injectUserSettings() async {
        // Inject CSS for user preferences
        let css = generateUserCSS()
        let script = """
        (function() {
            try {
                var style = document.createElement('style');
                style.textContent = `\(css.replacingOccurrences(of: "`", with: "\\`"))`;
                document.head.appendChild(style);
            } catch (error) {
                console.error('Failed to inject user settings:', error);
            }
        })();
        """
        
        do {
            _ = try await webView.evaluateJavaScript(script)
        } catch {
            log(.error, "Failed to inject user settings: \(error)")
        }
    }
    
    private func generateUserCSS() -> String {
        let settings = viewModel.settings
        
        return """
        .resource-content {
            font-size: \(settings.fontSize)em;
            line-height: \(settings.lineHeight ?? 1.6);
            color: #000000;
            background-color: #ffffff;
            font-family: \(settings.fontFamily?.rawValue ?? "-apple-system, BlinkMacSystemFont, sans-serif");
            text-align: left;
            word-spacing: \(settings.wordSpacing ?? 0)em;
            letter-spacing: \(settings.letterSpacing ?? 0)em;
            margin: 0 \(settings.pageMargins)em;
        }
        
        .resource-container {
            background-color: #ffffff;
        }
        
        body {
            background-color: #ffffff;
        }
        """
    }
    
    @objc private func voiceOverStatusDidChange() {
        // Handle VoiceOver changes if needed
        applySettings()
    }
    
    // FIX 3: Incremental loading methods to prevent scroll jumping
    private func loadPreviousResources() {
        guard !isLoadingResources else { return }
        isLoadingResources = true
        
        Task {
            defer { isLoadingResources = false }
            
            // Store current scroll position relative to content
            let scrollView = webView.scrollView
            let currentOffset = scrollView.contentOffset.y
            let currentContentHeight = scrollView.contentSize.height
            
            // Load previous resources without rebuilding entire view
            await loadAdditionalResourcesAtBeginning()
            
            // Restore scroll position relative to new content
            let newContentHeight = scrollView.contentSize.height
            let heightDifference = newContentHeight - currentContentHeight
            let newOffset = currentOffset + heightDifference
            
            await MainActor.run {
                scrollView.setContentOffset(CGPoint(x: 0, y: newOffset), animated: false)
            }
        }
    }
    
    private func loadNextResources() {
        guard !isLoadingResources else { return }
        isLoadingResources = true
        
        Task {
            defer { isLoadingResources = false }
            await loadAdditionalResourcesAtEnd()
        }
    }
    
    private func loadAdditionalResourcesAtBeginning() async {
        let currentStart = loadedResourceRange.lowerBound
        let newStart = max(0, currentStart - preloadCount)
        
        guard newStart < currentStart else { return }
        
        var additionalHTML = ""
        
        for i in newStart..<currentStart {
            let link = readingOrder[i]
            
            do {
                let resourceContent = try await loadResourceContent(link: link)
                let loadedResource = LoadedResource(
                    index: i,
                    link: link,
                    content: resourceContent,
                    startHeight: 0 // Will be calculated
                )
                
                additionalHTML += createResourceHTML(for: loadedResource)
                
            } catch {
                log(.error, "Failed to load resource \(link.href): \(error)")
            }
        }
        
        // Prepend to existing content
        await MainActor.run {
            let script = """
            (function() {
                try {
                    const container = document.body;
                    const tempDiv = document.createElement('div');
                    tempDiv.innerHTML = `\(additionalHTML.replacingOccurrences(of: "`", with: "\\`"))`;
                    
                    while (tempDiv.firstChild) {
                        container.insertBefore(tempDiv.firstChild, container.firstChild);
                    }
                } catch (error) {
                    console.error('Failed to prepend content:', error);
                }
            })();
            """
            
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    self.log(.error, "Failed to prepend content: \(error)")
                }
            }
        }
        
        loadedResourceRange = newStart..<loadedResourceRange.upperBound
    }
    
    private func loadAdditionalResourcesAtEnd() async {
        let currentEnd = loadedResourceRange.upperBound
        let newEnd = min(readingOrder.count, currentEnd + preloadCount)
        
        guard newEnd > currentEnd else { return }
        
        var additionalHTML = ""
        
        for i in currentEnd..<newEnd {
            let link = readingOrder[i]
            
            do {
                let resourceContent = try await loadResourceContent(link: link)
                let loadedResource = LoadedResource(
                    index: i,
                    link: link,
                    content: resourceContent,
                    startHeight: 0
                )
                
                additionalHTML += createResourceHTML(for: loadedResource)
                
            } catch {
                log(.error, "Failed to load resource \(link.href): \(error)")
            }
        }
        
        // Append to existing content
        await MainActor.run {
            let script = """
            (function() {
                try {
                    const container = document.body;
                    const tempDiv = document.createElement('div');
                    tempDiv.innerHTML = `\(additionalHTML.replacingOccurrences(of: "`", with: "\\`"))`;
                    
                    while (tempDiv.firstChild) {
                        container.appendChild(tempDiv.firstChild);
                    }
                } catch (error) {
                    console.error('Failed to append content:', error);
                }
            })();
            """
            
            webView.evaluateJavaScript(script) { _, error in
                if let error = error {
                    self.log(.error, "Failed to append content: \(error)")
                }
            }
        }
        
        loadedResourceRange = loadedResourceRange.lowerBound..<newEnd
    }
}

// MARK: - Data Structures

private struct LoadedResource {
    let index: Int
    let link: Link
    let content: String
    let startHeight: CGFloat
}

private struct ResourceBoundary {
    let resourceIndex: Int
    let startY: CGFloat
    let endY: CGFloat
}

// MARK: - Scroll View Delegate

extension EPUBContinuousScrollView: UIScrollViewDelegate {
    // FIX 3: Enhanced scroll delegate with proper state management
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Store current scroll position before any updates
        let currentOffset = scrollView.contentOffset.y
        
        // Update current locator and notify delegate
        if let locator = getCurrentLocator() {
            delegate?.continuousScrollView(self, didScrollTo: locator)
        }
        
        // Check if we need to load more resources (but don't reload existing ones)
        // Only load new resources if we're actually near boundaries and not already loading
        guard !isLoadingResources else { return }
        
        let contentHeight = scrollView.contentSize.height
        let viewportHeight = scrollView.frame.height
        
        if currentOffset < viewportHeight && loadedResourceRange.lowerBound > 0 {
            // Near top, load previous resources
            loadPreviousResources()
        } else if currentOffset > contentHeight - viewportHeight * 2 && 
                  loadedResourceRange.upperBound < readingOrder.count {
            // Near bottom, load next resources
            loadNextResources()
        }
    }
    
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollView.isUserInteractionEnabled = true
    }
}

// MARK: - WebView Delegates

extension EPUBContinuousScrollView: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        log(.debug, "Continuous scroll content loaded")
        
        // Update resource boundaries with actual heights
        Task {
            await updateResourceBoundaries()
        }
    }
    
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log(.error, "Failed to load continuous scroll content: \(error)")
    }
    
    private func updateResourceBoundaries() async {
        // Use JavaScript to get actual heights of each resource container
        let script = """
        (function() {
            try {
                const containers = document.querySelectorAll('.resource-container');
                const boundaries = [];
                let currentY = 0;
                
                containers.forEach((container, index) => {
                    const rect = container.getBoundingClientRect();
                    const height = rect.height;
                    boundaries.push({
                        index: parseInt(container.dataset.resourceIndex),
                        startY: currentY,
                        endY: currentY + height
                    });
                    currentY += height;
                });
                
                return boundaries;
            } catch (error) {
                console.error('Failed to calculate boundaries:', error);
                return [];
            }
        })();
        """
        
        do {
            let result = try await webView.evaluateJavaScript(script)
            if let boundariesData = result as? [[String: Any]] {
                await MainActor.run {
                    self.resourceBoundaries = boundariesData.compactMap { data in
                        guard let index = data["index"] as? Int,
                              let startY = data["startY"] as? CGFloat,
                              let endY = data["endY"] as? CGFloat else {
                            return nil
                        }
                        return ResourceBoundary(resourceIndex: index, startY: startY, endY: endY)
                    }
                }
            }
        } catch {
            log(.error, "Failed to update resource boundaries: \(error)")
        }
    }
}

extension EPUBContinuousScrollView: WKUIDelegate {
    // Handle any UI delegate methods as needed
}

// MARK: - Delegate Protocol

protocol EPUBContinuousScrollViewDelegate: AnyObject {
    /// Called when the continuous scroll view finishes loading
    func continuousScrollViewDidLoad(_ scrollView: EPUBContinuousScrollView)
    
    /// Called when the scroll position changes
    func continuousScrollView(_ scrollView: EPUBContinuousScrollView, didScrollTo locator: Locator)
    
    /// Called when the user taps on the scroll view
    func continuousScrollView(_ scrollView: EPUBContinuousScrollView, didTapAt point: CGPoint)
    
    /// Called when an error occurs
    func continuousScrollView(_ scrollView: EPUBContinuousScrollView, didEncounterError error: Error)
}
