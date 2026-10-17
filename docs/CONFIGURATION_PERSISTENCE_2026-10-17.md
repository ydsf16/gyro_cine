# Configuration persistence

- Removed unconditional launch resets of storage location and exposure display type. First-run defaults remain internal storage, 1×, H.265 4K60, A-Max/180°.
- Persist the last successfully applied physical lens ID, encoding, dimensions and FPS. Resolve capabilities again on launch using dimensions rather than unstable format indices; unsupported combinations use the existing closest-supported selection.
- Persist user control intentions: auto/A-Max/manual/angle exposure, maximum duration, manual ISO/duration/angle, EV, white-balance mode/Kelvin, focus mode/position/point. Restore after the format is configured with device limits applied. Auto controls resume measuring; transient measured values are not converted into manual settings.
- Existing Settings AppStorage, LUT and slate persistence remains intact. RAW still requires locked WB.
- Unit regression: `/tmp/gyrocine-all-settings.xcresult` passed `testCaptureConfigurationSurvivesRestart` and `testAllUserControlsPersistAcrossLaunch`. These validate persistence/migration and modes, not physical camera restoration accuracy.
- Release builds passed. Full physical control round-trip verification remains to be performed.
- TestFlight upload remains paused by user request.
