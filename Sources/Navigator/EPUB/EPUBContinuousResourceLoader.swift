//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared
import ReadiumInternal

/// Simple resource loader for continuous scroll mode with sequential loading
final class EPUBContinuousResourceLoader: Loggable {
    
    // MARK: - Properties
    
    private let viewModel: EPUBNavigatorViewModel
    private let readingOrder: [Link]
    
    /// Simple cache of processed resources
    private var resourceCache: [String: ProcessedResource] = [:]
    
    // MARK: - Initialization
    
    init(viewModel: EPUBNavigatorViewModel, readingOrder: [Link]) {
        self.viewModel = viewModel
        self.readingOrder = readingOrder
        
        // Log available publication resources for debugging
        log(.debug, "Publication resources available:")
        for resource in viewModel.publication.resources {
            log(.debug, "  - \(resource.href) (\(resource.mediaType?.string ?? "unknown type"))")
        }
        for readingOrderLink in viewModel.publication.readingOrder {
            log(.debug, "  - Reading order: \(readingOrderLink.href) (\(readingOrderLink.mediaType?.string ?? "unknown type"))")
        }
    }
    
    // MARK: - Public Methods
    
    /// Load a single resource by index
    func loadResource(at index: Int) async throws -> ProcessedResource {
        guard readingOrder.indices.contains(index) else {
            throw EPUBContinuousResourceLoaderError.invalidIndex(index)
        }
        
        let link = readingOrder[index]
        let cacheKey = link.href
        
        // Return cached resource if available
        if let cached = resourceCache[cacheKey] {
            return cached
        }
        
        // Load and process resource
        let resource = try await performResourceLoad(link: link, index: index)
        
        // Cache the resource
        resourceCache[cacheKey] = resource
        
        return resource
    }
    
    /// Load multiple resources sequentially (maintains order)
    func loadResourcesSequentially(in range: Range<Int>) async throws -> [ProcessedResource] {
        let startIndex = max(range.lowerBound, 0)
        let endIndex = min(range.upperBound, readingOrder.count)
        let validRange = startIndex..<endIndex
        
        var resources: [ProcessedResource] = []
        
        // Load resources one by one to maintain order
        for index in validRange {
            do {
                let resource = try await loadResource(at: index)
                resources.append(resource)
                log(.debug, "Loaded resource \(index): \(resource.link.href)")
            } catch {
                log(.error, "Failed to load resource at index \(index): \(error)")
                throw error
            }
        }
        
        return resources
    }
    
    /// Get a specific resource from cache
    func getCachedResource(for href: String) -> ProcessedResource? {
        return resourceCache[href]
    }
    
    
    /// Clear all cached resources
    func clearCache() {
        resourceCache.removeAll()
    }
    
    // MARK: - Private Methods
    
    private func performResourceLoad(link: Link, index: Int) async throws -> ProcessedResource {
        log(.debug, "Loading resource: \(link.href)")
        
        // Load resource using publication's built-in mechanism
        guard let resource = viewModel.publication.get(link) else {
            throw EPUBContinuousResourceLoaderError.resourceNotFound(link.href)
        }
        
        let data = try await resource.read().get()
        guard let rawHTML = String(data: data, encoding: .utf8) else {
            throw EPUBContinuousResourceLoaderError.invalidEncoding(link.href)
        }
        
        // Process the HTML content without URL fixing
        let processedContent = processHTMLContent(rawHTML, link: link, index: index)
        
        let processedResource = ProcessedResource(
            index: index,
            link: link,
            rawContent: rawHTML,
            cleanedHTML: processedContent.cleanedHTML,
            title: processedContent.title,
            estimatedHeight: processedContent.estimatedHeight
        )
        
        log(.debug, "Successfully loaded and processed resource: \(link.href)")
        return processedResource
    }
    
    private func processHTMLContent(_ html: String, link: Link, index: Int) -> (cleanedHTML: String, title: String, estimatedHeight: CGFloat) {
        var content = html
        
        // Extract title
        let title = extractTitle(from: content) ?? link.title ?? "Chapter \(index + 1)"
        
        // Remove document structure (DOCTYPE, html, head, body tags)
        content = removeDocumentStructure(content)
        
        // Fix relative URLs to include publication UUID prefix
        content = fixRelativeURLs(in: content, relativeTo: link)
        
        // Estimate content height (rough approximation)
        let estimatedHeight = estimateContentHeight(content)
        
        return (cleanedHTML: content, title: title, estimatedHeight: estimatedHeight)
    }
    
    private func extractTitle(from html: String) -> String? {
        // Extract title from <title> tag
        do {
            let titleRegex = try NSRegularExpression(pattern: "<title[^>]*>(.*?)</title>", options: [.caseInsensitive, .dotMatchesLineSeparators])
            let nsString = html as NSString
            let range = NSRange(location: 0, length: nsString.length)
            let results = titleRegex.matches(in: html, options: [], range: range)
            
            if let result = results.first, result.numberOfRanges > 1 {
                let titleRange = result.range(at: 1)
                if titleRange.location != NSNotFound && titleRange.location + titleRange.length <= nsString.length {
                    let title = nsString.substring(with: titleRange).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !title.isEmpty {
                        return title
                    }
                }
            }
        } catch {
            log(.warning, "Title extraction regex failed: \(error)")
        }
        
        // Fallback to first header
        do {
            let headerRegex = try NSRegularExpression(pattern: "<h[1-6][^>]*>(.*?)</h[1-6]>", options: [.caseInsensitive, .dotMatchesLineSeparators])
            let nsString = html as NSString
            let range = NSRange(location: 0, length: nsString.length)
            let results = headerRegex.matches(in: html, options: [], range: range)
            
            if let result = results.first, result.numberOfRanges > 1 {
                let headerRange = result.range(at: 1)
                if headerRange.location != NSNotFound && headerRange.location + headerRange.length <= nsString.length {
                    let title = nsString.substring(with: headerRange).trimmingCharacters(in: .whitespacesAndNewlines)
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
    
    private func removeDocumentStructure(_ html: String) -> String {
        var content = html
        
        // Use safer replacingOccurrences for HTML cleanup
        content = content.replacingOccurrences(of: "<!DOCTYPE[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        content = content.replacingOccurrences(of: "<html[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        content = content.replacingOccurrences(of: "</html>", with: "", options: [.regularExpression, .caseInsensitive])
        content = content.replacingOccurrences(of: "<head[^>]*>.*?</head>", with: "", options: [.regularExpression, .caseInsensitive])
        content = content.replacingOccurrences(of: "<body[^>]*>", with: "", options: [.regularExpression, .caseInsensitive])
        content = content.replacingOccurrences(of: "</body>", with: "", options: [.regularExpression, .caseInsensitive])
        
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func fixRelativeURLs(in html: String, relativeTo link: Link) -> String {
        let baseURL = viewModel.url(to: link).string
        let publicationBaseURL = viewModel.publicationBaseURL.string
        
        var content = html
        
        // Fix image src attributes  
        content = fixURLsWithPattern(
            content,
            pattern: #"src\s*=\s*["\']([^"\']+)["\']"#,
            replacement: { url in "src=\"\(self.makeAbsoluteURL(url, baseURL: baseURL, publicationBaseURL: publicationBaseURL))\"" }
        )
        
        // Fix link href attributes
        content = fixURLsWithPattern(
            content,
            pattern: #"href\s*=\s*["\']([^"\']+)["\']"#,
            replacement: { url in "href=\"\(self.makeAbsoluteURL(url, baseURL: baseURL, publicationBaseURL: publicationBaseURL))\"" }
        )
        
        return content
    }
    
    private func fixURLsWithPattern(_ content: String, pattern: String, replacement: @escaping (String) -> String) -> String {
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let nsString = content as NSString
            let range = NSRange(location: 0, length: nsString.length)
            let matches = regex.matches(in: content, options: [], range: range)
            
            var result = content
            // Process matches in reverse order to maintain string indices
            for match in matches.reversed() {
                guard match.numberOfRanges > 1,
                      let urlRange = Range(match.range(at: 1), in: content) else {
                    continue
                }
                
                let url = String(content[urlRange])
                let replacementString = replacement(url)
                let nsResult = result as NSString
                result = nsResult.replacingCharacters(in: match.range, with: replacementString)
            }
            
            return result
        } catch {
            log(.warning, "URL fixing regex failed: \(error)")
            return content
        }
    }
    
    private func makeAbsoluteURL(_ relativePath: String, baseURL: String, publicationBaseURL: String) -> String {
        // Already absolute
        if relativePath.hasPrefix("http://") || relativePath.hasPrefix("https://") || relativePath.hasPrefix("data:") {
            return relativePath
        }
        
        // Use proper URL resolution to get the correct path with UUID
        if let baseURLObject = URL(string: baseURL),
           let resolvedURL = URL(string: relativePath, relativeTo: baseURLObject) {
            let result = resolvedURL.absoluteString
            log(.debug, "Generated URL for \(relativePath): \(result)")
            return result
        }
        
        // Fallback: ensure UUID is included for proper HTTP server routing
        let cleanPublicationBaseURL = publicationBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanRelativePath = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fallbackResult = "\(cleanPublicationBaseURL)/\(cleanRelativePath)"
        log(.debug, "Fallback URL for \(relativePath): \(fallbackResult)")
        return fallbackResult
    }
    
    private func estimateContentHeight(_ html: String) -> CGFloat {
        // Simple estimation based on content length
        let characterCount = html.count
        let estimatedLinesPerScreen = 25.0
        let charactersPerLine = 80.0
        let lineHeight = 24.0
        
        let estimatedLines = Double(characterCount) / charactersPerLine
        let estimatedHeight = estimatedLines * lineHeight
        
        // Add padding for images, headers, etc.
        return CGFloat(estimatedHeight * 1.2)
    }
}

// MARK: - Data Structures

/// Simplified processed resource
struct ProcessedResource {
    let index: Int
    let link: Link
    let rawContent: String
    let cleanedHTML: String
    let title: String
    let estimatedHeight: CGFloat
}

// MARK: - Error Types

enum EPUBContinuousResourceLoaderError: Error {
    case invalidIndex(Int)
    case resourceNotFound(String)
    case invalidEncoding(String)
    case loadFailed(String, Error)
    
    var localizedDescription: String {
        switch self {
        case .invalidIndex(let index):
            return "Invalid resource index: \(index)"
        case .resourceNotFound(let href):
            return "Resource not found: \(href)"
        case .invalidEncoding(let href):
            return "Invalid text encoding for resource: \(href)"
        case .loadFailed(let href, let error):
            return "Failed to load resource \(href): \(error.localizedDescription)"
        }
    }
}