// Scroll-reveal for the landing-page sections.
//
// Each `.reveal` section starts hidden (only when the `js` class is present, so
// the content is never hidden if scripting is unavailable) and is shown as it
// scrolls into view. Users who prefer reduced motion, or whose browser lacks
// IntersectionObserver, get everything shown immediately.
(function () {
    "use strict";

    var els = document.querySelectorAll(".reveal");

    function showAll() {
        els.forEach(function (el) {
            el.classList.add("is-visible");
        });
    }

    var prefersReducedMotion = window.matchMedia(
        "(prefers-reduced-motion: reduce)"
    ).matches;

    if (prefersReducedMotion || !("IntersectionObserver" in window)) {
        showAll();
        return;
    }

    var observer = new IntersectionObserver(
        function (entries) {
            entries.forEach(function (entry) {
                if (entry.isIntersecting) {
                    entry.target.classList.add("is-visible");
                    observer.unobserve(entry.target);
                }
            });
        },
        { rootMargin: "0px 0px -10% 0px", threshold: 0.1 }
    );

    els.forEach(function (el) {
        observer.observe(el);
    });
})();
