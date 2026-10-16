require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-glass-lens"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"] || "https://www.npmjs.com/package/react-native-glass-lens"
  s.license      = package["license"]
  s.authors      = package["author"] || "react-native-glass-lens contributors"

  s.platforms    = { :ios => min_ios_version_supported }
  s.source       = { :git => package.dig("repository", "url") || "", :tag => "v#{s.version}" }

  s.source_files = "ios/**/*.{h,m,mm}"
  s.private_header_files = "ios/**/*.h"
  s.frameworks   = "Metal", "MetalKit", "MetalPerformanceShaders", "QuartzCore"

  install_modules_dependencies(s)
end
