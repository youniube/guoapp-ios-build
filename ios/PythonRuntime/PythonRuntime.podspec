Pod::Spec.new do |spec|
  spec.name = 'PythonRuntime'
  spec.version = '3.14.0'
  spec.summary = 'Embedded Python Spider runtime'
  spec.homepage = 'https://www.python.org'
  spec.author = 'Python contributors'
  spec.source = { :path => '.' }
  spec.license = { :type => 'PSF-2.0' }
  spec.ios.deployment_target = '15.1'
  spec.vendored_frameworks = 'Python.xcframework'
end
