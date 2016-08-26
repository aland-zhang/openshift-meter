class Nic
  attr_accessor :remote_id, :name, :kind, :ip_address, :mac_address, :readings

  def initialize
    @remote_id = nil
    @ip_address = "127.0.0.1"
    @mac_address = "00:00:00:00:00:00"
    @readings = []
  end

  def to_payload
    payload = {}
    payload["name"] = @name
    payload["kind"] = @kind
    payload["ip_address"] = @ip_address
    payload["mac_address"] = @mac_address

    # Return payload
    payload
  end

  def to_readings_payload (timestamp)
    nic_reading = NICReading.new
    nic_reading.reading_at = timestamp
    nic_reading.receive_kilobits = (@readings.inject(0.0) { |sum, reading| sum + reading.receive_kilobits } / @readings.size).to_i
    nic_reading.transmit_kilobits = (@readings.inject(0.0) { |sum, reading| sum + reading.transmit_kilobits } / @readings.size).to_i
    payload_readings = []
    payload_readings << nic_reading

    {
      :id => @remote_id,
      :readings => payload_readings.map {|reading| reading.to_payload}
    }
  end
end