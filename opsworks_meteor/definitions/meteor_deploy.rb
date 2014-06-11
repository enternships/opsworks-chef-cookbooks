#
# Based on:
# https://github.com/aws/opsworks-cookbooks/blob/release-chef-11.4/deploy/definitions/opsworks_deploy.rb
#
# Ruby on Rails related code has been removed.
# Uses custom app config for SCM info. Do not specify "Repository Type" in App settings (in AWS console).
# Meteor installation code has been added.
#


define :meteor_deploy do
  application = params[:app]
  deploy = params[:deploy_data]
  app_config = params[:app_config]

  directory "#{deploy[:deploy_to]}" do
    group deploy[:group]
    owner deploy[:user]
    mode "0775"
    action :create
    recursive true
  end

  if app_config[:scm]
    ensure_scm_package_installed(app_config[:scm][:scm_type])

    prepare_git_checkouts(
      :user => deploy[:user],
      :group => deploy[:group],
      :home => deploy[:home],
      :ssh_key => app_config[:scm][:ssh_key]
    ) if app_config[:scm][:scm_type].to_s == 'git'

    prepare_svn_checkouts(
      :user => deploy[:user],
      :group => deploy[:group],
      :home => deploy[:home],
      :deploy => deploy,
      :application => application
    ) if app_config[:scm][:scm_type].to_s == 'svn'

    if app_config[:scm][:scm_type].to_s == 'archive'
      repository = prepare_archive_checkouts(app_config[:scm])
      node.set[:deploy][application][:scm] = {
        :scm_type => 'git',
        :repository => repository
      }
    elsif app_config[:scm][:scm_type].to_s == 's3'
      repository = prepare_s3_checkouts(app_config[:scm])
      node.set[:deploy][application][:scm] = {
        :scm_type => 'git',
        :repository => repository
      }
    end
  end

  deploy = node[:deploy][application]

  directory "#{deploy[:deploy_to]}/shared/cached-copy" do
    recursive true
    action :delete
    only_if do
      deploy[:delete_cached_copy]
    end
  end

  ruby_block "change HOME to #{deploy[:home]} for source checkout" do
    block do
      ENV['HOME'] = "#{deploy[:home]}"
    end
  end

  # setup deployment & checkout
  if app_config[:scm] && app_config[:scm][:scm_type] != 'other'
    Chef::Log.debug("Checking out source code of application #{application} with type #{deploy[:application_type]}")
    deploy deploy[:deploy_to] do
      provider Chef::Provider::Deploy.const_get(deploy[:chef_provider])
      if deploy[:keep_releases]
        keep_releases deploy[:keep_releases]
      end
      repository app_config[:scm][:repository]
      user deploy[:user]
      group deploy[:group]
      revision app_config[:scm][:revision]
      migrate deploy[:migrate]
      migration_command deploy[:migrate_command]
      environment deploy[:environment].to_hash
      symlink_before_migrate( deploy[:symlink_before_migrate] )
      action deploy[:action]

      case app_config[:scm][:scm_type].to_s
      when 'git'
        scm_provider :git
        enable_submodules deploy[:enable_submodules]
        shallow_clone deploy[:shallow_clone]
      when 'svn'
        scm_provider :subversion
        svn_username app_config[:scm][:user]
        svn_password app_config[:scm][:password]
        svn_arguments "--no-auth-cache --non-interactive --trust-server-cert"
        svn_info_args "--no-auth-cache --non-interactive --trust-server-cert"
      else
        raise "unsupported SCM type #{app_config[:scm][:scm_type].inspect}"
      end
      
      before_restart do
        bash "Restart Node" do
          user "root"
          code <<-EOH
          monit restart node_web_app_#{app_slug_name}
          EOH
        end
      end

      before_migrate do
        # Check if domain name is set
        if deploy[:domains].length == 0
          Chef::Log.debug("Skipping Meteor installation of #{app_slug_name}. App does not have any domains configured.")
          next
        end

        # Set domain_name from custom_env JSON to construct $ROOT_URL 
        domain_name = deploy[:domain_name]

        if deploy[:ssl_support]
          protocol_prefix = "https://"
          port = 443 
        else
          protocol_prefix = "http://"
          port = 80
        end

        tmp_dir = "/tmp/meteor_tmp"
        repo_dir = "#{deploy[:deploy_to]}/shared/cached-copy"

        # Set $MONGO_URL from custom_env JSON 
        mongo_url = app_config[:mongo_url]

        bash "Deploy Meteor" do
          code <<-EOH
          # Install Demeteorizer
          npm install -g demeteorizer

          # Reset the Meteor temp directory
          rm -rf #{tmp_dir}
          mkdir -p #{tmp_dir}

          # Move files to the temp directory
          cp -R #{repo_dir}/. #{tmp_dir}

          # Demeteorize app
          cd #{tmp_dir}
          demeteorizer -t app.tar.gz

          # Copy the app archive to the release directory and uncompress
          cp #{tmp_dir}/app.tar.gz #{release_path}
          cd #{release_path}
          tar -xzvf app.tar.gz
          
          # Build npm dependencies
          npm install

          # Rename main.js to server.js for opsworks
          mv main.js server.js

          # OpsWorks expects a server.js file
          echo 'process.env.ROOT_URL  = "#{protocol_prefix}#{domain_name}";' > ./server.js
          echo 'process.env.MONGO_URL = "#{mongo_url}";' >> ./server.js
          echo 'process.env.PORT = #{port};' >> ./server.js
          echo 'require("./main.js");' >> ./server.js
          chown deploy:www-data ./server.js

          # Remove the temp directory
          rm -rf #{tmp_dir}
          EOH
        end

        link_tempfiles_to_current_release

        if deploy[:auto_npm_install_on_deploy]
          OpsWorks::NodejsConfiguration.npm_install(application, node[:deploy][application], release_path)
        end

        # run user provided callback file
        run_callback_from_file("#{release_path}/deploy/before_migrate.rb")
      end
    end
  end

  ruby_block "change HOME back to /root after source checkout" do
    block do
      ENV['HOME'] = "/root"
    end
  end

  template "/etc/logrotate.d/opsworks_app_#{application}" do
    backup false
    source "logrotate.erb"
    cookbook 'deploy'
    owner "root"
    group "root"
    mode 0644
    variables( :log_dirs => ["#{deploy[:deploy_to]}/shared/log" ] )
  end
end
