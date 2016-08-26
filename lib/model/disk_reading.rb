class DiskReading
  attr_accessor :reading_at, :usage_bytes, :read_kilobytes, :write_kilobytes

  def initialize
    @usage_bytes = 0
    @read_kilobytes = 0
    @write_kilobytes = 0
  end

  def to_payload
    payload = {}
    payload["reading_at"] = @reading_at
    payload["usage_bytes"] = @usage_bytes
    payload["read_kilobytes"] = @read_kilobytes
    payload["write_kilobytes"] = @write_kilobytes

    # Return payload
    payload
  end
end