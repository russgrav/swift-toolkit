//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared
import ReadiumInternal

/// Manages loading and caching of EPUB resources for continuous scroll mode
final class EPUBContinuousResourceLoader: Loggable {
    
    // MARK: - Properties
    
    private let viewModel: EPUBNavigatorViewModel
    private let readingOrder: [Link]
    private let maxCacheSize: Int
    
    /// Cache of loaded resource content
    private var resourceCache: [String: CachedResource] = [:]
    
    /// Queue for resource loading operations
    private let loadingQueue = DispatchQueue(label: "epub.resource.loading", qos: .userInitiated)
    
    /// Currently loading resources (to prevent duplicate loads)
    private var loadingTasks: [String: Task<CachedResource, Error>] = [:]
    
    // MARK: - Initialization
    
    init(viewModel: EPUBNavigatorViewModel, readingOrder: [Link], maxCacheSize: Int = 10) {
        self.viewModel = viewModel
        self.readingOrder = readingOrder
        self.maxCacheSize = maxCacheSize
    }
    
    // MARK: - Public Methods
    
    /// Load a resource and return its processed content
    func loadResource(at index: Int) async throws -> CachedResource {
        guard readingOrder.indices.contains(index) else {
            throw EPUBContinuousResourceLoaderError.invalidIndex(index)
        }
        
        let link = readingOrder[index]
        let cacheKey = link.href
        
        // Return cached resource if available
        if let cached = resourceCache[cacheKey] {
            cached.lastAccessTime = Date()
            return cached
        }
        
        // Return existing loading task if in progress
        if let existingTask = loadingTasks[cacheKey] {
            return try await existingTask.value
        }
        
        // Create new loading task
        let task = Task<CachedResource, Error> {
            try await self.performResourceLoad(link: link, index: index)
        }
        
        loadingTasks[cacheKey] = task
        
        do {
            let resource = try await task.value
            loadingTasks.removeValue(forKey: cacheKey)
            
            // Cache the resource
            resourceCache[cacheKey] = resource
            
            // Clean up cache if needed
            await cleanupCache()
            
            return resource
        } catch {
            loadingTasks.removeValue(forKey: cacheKey)
            throw error
        }
    }
    
    /// Load multiple resources in the specified range
    func loadResources(in range: Range<Int>) async throws -> [CachedResource] {
        let startIndex = max(range.lowerBound, 0)
        let endIndex = min(range.upperBound, readingOrder.count)
        let validRange = startIndex..<endIndex
        
        return try await withThrowingTaskGroup(of: (Int, CachedResource).self) { group in
            // Start loading tasks for all resources in range
            for index in validRange {
                group.addTask {
                    let resource = try await self.loadResource(at: index)
                    return (index, resource)
                }
            }
            
            // Collect results in order
            var results: [(Int, CachedResource)] = []
            for try await result in group {
                results.append(result)
            }
            
            // Sort by index and return resources
            return results.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }
    
    /// Preload resources around a target index
    func preloadResources(around targetIndex: Int, preloadCount: Int = 2) async {
        let startIndex = max(0, targetIndex - preloadCount)
        let endIndex = min(readingOrder.count, targetIndex + preloadCount + 1)
        
        // Load resources without throwing errors (fire and forget)
        await withTaskGroup(of: Void.self) { group in
            for index in startIndex..<endIndex {
                group.addTask {
                    do {
                        _ = try await self.loadResource(at: index)
                    } catch {
                        self.log(.warning, "Failed to preload resource at index \(index): \(error)")
                    }
                }
            }
            
            // Wait for all preloading tasks to complete
            for await _ in group {}
        }
    }
    
    /// Clear all cached resources
    func clearCache() {
        resourceCache.removeAll()
        loadingTasks.values.forEach { $0.cancel() }
        loadingTasks.removeAll()
    }
    
    /// Get cached resource if available
    func getCachedResource(for href: String) -> CachedResource? {
        return resourceCache[href]
    }
    
    // MARK: - Private Methods
    
    private func performResourceLoad(link: Link, index: Int) async throws -> CachedResource {
        let url = viewModel.url(to: link)
        
        do {
            // FIX 1: Use asynchronous URLSession instead of synchronous Data(contentsOf:)
            let (data, response) = try await URLSession.shared.data(from: url.url)
            
            // Validate response
            if let httpResponse = response as? HTTPURLResponse {
                guard httpResponse.statusCode == 200 else {
                    throw EPUBContinuousResourceLoaderError.loadFailed(
                        link.href, 
                        URLError(.badServerResponse)
                    )
                }
            }
            
            let rawContent = String(data: data, encoding: .utf8) ?? ""
            
            // Process the content
            let processedContent = try await processResourceContent(
                rawContent: rawContent,
                link: link,
                index: index
            )
            
            let resource = CachedResource(
                index: index,
                link: link,
                rawContent: rawContent,
                processedContent: processedContent,
                loadTime: Date(),
                lastAccessTime: Date()
            )
            
            log(.debug, "Loaded resource: \(link.href)")
            return resource
            
        } catch {
            log(.error, "Failed to load resource \(link.href): \(error)")
            throw EPUBContinuousResourceLoaderError.loadFailed(link.href, error)
        }
    }
    
    private func processResourceContent(
        rawContent: String,
        link: Link,
        index: Int
    ) async throws -> ProcessedResourceContent {
        
        // Extract title from content or use link title
        let title = extractTitle(from: rawContent) ?? link.title ?? "Chapter \(index + 1)"
        
        // Clean HTML content with proper asset URL fixing
        let cleanedHTML = cleanHTMLContent(rawContent, relativeTo: link)
        
        // Extract and process CSS
        let extractedCSS = extractCSS(from: rawContent)
        
        // Process images and other assets
        let processedHTML = try await processAssets(in: cleanedHTML, relativeTo: link)
        
        // Calculate estimated height (rough approximation)
        let estimatedHeight = estimateContentHeight(processedHTML)
        
        return ProcessedResourceContent(
            title: title,
            cleanedHTML: processedHTML,
            extractedCSS: extractedCSS,
            estimatedHeight: estimatedHeight,
            wordCount: countWords(in: processedHTML)
        )
    }
    
    // FIX 2: Updated cleanHTMLContent with proper asset URL resolution
    private func cleanHTMLContent(_ html: String, relativeTo link: Link) -> String {
        var cleaned = html
        
        // First fix relative URLs before removing document structure
        cleaned = fixRelativeURLs(in: cleaned, relativeTo: link)
        
        // Remove HTML document structure using safer string operations
        do {
            // Use safer replacingOccurrences for HTML cleanup
            cleaned = cleaned.replacingOccurrences(of: "<!DOCTYPE[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
            cleaned = cleaned.replacingOccurrences(of: "<html[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
            cleaned = cleaned.replacingOccurrences(of: "</html>", with: "", options: [.regularExpression, .caseInsensitive])
            cleaned = cleaned.replacingOccurrences(of: "<head[^>]*>.*?</head>", with: "", options: [.regularExpression, .caseInsensitive])
            cleaned = cleaned.replacingOccurrences(of: "<body[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
            cleaned = cleaned.replacingOccurrences(of: "</body>", with: "", options: [.regularExpression, .caseInsensitive])
        } catch {
            log(.warning, "Failed to apply regex cleaning: \(error)")
        }
        
        // Clean up extra whitespace
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        
        return cleaned
    }
    
    // FIX 2: New method to fix relative URLs for proper asset serving
    private func fixRelativeURLs(in html: String, relativeTo link: Link) -> String {
        var result = html
        
        do {
            // Fix image src attributes
            let imgRegex = try NSRegularExpression(
                pattern: #"<img([^>]*)\ssrc\s*=\s*["\']([^"\']+)["\']([^>]*)>"#,
                options: [.caseInsensitive]
            )
            
            let imgMatches = imgRegex.matches(in: result, options: [], range: NSRange(location: 0, length: result.count))
            for match in imgMatches.reversed() {
                let nsString = result as NSString
                guard match.numberOfRanges >= 4,
                      let srcRange = Range(match.range(at: 2), in: result),
                      let beforeRange = Range(match.range(at: 1), in: result),
                      let afterRange = Range(match.range(at: 3), in: result) else {
                    continue
                }
                
                let originalSrc = String(result[srcRange])
                let absoluteSrc = makeAbsoluteURL(from: originalSrc, relativeTo: link)
                
                let beforeSrc = String(result[beforeRange])
                let afterSrc = String(result[afterRange])
                
                let replacement = "<img\(beforeSrc) src=\"\(absoluteSrc)\"\(afterSrc)>"
                result = nsString.replacingCharacters(in: match.range, with: replacement)
            }
            
            // Fix CSS background-image URLs
            let bgImageRegex = try NSRegularExpression(
                pattern: #"background-image\s*:\s*url\s*\(\s*["\']?([^"\']+)["\']?\s*\)"#,
                options: [.caseInsensitive]
            )
            
            let bgMatches = bgImageRegex.matches(in: result, options: [], range: NSRange(location: 0, length: result.count))
            for match in bgMatches.reversed() {
                let nsString = result as NSString
                guard match.numberOfRanges >= 2,
                      let urlRange = Range(match.range(at: 1), in: result) else {
                    continue
                }
                
                let originalUrl = String(result[urlRange])
                let absoluteUrl = makeAbsoluteURL(from: originalUrl, relativeTo: link)
                
                let replacement = "background-image: url(\"\(absoluteUrl)\")"
                result = nsString.replacingCharacters(in: match.range, with: replacement)
            }
            
            // Fix link href attributes for stylesheets
            let linkRegex = try NSRegularExpression(
                pattern: #"<link([^>]*)\shref\s*=\s*["\']([^"\']+)["\']([^>]*)>"#,
                options: [.caseInsensitive]
            )
            
            let linkMatches = linkRegex.matches(in: result, options: [], range: NSRange(location: 0, length: result.count))
            for match in linkMatches.reversed() {
                let nsString = result as NSString
                guard match.numberOfRanges >= 4,
                      let hrefRange = Range(match.range(at: 2), in: result),
                      let beforeRange = Range(match.range(at: 1), in: result),
                      let afterRange = Range(match.range(at: 3), in: result) else {
                    continue
                }
                
                let originalHref = String(result[hrefRange])
                let absoluteHref = makeAbsoluteURL(from: originalHref, relativeTo: link)
                
                let beforeHref = String(result[beforeRange])
                let afterHref = String(result[afterRange])
                
                let replacement = "<link\(beforeHref) href=\"\(absoluteHref)\"\(afterHref)>"
                result = nsString.replacingCharacters(in: match.range, with: replacement)
            }
            
        } catch {
            log(.warning, "Failed to fix relative URLs: \(error)")
        }
        
        return result
    }
    
    private func makeAbsoluteURL(from relativePath: String, relativeTo link: Link) -> String {
        // Already absolute URL
        if relativePath.hasPrefix("http://") || relativePath.hasPrefix("https://") {
            return relativePath
        }
        
        // Data URLs
        if relativePath.hasPrefix("data:") {
            return relativePath
        }
        
        // Get the base URL for this resource
        let resourceURL = viewModel.url(to: link)
        let baseURL = resourceURL.string
        
        // Handle different types of relative paths
        if relativePath.hasPrefix("/") {
            // Absolute path from publication root
            let publicationBase = viewModel.publicationBaseURL.string
            return "\(publicationBase)\(relativePath)"
        } else if relativePath.hasPrefix("../") || relativePath.hasPrefix("./") {
            // Relative path from current resource
            if let baseURLObject = URL(string: baseURL) {
                let resolvedURL = URL(string: relativePath, relativeTo: baseURLObject)
                return resolvedURL?.absoluteString ?? "\(baseURL)/\(relativePath)"
            }
        }
        
        // Simple relative path
        if let lastSlash = baseURL.lastIndex(of: "/") {
            let directoryURL = String(baseURL[...lastSlash])
            return "\(directoryURL)\(relativePath)"
        }
        
        return "\(baseURL)/\(relativePath)"
    }
    
    private func extractTitle(from html: String) -> String? {
        // Try to extract title from <title> tag first using NSRegularExpression
        do {
            let titleRegex = try NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators])
            let nsString = html as NSString
            let results = titleRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))
            
            if let result = results.first, result.numberOfRanges > 1 {
                let range = result.range(at: 1)
                if range.location != NSNotFound {
                    let title = nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        return title
                    }
                }
            }
        } catch {
            log(.warning, "Title extraction regex failed: \(error)")
        }
        
        // Fallback to first h1, h2, etc.
        do {
            let headerRegex = try NSRegularExpression(pattern: "<h[1-6][^>]*>(.*?)</h[1-6]>", options: [.caseInsensitive, .dotMatchesLineSeparators])
            let nsString = html as NSString
            let results = headerRegex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))
            
            if let result = results.first, result.numberOfRanges > 1 {
                let range = result.range(at: 1)
                if range.location != NSNotFound {
                    let title = nsString.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        return title
                    }
                }
            }
        } catch {
            log(.warning, "Header extraction regex failed: \(error)")
        }
        
        return nil
    }
    
    private func extractCSS(from html: String) -> String {
        var css = ""
        
        // Extract inline styles using NSRegularExpression
        do {
            let regex = try NSRegularExpression(pattern: "<style[^>]*>(.*?)</style>", options: [.caseInsensitive, .dotMatchesLineSeparators])
            let nsString = html as NSString
            let results = regex.matches(in: html, options: [], range: NSRange(location: 0, length: nsString.length))
            
            for result in results {
                if result.numberOfRanges > 1 {
                    let range = result.range(at: 1) // Get the content inside <style> tags
                    if range.location != NSNotFound {
                        let styleContent = nsString.substring(with: range)
                        css += styleContent + "\n"
                    }
                }
            }
        } catch {
            // If regex fails, fallback to simple approach
            log(.warning, "CSS extraction regex failed: \(error)")
        }
        
        return css.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func processAssets(in html: String, relativeTo link: Link) async throws -> String {
        // Assets are now handled by fixRelativeURLs, so we just return the HTML
        // In the future, you could implement additional asset processing here
        return html
    }
    
    private func estimateContentHeight(_ html: String) -> CGFloat {
        // Very rough estimation based on content length
        // In a real implementation, you might want to:
        // 1. Count paragraphs, headers, images
        // 2. Apply typical line heights and spacing
        // 3. Consider viewport width
        
        let characterCount = html.count
        let estimatedLinesPerScreen = 25.0
        let charactersPerLine = 80.0
        let lineHeight = 24.0
        
        let estimatedLines = Double(characterCount) / charactersPerLine
        let estimatedHeight = estimatedLines * lineHeight
        
        // Add some padding for images, headers, etc.
        return CGFloat(estimatedHeight * 1.2)
    }
    
    private func countWords(in html: String) -> Int {
        // Remove HTML tags and count words using NSRegularExpression
        do {
            let regex = try NSRegularExpression(pattern: "<[^>]*>", options: [])
            let nsString = html as NSString
            let textOnly = regex.stringByReplacingMatches(in: html, options: [], range: NSRange(location: 0, length: nsString.length), withTemplate: " ")
            
            let words = textOnly.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            
            return words.count
        } catch {
            // Fallback to simple word count
            let words = html.components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
            return words.count
        }
    }
    
    private func cleanupCache() async {
        guard resourceCache.count > maxCacheSize else { return }
        
        // Remove least recently used resources
        let sortedResources = resourceCache.values.sorted { $0.lastAccessTime < $1.lastAccessTime }
        let resourcesToRemove = sortedResources.prefix(resourceCache.count - maxCacheSize)
        
        for resource in resourcesToRemove {
            resourceCache.removeValue(forKey: resource.link.href)
        }
        
        log(.debug, "Cleaned up cache, removed \(resourcesToRemove.count) resources")
    }
}

// MARK: - Data Structures

/// Represents a cached resource with processed content
final class CachedResource {
    let index: Int
    let link: Link
    let rawContent: String
    let processedContent: ProcessedResourceContent
    let loadTime: Date
    var lastAccessTime: Date
    
    init(
        index: Int,
        link: Link,
        rawContent: String,
        processedContent: ProcessedResourceContent,
        loadTime: Date,
        lastAccessTime: Date
    ) {
        self.index = index
        self.link = link
        self.rawContent = rawContent
        self.processedContent = processedContent
        self.loadTime = loadTime
        self.lastAccessTime = lastAccessTime
    }
}

/// Processed content of a resource ready for display
struct ProcessedResourceContent {
    let title: String
    let cleanedHTML: String
    let extractedCSS: String
    let estimatedHeight: CGFloat
    let wordCount: Int
}

// MARK: - Error Types

enum EPUBContinuousResourceLoaderError: Error {
    case invalidIndex(Int)
    case loadFailed(String, Error)
    case processingFailed(String, Error)
    
    var localizedDescription: String {
        switch self {
        case .invalidIndex(let index):
            return "Invalid resource index: \(index)"
        case .loadFailed(let href, let error):
            return "Failed to load resource \(href): \(error.localizedDescription)"
        case .processingFailed(let href, let error):
            return "Failed to process resource \(href): \(error.localizedDescription)"
        }
    }
}
