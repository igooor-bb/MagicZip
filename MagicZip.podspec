Pod::Spec.new do |s|
  s.name = 'MagicZip'
  s.version = File.read(File.join(__dir__, 'VERSION')).strip
  s.summary = 'Bounded streaming ZIP and AES archives for Swift.'
  s.description = 'A Swift ZIP reader and writer with transactional extraction, ZIP64 and WinZIP AES-256 over isolated minizip-ng.'
  s.homepage = 'https://github.com/igooor-bb/MagicZip'
  s.license = { :type => 'MIT', :file => 'LICENSE' }
  s.author = { 'Igor Belov' => 'https://github.com/igooor-bb' }
  s.source = { :git => 'https://github.com/igooor-bb/MagicZip.git', :tag => s.version.to_s }
  s.ios.deployment_target = '16.0'
  s.osx.deployment_target = '13.0'
  s.swift_version = '6.0'
  s.module_name = 'MagicZip'
  s.source_files = 'Sources/MagicZip/**/*.swift'
  s.dependency 'MagicZipCMinizip', s.version.to_s
end
