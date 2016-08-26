require 'rest-client'
require 'logger'
require '../lib/inventory_collector'
require '../lib/metrics_collector'
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

class UC6Connector
  private
  
  attr_accessor :datastore, :logger, :uc6_protocol, :uc6_token, :collate_machines, :terminated_containers

  public

  attr_accessor :created_infrastructures, :created_billing_groups, :created_machines
  attr_accessor :updated_infrastructures, :updated_billing_groups, :updated_machines
  attr_accessor :deleted_infrastructures, :deleted_billing_groups, :deleted_machines
  attr_accessor :readings_submitted, :errors

  def initialize(logger, datastore)
    @logger = logger
    @logger.debug("Initializing the UC6 connector...")
    @datastore = datastore
    @uc6_protocol = datastore.uc6_insecure ? 'http' : 'https'
    @uc6_token = @datastore.uc6_token
    @terminated_containers = {}
    @logger.debug("UC6 connector initialized successfully.")
    @uc6_base_url = "#{@uc6_protocol}://#{@datastore.uc6_host}:#{@datastore.uc6_port}/api/v2"
  end

  def run
    begin
      reset_statistics

      @logger.debug("Syncing Billing Groups...")
      sync_billing_groups
      @logger.info("Billing Groups sync completed successfully...")

      @logger.info("Syncing Infrastructures...")
      sync_infrastructures
      @logger.info("Infrastructures sync completed successfully...")

      @logger.info("Syncing machines...")
      sync_machines
      @logger.info("Machines sync completed successfully...")

      @datastore.reset_inventory

      @logger.info("Created #{@created_infrastructures} Infrastructures, #{@created_billing_groups} Billing Groups, #{@created_machines} Machines")
      @logger.info("Updated #{@updated_infrastructures} Infrastructures, #{@updated_billing_groups} Billing Groups, #{@updated_machines} Machines")
      @logger.info("Deleted #{@deleted_infrastructures} Infrastructures, #{@deleted_billing_groups} Billing Groups, #{@deleted_machines} Machines")
      @logger.info("Submitted #{@readings_submitted} Readings")
      @errors > 0 ? @logger.info('Data Submission completed with errors.') : @logger.info('Data Submission completed successfully.')
    rescue StandardError => e
      @logger.fatal("Data submission failed.")
      @logger.debug("#{e.message}")
      @logger.debug("#{e.backtrace}")
    end
  end

  def reset_statistics
    #created
    @created_infrastructures = 0
    @created_billing_groups = 0
    @created_machines = 0

    #Updated
    @updated_infrastructures = 0
    @updated_billing_groups = 0
    @updated_machines = 0

    #Deleted
    @deleted_infrastructures = 0
    @deleted_billing_groups = 0
    @deleted_machines = 0

    #submitted
    @readings_submitted = 0

    #Errors
    @errors = 0

  end

  def sync_billing_groups
    @datastore.billing_groups.values.each do |billing_group|
      begin
        if billing_group.remote_id
          update_billing_group(billing_group)
        else
          response = RestClient::Request.execute(:url => "#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/billing_groups?and={\"name\":{\"eq\":\"#{billing_group.name}\"}}&fields=remote_id&access_token=#{@uc6_token}", :method => :get)
          response_hash = JSON.parse(response.body)
          if response_hash["embedded"]["billing_groups"].empty?
            create_billing_group(billing_group)
          else
            @datastore.billing_groups[billing_group.platform_id].remote_id = response_hash["embedded"]["billing_groups"].first["remote_id"]
            update_billing_group(billing_group)
          end
        end
      rescue StandardError => e
        @logger.fatal("Syncing billing group #{billing_group.name} failed.")
        @logger.debug("#{e.message}")
        @logger.debug("#{e.backtrace}")
        @logger.debug("#{billing_group.inspect}")
        @errors += 1
      end
    end
  end

  def sync_infrastructures
    begin
      if @datastore.infrastructure.remote_id
        update_infrastructure(@datastore.infrastructure)
      else
        response = RestClient::Request.execute(:url => "#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/infrastructures?and={\"name\":{\"eq\":\"#{@datastore.infrastructure.name}\"}}&fields=remote_id&access_token=#{@uc6_token}", :method => :get)
        response_hash = JSON.parse(response.body)
        if response_hash["embedded"]["infrastructures"].empty?
          create_infrastructure(@datastore.infrastructure)
        else
          @datastore.infrastructure.remote_id = response_hash["embedded"]["infrastructures"].first["remote_id"]
          update_infrastructure(@datastore.infrastructure)
        end
      end
    rescue StandardError => e
      @logger.fatal("Syncing infrastructure #{infrastructure.name} failed.")
      @logger.debug("#{e.message}")
      @logger.debug("#{e.backtrace}")
      @logger.debug("#{infrastructure.inspect}")
      @errors += 1
    end
  end

  def sync_machines
    collate_machines

    # Create/Update machines based on changes
    @datastore.machines.values.each do |machine|
      begin
        if machine.remote_id
          update_machine(machine)
        else
          create_machine(machine)
        end
        sync_machine_disks(machine)
        sync_machine_nics(machine)
        submit_readings(machine)
      rescue StandardError => e
        @logger.fatal("Syncing machine #{machine.name} failed.")
        @logger.debug("#{e.message}")
        @logger.debug("#{e.backtrace}")
        @logger.debug("#{machine.inspect}")
        @errors += 1
      end
    end

    # Delete machines that do not exist
    @terminated_containers.values.each do |machine|
      begin
        delete_machine(machine)
      rescue StandardError => e
        @logger.fatal("Deleting machine #{machine.name} failed.")
        @logger.debug("#{e.message}")
        @logger.debug("#{e.backtrace}")
        @logger.debug("#{machine.inspect}")
        @errors += 1
      end
    end
  end

  def sync_machine_disks(machine)
    begin
      machine.disks.values.each do |disk|
        if disk.remote_id
          update_machine_disk(machine, disk)
        else
          response = RestClient::Request.execute(:url => "#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/infrastructures/#{@datastore.infrastructure.remote_id}/machines/#{machine.remote_id}/disks?and={\"name\":{\"eq\":\"#{disk.name}\"}}&fields=remote_id&access_token=#{@uc6_token}", :method => :get)
          response_hash = JSON.parse(response.body)
          if response_hash["embedded"]["disks"].empty?
            create_machine_disk(machine, disk)
          else
            @datastore.machines[machine.platform_id].disks[disk.name].remote_id = response_hash["embedded"]["disks"].first["remote_id"]
            update_machine_disk(machine, disk)
          end
        end
      end
    rescue StandardError => e
      @logger.fatal("Syncing machine disks for machine #{machine.name} failed.")
      @logger.debug("#{e.message}")
      @logger.debug("#{e.backtrace}")
      @errors += 1
    end
  end

  def sync_machine_nics(machine)
    begin
      machine.nics.values.each do |nic|
        if nic.remote_id
          update_machine_nic(machine, nic)
        else
          response = RestClient::Request.execute(:url => "#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/infrastructures/#{@datastore.infrastructure.remote_id}/machines/#{machine.remote_id}/nics?and={\"name\":{\"eq\":\"#{nic.name}\"}}&fields=remote_id&access_token=#{@uc6_token}", :method => :get)
          response_hash = JSON.parse(response.body)
          if response_hash["embedded"]["nics"].empty?
            create_machine_nic(machine, nic)
          else
            @datastore.machines[machine.platform_id].nics[nic.name].remote_id = response_hash["embedded"]["nics"].first["remote_id"]
            update_machine_nic(machine, nic)
          end
        end
      end
    rescue StandardError => e
      @logger.fatal("Syncing machine nics for machine #{machine.name} failed.")
      @logger.debug("#{e.message}")
      @logger.debug("#{e.backtrace}")
      @errors += 1
    end
  end

  def submit_readings(machine)
    begin
      @logger.debug("Submitting readings for machine #{machine.name}...")
      payload = machine.to_readings_payload (Time.now.utc.iso8601)
      RestClient.post("#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/infrastructures/#{@datastore.infrastructure.remote_id}/machines/#{machine.remote_id}/readings?access_token=#{@uc6_token}", payload.to_json, accept: :json, content_type: :json)
      @logger.debug("Submitting readings for machine #{machine.name} completed successfully.")
      @readings_submitted += machine.readings.count
    rescue StandardError => e
      @logger.fatal("Submitting readings for machine #{machine.name} failed.")
      @logger.debug("#{e.message}")
      @logger.debug("#{e.backtrace}")
      @logger.debug("#{machine.inspect}")
      @errors += 1
    end
  end

  def create_infrastructure(infrastructure)
    @logger.debug("Creating infrastructure #{infrastructure.name}...")
    payload = @datastore.infrastructure.to_payload
    response = RestClient.post("#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/infrastructures?access_token=#{@uc6_token}", payload.to_json, accept: :json, content_type: :json)
    new_infrastructure = JSON.parse(response.body)
    @datastore.infrastructure.remote_id = new_infrastructure["remote_id"]
    @logger.debug("Creating infrastructure #{infrastructure.name} completed successfully.")
    @created_infrastructures += 1
  end

  def update_infrastructure(infrastructure)
    @logger.debug("Updating infrastructure #{infrastructure.name}...")
    payload = @datastore.infrastructure.to_payload
    RestClient.put("#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/infrastructures/#{infrastructure.remote_id}?access_token=#{@uc6_token}", payload.to_json, accept: :json, content_type: :json)
    @logger.debug("Updating infrastructure #{infrastructure.name} completed successfully.")
    @updated_infrastructures += 1
  end

  def create_billing_group(billing_group)
    @logger.debug("Creating billing group #{billing_group.name}...")
    payload = billing_group.to_payload
    response = RestClient.post("#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/billing_groups?access_token=#{@uc6_token}", payload.to_json, accept: :json, content_type: :json)
    new_billing_group = JSON.parse(response.body)
    @datastore.billing_groups[billing_group.platform_id].remote_id = new_billing_group["remote_id"]
    @logger.debug("Creating billing group #{billing_group.name} completed successfully.")
    @created_billing_groups += 1
  end

  def update_billing_group(billing_group)
    @logger.debug("Updating billing group #{billing_group.name}...")
    payload = billing_group.to_payload
    RestClient.put("#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/billing_groups/#{billing_group.remote_id}?access_token=#{@uc6_token}", payload.to_json, accept: :json, content_type: :json)
    @logger.debug("Updating billing group #{billing_group.name} completed successfully.")
    @updated_billing_groups += 1
  end

  def delete_billing_group(billing_group)
    @logger.debug("Deleting billing group #{billing_group.name}...")
    RestClient.delete("#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/billing_groups/#{billing_group.remote_id}?access_token=#{@uc6_token}")
    @logger.debug("Deletion of billing group #{billing_group.name} completed successfully.")
    @deleted_billing_groups += 1
  end

  def collate_machines
    @logger.debug("Collating machines...")
    response = RestClient::Request.execute(:url => "#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/infrastructures/#{@datastore.infrastructure.remote_id}/machines?fields=remote_id,name,virtual_name&limit=500&access_token=#{@uc6_token}", :method => :get)
    begin
      response_hash = JSON.parse(response.body)
      response_hash["embedded"]["machines"].each do |machine|
        if @datastore.machines[machine["virtual_name"]]
          @datastore.machines[machine["virtual_name"]].remote_id = machine["remote_id"]
        else
          terminated_container = Machine.new
          terminated_container.platform_id = machine["virtual_name"]
          terminated_container.remote_id = machine["remote_id"]
          terminated_container.name = machine["name"]
          terminated_container.virtual_name = machine["virtual_name"]
          @terminated_containers.store(terminated_container.virtual_name, terminated_container)
        end
      end unless response_hash["embedded"]["machines"].empty?
      if response_hash["_links"]["next"]
        url = response_hash["_links"]["next"]["href"].split("api/v2").last
        response = RestClient::Request.execute(:url => "#{@uc6_base_url}#{url}&access_token=#{@uc6_token}", :method => :get)
      end
    end while response_hash["_links"]["next"]
    @logger.debug("Collating machines completed successfully.")
  end

  def create_machine(machine)
    @logger.debug("Creating machine #{machine.name}...")
    payload = machine.to_payload
    @logger.debug("Machine #{machine.name}(#{machine.virtual_name}) has an Unknown status. The container's status is #{machine.status}") if payload["status"] == "Unknown"
    response = RestClient.post("#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/infrastructures/#{@datastore.infrastructure.remote_id}/machines?access_token=#{@uc6_token}", payload.to_json, accept: :json, content_type: :json)
    new_machine = JSON.parse(response.body)
    @datastore.machines[machine.platform_id].remote_id = new_machine["remote_id"]
    @logger.debug("Creating machine #{machine.name} completed successfully.")
    @created_machines += 1
  end

  def update_machine(machine)
    @logger.debug("Updating machine #{machine.name}...")
    payload = machine.to_payload
    @logger.debug("Machine #{machine.name}(#{machine.virtual_name}) has an Unknown status. The container's status is #{machine.status}") if payload["status"] == "Unknown"
    RestClient.put("#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/infrastructures/#{@datastore.infrastructure.remote_id}/machines/#{machine.remote_id}?access_token=#{@uc6_token}", payload.to_json, accept: :json, content_type: :json)
    @logger.debug("Updating machine #{machine.name} completed successfully.")
    @updated_machines += 1
  end

  def delete_machine(machine)
    @logger.debug("Deleting machine #{machine.name}...")
    RestClient.delete("#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/infrastructures/#{@datastore.infrastructure.remote_id}/machines/#{machine.remote_id}?access_token=#{@uc6_token}")
    @logger.debug("Deleting machine #{machine.name} completed successfully.")
    @deleted_machines += 1
  end

  def create_machine_disk(machine, disk)
    @logger.debug("Creating disk #{disk.name}...")
    payload = disk.to_payload
    response = RestClient.post("#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/infrastructures/#{@datastore.infrastructure.remote_id}/machines/#{machine.remote_id}/disks?access_token=#{@uc6_token}", payload.to_json, accept: :json, content_type: :json)
    new_disk = JSON.parse(response.body)
    @datastore.machines[machine.platform_id].disks[disk.name].remote_id = new_disk["remote_id"]
    @logger.debug("Creating disk #{disk.name} completed successfully.")
  end

  def update_machine_disk(machine, disk)
    @logger.debug("Updating disk #{disk.name}...")
    payload = disk.to_payload
    RestClient.put("#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/infrastructures/#{@datastore.infrastructure.remote_id}/machines/#{machine.remote_id}/disks/#{disk.remote_id}?access_token=#{@uc6_token}", payload.to_json, accept: :json, content_type: :json)
    @logger.debug("Updating disk #{disk.name} completed successfully.")
  end

  def create_machine_nic(machine, nic)
    @logger.debug("Creating nic #{nic.name}...")
    payload = nic.to_payload
    response = RestClient.post("#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/infrastructures/#{@datastore.infrastructure.remote_id}/machines/#{machine.remote_id}/nics?access_token=#{@uc6_token}", payload.to_json, accept: :json, content_type: :json)
    new_nic = JSON.parse(response.body)
    @datastore.machines[machine.platform_id].nics[nic.name].remote_id = new_nic["remote_id"]
    @logger.debug("Creating nic #{nic.name} completed successfully.")
  end

  def update_machine_nic(machine, nic)
    @logger.debug("Updating nic #{nic.name}...")
    payload = nic.to_payload
    RestClient.put("#{@uc6_base_url}/organizations/#{@datastore.organization.remote_id}/infrastructures/#{@datastore.infrastructure.remote_id}/machines/#{machine.remote_id}/nics/#{nic.remote_id}?access_token=#{@uc6_token}", payload.to_json, accept: :json, content_type: :json)
    @logger.debug("Updating nic #{nic.name} completed successfully.")
  end

end