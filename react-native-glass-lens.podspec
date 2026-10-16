require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-glass-lens"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]

  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => "https://github.com/BuiHung1612/react-native-glass-lens.git", :tag => "v#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm}"
  s.private_header_files = "ios/**/*.h"
  s.frameworks   = "Metal", "MetalKit", "MetalPerformanceShaders", "QuartzCore"

  install_modules_dependencies(s)
end
