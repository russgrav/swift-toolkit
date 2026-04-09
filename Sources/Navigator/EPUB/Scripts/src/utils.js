//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

// Catch JS errors to log them in the app.

import { TextQuoteAnchor } from "./vendor/hypothesis/anchoring/types";
import { getCurrentSelection } from "./selection";

// Override console.log to send to native code
const originalConsoleLog = console.log;
console.log = function(...args) {
  const message = args.map(arg =>
    typeof arg === 'object' ? JSON.stringify(arg) : String(arg)
  ).join(' ');
  webkit.messageHandlers.log.postMessage(message);
  originalConsoleLog.apply(console, args);
};

window.addEventListener(
  "error",
  function (event) {
    webkit.messageHandlers.logError.postMessage({
      message: event.message,
      filename: event.filename,
      line: event.lineno,
    });
  },
  false
);

// Notify native code that the page has loaded.
window.addEventListener(
  "load",
  function () {
    const observer = new ResizeObserver(() => {
      appendVirtualColumnIfNeeded();
      onScroll();
    });
    observer.observe(document.body);

    // on page load
    window.addEventListener("orientationchange", function () {
      orientationChanged();
      snapCurrentPosition();
    });
    orientationChanged();
  },
  false
);

/**
 * Having an odd number of columns when displaying two columns per screen causes snapping and page
 * turning issues. To fix this, we insert a blank virtual column at the end of the resource.
 */
function appendVirtualColumnIfNeeded() {
  const id = "readium-virtual-page";
  var virtualCol = document.getElementById(id);
  if (isScrollModeEnabled() || getColumnCountPerScreen() != 2) {
    virtualCol?.remove();
  } else {
    var documentWidth = document.scrollingElement.scrollWidth;
    var pageWidth = window.innerWidth;
    var colCount = documentWidth / pageWidth;
    var hasOddColCount = (Math.round(colCount * 2) / 2) % 1 > 0.1;
    if (hasOddColCount) {
      if (virtualCol) {
        virtualCol.remove();
      } else {
        virtualCol = document.createElement("div");
        virtualCol.setAttribute("id", id);
        virtualCol.style.breakBefore = "column";
        virtualCol.innerHTML = "&#8203;"; // zero-width space
        document.body.appendChild(virtualCol);
      }
    }
  }
}

var last_known_scrollX_position = 0;
var last_known_scrollY_position = 0;
var ticking = false;
var maxScreenX = 0;

// Position in range [0 - 1].
function update(position) {
  var positionString = position.toString();
  webkit.messageHandlers.progressionChanged.postMessage(positionString);
}

window.addEventListener("scroll", onScroll);

function onScroll() {
  if (readium.isFixedLayout) {
    return;
  }

  const isVertical = isVerticalWritingMode();
  const isScroll = isScrollModeEnabled();

  if (isScroll) {
    if (!isVertical) {
      // Traditional vertical scroll mode for horizontal text
      last_known_scrollY_position =
        window.scrollY / document.scrollingElement.scrollHeight;
      last_known_scrollX_position = 0;
    } else {
      // Horizontal scroll for vertical text in scroll mode
      // Using Math.abs because for RTL, the value will be negative
      last_known_scrollX_position = Math.abs(
        window.scrollX / document.scrollingElement.scrollWidth
      );
      last_known_scrollY_position = 0;
    }
  } else {
    // Paginated mode - ALWAYS horizontal for both LTR and RTL/vertical
    // Using Math.abs because for RTL books, the value will be negative
    last_known_scrollX_position = Math.abs(
      window.scrollX / document.scrollingElement.scrollWidth
    );
    last_known_scrollY_position = 0;
  }

  // Window is hidden
  if (
    document.scrollingElement.scrollWidth === 0 ||
    document.scrollingElement.scrollHeight === 0
  ) {
    return;
  }

  if (!ticking) {
    window.requestAnimationFrame(function () {
      update(
        isScroll && !isVertical
          ? last_known_scrollY_position
          : last_known_scrollX_position
      );
      ticking = false;
    });
  }
  ticking = true;
}

document.addEventListener(
  "selectionchange",
  debounce(50, function () {
    webkit.messageHandlers.selectionChanged.postMessage(getCurrentSelection());
  })
);

function orientationChanged() {
  maxScreenX =
    window.orientation === 0 || window.orientation == 180
      ? screen.width
      : screen.height;
}

export function getColumnCountPerScreen() {
  return parseInt(
    window
      .getComputedStyle(document.documentElement)
      .getPropertyValue("column-count")
  );
}

export function isScrollModeEnabled() {
  const style = document.documentElement.style;
  return style.getPropertyValue("--USER__view").trim() == "readium-scroll-on";
}

export function isVerticalWritingMode() {
  // Check the CSS variable that indicates vertical text mode
  // This is more reliable than checking computed writing-mode since we keep html in horizontal-tb
  const userWritingMode = document.documentElement.style.getPropertyValue("--USER__writingMode").trim();
  if (userWritingMode === "vertical-rl") {
    return true;
  }

  // Fallback to checking computed writing-mode for scroll mode
  const writingMode = window
    .getComputedStyle(document.documentElement)
    .getPropertyValue("writing-mode");
  return writingMode.startsWith("vertical");
}

export function isRTL() {
  const style = window.getComputedStyle(document.documentElement);
  return (
    style.getPropertyValue("direction") == "rtl" ||
    style.getPropertyValue("writing-mode") == "vertical-rl"
  );
}

// Scroll to the given TagId in document and snap.
export function scrollToId(id) {
  let element = document.getElementById(id);
  if (!element) {
    return false;
  }

  scrollToRect(element.getBoundingClientRect());
  return true;
}

// Position must be in the range [0 - 1], 0-100%.
export function scrollToPosition(position, dir) {
  console.log("ScrollToPosition");
  if (position < 0 || position > 1) {
    console.log("InvalidPosition");
    return;
  }

  const isVertical = isVerticalWritingMode();
  const isScroll = isScrollModeEnabled();

  if (isScroll) {
    if (!isVertical) {
      // Traditional vertical scroll for horizontal text
      let offset = document.scrollingElement.scrollHeight * position;
      document.scrollingElement.scrollTop = offset;
    } else {
      // Horizontal scroll for vertical text (RTL direction)
      let offset = document.scrollingElement.scrollWidth * position;
      // For RTL, scrollLeft is negative or counted from the right
      document.scrollingElement.scrollLeft = -offset;
    }
  } else {
    // Paginated mode - ALWAYS horizontal for both LTR and RTL/vertical
    var documentWidth = document.scrollingElement.scrollWidth;
    // For vertical text (RTL), direction is inverted
    var factor = dir == "rtl" || isVertical ? -1 : 1;
    let offset = documentWidth * position * factor;
    document.scrollingElement.scrollLeft = snapOffset(offset);
  }
}

// Scrolls to the first occurrence of the given text snippet.
//
// The expected text argument is a Locator object, as defined here:
// https://readium.org/architecture/models/locators/
export function scrollToLocator(locator) {
  let range = rangeFromLocator(locator);
  if (!range) {
    return false;
  }
  return scrollToRange(range);
}

function scrollToRange(range) {
  return scrollToRect(range.getBoundingClientRect());
}

function scrollToRect(rect) {
  const isVertical = isVerticalWritingMode();
  const isScroll = isScrollModeEnabled();

  if (isScroll) {
    if (!isVertical) {
      // Traditional vertical scroll for horizontal text
      document.scrollingElement.scrollTop = rect.top + window.scrollY;
    } else {
      // Horizontal scroll for vertical text
      document.scrollingElement.scrollLeft = rect.left + window.scrollX;
    }
  } else {
    // Paginated mode - ALWAYS horizontal for both LTR and RTL/vertical
    document.scrollingElement.scrollLeft = snapOffset(
      rect.left + window.scrollX
    );
  }

  return true;
}

// Returns false if the page is already at the left-most scroll offset.
export function scrollLeft(dir) {
  const isVertical = isVerticalWritingMode();
  const isScroll = isScrollModeEnabled();
  var isRTL = dir == "rtl" || isVertical;

  if (isScroll && isVertical) {
    // Scroll mode with vertical text: scroll horizontally right (backward)
    var documentWidth = document.scrollingElement.scrollWidth;
    var pageWidth = window.innerWidth;
    var offset = window.scrollX + pageWidth;
    var maxOffset = 0; // RTL scrolling
    return scrollToOffset(Math.min(offset, maxOffset));
  } else if (isScroll && !isVertical) {
    // Scroll mode with horizontal text: not used (vertical scroll instead)
    return false;
  } else {
    // Paginated mode - ALWAYS horizontal scrolling
    var documentWidth = document.scrollingElement.scrollWidth;
    var pageWidth = window.innerWidth;
    var offset = window.scrollX - pageWidth;
    var minOffset = isRTL ? -(documentWidth - pageWidth) : 0;
    return scrollToOffset(Math.max(offset, minOffset));
  }
}

// Returns false if the page is already at the right-most scroll offset.
export function scrollRight(dir) {
  const isVertical = isVerticalWritingMode();
  const isScroll = isScrollModeEnabled();
  var isRTL = dir == "rtl" || isVertical;

  if (isScroll && isVertical) {
    // Scroll mode with vertical text: scroll horizontally left (forward)
    var documentWidth = document.scrollingElement.scrollWidth;
    var pageWidth = window.innerWidth;
    var offset = window.scrollX - pageWidth;
    var minOffset = -(documentWidth - pageWidth); // RTL scrolling
    return scrollToOffset(Math.max(offset, minOffset));
  } else if (isScroll && !isVertical) {
    // Scroll mode with horizontal text: not used (vertical scroll instead)
    return false;
  } else {
    // Paginated mode - ALWAYS horizontal scrolling
    var documentWidth = document.scrollingElement.scrollWidth;
    var pageWidth = window.innerWidth;
    var offset = window.scrollX + pageWidth;
    var maxOffset = isRTL ? 0 : documentWidth - pageWidth;
    return scrollToOffset(Math.min(offset, maxOffset));
  }
}

// Scrolls to the given left offset.
// Returns false if the page scroll position is already close enough to the given offset.
function scrollToOffset(offset) {
  var currentOffset = window.scrollX;
  var pageWidth = window.innerWidth;
  document.scrollingElement.scrollLeft = offset;
  // In some case the scrollX cannot reach the position respecting to innerWidth
  var diff = Math.abs(currentOffset - offset) / pageWidth;
  return diff > 0.01;
}

// Snap the offset to the screen width (page width).
function snapOffset(offset) {
  var value = offset + 1;

  return value - (value % maxScreenX);
}

function snapCurrentPosition() {
  if (isScrollModeEnabled()) {
    return;
  }
  var currentOffset = window.scrollX;
  var currentOffsetSnapped = snapOffset(currentOffset + 1);

  document.scrollingElement.scrollLeft = currentOffsetSnapped;
}

export function rangeFromLocator(locator) {
  try {
    let locations = locator.locations;
    let text = locator.text;
    if (text && text.highlight) {
      var root;
      if (locations && locations.cssSelector) {
        root = document.querySelector(locations.cssSelector);
      }
      if (!root) {
        root = document.body;
      }

      let anchor = new TextQuoteAnchor(root, text.highlight, {
        prefix: text.before,
        suffix: text.after,
      });

      return anchor.toRange();
    }

    if (locations) {
      var element = null;

      if (!element && locations.cssSelector) {
        element = document.querySelector(locations.cssSelector);
      }

      if (!element && locations.fragments) {
        for (const htmlId of locations.fragments) {
          element = document.getElementById(htmlId);
          if (element) {
            break;
          }
        }
      }

      if (element) {
        let range = document.createRange();
        range.setStartBefore(element);
        range.setEndAfter(element);
        return range;
      }
    }
  } catch (e) {
    logError(e);
  }

  return null;
}

/// User Settings.

export function setCSSProperties(properties) {
  for (const name in properties) {
    setProperty(name, properties[name]);
  }
  // Writing mode is handled by inline CSS injection, not here
}

// For setting user setting.
export function setProperty(key, value) {
  if (value === null) {
    removeProperty(key);
  } else {
    var root = document.documentElement;
    // The `!important` annotation is added with `setProperty()` because if
    // it's part of the `value`, it will be ignored by the Web View.
    root.style.setProperty(key, value, "important");
  }
}

// For removing user setting.
export function removeProperty(key) {
  var root = document.documentElement;

  root.style.removeProperty(key);
}

/// Toolkit

function debounce(delay, func) {
  var timeout;
  return function () {
    var self = this;
    var args = arguments;
    function callback() {
      func.apply(self, args);
      timeout = null;
    }
    clearTimeout(timeout);
    timeout = setTimeout(callback, delay);
  };
}

export function log() {
  var message = Array.prototype.slice.call(arguments).join(" ");
  webkit.messageHandlers.log.postMessage(message);
}

export function logErrorMessage(msg) {
  logError(new Error(msg));
}

export function logError(e) {
  webkit.messageHandlers.logError.postMessage({
    message: e.message,
  });
}
