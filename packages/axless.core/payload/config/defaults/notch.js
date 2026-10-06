.pragma library

var data = {
    "theme": "default",
    "position": "top",
    "hoverRegionHeight": 8,
    "keepHidden": false,
    // axless.core: swap the notch main row for live system metrics.
    // Required in defaults as well as in Config.qml: ConfigValidator
    // rebuilds the config by iterating the defaults object and drops any
    // key it does not know about, so a property missing here is silently
    // erased from notch.json on the next save.
    "showMetrics": false,
    "noMediaDisplay": "userHost",
    "customText": "Ambxst",
    "disableHoverExpansion": true
}
