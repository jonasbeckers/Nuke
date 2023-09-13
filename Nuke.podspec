Pod::Spec.new do |s|
    s.name             = 'Nuke'
    s.version          = '12.1.6'
    s.summary          = 'A powerful image loading and caching system'
    s.description  = <<-EOS
    A powerful image loading and caching system which makes simple tasks like loading images into views extremely simple, while also supporting more advanced features for more demanding apps.
    EOS

    s.homepage         = 'https://github.com/kean/Nuke'
    s.license          = 'MIT'
    s.author           = 'Alexander Grebenyuk'
    s.social_media_url = 'https://twitter.com/a_grebenyuk'
    s.source           = { :git => 'https://github.com/kean/Nuke.git', :tag => s.version.to_s }

    s.swift_versions = ['5.1', '5.2']

    s.ios.deployment_target = '13.0'
    s.watchos.deployment_target = '6.0'
    s.osx.deployment_target = '10.15'
    s.tvos.deployment_target = '12.0'

  # files
	s.source = {
		:git => 'https://github.com/jonasbeckers/Nuke.git',
		:tag => s.version,
		:submodules => true
	}

    s.default_subspec = 'Core', 'Extensions'

    s.subspec 'Core' do |ss|
        ss.source_files = 'Sources/Nuke/**/*.swift'
    end

    s.subspec 'Extensions' do |ss|
        ss.source_files = 'Sources/NukeExtensions/**/*.swift'
        ss.dependency 'Nuke/Core'
    end

    s.subspec 'UI' do |ss|
        ss.source_files = 'Sources/NukeUI/**/*.swift'
        ss.dependency 'Nuke/Core'
    end

    s.subspec 'Video' do |ss|
        ss.source_files = 'Sources/NukeVideo/**/*.swift'
        ss.dependency 'Nuke/Core'
    end
end