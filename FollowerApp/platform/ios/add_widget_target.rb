#!/usr/bin/env ruby
#
# Adds the Trio Follower widget extension to the Flutter-generated
# ios/Runner.xcodeproj, so neither CI nor a local build needs any manual Xcode
# work. Idempotent: re-running refreshes the settings of an existing target
# instead of adding a second one.
#
#   usage: add_widget_target.rb <app-group-id>
#
# The widget's bundle id is derived from Runner's, since an embedded extension
# must be prefixed with its host app's identifier. At this point Runner still
# carries the id flutter create gave it; fastlane renames both to the team's
# identifiers at archive time.
#
# Run from FollowerApp/ after `flutter create` has produced the iOS shell.

require 'xcodeproj'

PROJECT_PATH = 'ios/Runner.xcodeproj'.freeze
TARGET_NAME = 'TrioFollowerWidgetExtension'.freeze
GROUP_NAME = 'TrioFollowerWidget'.freeze
DEPLOYMENT_TARGET = '17.0'.freeze

app_group_id = ARGV[0]
abort('usage: add_widget_target.rb <app-group-id>') if app_group_id.to_s.empty?

abort("#{PROJECT_PATH} not found; run flutter create first") unless File.exist?(PROJECT_PATH)

project = Xcodeproj::Project.open(PROJECT_PATH)
runner = project.targets.find { |t| t.name == 'Runner' }
abort('Runner target not found') if runner.nil?

runner_bundle_id = runner.build_configurations
                        .map { |config| config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] }
                        .compact
                        .first
abort('Runner has no PRODUCT_BUNDLE_IDENTIFIER') if runner_bundle_id.to_s.empty?
bundle_id = "#{runner_bundle_id}.widget"

target = project.targets.find { |t| t.name == TARGET_NAME }
if target
  puts "==> Refreshing existing #{TARGET_NAME} target"
else
  puts "==> Creating #{TARGET_NAME} target"
  target = project.new_target(:app_extension, TARGET_NAME, :ios, DEPLOYMENT_TARGET, nil, :swift)
end

# --- Sources -----------------------------------------------------------------

group = project.main_group[GROUP_NAME] || project.main_group.new_group(GROUP_NAME, GROUP_NAME)

# Every Swift file the prepare script copied in, so adding a widget is a matter
# of dropping a file into platform/ios/TrioFollowerWidget/ and nothing else.
swift_names = Dir.glob('ios/TrioFollowerWidget/*.swift').map { |path| File.basename(path) }.sort
abort('no widget sources found in ios/TrioFollowerWidget') if swift_names.empty?

%w[Info.plist TrioFollowerWidget.entitlements Widget.xcconfig].each do |name|
  group.new_reference(name) unless group.files.any? { |f| f.path == name }
end

swift_names.each do |name|
  ref = group.files.find { |f| f.path == name } || group.new_reference(name)
  target.add_file_references([ref]) unless target.source_build_phase.files_references.include?(ref)
end

# --- Build settings ----------------------------------------------------------

# Only the Flutter version variables are inherited, via a dedicated xcconfig —
# deliberately not Runner's own Debug/Release xcconfig, which pulls in the
# Pods-Runner settings and would try to link Flutter into the extension.
config_ref = group.files.find { |f| f.path == 'Widget.xcconfig' }

target.build_configurations.each do |config|
  config.base_configuration_reference = config_ref
  config.build_settings.merge!(
    'ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES' => 'NO',
    'CODE_SIGN_ENTITLEMENTS' => "#{GROUP_NAME}/TrioFollowerWidget.entitlements",
    'CODE_SIGN_STYLE' => 'Manual',
    'CURRENT_PROJECT_VERSION' => '$(FLUTTER_BUILD_NUMBER)',
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'INFOPLIST_FILE' => "#{GROUP_NAME}/Info.plist",
    'IPHONEOS_DEPLOYMENT_TARGET' => DEPLOYMENT_TARGET,
    'LD_RUNPATH_SEARCH_PATHS' => [
      '$(inherited)',
      '@executable_path/Frameworks',
      '@executable_path/../../Frameworks'
    ],
    'MARKETING_VERSION' => '$(FLUTTER_BUILD_NAME)',
    'PRODUCT_BUNDLE_IDENTIFIER' => bundle_id,
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'SKIP_INSTALL' => 'YES',
    'SWIFT_VERSION' => '5.0',
    'TARGETED_DEVICE_FAMILY' => '1,2'
  )
end

# --- Alert tones -------------------------------------------------------------

# UNNotificationSound resolves an APNS `sound` name against the app bundle, so
# the tones have to be Runner resources. Flutter assets are no use here: they
# land under flutter_assets/, where the notification system will not look.
sounds = Dir.glob('ios/Runner/Sounds/*.wav').map { |path| File.basename(path) }.sort
unless sounds.empty?
  sound_group = project.main_group['Sounds'] || project.main_group.new_group('Sounds', 'Runner/Sounds')
  sounds.each do |name|
    ref = sound_group.files.find { |f| f.path == name } || sound_group.new_reference(name)
    next if runner.resources_build_phase.files_references.include?(ref)

    runner.resources_build_phase.add_file_reference(ref)
  end
  puts "==> alert tones bundled: #{sounds.join(', ')}"
end

# --- Embed into the app ------------------------------------------------------

runner.add_dependency(target) unless runner.dependencies.any? { |d| d.target&.name == TARGET_NAME }

embed_phase = runner.build_phases.find do |phase|
  phase.is_a?(Xcodeproj::Project::Object::PBXCopyFilesBuildPhase) &&
    phase.symbol_dst_subfolder_spec == :plug_ins
end

if embed_phase.nil?
  embed_phase = runner.new_copy_files_build_phase('Embed Foundation Extensions')
  embed_phase.symbol_dst_subfolder_spec = :plug_ins
end

already_embedded = embed_phase.files_references.include?(target.product_reference)
unless already_embedded
  build_file = embed_phase.add_file_reference(target.product_reference)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

# The embed phase has to run before Flutter's "Thin Binary" script, which takes a
# directory signature of Runner.app. Copying the extension in afterwards makes
# each phase depend on the other, and Xcode refuses the build with
# "Cycle inside Runner". A new phase is appended at the end, so move it up.
thin_binary_index = runner.build_phases.index do |phase|
  phase.respond_to?(:name) && phase.name == 'Thin Binary'
end
embed_index = runner.build_phases.index(embed_phase)

if thin_binary_index && embed_index && embed_index > thin_binary_index
  puts "==> Moving the embed phase before Thin Binary (was #{embed_index}, now #{thin_binary_index})"
  runner.build_phases.move(embed_phase, thin_binary_index)
end

project.save

puts "==> #{TARGET_NAME} ready (bundle id #{bundle_id}, app group #{app_group_id})"
puts "==> widget sources: #{swift_names.join(', ')}"
