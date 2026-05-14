# BugScreen iOS SDK

Screenshot-triggered bug reporting for iOS apps. When your users take a screenshot, BugScreen prompts them to file a bug report — screenshot, device metadata, and logs are sent to your BugScreen workspace and routed to GitHub or Jira automatically.

- Website: [bugscreen.app](https://bugscreen.app)
- Documentation: [bugscreen.app/docs/ios](https://bugscreen.app/docs/ios)

This repository is a read-only mirror of the iOS SDK source, published on each release. Issues and pull requests are accepted here.

## Requirements

- iOS 15.0+
- Swift 5.9+
- Xcode 15+

## Installation

### Swift Package Manager

In Xcode, go to **File → Add Package Dependencies…** and enter:

```
https://github.com/bugscreenapp/bugscreen-ios
```

Or add it to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/bugscreenapp/bugscreen-ios", from: "0.1.0")
]
```

## Quick start

Configure the SDK once at app launch with your API key from the [BugScreen console](https://bugscreen.app/console):

```swift
import BugScreenSDK
import SwiftUI

@main
struct MyApp: App {
    init() {
        BugScreenSDK.configure(
            apiKey: "fb_your_api_key_here",
            enableScreenshotDetection: true,
            enableLogging: false
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

With `enableScreenshotDetection: true`, taking a screenshot inside the app presents the bug report flow automatically. You can also present it manually:

```swift
BugScreenSDK.presentBugReport()
```

Attach logs from anywhere in your app:

```swift
BugScreenSDK.log("User tapped checkout", level: .info)
```

See the [iOS documentation](https://bugscreen.app/docs/ios) for the full API.

## Privacy

The SDK ships with a `PrivacyInfo.xcprivacy` manifest declaring the APIs it uses and the data it collects (device ID, diagnostic data, screenshots, user-provided text). All entries are marked `linked = false` and `tracking = false`. Data is sent only to BugScreen's backend in response to user-initiated bug reports.

## Reporting issues

File issues at [github.com/bugscreenapp/bugscreen-ios/issues](https://github.com/bugscreenapp/bugscreen-ios/issues).

## License

Apache License 2.0. See [LICENSE](LICENSE).
