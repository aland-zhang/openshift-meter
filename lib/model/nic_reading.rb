class NICReading
  attr_accessor :reading_at, :transmit_kilobits, :receive_kilobits

  def initialize
    @transmit_kilobits = 0
    @receive_kilobits = 0
  end

  def to_payload
    payload = {}
    payload["reading_at"] = @reading_at
    payload["transmit_kilobits"] = @transmit_kilobits
    payload["receive_kilobits"] = @receive_kilobits

    # Return payload
    payload
  end
end