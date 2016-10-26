#!/usr/bin/env ruby

require 'timeout'
require 'logger'
require '../lib/uc6_connector'


begin

  logger = Logger.new(STDOUT)
  logger.level = Logger::DEBUG
  logger.info("Initializing the Meter...")

  #Create the datastore and set the configuration options
  datastore = Datastore.new
  
  # Retrieve configuration from kubernetes secrets
  datastore.organization.remote_id = File.read('/var/run/secrets/uc6/organizationid') if File.exist?('/var/run/secrets/uc6/organizationid')
  datastore.kubernetes_token = File.read('/var/run/secrets/kubernetes.io/serviceaccount/token') if File.exist?('/var/run/secrets/kubernetes.io/serviceaccount/token')
  datastore.uc6_host = File.read('/var/run/secrets/uc6/host') if File.exist?('/var/run/secrets/uc6/host')
  datastore.uc6_port = File.read('/var/run/secrets/uc6/port') if File.exist?('/var/run/secrets/uc6/port')
  datastore.uc6_token = File.read('/var/run/secrets/uc6/token') if File.exist?('/var/run/secrets/uc6/token')
  datastore.uc6_insecure = File.read('/var/run/secrets/uc6/insecure') if File.exist?('/var/run/secrets/uc6/insecure')
  datastore.kubelet_insecure = File.read('/var/run/secrets/kubelet/port') if File.exist?('/var/run/secrets/kubelet/port')
  datastore.kubelet_insecure = File.read('/var/run/secrets/kubelet/insecure') if File.exist?('/var/run/secrets/kubelet/insecure')
  
  # Retrieve configuration from environment variables
  datastore.organization.remote_id = ENV["ORGANIZATIONID"] unless ENV["ORGANIZATIONID"].nil?
  datastore.kubernetes_host = ENV["KUBERNETES_SERVICE_HOST"] unless ENV["KUBERNETES_SERVICE_HOST"].nil?
  datastore.kubernetes_port = ENV["KUBERNETES_PORT_443_TCP_PORT"] unless ENV["KUBERNETES_PORT_443_TCP_PORT"].nil?
  datastore.kubernetes_token = ENV["KUBERNETES_TOKEN"] unless ENV["KUBERNETES_TOKEN"].nil?
  datastore.kubernetes_insecure = ENV["KUBERNETES_INSECURE"] unless ENV["KUBERNETES_INSECURE"].nil?
  datastore.uc6_host = ENV["UC6_SERVICE_HOST"] unless ENV["UC6_SERVICE_HOST"].nil?
  datastore.uc6_port = ENV["UC6_PORT_443_TCP_PORT"] unless ENV["UC6_PORT_443_TCP_PORT"].nil?
  datastore.uc6_token = ENV["UC6_TOKEN"] unless ENV["UC6_TOKEN"].nil?
  datastore.uc6_insecure = ENV["UC6_INSECURE"] unless ENV["UC6_INSECURE"].nil?
  datastore.kubelet_port = ENV["KUBELET_PORT_443_TCP_PORT"] unless ENV["KUBELET_PORT_443_TCP_PORT"].nil?
  datastore.kubelet_insecure = ENV["KUBELET_INSECURE"] unless ENV["KUBELET_INSECURE"].nil?
  
  # Retrieve configuration from command line arguments 
  datastore.organization.remote_id = ARGV[0] unless ARGV.empty?
  datastore.kubernetes_host = ARGV[1] unless ARGV.empty?
  datastore.kubernetes_port = ARGV[2] unless ARGV.empty?
  datastore.kubernetes_token = ARGV[3] unless ARGV.empty?
  datastore.kubernetes_insecure = ARGV[4] unless ARGV.empty?
  datastore.uc6_host = ARGV[4] unless ARGV.empty?
  datastore.uc6_port = ARGV[6] unless ARGV.empty?
  datastore.uc6_token = ARGV[7] unless ARGV.empty?
  datastore.uc6_insecure = ARGV[8] unless ARGV.empty?
  datastore.kubelet_port = ARGV[9] unless ARGV.empty?
  datastore.kubelet_insecure = ARGV[10] unless ARGV.empty?
  
  # Check configuration and throw error if invalid
  errors = []
  errors << "Organization ID is missing" unless datastore.organization.remote_id
  errors << "Kubernetes master host is missing" unless datastore.kubernetes_host
  errors << "Kubernetes master port is missing" unless datastore.kubernetes_port
  errors << "UC6 host is missing" unless datastore.uc6_host
  errors << "UC6 port is missing" unless datastore.uc6_port
  errors << "UC6 token is missing" unless datastore.uc6_token
  if errors.size > 0
    errors.each { |error| logger.fatal(error) }
    raise "Meter configuration could not be loaded"
  end

  # Instantiate collectors and connectors
  uc6_connector = UC6Connector.new(logger, datastore)
  inventory_collector = InventoryCollector.new(logger, datastore)
  metrics_collector = MetricsCollector.new(logger, datastore)
  sync_required = true

  logger.info("Meter Initialization completed successfully...")
  logger.debug("-----start of configuration-----")
  logger.debug("  organization_id: #{datastore.organization.remote_id}")
  logger.debug("  kubernetes_host: #{datastore.kubernetes_host}")
  logger.debug("  kubernetes_port: #{datastore.kubernetes_port}")
  logger.debug("  kubernetes_token: #{datastore.kubernetes_token}")
  logger.debug("  kubernetes_insecure: #{datastore.kubernetes_insecure}")
  logger.debug("  uc6_host: #{datastore.uc6_host}")
  logger.debug("  uc6_port: #{datastore.uc6_port}")
  logger.debug("  uc6_token: #{datastore.uc6_token}")
  logger.debug("  uc6_insecure: #{datastore.uc6_insecure}")
  logger.debug("  kubelet_port: #{datastore.kubelet_port}")
  logger.debug("  kubelet_insecure: #{datastore.kubelet_insecure}")
  logger.debug("-----end of configuration-----")

  # Start the Meter
  while true do
    logger.info("Meter Starting...")

    logger.info('Collecting inventory...')
    inventory_collector.run

    logger.info('Collecting metrics...')
    metrics_collector.run

   if Time.now.min % 5 == 0
      if sync_required
        logger.info('Submitting data to 6fusion via UC6 Connector...')
        uc6_connector.run
      end
      sync_required = false
    else
      sync_required = true
    end

    logger.info('Waiting for the next collection interval....')
    sleep 10
  end

rescue StandardError => e
  logger.fatal("Meter was unable to start.")
  logger.debug("#{e.message}")
  logger.debug("Backtrace : #{e.backtrace}")
end