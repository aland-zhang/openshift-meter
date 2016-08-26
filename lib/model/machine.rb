class Machine

  private

  attr_accessor :statuses

  public

  attr_accessor :remote_id, :name, :virtual_name, :cpu_count, :cpu_speed_mhz, :maximum_memory_bytes, :host, :billing_group, :tags, :status, :disks, :nics, :previous_reading, :readings
  attr_accessor :platform_id, :platform_meter_id
  attr_accessor :container_name

  def initialize
    @statuses = {"Waiting" => "Deploying", "Pending" => "deploying", "Running" => "poweredOn", "running" => "poweredOn", "Terminated" => "deleted", "Unknown" => "Unknown", "Succeeded" => "poweredOff"}
    @statuses.default = "Unknown"
    @remote_id = nil
    @disks = {}
    @nics = {}
    @previous_reading = nil
    @readings = []
  end

  def pod_id
    @container_name.split("_")[4] || nil 
  end

  def pod_container?
    @container_name.split("_")[1].split(".")[0] == "POD"
  end

  def to_payload
    payload = {}
    payload["name"] = @name
    payload["virtual_name"] = @virtual_name
    payload["cpu_count"] = @cpu_count
    payload["cpu_speed_mhz"] = @cpu_speed_mhz
    payload["maximum_memory_bytes"] = @maximum_memory_bytes
    payload["billing_group_id"] = @billing_group.remote_id unless @billing_group.nil?
    payload["tags"] = @tags
    payload["status"] = statuses[@status]
    
    # Return payload
    payload
  end 

  def to_readings_payload (timestamp)
    machine_reading = MachineReading.new
    machine_reading.reading_at = timestamp
    machine_reading.cpu_usage_percent = sprintf('%.6f', @readings.inject(0.0) { |sum, reading| sum + reading.cpu_usage_percent } / @readings.size)
    machine_reading.memory_bytes = (@readings.inject(0.0) { |sum, reading| sum + reading.memory_bytes } / @readings.size).to_i
    payload_readings = []
    payload_readings << machine_reading

    {
      :readings => payload_readings.map {|reading| reading.to_payload},
      :disks => @disks.values.map {|disk| disk.to_readings_payload (timestamp)},
      :nics => @nics.values.map {|nic| nic.to_readings_payload (timestamp)}
    }
  end
end