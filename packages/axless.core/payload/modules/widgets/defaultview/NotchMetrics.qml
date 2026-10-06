import QtQuick
import QtQuick.Layouts
import qs.modules.theme
import qs.config
import qs.modules.services

/**
 * NotchMetrics — live system metrics in the notch's main row.
 *
 * axless.core. Replaces the clock row while metrics are on.
 *
 * Scope is deliberately limited to what Ambxst's Go `systemmonitor`
 * backend actually emits: cpu{usage,temp}, ram{usage}, disk{usage},
 * gpu{usages,temps}. NothingLess also showed power draw and FPS, but
 * Ambxst has no source for either — its payload carries no watts and no
 * frame rate — so those are not shown rather than faked.
 */
RowLayout {
    id: root

    readonly property bool enabled: (Config.notch && Config.notch.showMetrics === true)

    // The subscription in SystemResources is normally only alive while the
    // dashboard metrics tab is open (see the monitoringActive patch). If it
    // has not delivered anything yet, render dashes instead of zeroes so a
    // stale sample is never mistaken for a real "0%" reading.
    readonly property bool hasData: SystemResources.totalDataPoints > 0
    readonly property real sampleMs: 1000

    spacing: 14

    function dash(value) {
        return root.hasData && value !== undefined && value !== null ? value : "--"
    }

    MetricsGroupWrapper {
        visible: SystemResources.gpuCount > 0
        label: "CPU"
        labelColor: Styling.srItem("primary")
        valueText: SystemResources.cpuTemp > 0
            ? SystemResources.cpuTemp + "° " + Math.round(SystemResources.cpuUsage)
            : root.dash(Math.round(SystemResources.cpuUsage))
    }

    MetricsGroupWrapper {
        visible: SystemResources.gpuCount > 0
        label: "GPU"
        labelColor: Styling.srItem("tertiary")
        valueText: (SystemResources.gpuTemps[0] ?? -1) > 0
            ? SystemResources.gpuTemps[0] + "° " + Math.round(SystemResources.gpuUsages[0] || 0)
            : root.dash(Math.round(SystemResources.gpuUsages[0] || 0))
    }

    MetricsGroupWrapper {
        label: "RAM"
        labelColor: Styling.srItem("secondary")
        valueText: root.dash(Math.round(SystemResources.ramUsage))
        subValue: SystemResources.ramTotal > 0
            ? String(Math.round((SystemResources.ramUsed || 0) / 1024 / 1024 / 1024)) + "G"
            : ""
    }

    MetricsGroupWrapper {
        visible: SystemResources.validDisks.length > 0
        label: "DSK"
        labelColor: Styling.srItem("error")
        valueText: root.dash(Math.round(
            SystemResources.diskUsage[SystemResources.validDisks[0]] ?? -1))
    }
}
