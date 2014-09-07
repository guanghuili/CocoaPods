require 'active_support/core_ext/string/inflections'

module Pod
  class Installer
    class UserProjectIntegrator
      # This class is responsible for integrating the library generated by a
      # {TargetDefinition} with its destination project.
      #
      class TargetIntegrator
        autoload :XCConfigIntegrator, 'cocoapods/installer/user_project_integrator/target_integrator/xcconfig_integrator'

        # @return [Target] the target that should be integrated.
        #
        attr_reader :target

        # @param  [Target] target @see #target_definition
        #
        def initialize(target)
          @target = target
        end

        # Integrates the user project targets. Only the targets that do **not**
        # already have the Pods library in their frameworks build phase are
        # processed.
        #
        # @return [void]
        #
        def integrate!
          UI.section(integration_message) do
            # TODO: refactor into Xcodeproj https://github.com/CocoaPods/Xcodeproj/issues/202
            project_is_dirty = [
              XCConfigIntegrator.integrate(target, native_targets),
              update_to_cocoapods_0_34,
              unless native_targets_to_integrate.empty?
                add_pods_library
                add_copy_resources_script_phase
                add_check_manifest_lock_script_phase
                true
              end
            ].any?

            if project_is_dirty
              user_project.save
            else
              # There is a bug in Xcode where the process of deleting and
              # re-creating the xcconfig files used in the build
              # configuration cause building the user project to fail until
              # Xcode is relaunched.
              #
              # Touching/saving the project causes Xcode to reload these.
              #
              # https://github.com/CocoaPods/CocoaPods/issues/2665
              FileUtils.touch(user_project.path + 'project.pbxproj')
            end
          end
        end

        # @return [String] a string representation suitable for debugging.
        #
        def inspect
          "#<#{self.class} for target `#{target.label}'>"
        end

        private

        # @!group Integration steps
        #---------------------------------------------------------------------#

        # Fixes the paths of the copy resource scripts.
        #
        # @return [Bool] whether any changes to the project were made.
        #
        # @todo   This can be removed for CocoaPods 1.0
        #
        def update_to_cocoapods_0_34
          phases = native_targets.map do |target|
            target.shell_script_build_phases.select do |bp|
              bp.name == 'Copy Pods Resources'
            end
          end.flatten

          script_path = target.copy_resources_script_relative_path
          shell_script = %("#{script_path}"\n)
          changes = false
          phases.each do |phase|
            unless phase.shell_script == shell_script
              phase.shell_script = shell_script
              changes = true
            end
          end
          changes
        end

        # Adds spec product reference to the frameworks build phase of the
        # {TargetDefinition} integration libraries. Adds a file reference to
        # the frameworks group of the project and adds it to the frameworks
        # build phase of the targets.
        #
        # @return [void]
        #
        def add_pods_library
          frameworks = user_project.frameworks_group
          native_targets_to_integrate.each do |native_target|
            build_phase = native_target.frameworks_build_phase

            # Find and delete possible reference for the other product type
            old_product_name = target.requires_framework? ? target.static_library_name : target.framework_name
            old_product_ref = frameworks.files.find { |f| f.path == old_product_name }
            if old_product_ref.present?
              UI.message("Remove old Pod product reference #{old_product_name} from project.")
              build_phase.remove_file_reference(old_product_ref)
              frameworks.remove_reference(old_product_ref)
            end

            # Find or create and add a reference for the current product type
            target_basename = target.product_basename
            new_product_ref = frameworks.files.find { |f| f.path == target.product_name } ||
              frameworks.new_product_ref_for_target(target_basename, target.product_type)
            unless build_phase.files_references.include?(new_product_ref)
              build_phase.add_file_reference(new_product_ref)
            end
          end
        end

        # Adds a shell script build phase responsible to copy the resources
        # generated by the TargetDefinition to the bundle of the product of the
        # targets.
        #
        # @return [void]
        #
        def add_copy_resources_script_phase
          phase_name = 'Copy Pods Resources'
          native_targets_to_integrate.each do |native_target|
            phase = native_target.shell_script_build_phases.select { |bp| bp.name == phase_name }.first
            phase ||= native_target.new_shell_script_build_phase(phase_name)
            script_path = target.copy_resources_script_relative_path
            phase.shell_script = %("#{script_path}"\n)
            phase.show_env_vars_in_log = '0'
          end
        end

        # Adds a shell script build phase responsible for checking if the Pods
        # locked in the Pods/Manifest.lock file are in sync with the Pods defined
        # in the Podfile.lock.
        #
        # @note   The build phase is appended to the front because to fail
        #         fast.
        #
        # @return [void]
        #
        def add_check_manifest_lock_script_phase
          phase_name = 'Check Pods Manifest.lock'
          native_targets_to_integrate.each do |native_target|
            next if native_target.shell_script_build_phases.any? { |phase| phase.name == phase_name }
            phase = native_target.project.new(Xcodeproj::Project::Object::PBXShellScriptBuildPhase)
            native_target.build_phases.unshift(phase)
            phase.name = phase_name
            phase.shell_script = <<-EOS.strip_heredoc
              diff "${PODS_ROOT}/../Podfile.lock" "${PODS_ROOT}/Manifest.lock" > /dev/null
              if [[ $? != 0 ]] ; then
                  cat << EOM
              error: The sandbox is not in sync with the Podfile.lock. Run 'pod install' or update your CocoaPods installation.
              EOM
                  exit 1
              fi
            EOS
            phase.show_env_vars_in_log = '0'
          end
        end

        private

        # @!group Private helpers
        #---------------------------------------------------------------------#

        # @return [Array<PBXNativeTarget>] The list of all the targets that
        #         match the given target.
        #
        def native_targets
          @native_targets ||= target.user_targets(user_project)
        end

        # @return [Array<PBXNativeTarget>] The list of the targets
        #         that have not been integrated by past installations
        #         of
        #
        def native_targets_to_integrate
          unless @native_targets_to_integrate
            @native_targets_to_integrate = native_targets.reject do |native_target|
              native_target.frameworks_build_phase.files.any? do |build_file|
                file_ref = build_file.file_ref
                file_ref &&
                  file_ref.isa == 'PBXFileReference' &&
                  file_ref.display_name == target.product_name
              end
            end
          end
          @native_targets_to_integrate
        end

        # Read the project from the disk to ensure that it is up to date as
        # other TargetIntegrators might have modified it.
        #
        def user_project
          @user_project ||= Xcodeproj::Project.open(target.user_project_path)
        end

        # @return [Specification::Consumer] the consumer for the specifications.
        #
        def spec_consumers
          @spec_consumers ||= target.pod_targets.map(&:file_accessors).flatten.map(&:spec_consumer)
        end

        # @return [String] the message that should be displayed for the target
        #         integration.
        #
        def integration_message
          "Integrating target `#{target.name}` " \
            "(#{UI.path target.user_project_path} project)"
        end
      end
    end
  end
end
