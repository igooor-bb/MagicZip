require 'xcodeproj'

root = File.expand_path(__dir__)
project = Xcodeproj::Project.new(File.join(root, 'Client.xcodeproj'))
[['ClientMac', :osx, '13.0'], ['ClientIOS', :ios, '16.0']].each do |name, platform, version|
  target = project.new_target(:application, name, platform, version)
  source = project.main_group.new_file('main.swift')
  target.source_build_phase.add_file_reference(source)
  target.build_configurations.each do |config|
    config.build_settings['SWIFT_VERSION'] = '6.0'
    config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'org.magiczip.' + name
    config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
    config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
    config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
  end
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(target)
  scheme.set_launch_target(target)
  scheme.save_as(File.join(root, 'Client.xcodeproj'), name, true)
end
project.save
