Pod::Spec.new do |s|
  s.name             = 'BugScreenSDK'
  s.version          = '1.9.0'
  s.summary          = 'Turn screenshots into bug reports in your issue tracker.'
  s.description      = <<-DESC
    BugScreen detects screenshots in your iOS app and lets users file a bug
    report straight into your configured GitHub or Jira project, complete with
    the screenshot, device metadata, and recent logs.
  DESC

  s.homepage         = 'https://github.com/bugscreenapp/bugscreen-ios'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'BugScreen' => 'contact@bugscreen.app' }
  s.source           = { :git => 'https://github.com/bugscreenapp/bugscreen-ios.git', :tag => "v#{s.version}" }

  s.ios.deployment_target = '15.0'
  s.swift_versions        = ['5.9']

  s.source_files = 'Sources/BugScreenSDK/**/*.swift'

  # This pod must never gain an `s.dependency`, and the reporter UI is why the rule is
  # written down. CocoaPods honours `:configurations` ONLY for pods declared directly in a
  # Podfile — verified in cocoapods 1.16.2, installer/analyzer.rb#filter_pod_targets_for_
  # target_definition, where a transitive pod yields no whitelist and is appended to EVERY
  # build configuration. So a dependency here would land in the Release binary of every
  # consumer following DX-009's no-op swap, silently, on a version bump alone — breaking
  # the install guide's promise that no BugScreen code ships in production. The reporter is
  # shared with the companion app by compiling the same sources, not by a second pod:
  # RFC-003 §2.1.

  # PrivacyInfo.xcprivacy must ship inside a sub-bundle (resource_bundles),
  # not via s.resources. s.resources copies the manifest to the consumer
  # app's .app root and collides with the app target's own PrivacyInfo —
  # Xcode fails with "Multiple commands produce .../<App>.app/PrivacyInfo.xcprivacy".
  # Apple's submission tooling aggregates manifests from sub-bundles, so
  # privacy compliance is unchanged.
  #
  # The bundle key must stay 'BugScreenSDK' — BugScreenResources looks it up by that exact
  # name and a mismatch fails silently, on the CocoaPods channel only. BundleAccessorTests
  # pins the pair.
  s.resource_bundles = {
    'BugScreenSDK' => [
      'Sources/BugScreenSDK/Resources/PrivacyInfo.xcprivacy',
      'Sources/BugScreenSDK/Resources/ReportNotification.strings',
      'Sources/BugScreenSDK/Reporter/Resources/Localizable.xcstrings',
      'Sources/BugScreenSDK/Reporter/Resources/Media.xcassets'
    ]
  }
end
