class Datastore
  attr_accessor :timestamp, :organization, :infrastructure, :billing_groups, :machines
  attr_accessor :kubernetes_host, :kubernetes_port, :kubernetes_token, :kubernetes_insecure, :uc6_host, :uc6_port, :uc6_token, :uc6_insecure, :kubelet_port, :kubelet_insecure

  def initialize
    @organization = Organization.new
    @infrastructure = Infrastructure.new
    @billing_groups = {}
    @machines = {}

    #Defaults
    @kubelet_port = 10255
    @kubelet_insecure = true
  end

  def reset_inventory
    @infrastructure = Infrastructure.new
    @billing_groups = {}
    @machines = {}
  end

end