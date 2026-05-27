Pod::Spec.new do |s|
  s.name             = 'BugScreenSDK'
  s.version          = '1.1.0'
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

  s.resources = ['Sources/BugScreenSDK/Resources/PrivacyInfo.xcprivacy']

  s.resource_bundles = {
    'BugScreenSDK' => [
      'Sources/BugScreenSDK/Resources/Localizable.xcstrings'
    ]
  }
end
