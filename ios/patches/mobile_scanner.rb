require 'digest'
require 'fileutils'
require 'open3'

# Patch a generated copy, never Flutter's shared pub cache. The checksum pins
# this adaptation to mobile_scanner 7.0.0-beta.6 and fails on an unreviewed upgrade.
module TechPieMobileScannerPatch
  SOURCE_SHA256 = 'a6658518233de20fbcd05e4af0daf0301bac8caf481bb102eaf298e487b16055'.freeze

  def self.apply(installer)
    pod = installer.pod_targets.find { |target| target.pod_name == 'mobile_scanner' }
    raise 'mobile_scanner pod is missing' unless pod

    source = pod.file_accessors.flat_map(&:source_files).find do |path|
      path.basename.to_s == 'MobileScannerPlugin.swift'
    end
    unless source && Digest::SHA256.file(source).hexdigest == SOURCE_SHA256
      raise 'mobile_scanner source changed; review ios/patches/mobile_scanner_capture.patch before building'
    end

    directory = installer.sandbox.root.join('TechPiePatches')
    FileUtils.mkdir_p(directory)
    generated = directory.join('MobileScannerPlugin.swift')
    FileUtils.cp(source, generated)
    patch = File.join(__dir__, 'mobile_scanner_capture.patch')
    output, error, status = Open3.capture3('/usr/bin/patch', '--batch', '--forward', '--fuzz=0', generated.to_s, patch)
    raise "mobile_scanner capture patch failed: #{output}#{error}" unless status.success?

    references = installer.pods_project.targets
      .select { |target| target.name == pod.label }
      .flat_map { |target| target.source_build_phase.files }
      .map(&:file_ref)
      .compact
      .select { |reference| File.basename(reference.path) == 'MobileScannerPlugin.swift' }
    raise 'mobile_scanner compile source was not found' if references.empty?

    references.each do |reference|
      reference.source_tree = '<absolute>'
      reference.path = generated.to_s
    end
  end
end
