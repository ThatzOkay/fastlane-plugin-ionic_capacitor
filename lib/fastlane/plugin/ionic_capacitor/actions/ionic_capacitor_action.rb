require 'fastlane/action'
require_relative '../helper/ionic_capacitor_helper'

module Fastlane
  module Actions
    class IonicCapacitorAction < Action
      # valid action params

      ANDROID_ARGS_MAP = {
        keystore_path:        'keystore',
        keystore_password:    'storePassword',
        key_password:         'password',
        keystore_alias:       'alias',
        build_number:         'versionCode',
        min_sdk_version:      'gradleArg=-PcdvMinSdkVersion',
        capacitor_no_fetch:   'capacitorNoFetch',
        android_package_type: 'packageType'
      }

      IOS_ARGS_MAP = {
        scheme:              'scheme',
        type:                 'packageType',
        team_id:              'developmentTeam',
        provisioning_profile: 'provisioningProfile',
        build_flag:           'buildFlag'
      }

      # extract arguments only valid for the platform from all arguments
      # + map action params to the cli param they will be used for
      def self.get_platform_args(params, platform_args_map)
        platform_args = []
        platform_args_map.each do |action_key, cli_param|
          param_value = params[action_key]

          # handle `build_flag` being an Array
          if action_key.to_s == 'build_flag' && param_value.kind_of?(Array)
            unless param_value.empty?
              param_value.each do |flag|
                platform_args << "--#{cli_param}=#{flag.shellescape}"
              end
            end
          # handle all other cases
          else
            if !param_value.to_s.empty? && param_value.kind_of?(String)
              platform_args << "--#{cli_param}=#{param_value.shellescape}"
            end
          end
        end

        return platform_args.join(' ')
      end

      def self.get_android_args(params)
        if params[:key_password].empty?
          params[:key_password] = params[:keystore_password]
        end

        return self.get_platform_args(params, ANDROID_ARGS_MAP)
      end

      def self.get_ios_args(params)
        app_identifier = CredentialsManager::AppfileConfig.try_fetch_value(:app_identifier)

        if params[:provisioning_profile].empty?
          # If `match` or `sigh` were used before this, use the certificates returned from there
          params[:provisioning_profile] = ENV['SIGH_UUID'] || ENV["sigh_#{app_identifier}_#{params[:type].sub('-', '')}"]
        end

        if params[:type] == 'adhoc'
          params[:type] = 'ad-hoc'
        end
        if params[:type] == 'appstore'
          params[:type] = 'app-store'
        end

        return self.get_platform_args(params, IOS_ARGS_MAP)
      end

      # add platform if missing (run step #1)
      def self.check_platform(params)
        platform = params[:platform]
        args = []
        args << '--nofetch' if params[:capacitor_no_fetch]
        args << '--no-resources' if params[:capacitor_no_resources]
        if platform && !File.directory?("./#{platform}")
          sh "ionic capacitor platform add #{platform} --no-interactive #{args.join(' ')}"
        end
      end

      # app_name
      def self.get_app_name
        config = JSON.parse(File.read('ionic.config.json'))
        return config['name']
      end

      # actual building! (run step #2)
      def self.build(params)
        args = [params[:release] ? '--prod' : '--debug']
        args << '--device' if params[:device]
        args << '--prod' if params[:prod]
        args << '--browserify' if params[:browserify]
        args << '--verbose' if params[:verbose]

        if !params[:capacitor_build_config_file].to_s.empty?
          args << "--buildConfig=#{Shellwords.escape(params[:capacitor_build_config_file])}"
        end

        android_args = self.get_android_args(params) if params[:platform].to_s == 'android'
        ios_args = self.get_ios_args(params) if params[:platform].to_s == 'ios'

        # special handling for `build_number` param
        if params[:platform].to_s == 'ios' && !params[:build_number].to_s.empty?
          cf_bundle_version = params[:build_number].to_s
          Actions::UpdateInfoPlistAction.run(
            xcodeproj: "./ios/#{self.get_app_name}.xcodeproj",
            plist_path: "#{self.get_app_name}/#{self.get_app_name}-Info.plist",
            block: lambda { |plist|
              plist['CFBundleVersion'] = cf_bundle_version
            }
          )
        end

        is_windows = (ENV['OS'] == 'Windows_NT')
        if is_windows
          output = `powershell -Command "(gcm bunx).Path"`
          if !output.empty?
            if `bun pm ls`.include?('@capacitor/assets')
              sh "bunx capacitor-assets generate"
            end
          else
            if `npm list @capacitor/assets`.include?('@capacitor/assets')
              sh "npx capacitor-assets generate"
            end
          end
        else
          if !`which bunx`.empty?
            if `bun pm ls`.include?('@capacitor/assets')
              sh "bunx capacitor-assets generate"
            end
          else
            if `npm list @capacitor/assets`.include?('@capacitor/assets')
              sh "npx capacitor-assets generate"
            end
          end
        end

        if params[:platform].to_s == 'ios'
          sh "ionic capacitor build #{params[:platform]} --no-open --no-interactive #{args.join(' ')} -- #{ios_args}" 
          sh "xcodebuild -configuration debug -workspace ios/*.xcworkspace -scheme #{params[:scheme]} build"
        elsif params[:platform].to_s == 'android'
          sh "ionic capacitor build #{params[:platform]} --no-open --no-interactive #{args.join(' ')} -- -- #{android_args}" 
          if params[:android_package_type] == 'bundle'
            if !params[:keystore_path].empty?
              sh "./android/gradlew --project-dir android app:bundleRelease -Pandroid.injected.signing.store.file=#{params[:keystore_path]} -Pandroid.injected.signing.store.password=#{params[:keystore_password]} -Pandroid.injected.signing.key.alias=#{params[:keystore_alias]} -Pandroid.injected.signing.key.password=#{params[:key_password]}"
            else
              sh "./android/gradlew --project-dir android app:bundleRelease"
            end
          else
            if !params[:keystore_path].empty?
              sh "./android/gradlew --project-dir android app:assembleRelease -Pandroid.injected.signing.store.file=#{params[:keystore_path]} -Pandroid.injected.signing.store.password=#{params[:keystore_password]} -Pandroid.injected.signing.key.alias=#{params[:keystore_alias]} -Pandroid.injected.signing.key.password=#{params[:key_password]}"
            else
              sh "./android/gradlew --project-dir android app:assembleRelease"
            end
          end
        end
      end

      # export build paths (run step #3)
      def self.set_build_paths(params, is_release)
        app_name = self.get_app_name
        build_type = is_release ? 'release' : 'debug'

        # Update the build path accordingly if Android is being
        # built as an Android Application Bundle.

        android_package_type = params[:android_package_type] || 'apk'
        android_package_extension = android_package_type == 'bundle' ? '.aab' : '.apk'

        is_signed = !params[:keystore_path].empty?
        signed = is_signed ? '' : '-unsigned'

        ENV['CAPACITOR_ANDROID_RELEASE_BUILD_PATH'] = "./android/app/build/outputs/#{android_package_type}/#{build_type}/app-#{build_type}#{signed}#{android_package_extension}"
        ENV['CAPACITOR_IOS_RELEASE_BUILD_PATH'] = "./ios/build/device/app.ipa"
      end

      def self.run(params)
        self.check_platform(params)
        self.build(params)
        self.set_build_paths(params, params[:release])
      end

      def self.description
        "Build your Ionic Capacitor apps"
      end

      def self.authors
        ["ThatzOkay"]
      end

      def self.return_value
        # If your method provides a return value, you can describe here what it does
      end

      def self.details
        # Optional:
        "Easily build Ionic Capacitor apps using this plugin. Cordova not supported"
      end

      def self.available_options
        [
          FastlaneCore::ConfigItem.new(
            key: :platform,
            env_name: "CAPACITOR_PLATFORM",
            description: "Platform to build on. Should be either android or ios",
            is_string: true,
            default_value: '',
            verify_block: proc do |value|
              UI.user_error!("Platform should be either android or ios") unless ['', 'android', 'ios'].include? value
            end
          ),
          FastlaneCore::ConfigItem.new(
            key: :release,
            env_name: "CAPACITOR_RELEASE",
            description: "Build for release if true, or for debug if false",
            is_string: false,
            default_value: true,
            verify_block: proc do |value|
              UI.user_error!("Release should be boolean") unless [false, true].include? value
            end
          ),
          FastlaneCore::ConfigItem.new(
            key: :device,
            env_name: "CAPACITOR_DEVICE",
            description: "Build for device",
            is_string: false,
            default_value: true,
            verify_block: proc do |value|
              UI.user_error!("Device should be boolean") unless [false, true].include? value
            end
          ),
          FastlaneCore::ConfigItem.new(
            key: :prod,
            env_name: "IONIC_PROD",
            description: "Build for production",
            is_string: false,
            default_value: false,
            verify_block: proc do |value|
              UI.user_error!("Prod should be boolean") unless [false, true].include? value
            end
          ),
          FastlaneCore::ConfigItem.new(
            key: :scheme,
            env_name: "CAPACITOR_IOS_SCHEME",
            description: "The scheme to use when building the app",
            is_string: true,
            default_value: 'App'
          ),
          FastlaneCore::ConfigItem.new(
            key: :type,
            env_name: "CAPACITOR_IOS_PACKAGE_TYPE",
            description: "This will determine what type of build is generated by Xcode. Valid options are development, enterprise, adhoc, and appstore",
            is_string: true,
            default_value: 'appstore',
            verify_block: proc do |value|
              UI.user_error!("Valid options are development, enterprise, adhoc, and appstore.") unless ['development', 'enterprise', 'adhoc', 'appstore', 'ad-hoc', 'app-store'].include? value
            end
          ),
          FastlaneCore::ConfigItem.new(
            key: :verbose,
            env_name: "CAPACITOR_VERBOSE",
            description: "Pipe out more verbose output to the shell",
            default_value: false,
            is_string: false,
            verify_block: proc do |value|
              UI.user_error!("Verbose should be boolean") unless [false, true].include? value
            end
          ),
          FastlaneCore::ConfigItem.new(
            key: :team_id,
            env_name: "CAPACITOR_IOS_TEAM_ID",
            description: "The development team (Team ID) to use for code signing",
            is_string: true,
            default_value: CredentialsManager::AppfileConfig.try_fetch_value(:team_id)
          ),
          FastlaneCore::ConfigItem.new(
            key: :provisioning_profile,
            env_name: "CAPACITOR_IOS_PROVISIONING_PROFILE",
            description: "GUID of the provisioning profile to be used for signing",
            is_string: true,
            default_value: ''
          ),
          FastlaneCore::ConfigItem.new(
            key: :android_package_type,
            env_name: "CAPACITOR_ANDROID_PACKAGE_TYPE",
            description: "This will determine what type of Android build is generated. Valid options are apk or bundle",
            default_value: 'apk',
            verify_block: proc do |value|
              UI.user_error!("Valid options are apk or bundle.") unless ['apk', 'bundle'].include? value
            end
          ),
          FastlaneCore::ConfigItem.new(
            key: :keystore_path,
            env_name: "CAPACITOR_ANDROID_KEYSTORE_PATH",
            description: "Path to the Keystore for Android",
            is_string: true,
            default_value: ''
          ),
          FastlaneCore::ConfigItem.new(
            key: :keystore_password,
            env_name: "CAPACITOR_ANDROID_KEYSTORE_PASSWORD",
            description: "Android Keystore password",
            is_string: true,
            default_value: ''
          ),
          FastlaneCore::ConfigItem.new(
            key: :key_password,
            env_name: "CAPACITOR_ANDROID_KEY_PASSWORD",
            description: "Android Key password (default is keystore password)",
            is_string: true,
            default_value: ''
          ),
          FastlaneCore::ConfigItem.new(
            key: :keystore_alias,
            env_name: "CAPACITOR_ANDROID_KEYSTORE_ALIAS",
            description: "Android Keystore alias",
            is_string: true,
            default_value: ''
          ),
          FastlaneCore::ConfigItem.new(
            key: :build_number,
            env_name: "CAPACITOR_BUILD_NUMBER",
            description: "Sets the build number for iOS and version code for Android",
            optional: true,
            is_string: false
          ),
          FastlaneCore::ConfigItem.new(
            key: :browserify,
            env_name: "CAPACITOR_BROWSERIFY",
            description: "Specifies whether to browserify build or not",
            default_value: false,
            is_string: false
          ),
          FastlaneCore::ConfigItem.new(
            key: :capacitor_prepare,
            env_name: "CAPACITOR_PREPARE",
            description: "Specifies whether to run `ionic capacitor prepare` before building",
            default_value: true,
            is_string: false
          ),
          FastlaneCore::ConfigItem.new(
            key: :min_sdk_version,
            env_name: "CAPACITOR_ANDROID_MIN_SDK_VERSION",
            description: "Overrides the value of minSdkVersion set in AndroidManifest.xml",
            default_value: '',
            is_string: false
          ),
          FastlaneCore::ConfigItem.new(
            key: :capacitor_no_fetch,
            env_name: "CAPACITOR_NO_FETCH",
            description: "Call `capacitor platform add` with `--nofetch` parameter",
            default_value: false,
            is_string: false
          ),
          FastlaneCore::ConfigItem.new(
            key: :capacitor_no_resources,
            env_name: "CAPACITOR_NO_RESOURCES",
            description: "Call `capacitor platform add` with `--no-resources` parameter",
            default_value: false,
            is_string: false
          ),
          FastlaneCore::ConfigItem.new(
            key: :build_flag,
            env_name: "CAPACITOR_IOS_BUILD_FLAG",
            description: "An array of Xcode buildFlag. Will be appended on compile command",
            is_string: false,
            optional: true,
            default_value: []
          ),
          FastlaneCore::ConfigItem.new(
            key: :capacitor_build_config_file,
            env_name: "CAPACITOR_BUILD_CONFIG_FILE",
            description: "Call `ionic capacitor compile` with `--buildConfig=<ConfigFile>` to specify build config file path",
            is_string: true,
            optional: true,
            default_value: ''
          )
        ]
      end

      def self.is_supported?(platform)
        # Adjust this if your plugin only works for a particular platform (iOS vs. Android, for example)
        # See: https://docs.fastlane.tools/advanced/#control-configuration-by-lane-and-by-platform
        #
        # [:ios, :mac, :android].include?(platform)
        true
      end
    end
  end
end
