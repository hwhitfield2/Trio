Pod::Spec.new do |s|
  s.name             = 'trio_live_activity'
  s.version          = '0.1.0'
  s.summary          = 'Trio Follower Live Activity bridge'
  s.description      = 'Starts, updates and ends the Trio Follower Live Activity.'
  s.homepage         = 'https://github.com/nightscout/Trio'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Trio' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
