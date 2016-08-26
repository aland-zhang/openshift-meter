class Infrastructure
  attr_accessor :remote_id, :name, :tags, :status, :summary, :hosts, :networks, :volumes
  attr_accessor :platform_id

  def initialize
    @remote_id = nil
    @tags = "type:kubernetes"
    @status = "Active"
    @summary = {}
    @hosts = {}
    @networks = {}
    @volumes = {}
  end

  def to_payload
    payload = {}
    payload["name"] = @name
    payload["tags"] = @tags
    payload["status"] = @status
    payload["summary"] = @summary
    payload["hosts"] = @hosts.values.map {|host| host}
    payload["networks"] = @networks.values.map {|network| network}
    payload["volumes"] = @volumes.values.map {|volume| volume}

    # Return payload
    payload
  end
end