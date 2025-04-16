/**
 * Fixed JavaScript code to properly track progression in both paginated and scroll modes
 * This should be added to the document when it loads
 */
(function() {
    // Track scroll changes and report progression
    let lastScrollTime = 0;
    let scrollTimeoutId = null;
    const SCROLL_INTERVAL = 250; // ms between progression updates
    
    // Function to calculate and report progression
    function reportProgression() {
        let progression;
        const isVerticalScroll = window.getComputedStyle(document.documentElement).getPropertyValue('overflow-y') === 'auto';
        
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
    reportProgression();
    
    // Make the function available globally to call when needed
    window.reportProgression = reportProgression;
})();
