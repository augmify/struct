require 'paint'
require 'xcodeproj'
require 'semantic'
require_relative '../spec/spec_file'

module StructCore
	class Migrator
		CONFIG_PROFILE_PATH = File.join(__dir__, '..', '..', 'res', 'config_profiles')
		TARGET_CONFIG_PROFILE_PATH = File.join(__dir__, '..', '..', 'res', 'target_config_profiles')
		DEBUG_SETTINGS_MERGED = %w(general:debug ios:debug).map { |profile_name|
			[profile_name, File.join(CONFIG_PROFILE_PATH, "#{profile_name.sub(':', '_')}.yml")]
		}.map { |data|
			profile_name, profile_file_name = data
			unless File.exist? profile_file_name
				puts Paint["Warning: unrecognised project configuration profile '#{profile_name}'. Ignoring...", :yellow]
				next nil
			end

			next YAML.load_file(profile_file_name)
		}.inject({}) { |settings, next_settings|
			settings.merge next_settings || {}
		}
		RELEASE_SETTINGS_MERGED = %w(general:release ios:release).map { |profile_name|
			[profile_name, File.join(CONFIG_PROFILE_PATH, "#{profile_name.sub(':', '_')}.yml")]
		}.map { |data|
			profile_name, profile_file_name = data
			unless File.exist? profile_file_name
				puts Paint["Warning: unrecognised project configuration profile '#{profile_name}'. Ignoring...", :yellow]
				next nil
			end

			next YAML.load_file(profile_file_name)
		}.inject({}) { |settings, next_settings|
			settings.merge next_settings || {}
		}

		# TODO: Improve the formatting of this method once integration tests are added
		# rubocop:disable Metrics/MethodLength
		# rubocop:disable Metrics/BlockLength
		# rubocop:disable Metrics/AbcSize
		# rubocop:disable Metrics/PerceivedComplexity
		# rubocop:disable Metrics/CyclomaticComplexity
		def self.migrate(xcodeproj_file, dir, return_instead_of_write = false)
			xcodeproj_path = Pathname.new(xcodeproj_file).absolute? ? xcodeproj_file : File.expand_path(File.join(Dir.pwd, xcodeproj_file))
			directory = File.expand_path(Pathname.new(File.expand_path(dir)).absolute? ? dir : File.join(Dir.pwd, dir))

			unless File.exist? xcodeproj_path
				raise StandardError.new 'Invalid xcode project'
			end

			FileUtils.mkdir_p directory unless return_instead_of_write

			project = Xcodeproj::Project.open(xcodeproj_path)
			project_dir = File.dirname(xcodeproj_path)

			spec_version = Semantic::Version.new('1.1.0')
			configurations = migrate_build_configurations project

			targets = project.targets.map { |target|
				name = target.name
				raise StandardError.new "Target: #{name} has no configurations" if target.build_configurations.empty?

				type = target.product_type.sub 'com.apple.product-type.', ':'
				profiles = nil
				target_sdk = nil

				target_configuration_overrides = target.build_configurations.map { |config|
					config_name = config.name
					config_name = name.downcase if %w(Debug Release).include? name
					config_xcconfig_overrides = extract_target_xcconfig_overrides config.base_configuration_reference, project_dir

					if profiles.nil?
						target_sdk = target.sdk
						target_sdk = config_xcconfig_overrides['SDKROOT'] unless config_xcconfig_overrides['SDKROOT'].nil?

						if target_sdk.include? 'iphoneos'
							profiles = ['platform:ios', type.sub(':', '')]
						elsif target_sdk.include? 'macosx'
							profiles = ['platform:mac', type.sub(':', '')]
						elsif target_sdk.include? 'appletvos'
							profiles = ['platform:tvos', type.sub(':', '')]
						elsif target_sdk.include? 'watchos'
							profiles = ['platform:watchos', type.sub(':', '')]
						end
					end

					merged_config_settings = extract_target_config_overrides(profiles, config.build_settings)
					merged_config_settings.merge! config_xcconfig_overrides

					[config_name, merged_config_settings]
				}.to_h

				target_references = target.frameworks_build_phase.files.map { |f|
					if f.file_ref.source_tree == 'SDKROOT' || f.file_ref.source_tree == 'DEVELOPER_DIR'
						if f.file_ref.path.include? 'System/Library/Frameworks'
							StructCore::Specfile::Target::SystemFrameworkReference.new(f.file_ref.path.split('/').last.sub('.framework', ''))
						elsif f.file_ref.path.include? 'usr/lib'
							StructCore::Specfile::Target::SystemLibraryReference.new(f.file_ref.path.split('/').last)
						else
							next nil
						end
					else
						StructCore::Specfile::Target::LocalFrameworkReference.new(f.file_ref.path, nil)
					end
				}.compact

				raise StandardError.new "Unrecognised SDK #{target.sdk} for target: #{name}" if target_sdk.empty?

				target_scripts = target.build_phases.select { |f| f.isa == 'PBXShellScriptBuildPhase' }.map { |f|
					destination_dir = File.join directory, 'scripts'
					FileUtils.mkdir_p destination_dir
					destination_path = File.join(destination_dir, "#{name}_#{f.name.sub('.', '').sub('sh', '').sub('/', '')}.sh")

					File.write destination_path, f.shell_script
					StructCore::Specfile::Target::RunScript.new(destination_path)
				}

				StructCore::Specfile::Target.new(
					name,
					type,
					"src-#{name.downcase.sub(' ', '_')}",
					target.build_configurations.map { |config|
						StructCore::Specfile::Target::Configuration.new(
							config.name, target_configuration_overrides[config.name], profiles
						)
					},
					target_references,
					[],
					nil,
					[],
					target_scripts
				)
			}

			targets_files = project.targets.map { |target|
				target_files = target.source_build_phase.files.map { |file| file.file_ref.real_path }
				target_files.unshift(*target.resources_build_phase.files.map { |file|
					next nil if file.file_ref.nil?
					file.file_ref.real_path
				}.compact)
				target_files = target_files.map(&:to_s)
				target_files = target_files.select { |f| !File.directory?(f) || f.end_with?('xcassets') }
				target_glob_files = target_files.select { |f|
					File.directory? f
				}.flatten
				target_files = target_files.select { |f|
					!target_glob_files.include? f
				}
				target_files.unshift(*target_glob_files.map { |f|
					Dir[File.join f, '**', '*']
				}.flatten.select { |f|
					!File.directory? f
				})

				target_res_files = target.resources_build_phase.files.select { |f|
					!f.file_ref.name.nil? && f.file_ref.name.end_with?('.storyboard', '.strings', '.stringsdict')
				}.map { |f|
					f.file_ref.name
				}

				target_files.unshift(*Dir[File.join project_dir, '**', '*.lproj', '**', '*'].select { |f|
					!File.directory?(f) && target_res_files.include?(File.basename(f))
				})

				[target.name, target_files]
			}

			spec_file = StructCore::Specfile.new(spec_version, targets, configurations, [], directory)
			return spec_file if return_instead_of_write

			spec_file.write File.join(directory, 'project.yml')

			targets_files.each { |name, files|
				destination_dir = File.join directory, "src-#{name.downcase.sub(' ', '_')}"
				FileUtils.mkdir_p destination_dir

				files.each { |f|
					FileUtils.mkdir_p File.dirname(f.sub(project_dir, destination_dir))
					next unless File.exist? f
					FileUtils.cp_r f, f.sub(project_dir, destination_dir)
				}
			}
		end
		# rubocop:enable Metrics/MethodLength
		# rubocop:enable Metrics/BlockLength
		# rubocop:enable Metrics/AbcSize
		# rubocop:enable Metrics/PerceivedComplexity
		# rubocop:enable Metrics/CyclomaticComplexity

		private_class_method def self.migrate_build_configurations(project)
			project.build_configurations.map { |config|
				if config.type == :debug
					overrides = config.build_settings.reject { |k, _| DEBUG_SETTINGS_MERGED.include? k }
					next StructCore::Specfile::Configuration.new(config.name, %w(general:debug ios:debug), overrides, 'debug')
				elsif config.type == :release
					overrides = config.build_settings.reject { |k, _| RELEASE_SETTINGS_MERGED.include? k }
					next StructCore::Specfile::Configuration.new(config.name, %w(general:release ios:release), overrides, 'release')
				else
					raise StandardError.new "Unsupported build configuration type: #{config.type}"
				end
			}
		end

		private_class_method def self.extract_target_config_overrides(profiles, build_settings)
			default_settings = profiles.map { |profile_name|
				[profile_name, File.join(TARGET_CONFIG_PROFILE_PATH, "#{profile_name.sub(':', '_')}.yml")]
			}.map { |data|
				profile_name, profile_file_name = data
				unless File.exist? profile_file_name
					puts Paint["Warning: unrecognised project configuration profile '#{profile_name}'. Ignoring...", :yellow]
					next nil
				end

				next YAML.load_file(profile_file_name)
			}.inject({}) { |settings, next_settings|
				settings.merge next_settings || {}
			}

			build_settings.reject { |k, _| default_settings.include? k }
		end

		private_class_method def self.extract_target_xcconfig_overrides(xcconfig_file_ref, project_dir)
			return {} if xcconfig_file_ref.nil?

			xcconfig_file = xcconfig_file_ref.hierarchy_path || ''
			xcconfig_file[0] = '' if xcconfig_file .start_with? '/'
			abs_xcconfig_file = xcconfig_file
			abs_xcconfig_file = File.join(project_dir, xcconfig_file) unless Pathname.new(xcconfig_file).absolute?
			return {} if xcconfig_file.nil? || !File.exist?(abs_xcconfig_file)

			config_str = File.read abs_xcconfig_file
			config_str = config_str.gsub(/^\/\/.*\n/, '').sub("\n\n", "\n").gsub(/\s*=\s*/, '=')

			config = {}
			config_str.split("\n").each { |entry|
				pair = entry.split('=')
				next unless pair.length == 2
				config[pair[0]] = pair[1]
			}

			config
		end
	end
end