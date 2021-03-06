#
# Author:: Sean OMeara (<sean@sean.io>)
#
# Copyright (C) 2015, Sean OMeara
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'digest'
require 'kitchen'
require 'tmpdir'
require 'docker'
require_relative '../helpers'

include Dokken::Helpers

# FIXME: - make true
Excon.defaults[:ssl_verify_peer] = false

module Kitchen
  module Driver
    # Dokken driver for Kitchen.
    #
    # @author Sean OMeara <sean@sean.io>
    class Dokken < Kitchen::Driver::Base
      default_config :api_retries, 20
      default_config :binds, []
      default_config :cap_add, nil
      default_config :cap_drop, nil
      default_config :chef_image, 'chef/chef'
      default_config :chef_version, 'latest'
      default_config :data_image, 'dokken/kitchen-cache:latest'
      default_config :dns, nil
      default_config :dns_search, nil
      default_config :docker_host_url, default_docker_host
      default_config :forward, nil
      default_config :hostname, nil
      default_config :image_prefix, nil
      default_config :links, nil
      default_config :network_mode, 'bridge'
      default_config :pid_one_command, 'sh -c "trap exit 0 SIGTERM; while :; do sleep 1; done"'
      default_config :privileged, false
      default_config :read_timeout, 3600
      default_config :security_opt, nil
      default_config :volumes, nil
      default_config :write_timeout, 3600

      # (see Base#create)
      def create(state)
        # image to config
        pull_platform_image

        # chef
        pull_chef_image
        create_chef_container state

        # data
        dokken_create_sandbox

        if remote_docker_host?
          make_data_image
          start_data_container state
        end

        # work image
        build_work_image state

        # runner
        start_runner_container state

        # misc
        save_misc_state state
      end

      def destroy(_state)
        if remote_docker_host?
          stop_data_container
          delete_data_container
        end

        stop_runner_container
        delete_runner_container
        delete_work_image
        dokken_delete_sandbox
      end

      private

      def remote_docker_host?
        return true if config[:docker_host_url] =~ /^tcp:/
        false
      end

      def api_retries
        config[:api_retries]
      end

      def docker_connection
        opts = ::Docker.options
        opts[:read_timeout] = config[:read_timeout]
        opts[:write_timeout] = config[:write_timeout]
        @docker_connection ||= ::Docker::Connection.new(config[:docker_host_url], opts)
      end

      def delete_work_image
        return unless ::Docker::Image.exist?(work_image, {}, docker_connection)
        with_retries { @work_image = ::Docker::Image.get(work_image, {}, docker_connection) }

        begin
          with_retries { @work_image.remove(force: true) }
        rescue ::Docker::Error::ConflictError
          debug "driver - #{work_image} cannot be removed"
        end
      end

      def build_work_image(state)
        info('Building work image..')
        return if ::Docker::Image.exist?(work_image, {}, docker_connection)

        begin
          @intermediate_image = ::Docker::Image.build(
            work_image_dockerfile,
            {
              't' => work_image,
            },
            docker_connection
          )
        rescue
          raise 'work_image build failed'
        end

        state[:work_image] = work_image
      end

      def work_image_dockerfile
        from = "FROM #{platform_image}"
        custom = ['RUN /bin/sh -c "echo Built with Test Kitchen"']
        Array(config[:intermediate_instructions]).each { |c| custom << c }
        [from, custom].join("\n")
      end

      def save_misc_state(state)
        state[:platform_image] = platform_image
        state[:instance_name] = instance_name
        state[:instance_platform_name] = instance_platform_name
        state[:image_prefix] = image_prefix
      end

      def delete_chef_container
        debug "driver - deleting container #{chef_container_name}"
        delete_container chef_container_name
      end

      def delete_data_container
        debug "driver - deleting container #{data_container_name}"
        delete_container data_container_name
      end

      def delete_runner_container
        debug "driver - deleting container #{runner_container_name}"
        delete_container runner_container_name
      end

      def image_prefix
        config[:image_prefix]
      end

      def instance_platform_name
        instance.platform.name
      end

      def stop_runner_container
        debug "driver - stopping container #{runner_container_name}"
        stop_container runner_container_name
      end

      def stop_data_container
        debug "driver - stopping container #{data_container_name}"
        stop_container data_container_name
      end

      def work_image
        return "#{image_prefix}/#{instance_name}" unless image_prefix.nil?
        instance_name
      end

      class PartialHash < Hash
        def ==(other)
          other.is_a?(Hash) && all? { |key, val| other.key?(key) && other[key] == val }
        end
      end

      def dokken_binds
        ret = []
        ret << "#{dokken_kitchen_sandbox}:/opt/kitchen" unless dokken_kitchen_sandbox.nil?
        ret << "#{dokken_verifier_sandbox}:/opt/verifier" unless dokken_verifier_sandbox.nil?
        ret << Array(config[:binds]) unless config[:binds].nil?
        ret.flatten
      end

      def dokken_volumes
        coerce_volumes(config[:volumes])
      end

      def coerce_volumes(v)
        case v
        when PartialHash, nil
          v
        when Hash
          PartialHash[v]
        else
          b = []
          v = Array(v).to_a # in case v.is_A?(Chef::Node::ImmutableArray)
          v.delete_if do |x|
            parts = x.split(':')
            b << x if parts.length > 1
          end
          b = nil if b.empty?
          config[:binds].push(b) unless config[:binds].include?(b) || b.nil?
          return PartialHash.new if v.empty?
          v.each_with_object(PartialHash.new) { |volume, h| h[volume] = {} }
        end
      end

      def dokken_volumes_from
        ret = []
        ret << chef_container_name
        ret << data_container_name if remote_docker_host?
        ret
      end

      def start_runner_container(state)
        debug "driver - starting #{runner_container_name}"

        runner_container = run_container(
          'name' => runner_container_name,
          'Cmd' => Shellwords.shellwords(config[:pid_one_command]),
          'Image' => "#{repo(work_image)}:#{tag(work_image)}",
          'Hostname' => config[:hostname],
          'ExposedPorts' => exposed_ports({}, config[:forward]),
          'Volumes' => dokken_volumes,
          'HostConfig' => {
            'Privileged' => config[:privileged],
            'VolumesFrom' => dokken_volumes_from,
            'Binds' => dokken_binds,
            'Dns' => config[:dns],
            'DnsSearch' => config[:dns_search],
            'Links' => Array(config[:links]),
            'CapAdd' => Array(config[:cap_add]),
            'CapDrop' => Array(config[:cap_drop]),
            'SecurityOpt' => Array(config[:security_opt]),
            'NetworkMode' => config[:network_mode],
            'PortBindings' => port_forwards({}, config[:forward]),
          }
        )
        state[:runner_container] = runner_container.json
      end

      def start_data_container(state)
        debug "driver - creating #{data_container_name}"
        data_container = run_container(
          'name' => data_container_name,
          'Image' => "#{repo(data_image)}:#{tag(data_image)}",
          'HostConfig' => {
            'PortBindings' => port_forwards({}, '22'),
            'PublishAllPorts' => true,
          }
        )
        state[:data_container] = data_container.json
      end

      def make_data_image
        debug 'driver - calling create_data_image'
        create_data_image
      end

      def create_chef_container(state)
        ::Docker::Container.get(chef_container_name, {}, docker_connection)
      rescue ::Docker::Error::NotFoundError
        begin
          debug "driver - creating volume container #{chef_container_name} from #{chef_image}"
          chef_container = create_container(
            'name' => chef_container_name,
            'Cmd' => 'true',
            'Image' => "#{repo(chef_image)}:#{tag(chef_image)}"
          )
          state[:chef_container] = chef_container.json
        rescue
          debug "driver - #{chef_container_name} already exists"
        end
      end

      def pull_platform_image
        debug "driver - pulling #{chef_image} #{repo(platform_image)} #{tag(platform_image)}"
        pull_if_missing platform_image
      end

      def pull_chef_image
        debug "driver - pulling #{chef_image} #{repo(chef_image)} #{tag(chef_image)}"
        pull_if_missing chef_image
      end

      def delete_image(name)
        with_retries { @image = ::Docker::Image.get(name, {}, docker_connection) }
        with_retries { @image.remove(force: true) }
      rescue ::Docker::Error
        puts "Image #{name} not found. Nothing to delete."
      end

      def container_exist?(name)
        return true if ::Docker::Container.get(name, {}, docker_connection)
      rescue
        false
      end

      def parse_image_name(image)
        parts = image.split(':')

        if parts.size > 2
          tag = parts.pop
          repo = parts.join(':')
        else
          tag = parts[1] || 'latest'
          repo = parts[0]
        end

        [repo, tag]
      end

      def repo(image)
        parse_image_name(image)[0]
      end

      def create_container(args)
        with_retries do
          @container = ::Docker::Container.create(args.clone, docker_connection)
          @container = ::Docker::Container.get(args['name'], {}, docker_connection)
        end
      rescue ::Docker::Error::ConflictError
        with_retries { @container = ::Docker::Container.get(args['name'], {}, docker_connection) }
      end

      def run_container(args)
        create_container(args)
        with_retries do
          @container.start
          @container = ::Docker::Container.get(args['name'], {}, docker_connection)
          wait_running_state(args['name'], true)
        end
        @container
      end

      def container_state
        @container ? @container.info['State'] : {}
      end

      def stop_container(name)
        with_retries { @container = ::Docker::Container.get(name, {}, docker_connection) }
        with_retries do
          @container.stop(force: false)
          wait_running_state(name, false)
        end
      rescue ::Docker::Error::NotFoundError
        debug "Container #{name} not found. Nothing to stop."
      end

      def delete_container(name)
        with_retries { @container = ::Docker::Container.get(name, {}, docker_connection) }
        with_retries { @container.delete(force: true, v: true) }
      rescue ::Docker::Error::NotFoundError
        debug "Container #{name} not found. Nothing to delete."
      end

      def wait_running_state(name, v)
        @container = ::Docker::Container.get(name, {}, docker_connection)
        i = 0
        tries = 20
        until container_state['Running'] == v || container_state['FinishedAt'] != '0001-01-01T00:00:00Z'
          i += 1
          break if i == tries
          sleep 0.1
          @container = ::Docker::Container.get(name, {}, docker_connection)
        end
      end

      def tag(image)
        parse_image_name(image)[1]
      end

      def chef_container_name
        "chef-#{chef_version}"
      end

      def chef_image
        "#{config[:chef_image]}:#{chef_version}"
      end

      def chef_version
        return 'latest' if config[:chef_version] == 'stable'
        config[:chef_version]
      end

      def data_container_name
        "#{instance_name}-data"
      end

      def data_image
        config[:data_image]
      end

      def platform_image
        config[:image]
      end

      def exposed_ports(config, rules)
        Array(rules).each do |prt_string|
          guest, _host = prt_string.to_s.split(':').reverse
          config["#{guest}/tcp"] = {}
        end
        config
      end

      def port_forwards(config, rules)
        Array(rules).each do |prt_string|
          guest, host = prt_string.to_s.split(':').reverse
          config["#{guest}/tcp"] = [{
            HostPort: host || '',
          }]
        end
        config
      end

      def pull_if_missing(image)
        return if ::Docker::Image.exist?("#{repo(image)}:#{tag(image)}", {}, docker_connection)
        pull_image image
      end

      def pull_image(image)
        with_retries do
          ::Docker::Image.create({ 'fromImage' => "#{repo(image)}:#{tag(image)}" }, nil, docker_connection)
        end
      end

      def runner_container_name
        instance_name.to_s
      end

      def with_retries
        tries = api_retries
        begin
          yield
        # Only catch errors that can be fixed with retries.
        rescue ::Docker::Error::ServerError, # 404
               ::Docker::Error::UnexpectedResponseError, # 400
               ::Docker::Error::TimeoutError,
               ::Docker::Error::IOError => e
          tries -= 1
          retry if tries > 0
          raise e
        end
      end
    end
  end
end
