require 'rest-client'
require 'logger'
require '../lib/model/datastore'
require '../lib/model/organization'
require '../lib/model/billing_group'
require '../lib/model/infrastructure'
require '../lib/model/machine'
require '../lib/model/disk'
require '../lib/model/nic'
require '../lib/model/machine_reading'
require '../lib/model/disk_reading'
require '../lib/model/nic_reading'

class MetricsCollector
  private
  
  attr_accessor :datastore, :logger, :kubelet_protocol, :kubelet_port
  
  public

  attr_accessor :containers, :readings

  def initialize(logger, datastore)
    @logger = logger
    @logger.debug("Initializing the Metrics Collector...")
    @datastore = datastore
    @kubelet_protocol = datastore.kubelet_insecure ? 'http' : 'https'
    @kubelet_port = datastore.kubelet_port
    @logger.debug("Metrics Collector initialized successfully.")
  end

  def run
    begin
      reset_statistics
      collect_metrics
      @logger.info("Collected #{@readings} Readings for #{@containers} Containers")
      @logger.info('Metrics collected successfully.')
    rescue StandardError => e
      @logger.fatal("Metrics collection failed.")
      @logger.debug("#{e.message}")
      @logger.debug("#{e.backtrace}")
    end
  end

  def reset_statistics
    @containers = 0
    @readings = 0
  end

  def collect_metrics
    metrics = {}
    datastore.infrastructure.hosts.keys.each do |host_ip|
      payload = '{"containerName":"/system.slice/docker-","subcontainers":true,"num_stats":11}'
      response = RestClient::Request.execute(:url => "#{@kubelet_protocol}://#{host_ip}:#{@kubelet_port}/stats/container", :method => :post, :payload => payload, accept: :json, content_type: :json)
      response_hash = JSON.parse(response.body)
      metrics.merge!(response_hash)
    end

    @datastore.machines.values.each do |machine|
      @logger.debug("Collecting metrics for #{machine.name} container...")
      readings = metrics["#{machine.platform_meter_id}"]
      
      if readings
        readings["stats"].each do |reading|
          
          # Set the current reading for each machine
          current_reading = {}
          current_reading.default = 0

          current_reading["timestamp"] = reading["timestamp"]
          if reading["has_cpu"]
            unless reading["cpu"].empty?
              current_reading["cpu_usage"] = reading["cpu"]["usage"]["total"] 
            end
          end
          if reading["has_memory"]
            unless reading["memory"].empty?
              current_reading["memory_usage"] = reading["memory"]["usage"]
            end 
          end
          if reading["has_diskio"]
            unless reading["diskio"].empty?
              current_reading["diskio_bytes_read"] = reading["diskio"]["io_service_bytes"][0]["stats"]["Read"]
              current_reading["diskio_bytes_write"] = reading["diskio"]["io_service_bytes"][0]["stats"]["Write"]
            end
          end
          if reading["has_network"]
            unless reading["network"].empty?
              current_reading["network_bytes_receive"] = reading["network"]["interfaces"][0]["rx_bytes"]
              current_reading["network_bytes_transmit"] = reading["network"]["interfaces"][0]["tx_bytes"]
            end
          end
          if reading["has_filesystem"]
            unless reading["filesystem"].empty?
              current_reading["usage_bytes"] = reading["filesystem"][0]["usage"]
            end
          end

          if machine.previous_reading
            # Collect the reading for machine
            machine_reading = MachineReading.new
            disk_reading = DiskReading.new
            nic_reading = NICReading.new

            # Set the machine reading
            machine_reading.reading_at = current_reading["timestamp"]
            machine_reading.cpu_usage_percent = ((current_reading["cpu_usage"] - machine.previous_reading["cpu_usage"]).abs / (1000000000.0 * machine.cpu_count)) * 100
            machine_reading.memory_bytes = current_reading["memory_usage"]
          
            #Set the disk reading
            disk_reading.reading_at = current_reading["timestamp"]
            disk_reading.usage_bytes = current_reading["usage_bytes"]
            disk_reading.read_kilobytes = (current_reading["diskio_bytes_read"] - machine.previous_reading["diskio_bytes_read"]).abs / 1024
            disk_reading.write_kilobytes = (current_reading["diskio_bytes_write"] - machine.previous_reading["diskio_bytes_write"]).abs / 1024
            
            #Set the nic reading
            nic_reading.reading_at = current_reading["timestamp"]
            nic_reading.receive_kilobits = (current_reading["network_bytes_receive"] - machine.previous_reading["network_bytes_receive"]) * 8 / 1000
            nic_reading.transmit_kilobits = (current_reading["network_bytes_transmit"] - machine.previous_reading["network_bytes_transmit"]) * 8 / 1000
        
            # Add readings to machine
            machine.readings << machine_reading
            machine.disks["disk-#{machine.platform_id[0...8]}"].readings << disk_reading
            machine.nics["nic-#{machine.platform_id[0...8]}"].readings << nic_reading
          end

          # Set the previous reading for each machine
          machine.previous_reading = {}
          machine.previous_reading.default = 0
          machine.previous_reading["cpu_usage"] = current_reading["cpu_usage"]
          machine.previous_reading["memory_usage"] = current_reading["memory_usage"]
          machine.previous_reading["usage_bytes"] = current_reading["usage_bytes"]
          machine.previous_reading["diskio_bytes_read"] = current_reading["diskio_bytes_read"]
          machine.previous_reading["diskio_bytes_write"] = current_reading["diskio_bytes_write"]
          machine.previous_reading["network_bytes_receive"] = current_reading["network_bytes_receive"]
          machine.previous_reading["network_bytes_transmit"] = current_reading["network_bytes_transmit"]
          
          @readings += 1
        end
      end
      @logger.debug("Collected metrics for #{machine.name} successfully.")
      @containers += 1
    end
    metrics.count
  end

end