//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import Foundation
import ReadiumShared

/// Builds HTML content for continuous scroll mode by combining multiple EPUB resources
final class EPUBContinuousHTMLBuilder {
    
    private let viewModel: EPUBNavigatorViewModel
    private let readingOrder: [Link]
    
    init(viewModel: EPUBNavigatorViewModel, readingOrder: [Link]) {
        self.viewModel = viewModel
        self.readingOrder = readingOrder
    }
    
    /// Build a complete HTML document from cached resources
    func buildContinuousHTML(from resources: [CachedResource]) -> String {
        let head = buildHTMLHead(from: resources)
        let body = buildHTMLBody(from: resources)
        
        return """
        <!DOCTYPE html>
        <html lang="\(getDocumentLanguage())">
        \(head)
        \(body)
        </html>
        """
    }
    
    // MARK: - Private Methods
    
    private func buildHTMLHead(from resources: [CachedResource]) -> String {
        let viewport = buildViewportMeta()
        let baseStyles = buildBaseStyles()
        let userStyles = buildUserStyles()
        let combinedCSS = extractAndCombineCSS(from: resources)
        let scripts = buildJavaScripts()
        
        return """
        <head>
            <meta charset="utf-8">
            \(viewport)
            <title>\(getDocumentTitle(from: resources))</title>
            
            <!-- Base Styles -->
            <style id="base-styles">
        \(baseStyles)
            </style>
            
            <!-- User Preference Styles -->
            <style id="user-styles">
        \(userStyles)
            </style>
            
            <!-- Resource CSS -->
            <style id="resource-styles">
        \(combinedCSS)
            </style>
            
            <!-- JavaScript -->
        \(scripts)
        </head>
        """
    }
    
    private func buildHTMLBody(from resources: [CachedResource]) -> String {
        let resourceContent = resources.map { buildResourceHTML(for: $0) }.joined()
        
        return """
        <body class="readium-continuous-scroll" data-readium-mode="continuous">
            <div id="readium-continuous-container">
        \(resourceContent)
            </div>
            
            <!-- Loading indicator -->
            <div id="readium-loading-indicator" style="display: none;">
                <div class="spinner"></div>
                <p>Loading more content...</p>
            </div>
            
            <!-- Navigation markers (invisible) -->
            <div id="readium-nav-markers"></div>
        </body>
        """
    }
    
    private func buildResourceHTML(for resource: CachedResource) -> String {
        let title = resource.processedContent.title
        let content = resource.processedContent.cleanedHTML
        let href = resource.link.href
        let index = resource.index
        
        return """
        
            <article 
                class="readium-resource" 
                data-resource-index="\(index)"
                data-resource-href="\(href)"
                data-resource-title="\(escapeHTML(title))"
                id="readium-resource-\(index)">
                
                <!-- Resource header (can be hidden via CSS) -->
                <header class="readium-resource-header">
                    <h1 class="readium-resource-title">\(escapeHTML(title))</h1>
                    <div class="readium-resource-meta">
                        <span class="readium-chapter-number">Chapter \(index + 1)</span>
                    </div>
                </header>
                
                <!-- Resource content -->
                <div class="readium-resource-content">
        \(content)
                </div>
                
                <!-- Resource footer -->
                <footer class="readium-resource-footer">
                    <div class="readium-resource-separator"></div>
                </footer>
                
            </article>
        """
    }
    
    private func buildViewportMeta() -> String {
        return """
        <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        """
    }
    
    private func buildBaseStyles() -> String {
        let settings = viewModel.settings
        
        return """
        /* Reset and base styles */
        * {
            box-sizing: border-box;
        }
        
        html {
            height: 100%;
            scroll-behavior: smooth;
        }
        
        body {
            margin: 0;
            padding: 0;
            font-family: \(getFontFamily());
            font-size: \(settings.fontSize)em;
            line-height: \(settings.lineHeight ?? 1.6);
            color: #000000;
            background-color: #ffffff;
            word-spacing: \(settings.wordSpacing ?? 0)em;
            letter-spacing: \(settings.letterSpacing ?? 0)em;
            text-align: left;
            overflow-x: hidden;
            overflow-y: auto;
            -webkit-text-size-adjust: none;
            text-size-adjust: none;
        }
        
        /* Continuous scroll container */
        #readium-continuous-container {
            width: 100%;
            max-width: 100%;
        }
        
        /* Resource styling */
        .readium-resource {
            margin: 0 auto \(settings.pageMargins * 2)em auto;
            padding: \(settings.pageMargins)em;
            max-width: 50em; /* Optimal reading width */
            position: relative;
        }
        
        .readium-resource-header {
            margin-bottom: 2em;
            border-bottom: 1px solid #e0e0e0;
            padding-bottom: 1em;
        }
        
        .readium-resource-title {
            margin: 0 0 0.5em 0;
            font-size: 1.5em;
            font-weight: 600;
            color: #333;
        }
        
        .readium-resource-meta {
            font-size: 0.9em;
            color: #666;
        }
        
        .readium-resource-content {
            /* Content inherits from body styles */
        }
        
        .readium-resource-footer {
            margin-top: 3em;
            padding-top: 2em;
        }
        
        .readium-resource-separator {
            height: 1px;
            background: linear-gradient(to right, transparent, #e0e0e0, transparent);
            margin: 0 auto;
            width: 50%;
        }
        
        /* Image handling */
        .readium-resource-content img {
            max-width: 100%;
            height: auto;
            display: block;
            margin: 1em auto;
            border-radius: 4px;
            box-shadow: 0 2px 8px rgba(0, 0, 0, 0.1);
        }
        
        /* Handle missing images gracefully */
        .readium-resource-content img[src=""], 
        .readium-resource-content img:not([src]) {
            display: none;
        }
        
        /* Typography improvements */
        .readium-resource-content p {
            margin: 0 0 1em 0;
            text-indent: 1.2em;
        }
        
        .readium-resource-content p:first-child {
            text-indent: 0;
        }
        
        .readium-resource-content h1,
        .readium-resource-content h2,
        .readium-resource-content h3,
        .readium-resource-content h4,
        .readium-resource-content h5,
        .readium-resource-content h6 {
            margin: 2em 0 1em 0;
            line-height: 1.3;
            font-weight: 600;
        }
        
        .readium-resource-content h1 { font-size: 1.8em; }
        .readium-resource-content h2 { font-size: 1.5em; }
        .readium-resource-content h3 { font-size: 1.3em; }
        .readium-resource-content h4 { font-size: 1.1em; }
        .readium-resource-content h5 { font-size: 1em; }
        .readium-resource-content h6 { font-size: 0.9em; }
        
        /* Lists */
        .readium-resource-content ul,
        .readium-resource-content ol {
            margin: 1em 0;
            padding-left: 2em;
        }
        
        .readium-resource-content li {
            margin: 0.5em 0;
        }
        
        /* Blockquotes */
        .readium-resource-content blockquote {
            margin: 2em 1em;
            padding: 1em 1.5em;
            border-left: 4px solid #ddd;
            background-color: #f9f9f9;
            font-style: italic;
        }
        
        /* Code blocks */
        .readium-resource-content pre,
        .readium-resource-content code {
            font-family: 'Courier New', monospace;
            background-color: #f5f5f5;
            border-radius: 3px;
        }
        
        .readium-resource-content pre {
            padding: 1em;
            overflow-x: auto;
            margin: 1em 0;
        }
        
        .readium-resource-content code {
            padding: 0.2em 0.4em;
        }
        
        /* Tables */
        .readium-resource-content table {
            width: 100%;
            border-collapse: collapse;
            margin: 1em 0;
        }
        
        .readium-resource-content th,
        .readium-resource-content td {
            padding: 0.5em;
            border: 1px solid #ddd;
            text-align: left;
        }
        
        .readium-resource-content th {
            background-color: #f5f5f5;
            font-weight: 600;
        }
        
        /* Loading indicator */
        #readium-loading-indicator {
            text-align: center;
            padding: 2em;
            color: #666;
        }
        
        .spinner {
            width: 40px;
            height: 40px;
            margin: 0 auto 1em auto;
            border: 4px solid #f3f3f3;
            border-top: 4px solid #3498db;
            border-radius: 50%;
            animation: spin 1s linear infinite;
        }
        
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        
        /* Responsive design */
        @media (max-width: 768px) {
            .readium-resource {
                margin-left: 1em;
                margin-right: 1em;
                padding: 1em;
            }
            
            .readium-resource-title {
                font-size: 1.3em;
            }
            
            .readium-resource-content h1 { font-size: 1.5em; }
            .readium-resource-content h2 { font-size: 1.3em; }
            .readium-resource-content h3 { font-size: 1.1em; }
        }
        
        @media (max-width: 480px) {
            .readium-resource {
                margin-left: 0.5em;
                margin-right: 0.5em;
                padding: 0.5em;
            }
            
            .readium-resource-content p {
                text-indent: 0;
            }
        }
        
        /* Print styles */
        @media print {
            .readium-resource-header,
            .readium-resource-footer,
            #readium-loading-indicator {
                display: none;
            }
            
            .readium-resource {
                margin: 0;
                padding: 0;
                page-break-inside: avoid;
            }
        }
        """
    }
    
    private func buildUserStyles() -> String {
        // Simplified user styles that avoid potential type issues
        return """
        /* User preference styles */
        .readium-resource-content {
            /* Styles will be applied by user settings injection */
        }
        """
    }
    
    private func extractAndCombineCSS(from resources: [CachedResource]) -> String {
        var combinedCSS = ""
        
        for resource in resources {
            let resourceCSS = resource.processedContent.extractedCSS
            if !resourceCSS.isEmpty {
                combinedCSS += """
                
                /* CSS from \(resource.link.href) */
                \(resourceCSS)
                
                """
            }
        }
        
        return combinedCSS
    }
    
    private func buildJavaScripts() -> String {
        return """
        <script>
        (function() {
            'use strict';
            
            // Enhanced scroll tracking with throttling
            let scrollTimeout;
            let isScrolling = false;
            
            function handleScroll() {
                if (isScrolling) return;
                isScrolling = true;
                
                requestAnimationFrame(function() {
                    try {
                        const scrollTop = window.pageYOffset;
                        const documentHeight = document.documentElement.scrollHeight;
                        const windowHeight = window.innerHeight;
                        const scrollPercent = Math.min(Math.max(scrollTop / (documentHeight - windowHeight), 0), 1);
                        
                        // Find current resource
                        const resources = document.querySelectorAll('.readium-resource');
                        let currentResource = null;
                        
                        for (let i = 0; i < resources.length; i++) {
                            const rect = resources[i].getBoundingClientRect();
                            if (rect.top <= windowHeight / 2 && rect.bottom > windowHeight / 2) {
                                currentResource = resources[i];
                                break;
                            }
                        }
                        
                        // Post message to native layer with error handling
                        if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.scrollProgress) {
                            window.webkit.messageHandlers.scrollProgress.postMessage({
                                scrollTop: scrollTop,
                                scrollPercent: scrollPercent,
                                documentHeight: documentHeight,
                                windowHeight: windowHeight,
                                currentResourceIndex: currentResource ? parseInt(currentResource.dataset.resourceIndex) : null,
                                currentResourceHref: currentResource ? currentResource.dataset.resourceHref : null,
                                timestamp: Date.now()
                            });
                        }
                    } catch (error) {
                        console.error('Scroll tracking error:', error);
                    }
                    
                    isScrolling = false;
                });
            }
            
            // Throttled scroll listener
            window.addEventListener('scroll', function() {
                clearTimeout(scrollTimeout);
                scrollTimeout = setTimeout(handleScroll, 16); // ~60fps
            }, { passive: true });
            
            // Handle image load errors and lazy loading
            function setupImages() {
                const images = document.querySelectorAll('.readium-resource-content img');
                
                images.forEach(function(img) {
                    // Error handling
                    img.addEventListener('error', function() {
                        console.warn('Failed to load image:', img.src);
                        img.style.display = 'none';
                        
                        // Try to find alternative text or replace with placeholder
                        const alt = img.alt || 'Image not available';
                        const placeholder = document.createElement('div');
                        placeholder.className = 'image-placeholder';
                        placeholder.textContent = alt;
                        placeholder.style.cssText = 'padding: 2em; background: #f5f5f5; border: 1px dashed #ccc; text-align: center; color: #666; font-style: italic;';
                        
                        if (img.parentNode) {
                            img.parentNode.replaceChild(placeholder, img);
                        }
                    });
                    
                    // Lazy loading for better performance
                    if ('IntersectionObserver' in window) {
                        const observer = new IntersectionObserver(function(entries) {
                            entries.forEach(function(entry) {
                                if (entry.isIntersecting) {
                                    const img = entry.target;
                                    if (img.dataset.src) {
                                        img.src = img.dataset.src;
                                        img.removeAttribute('data-src');
                                    }
                                    observer.unobserve(img);
                                }
                            });
                        }, { rootMargin: '50px' });
                        
                        if (img.dataset.src) {
                            observer.observe(img);
                        }
                    }
                });
            }
            
            // Smooth navigation to resources
            window.navigateToResource = function(resourceIndex, animated) {
                const resource = document.getElementById('readium-resource-' + resourceIndex);
                if (resource) {
                    resource.scrollIntoView({
                        behavior: animated ? 'smooth' : 'auto',
                        block: 'start'
                    });
                    return true;
                }
                return false;
            };
            
            // Get resource position information
            window.getResourcePosition = function(resourceIndex) {
                const resource = document.getElementById('readium-resource-' + resourceIndex);
                if (resource) {
                    const rect = resource.getBoundingClientRect();
                    return {
                        top: rect.top + window.pageYOffset,
                        bottom: rect.bottom + window.pageYOffset,
                        height: rect.height,
                        visible: rect.top < window.innerHeight && rect.bottom > 0
                    };
                }
                return null;
            };
            
            // Initialize when DOM is ready
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', setupImages);
            } else {
                setupImages();
            }
            
            // Re-setup images when new content is added
            const observer = new MutationObserver(function(mutations) {
                mutations.forEach(function(mutation) {
                    if (mutation.type === 'childList' && mutation.addedNodes.length > 0) {
                        setTimeout(setupImages, 100); // Debounce
                    }
                });
            });
            
            observer.observe(document.body, {
                childList: true,
                subtree: true
            });
            
        })();
        </script>
        """
    }
    
    private func getDocumentLanguage() -> String {
        return "en" // Simplified to avoid type issues
    }
    
    private func getDocumentTitle(from resources: [CachedResource]) -> String {
        if let firstResource = resources.first {
            return firstResource.processedContent.title
        }
        return "EPUB Document"
    }
    
    private func escapeHTML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
    
    private func getFontFamily() -> String {
        // Simplified font family handling to avoid type issues
        return "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif"
    }
}
