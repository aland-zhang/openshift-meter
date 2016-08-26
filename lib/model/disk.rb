class Disk
  attr_accessor :remote_id, :name, :maximum_size_bytes, :type, :readings

  def initialize
    @remote_id = nil
    @readings = []
  end

  def to_payload
    payload = {}
    payload["name"] = @name
    payload["maximum_size_bytes"] = @maximum_size_bytes
    payload["type"] = @type

    # Return payload
    payload
  end

  def to_readings_payload (timestamp)
    disk_reading = DiskReading.new
    disk_reading.reading_at = timestamp
    disk_reading.usage_bytes = (@readings.inject(0.0) { |sum, reading| sum + reading.usage_bytes } / @readings.size).to_i
    disk_reading.read_kilobytes = (@readings.inject(0.0) { |sum, reading| sum + reading.read_kilobytes } / @readings.size).to_i
    disk_reading.write_kilobytes = (@readings.inject(0.0) { |sum, reading| sum + reading.write_kilobytes } / @readings.size).to_i
    payload_readings = []
    payload_readings << disk_reading

    {
      :id => @remote_id,
      :readings => payload_readings.map {|reading| reading.to_payload}
    }
  end
end