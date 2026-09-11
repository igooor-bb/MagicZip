Pod::Spec.new do |s|
  s.name = 'MagicZipCMinizip'
  s.version = '0.1.0'
  s.summary = 'Private, namespaced minizip-ng implementation for MagicZip.'
  s.homepage = 'https://github.com/igooor-bb/MagicZip'
  s.license = { :type => 'zlib', :file => 'Sources/CMinizip/vendor/LICENSE' }
  s.author = { 'Igor Belov' => 'https://github.com/igooor-bb' }
  s.source = { :git => 'https://github.com/igooor-bb/MagicZip.git', :tag => s.version.to_s }
  s.ios.deployment_target = '16.0'
  s.osx.deployment_target = '13.0'
  s.module_name = 'CMinizip'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.source_files = 'Sources/CMinizip/**/*.{c,h}'
  s.public_header_files = 'Sources/CMinizip/include/CMinizip.h'
  s.preserve_paths = 'Sources/CMinizip/vendor/LICENSE', 'Sources/CMinizip/vendor/METADATA.json', 'THIRD_PARTY_NOTICES', 'LICENSE'
  s.libraries = 'z'
  s.frameworks = 'Security'
end
