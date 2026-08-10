Pod::Spec.new do |s|
  s.name             = 'BugScreenSDK-NoOp'
  s.version          = '1.6.0'
  s.summary          = 'No-op stub of BugScreenSDK to keep BugScreen out of production builds.'
  s.description      = <<-DESC
    A drop-in replacement for BugScreenSDK with an identical public API but empty
    implementations. Pair it with BugScreenSDK per build configuration so the real
    SDK ships only in Debug and this stub ships in Release:

      pod 'BugScreenSDK',      :configurations => ['Debug']
      pod 'BugScreenSDK-NoOp', :configurations => ['Release']

    Because this pod vends the same `BugScreenSDK` module, your call sites compile
    unchanged. No BugScreen networking, UI, screenshot detection, resource bundle,
    or privacy-manifest declarations ship in your release binary.
  DESC

  s.homepage         = 'https://github.com/bugscreenapp/bugscreen-ios'
  s.license          = { :type => 'Apache-2.0', :file => 'LICENSE' }
  s.author           = { 'BugScreen' => 'contact@bugscreen.app' }
  # Shares the mirror's single per-release tag with the real pod — both are
  # published from the same commit and select different files from it.
  s.source           = { :git => 'https://github.com/bugscreenapp/bugscreen-ios.git', :tag => "v#{s.version}" }

  s.ios.deployment_target = '15.0'
  s.swift_versions        = ['5.9']

  # Same module name as the real pod so `import BugScreenSDK` and every call site
  # resolve against either. The two pods are scoped to disjoint build
  # configurations, so only one links per configuration and there is no
  # duplicate-symbol clash.
  s.module_name  = 'BugScreenSDK'
  s.source_files = 'Sources/BugScreenSDKNoOp/**/*.swift'

  # Intentionally NO resource_bundles: the whole point of the stub is that
  # PrivacyInfo.xcprivacy, the localized strings, and the asset catalog do not
  # ship in production. The App Store privacy label aggregates the real pod's
  # manifest only in Debug builds.
end
