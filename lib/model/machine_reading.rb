class MachineReading
  attr_accessor :reading_at, :cpu_usage_percent, :memory_bytes

  def initialize
    @cpu_usage_percent = 0
    @memory_bytes = 0
  end

  def to_payload
    payload = {}
    payload["reading_at"] = @reading_at
    payload["cpu_usage_percent"] = @cpu_usage_percent
    payload["memory_bytes"] = @memory_bytes

    # Return payload
    payload
  end
end