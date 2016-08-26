class BillingGroup
  attr_accessor :remote_id, :name
  attr_accessor :platform_id

  def initialize
    @remote_id = nil
  end

  def to_payload
    payload = {}
    payload["name"] = @name

    # Return payload
    payload
  end

end