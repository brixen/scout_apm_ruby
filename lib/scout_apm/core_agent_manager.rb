require 'minitar'
require 'fileutils'

module ScoutApm
  class CoreAgentManager
    attr_reader :logger
    attr_reader :context

    def initialize(context)
      @context = context
      @logger = context.logger
      @core_agent_bin_path = nil
      @core_agent_bin_version = nil
      # core_agent_full_name: scout_apm_core-latest-x86_64-apple-darwin.tgz
      @core_agent_full_name = "scout_apm_core-#{context.config.value('core_agent_version')}-#{ScoutApm::Environment.instance.arch}-#{ScoutApm::Environment.instance.core_agent_platform}"
      @core_agent_dir = "#{context.config.value('core_agent_dir')}/#{@core_agent_full_name}"
      @downloader = ScoutApm::CoreAgentDownloader.new(context, @core_agent_dir, @core_agent_full_name)
    end

    def launch
      if !context.config.value('core_agent_launch')
        logger.debug("Not attempting to launch Core Agent due to 'core_agent_launch' setting.")
        return
      end

      if !verify
        if context.config.value('core_agent_download')
          download
        else
          logger.debug("Not attempting to download Core Agent due to 'core_agent_download' setting.")
        end
      end

      if !verify
        logger.debug("Failed to verify Core Agent. Not launching Core Agent.")
        return false
      end

      return run
    end

    def download
      @downloader.download
    end

    def run
      process = IO.popen(agent_binary +
                        daemonize_flag +
                        log_level +
                        log_file +
                        config_file +
                        socket_path)
      Process.wait(process.pid)
      rescue StandardError => e
          # TODO detect failure of launch properly
          logger.error("Error running Core Agent: #{e}")
          return false
      return true
    end

    def agent_binary
      return [@core_agent_bin_path, 'start']
    end

    def daemonize_flag
      return ['--daemonize', 'true']
    end

    def socket_path
      socket_path = context.config.value('socket_path')
      return ['--socket', socket_path]
    end

    def log_level
      level = context.config.value('log_level')
      return ['--log-level', level]
    end

    def log_file
      if path = context.config.value('log_file')
        return ['--log-file', path]
      else
        return []
      end
    end

    def config_file
      if path = context.config.value('config_file')
        return ['--config-file', path]
      else
        return []
      end
    end

    def verify
      manifest = ScoutApm::CoreAgentManifest.new(context, @core_agent_dir + '/manifest.json')
      if !manifest.valid?
        logger.debug('Core Agent verification failed: CoreAgentManifest is not valid.')
        @core_agent_bin_path = nil
        @core_agent_bin_version = nil
        return false
      end

      bin_path = @core_agent_dir + '/' + manifest.bin_name
      if digest(bin_path) == manifest.sha256
        @core_agent_bin_path = bin_path
        @core_agent_bin_version = manifest.bin_version
        return true
      else
        logger.debug('Core Agent verification failed: SHA mismatch.')
        @core_agent_bin_path = nil
        @core_agent_bin_version = nil
        return false
      end
    end

    def digest(bin_path)
      sha256 = Digest::SHA256.new
      f = File.open(bin_path, 'rb')
      until f.eof?
        sha256 << f.read(65536)
      end
      return sha256.hexdigest
    rescue StandardError => e
      logger.debug("Error on digest: #{e}")
      return nil
    end
  end
end

module ScoutApm
  class CoreAgentDownloader
    attr_reader :logger
    attr_reader :context

    def initialize(context, download_destination, core_agent_full_name)
      @context = context
      @logger = context.logger

      @destination = download_destination
      @core_agent_full_name = core_agent_full_name
      @package_location = @destination + "/#{@core_agent_full_name}.tgz"
      @download_lock_path = @destination + '/download.lock'
      @download_lock_fd = nil
      @stale_download_secs = 120
    end

    def download
      create_core_agent_dir
      obtain_download_lock
      if @download_lock_fd
          download_package
          untar
      end
    rescue StandardError => e
      logger.error("Exception raised while downloading Core Agent: #{e}")
    ensure
      release_download_lock
    end

    def create_core_agent_dir
      FileUtils.makedirs(@destination)
      FileUtils.chmod_R(0700, @destination)
    rescue StandardError => e
      # Do Nothing
    end

    def obtain_download_lock
      clean_stale_download_lock
      @download_lock_fd = File.open(@download_lock_path, File::RDWR | File::CREAT | File::EXCL | File::NONBLOCK)
    rescue StandardError => e
      logger.debug("Could not obtain download lock on #{@download_lock_path}: #{e}")
      @download_lock_fd = nil
    end

    def clean_stale_download_lock
      delta = Time.now - File.stat(@download_lock_path).ctime
      if delta > @stale_download_secs
        logger.debug("Clearing stale download lock file.")
        File.unlink(@download_lock_path)
      end
    rescue StandardError
      # Do nothing
    end

    def release_download_lock
      if @download_lock_fd
        File.unlink(@download_lock_path)
        @download_lock_fd.close
      end
    end

    def download_package
      logger.debug("Downloading: #{full_url} to #{@package_location}")
      uri = URI(full_url)
      Net::HTTP.start(uri.host, uri.port, :use_ssl => uri.scheme == 'https') do |http|
        request = Net::HTTP::Get.new uri

        http.request request do |response|
          open @package_location, 'wb' do |io|
            response.read_body do |chunk|
              io.write chunk
            end
          end
        end
      end # Net::HTTP.start
    end

    def untar
      Minitar.unpack(Zlib::GzipReader.new(File.open(@package_location, 'rb')), @destination)
    end

    def full_url
      return "#{root_url}/#{@core_agent_full_name}.tgz"
    end

    def root_url
      return context.config.value('download_url')
    end
  end
end

module ScoutApm
  class CoreAgentManifest
    attr_reader :logger
    attr_reader :context

    attr_reader :bin_name
    attr_reader :bin_version
    attr_reader :sha256

    def initialize(context, path)
      @context = context
      @logger = context.logger

      @manifest_path = path
      @bin_name = nil
      @bin_version = nil
      @sha256 = nil
      @valid = false
      parse
    rescue StandardError => e
      logger.debug("Error parsing Core Agent Manifest: #{e}")
    end

    def parse
      logger.debug("Parsing Core Agent manifest path: #{@manifest_path}")
      manifest_file = File.open(@manifest_path)
      @raw = manifest_file.read
      @json = JSON.parse(@raw)
      @version = @json['version']
      @bin_version = @json['core_agent_version']
      @bin_name = @json['core_agent_binary']
      @sha256 = @json['core_agent_binary_sha256']
      @valid = true
      logger.debug("Core Agent manifest json: #{@json}")
    end

    def valid?
      @valid
    end
  end
end