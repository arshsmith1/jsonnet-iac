// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

local hcl = import 'hcl.libsonnet';

{
  // Env-level mixin.
  // Refer existing DNS Zone in provided project.
  // Creates google_dns_managed_zone data block to be used by other dns resources.
  // Args:
  //   project_id: GCP project ID to refer existing zone from. If not provided, the project ID from the current context will be used.
  //   name: DNS zone name. If not provided, the environment name will be used.
  //   dns_name: DNS suffix of the zone. If not provided, the environment's DNS name will be used.
  // Example:
  //   + dns.existing_zone_data(project_id='dasinfra-sap-business-dev5')
  existing_zone_data(project_id='%(project_id)s', name='%(env)s', dns_name=null): {
    local base = self.base,
    project+:: {
      zone: hcl.data {
        hcllabels:: ['google_dns_managed_zone', hcl.strToSnake(self.name)],
        // This field is needed for tfimport of other dns resources.
        project_id:: self.project,
        name: name % base,
        dns_name:: if dns_name != null then dns_name % base else hcl.toString(self.self_ref('dns_name')),
        project: project_id % base,
      },
    },
  },

  // Env-level mixin.
  // Creates google_dns_managed_zone resource.
  // Args:
  //   dns_name: The DNS name of this managed zone, for instance "example.com.".
  //   name: optional, user assigned name for this resource. If not provided, the environment name will be used.
  //   visibility: optional, The zone's visibility: public zones are exposed to the Internet, while private zones are visible only to Virtual Private Cloud resources.
  //   description: optional, a textual description field.
  //   dnssec_config: optional, the DNSSEC configuration block.
  //   visible_vpcs: optional, list of VPCs that can see the zone. If provided, the zone will be private.
  // Example:
  //   + dns.managed_zone(dns_name='gcp.internal.')
  managed_zone(dns_name, name='%(env)s', description=null, dnssec_config=null, visible_vpcs=null):: {
    local base = self.base,
    local project = self.project.google_project.self_ref('project_id'),
    local vpcs = self.vpcs,
    project+:: {
      zone: hcl.resource {
        hcllabels:: ['google_dns_managed_zone', hcl.strToSnake(self.name)],
        tfimport:: '%(project_id)s/%(name)s' % self,
        project_id:: base.project_id,
        name: name % base,
        dns_name: dns_name % base,
        project: project,
        [if description != null then 'description']: description % base,
        [if dnssec_config != null then 'dnssec_config']: hcl.nested_block + dnssec_config,
        [if visible_vpcs != null then 'visibility']: 'private',
        [if visible_vpcs != null then 'private_visibility_config']: hcl.nested_block {
          networks: hcl.repeated_block() {
            blocks:: [
              {
                network_url:
                  if std.isString(vpc) && vpc in vpcs
                  then vpcs[vpc].network.self_link
                  else vpc,
              }
              for vpc in visible_vpcs
            ],
          },
        },
      },
    },
  },

  // Comp-level mixin.
  // Creates google_dns_record_set resource with type 'A' for all instances in a component.
  // IMPORTANT: env-level mixin dns.existing_zone_data() or dns.managed_zone() should be used.
  // Args:
  //   name: record name. If not provided, '%(comp)s.%(dns_name)s' will be used.
  // Example:
  //   + environment.component(
  //     ...
  //     + dns.global_a()
  //   )
  global_a(name=null): {
    local base = self.base,
    local zone = self.env.project.zone,
    local instances = [i for r in self.regions for i in r.instances],
    dns+: {
      global_a: hcl.resource {
        hcllabels:: ['google_dns_record_set', hcl.strToSnake(base.comp + '_' + std.asciiLower(self.type))],
        name: if name != null then name else '%s.%s' % [base.comp, zone.dns_name],
        project: zone.project,
        managed_zone: zone.self_ref('name'),
        type: 'A',
        ttl: 60,
        rrdatas: [i.compute.vm.self_ref('network_interface[0].network_ip') for i in instances],
      },
    },
  },

  // Comp-level mixin.
  // Creates google_dns_record_set resource with type 'PTR' for all instances in a component.
  // IMPORTANT: env-level mixin dns.existing_zone_data() or dns.managed_zone() should be used.
  // Args:
  //   name: record name. If not provided, '%(comp)s.%(dns_name)s' will be used.
  // Example:
  //   + environment.component(
  //     ...
  //     + dns.global_ptr()
  //   )
  global_ptr(name=null): {
    local base = self.base,
    local zone = self.env.project.zone,
    local instances = [i for r in self.regions for i in r.instances],
    dns+: {
      global_ptr: hcl.resource {
        hcllabels:: ['google_dns_record_set', hcl.strToSnake(base.comp + '_' + std.asciiLower(self.type))],
        name: if name != null then name else '%s.%s' % [base.comp, zone.dns_name],
        project: zone.project,
        managed_zone: zone.self_ref('name'),
        type: 'PTR',
        ttl: 60,
        rrdatas: ['%s.' % i.base.fqdn for i in instances],
      },
    },
  },

  // Comp-level mixin.
  // Creates google_dns_record_set resource with type 'A' for each zone in each region for instances in that zone.
  // IMPORTANT: env-level mixin dns.existing_zone_data() or dns.managed_zone() should be used.
  // Example:
  //   + environment.component(
  //     ...
  //     + dns.zonal_a()
  //   )
  zonal_a(): {
    local zone = self.env.project.zone,
    by_region+:: {
      local region_instances = self.instances,
      local base = self.base,
      dns+: {
        zonal_a: {
          [z]: hcl.resource {
            hcllabels:: ['google_dns_record_set', hcl.strToSnake('%s-%s-a' % [base.comp, z])],
            name: '%s.%s.%s' % [base.comp, z, zone.dns_name],
            type: 'A',
            ttl: 60,
            managed_zone: zone.self_ref('name'),
            rrdatas: [i.compute.vm.self_ref('network_interface[0].network_ip') for i in region_instances if i.base.zone == z],
            project: zone.project,
          }
          for z in base.zones
        },
      },
    },
  },

  // Comp-level mixin.
  // Creates google_dns_record_set resource with type 'PTR' for each zone in each region for instances in that zone.
  // IMPORTANT: env-level mixin dns.existing_zone_data() or dns.managed_zone() should be used.
  // Example:
  //   + environment.component(
  //     ...
  //     + dns.zonal_ptr()
  //   )
  zonal_ptr(): {
    local zone = self.env.project.zone,
    by_region+:: {
      local region_instances = self.instances,
      local base = self.base,
      dns+: {
        zonal_ptr: {
          [z]: hcl.resource {
            hcllabels:: ['google_dns_record_set', hcl.strToSnake('%s-%s-ptr' % [base.comp, z])],
            name: '%s.%s.%s' % [base.comp, z, zone.dns_name],
            type: 'PTR',
            ttl: 60,
            managed_zone: zone.self_ref('name'),
            rrdatas: ['%s.' % i.base.fqdn for i in region_instances if i.base.zone == z],
            project: zone.project,
          }
          for z in base.zones
        },
      },
    },
  },

  // Env-level mixin.
  // Creates google_dns_managed_zone resource for peering.
  // Args:
  //   dns_name: The DNS name of this managed zone, for instance "example.com.".
  //   peer_network_url: The destination network where DNS queries are sent.
  //   name: optional, user assigned name for this resource. If not provided, the environment name will be used.
  //   description: optional, a textual description field.
  //   visible_vpcs: optional, list of VPCs that can see the zone. If not provided, the default VPC will be used.
  // Example:
  //   + dns.peering_zone(dns_name='gcp.internal.', peer_network_url='https://www.googleapis.com/compute/v1/projects/other-project/global/networks/other-vpc')
  peering_zone(dns_name, peer_network_url, name='%(env)s', description=null, visible_vpcs):: {
    local base = self.base,
    local project = self.project.google_project.self_ref('project_id'),
    local vpcs = self.vpcs,
    project+:: {
      [hcl.strToSnake(name % base)]: hcl.resource {
        hcllabels:: ['google_dns_managed_zone', hcl.strToSnake(self.name)],
        tfimport:: '%(project_id)s/%(name)s' % self,
        project_id:: base.project_id,
        name: name % base,
        dns_name: dns_name % base,
        project: project,
        [if description != null then 'description']: description % base,
        visibility: 'private',
        peering_config: hcl.nested_block {
          target_network: hcl.nested_block {
            network_url: peer_network_url % base,
          },
        },
        private_visibility_config: hcl.nested_block {
          networks: hcl.repeated_block() {
            blocks:: [
              {
                network_url:
                  if std.isString(vpc) then
                    if std.startsWith(vpc, 'https://') then vpc
                    else if std.startsWith(vpc, 'projects/') then vpc
                    else if vpc in vpcs then 'projects/%s/global/networks/%s' % [vpcs[vpc].project_id, vpcs[vpc].network.name]
                    else vpc
                  else if std.isObject(vpc) then
                    if 'network' in vpc then 'projects/%s/global/networks/%s' % [vpc.project_id, vpc.network.name]
                    else if 'not_jsonnet_project' in vpc then 'projects/%s/global/networks/%s' % [vpc.project_id, vpc.vpc_name]
                    else std.toString(vpc)
                  else vpc,
              }
              for vpc in visible_vpcs
            ],
          },
        },
      },
    },
  },
}
