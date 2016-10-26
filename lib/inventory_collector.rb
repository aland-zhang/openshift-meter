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

class InventoryCollector
  private
  
  attr_accessor :datastore, :logger, :k8s_protocol, :k8s_token, :kubelet_port, :kubelet_protocol

  public

  attr_accessor :infrastructures, :projects, :services, :pods, :containers, :nodes
 
  def initialize(logger, datastore)
    @logger = logger
    @logger.debug("Initializing the Inventory Collector...")
    @datastore = datastore
    @k8s_token = @datastore.kubernetes_token
    @k8s_protocol = datastore.kubernetes_insecure ? 'http' : 'https'
    @kubelet_protocol = datastore.kubelet_insecure ? 'http' : 'https'
    @kubelet_port = datastore.kubelet_port
    @k8s_headers = {}
    @k8s_headers = {Authorization: "Bearer #{@k8s_token}"} unless @k8s_token.nil?
    @kubelet_headers = {}
    @kubelet_headers = {Authorization: "Bearer #{@k8s_token}"} unless @k8s_token.nil? || datastore.kubelet_insecure
    @k8s_base_url = "#{@k8s_protocol}://#{@datastore.kubernetes_host}:#{@datastore.kubernetes_port}/api/v1"
    @openshift_base_url = "#{@k8s_protocol}://#{@datastore.kubernetes_host}:#{@datastore.kubernetes_port}/oapi/v1"
    @logger.debug("Inventory Collector initialized successfully.")
  end

  def run
    begin
      reset_statistics
      @logger.debug("Collecting infrastructures...")
      num_of_infrastructures = collect_infrastructures
      @logger.debug("Collected #{num_of_infrastructures} infrastructure(s).")
      @logger.debug("Collecting projects...")
      num_of_projects = collect_projects
      @logger.debug("Collected #{num_of_projects} project(s).")
      @logger.info("Collected #{infrastructures} Infrastructure(s), #{@projects} project(s), #{@nodes} Node(s), #{@services} Service(s), #{@pods} Pod(s) #{@containers} Container(s)")
      @logger.info('Inventory collected successfully.')
    rescue StandardError => e
      @logger.fatal("Inventory collection failed.")
      @logger.debug("#{e.message}")
      @logger.debug("#{e.backtrace}")
    end
  end

  def reset_statistics
    @infrastructures = 0
    @projects = 0
    @services = 0
    @pods = 0
    @containers = 0
    @nodes = 0
  end

  def collect_infrastructures
    infrastructure = datastore.infrastructure || Infrastructure.new
    infrastructure.platform_id = @datastore.kubernetes_host
    infrastructure.name = "Openshift Cluster(#{@datastore.kubernetes_host})"
    datastore.infrastructure = infrastructure
    @logger.debug("Collecting nodes for the cluster...")
    num_of_nodes = collect_nodes
    @logger.debug("Collected #{num_of_nodes} nodes for the cluster.")
    @infrastructures += 1
  end

  def collect_projects
    response = RestClient::Request.execute(:method => :get, :url => "#{@openshift_base_url}/projects", :headers => @k8s_headers, :verify_ssl => false)
    response_hash = JSON.parse(response.body)
    response_hash["items"].each do |project|
      billing_group = @datastore.billing_groups["#{project["metadata"]["uid"]}"] || BillingGroup.new
      billing_group.platform_id = project["metadata"]["uid"]
      billing_group.name = "project:#{project["metadata"]["name"]}"
      @datastore.billing_groups.store("#{billing_group.platform_id}", billing_group)

      #This has to be run first to get all pods
      @logger.debug("Collecting pods for #{project["metadata"]["name"]} project...")
      num_of_pods = collect_pods(project)
      @logger.debug("Collected #{num_of_pods} pod(s) for #{project["metadata"]["name"]} project.")

      #This has to be run second to add the service tags and will only update the pods attached to services
      @logger.debug("Collecting services for #{project["metadata"]["name"]} project...")
      num_of_services = collect_services(project)
      @logger.debug("Collected #{num_of_services} service(s) for #{project["metadata"]["name"]} project.")
      @projects += 1
    end
    response_hash["items"].count
  end

  def collect_services(project)
    response = RestClient::Request.execute(:url => "#{@k8s_base_url}/namespaces/#{project["metadata"]["name"]}/services", :method => :get, :headers => @k8s_headers, :verify_ssl => false)
    response_hash = JSON.parse(response.body)
    response_hash["items"].each do |service|
      collect_pods(project,service) unless service["spec"]["selector"].nil?
      @services += 1
    end
    response_hash["items"].count
  end

  def collect_pods(project, service = nil)
    if service
      label_selector = ''
      service["spec"]["selector"].each {|k, v| label_selector << "#{k}=#{v},"} unless service["spec"]["selector"].nil?
      label_selector = label_selector.to_s.chop
      response = RestClient::Request.execute(:url => "#{@k8s_base_url}/namespaces/#{project["metadata"]["name"]}/pods?labelSelector=#{label_selector}", :method => :get, :headers => @k8s_headers, :verify_ssl => false)
    else
      response = RestClient::Request.execute(:url => "#{@k8s_base_url}/namespaces/#{project["metadata"]["name"]}/pods", :method => :get, :headers => @k8s_headers, :verify_ssl => false)
    end
    response_hash = JSON.parse(response.body)
    response_hash["items"].each do |pod|

      # Find the infrastructure container for the pod
      machine = @datastore.machines.values.select { |value| value.pod_container? == true and value.pod_id == pod["metadata"]["uid"]}.first
      machine = @datastore.machines.values.select { |value| value.pod_container? == true and value.pod_id == pod["metadata"]["annotations"]["kubernetes.io/config.hash"]}.first unless machine

      if machine
        # Set machine basic attributes
        machine.name = "pod-#{machine.pod_id}"
        machine.status = pod["status"]["phase"]
        machine.billing_group = datastore.billing_groups["#{project["metadata"]["uid"]}"]
        machine.tags = "type:container,pod:#{pod["metadata"]["name"]}"
        
        #Save the machine
        @datastore.machines.store("#{machine.platform_id}", machine)
      end

      if pod["status"]["containerStatuses"]
        pod["status"]["containerStatuses"].each do |container|
          if container["ready"]
            # Retrieve machine or create new machine
            machine = @datastore.machines["#{container["containerID"].split("//").last}"]

            if machine
              # Set machine basic attributes
              machine.name = "#{container["name"]}-#{machine.platform_id[0...8]}"
              machine.status = container["state"].keys.first
              machine.billing_group = datastore.billing_groups["#{project["metadata"]["uid"]}"]

              # Set machine tags
              if service
                machine.tags = "type:container,pod:#{pod["metadata"]["name"]},service:#{service["metadata"]["name"]}"
              else
                machine.tags = "type:container,pod:#{pod["metadata"]["name"]}"
              end

              #Save the machine
              @datastore.machines.store("#{container["containerID"].split("//").last}", machine)
            end
          end
        end
      end
      @pods += 1
    end
    response_hash["items"].count
  end

  def collect_nodes
    response = RestClient::Request.execute(:url => "#{@k8s_base_url}/nodes", :method => :get, :headers => @k8s_headers, :verify_ssl => false)
    response_hash = JSON.parse(response.body)
    response_hash["items"].each do |node|
      host_ip = node["status"]["addresses"][0]["address"]
      @logger.debug("Collecting containers for #{host_ip} node....")
      num_of_containers = collect_containers(node)
      @logger.debug("Collected #{num_of_containers} containers for #{host_ip} node.")
      @nodes += 1
    end
    response_hash["items"].count
  end

  def collect_containers (node)
    #response = RestClient::Request.execute(:url => "#{@kubelet_protocol}://#{node_ip_address}:#{@kubelet_port}/spec", :method => :get, :headers => @kubelet_headers, :verify_ssl => false)
    #node_attributes = JSON.parse(response.body)
    node_attributes = node["status"]
    node_ip_address = node_attributes["addresses"][0]["address"]
    payload = '{"containerName":"/system.slice/docker-","subcontainers":true,"num_stats":1}'
    response = RestClient::Request.execute(:url => "#{@kubelet_protocol}://#{node_ip_address}:#{@kubelet_port}/stats/container", :method => :post, :payload => payload, accept: :json, content_type: :json, :headers => @kubelet_headers, :verify_ssl => false)
    response_hash = JSON.parse(response.body)
    response_hash.each do |id,container|
      if container["aliases"]
        # Parse aliases
        container_name = container["aliases"][0]
        container_id = container["aliases"][1]

        # Retrieve machine or create new machine
        machine = @datastore.machines[container_id] || Machine.new

        # Set machine basic attributes
        machine.platform_id = container_id
        machine.platform_meter_id = id
        machine.virtual_name = container_id
        machine.container_name = container_name
        machine.host = node_ip_address

        # Set CPU and Memory Allocations
        machine.cpu_count = container["spec"]["cpu"]["limit"] < node_attributes["capacity"]["cpu"] ? container["cpu"]["limit"] * 1 : node_attributes["capacity"]["cpu"] * 1
        machine.cpu_speed_mhz = 3300000
        machine.maximum_memory_bytes = container["spec"]["memory"]["limit"] < (node_attributes['capacity']['memory'])[0..-3] * 1024 ? container["spec"]["memory"]["limit"] : (node_attributes['capacity']['memory'])[0..-3] * 1024

        # Set Machine Disks
        machine_disk = Disk.new
        machine_disk.name = "disk-#{machine.platform_id[0...8]}"
        machine_disk.maximum_size_bytes = 0
        machine_disk.type = "disk"
        machine.disks.store("#{machine_disk.name}", machine_disk)

        # Set Machine NICs
        machine_nic = Nic.new
        machine_nic.name = "nic-#{machine.platform_id[0...8]}"
        machine_nic.kind = 0
        machine.nics.store("#{machine_nic.name}", machine_nic)

        # Add Machine to List
        @datastore.machines.store("#{machine.platform_id}", machine)
        @containers += 1
      end
    end
    response_hash.length
  end
end