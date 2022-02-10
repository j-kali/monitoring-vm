# MIT License
#
# Copyright (c) 2022 CSC - IT Center for Science Ltd.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

# Define required providers
terraform {
  required_version = ">= 1.1.5"
  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.35.0"
    }
  }
  backend "swift" {
    container         = "ced-terraform-state"
    archive_container = "ced-terraform-state-archive"
    # state_name should be set using set-name.sh and present in the
    # backend configuration file which is used during terraform init
  }
}

variable "instance_name" {
  # set with set-name.sh <instance_name>
  type = string
}

resource "openstack_compute_keypair_v2" "instance_keypair" {
  name = "${var.instance_name}-keys"
  # For privacy reasons public keys are marked as secrets
  # Bravely assuming you have ~/.ssh/id_rsa.pub to use for
  # provisioning of the VM
  #
  # Assuming rsa keys instead of ed25519 as at the time of writing rsa is still
  # more widely adopted/compatible
  public_key = join("\n", [file("~/.ssh/id_rsa.pub"), file("secrets/public_keys")])
}

# The actual VM is defined here
resource "openstack_compute_instance_v2" "instance" {
  name = "${var.instance_name}"
  image_name = "Ubuntu-20.04"
  flavor_name = "standard.tiny"
  key_pair = "${openstack_compute_keypair_v2.instance_keypair.name}"
  security_groups = [
    openstack_networking_secgroup_v2.security_group.name,
  ]
  network {
    uuid = "${openstack_networking_network_v2.instance_net.id}"
  }
  # Pouta API refuses to create the instance unless the subnet is ready to go
  depends_on = [
    openstack_networking_subnet_v2.instance_subnet,
  ]
}

# Because of how networking is done on Pouta, provisioning needs to be
# done after the FloatingIP is attached. However, attachment happens
# after instance is created (and provisioned!) so we need to define a
# null_resource that will govern the provisioning of the VM.
resource "null_resource" "provision" {

  triggers = {
    instance = openstack_compute_instance_v2.instance.id
  }

  connection {
    type = "ssh"
    host = "${openstack_networking_floatingip_v2.ip.address}"
    user = "ubuntu"
    private_key = file("~/.ssh/id_rsa")
  }

  provisioner "remote-exec" {
    # Again, for privacy reasons setup.sh is also marked as a secret
    script = "secrets/setup.sh"
  }
}

# Network for the VM to be in. It is not allowed in most cases to have
# VMs directly in the public network on Pouta
resource "openstack_networking_network_v2" "instance_net" {
  name = "${var.instance_name}-net"
  admin_state_up = "true"
}

# A router to attach the network defined earlier to the public network
resource "openstack_networking_router_v2" "router" {
  name = "${var.instance_name}-router"
  admin_state_up = "true"
  # Magic UUID is the UUID of our public network, somewhat difficult
  # to refer to it by name here so we are stuck with the magic thing
  # for now
  external_network_id = "26f9344a-2e81-4ef5-a018-7d20cff891ee"
}

# Attachment of the router to the VM subnet
resource "openstack_networking_router_interface_v2" "interface" {
  router_id = "${openstack_networking_router_v2.router.id}"
  subnet_id = "${openstack_networking_subnet_v2.instance_subnet.id}"
}

# The floating ip, which will be a public IP used to access the VM
resource "openstack_networking_floatingip_v2" "ip" {
  pool = "public"
  depends_on = [openstack_networking_router_interface_v2.interface]
}

# Attachment of the IP to the instance. It is important to realize why
# this is separate from the floating ip it self. It is separate, so
# one can redeploy an instance and attach the IP to the new instance
# without the need to do anything about the IP object itself.
resource "openstack_compute_floatingip_associate_v2" "ip_attach" {
  floating_ip = "${openstack_networking_floatingip_v2.ip.address}"
  instance_id = "${openstack_compute_instance_v2.instance.id}"
}

#######################################################################
# Security group and its rules
#######################################################################
resource "openstack_networking_secgroup_v2" "security_group" {
  name        = "${var.instance_name}"
}

resource "openstack_networking_secgroup_rule_v2" "ssh-in" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = "${openstack_networking_secgroup_v2.security_group.id}"
}

resource "openstack_networking_secgroup_rule_v2" "http-out" {
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = "${openstack_networking_secgroup_v2.security_group.id}"
}

resource "openstack_networking_secgroup_rule_v2" "https-out" {
  direction         = "egress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = "${openstack_networking_secgroup_v2.security_group.id}"
}

resource "openstack_networking_secgroup_rule_v2" "https-in" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = "${openstack_networking_secgroup_v2.security_group.id}"
}

# Subnet for the VM. On Pouta all VMs need to be in subnets to boot properly
resource "openstack_networking_subnet_v2" "instance_subnet" {
  name = "${var.instance_name}-subnet"
  network_id = "${openstack_networking_network_v2.instance_net.id}"
  cidr = "10.0.0.0/24"
  ip_version = 4
  dns_nameservers = [
    "1.1.1.1",
    "1.1.0.0",
  ]
}

# Handy output to get the IP address that we've got in the output
output "address" {
  value = "${openstack_networking_floatingip_v2.ip.address}"
}