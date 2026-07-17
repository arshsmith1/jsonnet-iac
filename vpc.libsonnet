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

// Collection of mixins to define resources for VPC networks.
{
  // Env-level mixin.
  // It's a facade for
  // vpc.network() + vpc.subnets() + vpc.router() + vpc.router_nat().
  // (Convenient for standard cases).
  //
  // Creates a VPC network, subnets, NAT gateway, and NAT router for the given regions.
  // Args:
  //   vpc_logical_name: string, the name of the VPC network (e.g., 'servers').
  //   regions: array of strings or region metadata objects, the names or metadata of the regions.
  //   ip_ranges: a) array or ranges or
  //              b) map of ranges: e.g. {'us-east1': ['10.0.0.0/24', '10.0.1.0/24']}
  //              Each item in the array is one of:
  //              1) string, the CIDR range
  //              2) mixin which applied to subnet_tuple (see vpc.libsonnet for details).
  //   router - [optional, default true]
  //            Creates router resource for this VPC network.
  //   router_nat - [optional, default = value of router arg]
  //                Creates router NAT and address for this VPC. Uses router.
  //   network_name_pattern - [optional] string, pattern for network name.
  //                           If not specified, used vpc.network() default pattern.
  //   subnet_name_pattern - [optional] string, pattern for subnet name.
  //                         If not specified, used vpc.subnet() default pattern.
  network_subnets_router_nat(
    vpc_logical_name,
    regions,
    ip_ranges,
    router=true,
    router_nat=router,
    network_name_pattern=null,
    subnet_name_pattern=null,
  ):
    (if network_name_pattern == null
     then $.network(vpc_logical_name)
     else $.network(vpc_logical_name, name=network_name_pattern)) +
    std.foldl(
      function(acc, r)
        local r_name =
          if std.isString(r) then r
          else if 'region' in r then r.region
          else std.objectValuesAll(r.regions_metadata)[0].region;
        local ip_ranges_per_region = if std.isArray(ip_ranges) then ip_ranges else ip_ranges[r_name];
        acc
        + (if router then $.router(vpc_logical_name=vpc_logical_name, region=r_name) else {})
        + (if router_nat then $.router_nat(vpc_logical_name=vpc_logical_name, region=r_name, external_ip_count=1) else {})
        + std.foldl(
          function(acc2, i)
            acc2
            + if subnet_name_pattern == null
            then $.subnet(vpc_logical_name, region=r_name, ip_range=ip_ranges_per_region[i - 1], subnet_index=i)
            else $.subnet(vpc_logical_name, region=r_name, ip_range=ip_ranges_per_region[i - 1], subnet_index=i, name=subnet_name_pattern),
          std.range(1, std.length(ip_ranges_per_region)),
          {},
        ),
      regions,
      {},
    ),

  // Env-level mixin.
  // Creates a google_compute_network resource for the given VPC name.
  // Materializes the VPC network and all related resources to the vpcs.tf file.
  // Args:
  //   logical_name: string, the logical name of the VPC network (e.g., 'servers')
  //                 used in fields hierarchy to reference this particular group of tf resources.
  //   name: [optional] string, the name of google_compute_network tf resource.
  //         If not specified, defaults to '%(env)s-%(logical_name)s'.
  network(logical_name, name='%(env)s-%(logical_name)s'): {
    'vpcs.tf': hcl.manifest(self.vpcs, base.tf_comments),
    local base = self.base,
    vpcs+:: {
      each_vpc+:: {},  // to let decorating logic apply changes to all vpcs at once without need to iterate.
      [logical_name]+: {  // e.g. servers or reverse-proxies
        vpc_name:: logical_name,
        project_id:: base.project_id,
        base:: base,  // useful to check project metadata in downstream logic.
        network: hcl.resource {
          hcllabels:: ['google_compute_network', hcl.strToSnake(self.name)],
          tfimport:: '%s/%s' % [base.project_id, self.name],
          name: name % base { logical_name: logical_name },
          auto_create_subnetworks: false,
          project: base.project,
        },
        // this field is merged into each region below,
        // use it to apply change to all regions of this particular VPC, e.g. see router_description()
        each_region+:: {},
      } + self.each_vpc,
      // this field is merged into each region below,
      // use it to apply change to all regions, e.g. see router_description()
      each_region+:: {},
      // similar to each_region
      each_subnet_tuple+:: {},
    },
  },

  // Env-level mixin.
  // Creates a google_compute_subnetwork resource.
  // Use it multiple times with different ip_range to create multiple subnets in the same VPC and region.
  // Args:
  //   vpc_logical_name: string, logical name of the VPC network
  //                     (e.g., 'servers'), defined in vpc.network().
  //   region: string, the name of the region.
  //   ip_range: string or object:
  //             1) string, the CIDR range
  //             2) mixin which is applied to each subnet_tuple.
  //                That mixin defines subnet.ip_cidr_range field
  //                and if necessary additional resources.
  //                NOTE for mixin authors: see subnet_level_base field.
  //   subnet_index: int, 1-based index of the subnet within the VPC and region.
  //   extra_mixin: optional object, additional fields to merge into the subnet resource.
  //   private_ip_google_access: bool, whether to enable private IP Google access.
  //   name: [optional] string, the name of the google_compute_subnetwork tf resource.
  //         If not specified, defaults to '%(network_name)s%(ipblock_infix)s-%(region)s'.
  //         There are additional to env metadata values which can be used:
  //         - network_name: the cloud resource name of the VPC network, taken from vpc.network().
  //         - ipblock_infix: '-ipblock%(subnet_index)s' if subnet_index > 1, '' otherwise.
  //         - region: the name of the region.
  //         - vpc_logical_name: the value of passed vpc_logical_name arg.
  subnet(
    vpc_logical_name,
    region,
    ip_range,
    subnet_index=1,
    extra_mixin={},
    private_ip_google_access=true,
    name='%(network_name)s%(ipblock_infix)s-%(region)s',
  ): {
    local base = self.base,
    local vpcs = self.vpcs,
    vpcs+:: {
      [vpc_logical_name]+: {
        local vpc = self,
        [region]+: {
          subnet_tuples+: [
            {
              subnet_level_base:: base {  // useful for ip_range mixins and name pattern fomatting.
                region: region,
                network_name: vpc.network.name,
                subnet_index: subnet_index,
                vpc_logical_name: vpc_logical_name,
                // 1st subnet is default and can ommit ipblock element in the name.
                ipblock_infix: if subnet_index > 1 then '-ipblock%s' % subnet_index else '',
              },
              local subnet_level_base = self.subnet_level_base,
              subnet: hcl.resource {
                hcllabels:: ['google_compute_subnetwork', hcl.strToSnake(self.name)],
                tfimport:: '%s/%s/%s' % [base.project_id, region, self.name],
                name: name % subnet_level_base,
                [if std.isString(ip_range) then 'ip_cidr_range']: ip_range,
                network: vpc.network.self_link,
                region: region,
                project: base.project,
                private_ip_google_access: private_ip_google_access,
              },
            }
            + (if std.isObject(ip_range) then ip_range else {})
            + extra_mixin
            + vpcs.each_subnet_tuple,
          ],
        } + vpcs.each_region + self.each_region,
      },
    },
  },

  // Env-level mixin.
  // Creates a google_compute_router and a google_compute_address for NAT.
  // Args:
  //   vpc_logical_name: string, logical name of the VPC network
  //                     (e.g., 'servers'), defined in vpc.network().
  //   region: string, the name of the region.
  //   name: [optional] string, the name of the google_compute_router tf resource.
  //                If not specified, defaults to '%(network_name)s-%(region)s'.
  router(
    vpc_logical_name,
    region,
    name='%(network_name)s-%(region)s'
  ): {
    local base = self.base,
    vpcs+:: {
      [vpc_logical_name]+: {
        local vpcs_each_region = self.each_region,
        local network = self.network,
        [region]+: {
          router: hcl.resource {
            hcllabels:: ['google_compute_router', hcl.strToSnake(self.name)],
            tfimport:: '%s/%s/%s' % [base.project_id, region, self.name],
            name: name % base {
              vpc_logical_name: vpc_logical_name,
              region: region,
              network_name: network.name,
            },
            region: region,
            network: network.self_link,
            project: base.project,
          },
        } + vpcs_each_region + self.each_region,
      },
    },
  },

  // Env-level mixin.
  // Creates a google_compute_router_nat resource.
  // IMPORTANT: Requires vpc.router() to be called for the same vpc_logical_name and region.
  // Args:
  //   vpc_logical_name: string, logical name of the VPC network
  //                     (e.g., 'servers'), defined in vpc.network().
  //   region: string, the name of the region.
  //   name: [optional] string, the name of the google_compute_router_nat tf resource.
  //         Defaults to '%(network_name)s-%(region)s'.
  //   external_ip_count: [optional, default 0] int, the number of external IPs to manually allocate.
  //                      If 0, 'AUTO_ONLY' mode is used. If > 0, 'MANUAL_ONLY' mode is used,
  //                      and google_compute_address resources are created.
  //   external_ip_name: [optional] string, the name pattern for the google_compute_address tf resources.
  //                     Defaults to '%(network_name)s-%(region)s%(i_suffix)s'.
  //                     'i_suffix' is an empty string for the first IP, and the IP index (e.g., '2') for subsequent IPs.
  //   source_subnetwork_ip_ranges_to_nat: [optional, default 'ALL_SUBNETWORKS_ALL_IP_RANGES'] string,
  //                                       the IP ranges to NAT.
  router_nat(
    vpc_logical_name,
    region,
    name='%(network_name)s-%(region)s',
    external_ip_name='%(network_name)s-%(region)s%(i_suffix)s',
    source_subnetwork_ip_ranges_to_nat='ALL_SUBNETWORKS_ALL_IP_RANGES',
    external_ip_count=0,
  ): {
    local base = self.base,
    vpcs+:: {
      local vpcs_each_region = self.each_region,
      [vpc_logical_name]+: {
        local network = self.network,
        [region]+: {
          local regional_resources = self,
          router_nat_external_ips: [
            hcl.resource {
              hcllabels:: ['google_compute_address', hcl.strToSnake(self.name)],
              tfimport:: '%s/%s/%s' % [base.project_id, region, self.name],
              project: if i > 1 then base.project_id else base.project,  // TODO: remove i
              region: region,
              name: external_ip_name % base {
                i: i,
                i_suffix: if i > 1 then i else '',
                vpc_logical_name: vpc_logical_name,
                region: region,
                network_name: network.name,
              },
              address_type: 'EXTERNAL',
            }
            for i in std.range(1, external_ip_count)
          ],
          router_nat: hcl.resource {
            hcllabels:: ['google_compute_router_nat', hcl.strToSnake(self.name)],
            tfimport:: '%s/%s/%s/%s' % [base.project_id, region, regional_resources.router.name, self.name],
            project: base.project,
            region: region,
            name: name % base {
              vpc_logical_name: vpc_logical_name,
              region: region,
              network_name: network.name,
            },
            router: regional_resources.router.self_ref('name'),
            source_subnetwork_ip_ranges_to_nat: source_subnetwork_ip_ranges_to_nat,
            nat_ip_allocate_option: if external_ip_count > 0 then 'MANUAL_ONLY' else 'AUTO_ONLY',
            nat_ips: [ip.self_link for ip in regional_resources.router_nat_external_ips],
          },
        } + vpcs_each_region + self.each_region,
      },
    },
  },

  // Env-level mixin.
  // Creates VPC peerings.
  // Args:
  //   from:          string, VPC to peer from.
  //   to:            string or object, VPC to peer to. Can be from another environment.
  //                 This argument supports several formats:
  //                 1.  A string representing a VPC name within the *current* environment
  //                     (e.g., 'reverse-proxies').
  //                 2.  An imported Jsonnet object representing a VPC from *another*
  //                     Jsonnet-managed GCP project (e.g., `(import 'dev7.jsonnet').vpcs.servers`).
  //                 3.  A string in the format 'projects/<project-id>/global/networks/<vpc-name>'
  //                     for peering with VPCs in projects *not* managed by Jsonnet IAC
  //                     (e.g., 'project/my-project-id/networks/my-vpc-name').
  //   name: optional string, the name pattern of the peering tf resource.
  //          Defaults to '%(from)s-to%(external_project_id_infix)s-%(to)s'.
  //          There are additional to env metadata values which can be used:
  //          - from: the value of passed from arg.
  //          - to: the value of passed to arg.
  //          - external_project_id_infix: '-' + to_vpc.project_id if to_vpc is an external project, '' otherwise.
  //   customization: optional object, additional fields to merge into the peering resource.
  // For example:
  // + peering('servers', 'reverse-proxies')
  // will generate :
  //   resource "google_compute_network_peering" "reverse-proxies-servers" {
  //     name         = "reverse-proxies-servers"
  //     network      = google_compute_network.uat3-reverse-proxies.self_link
  //     peer_network = google_compute_network.uat3-servers.self_link
  //   }
  //
  //  + vpc.peering('servers', (import 'dev7.jsonnet').vpcs.servers)
  // will generate :
  // resource "google_compute_network_peering" "dasinfra-sap-business-dev7-servers" {
  //   name         = "dasinfra-sap-business-dev7-servers"
  //   network      = google_compute_network.poc3-servers.self_link
  //   peer_network = "projects/dasinfra-sap-business-dev7/global/networks/dev7-servers"
  // }
  //
  //  + vpc.peering('servers', 'projects/my-project-id/global/networks/my-vpc-name')
  // will generate :
  // resource "google_compute_network_peering" "servers-to-my-project-id-my-vpc-name" {
  //   name         = "servers-to-my-project-id-my-vpc-name"
  //   network      = google_compute_network.poc3-servers.self_link
  //   peer_network = "projects/my-project-id/global/networks/my-vpc-name"
  // }
  peering(from,
          to,
          name='%(from)s-to%(external_project_id_infix)s-%(to)s',
          customization={}): {
    local base = self.base,
    vpcs+: {
      local from_vpc = self[from],
      local to_vpc = if std.isString(to) then
        if std.startsWith(to, 'projects/') then
          $.non_jsonnet_peer_to_vpc(
            project_id=std.split(to, '/')[1],
            vpc_name=std.split(to, '/')[4]
          )
        else
          self[to]
      else to,
      peering+: [
        hcl.resource {
          hcllabels:: ['google_compute_network_peering', hcl.strToSnake(self.name)],
          tfimport:: '%s/%s/%s' % [from_vpc.project_id, from_vpc.network.name, self.name],
          network: from_vpc.network.self_link,
        }

        // Case 1: VPCs from the same project
        + (
          if from_vpc.project_id == to_vpc.project_id then {
            name: name % base {
              from: from,
              to: to_vpc.vpc_name,
              external_project_id_infix: '',
            },
            peer_network: to_vpc.network.self_link,
            peer_network_name:: 'projects/%s/global/networks/%s' % [to_vpc.project_id, to_vpc.network.name],
          }

          // Case 2: peered VPC from another JSONNET GCP Project
          else if 'base' in to_vpc then {
            name: name % base {
              from: from,
              to: to_vpc.vpc_name,
              external_project_id_infix: '-' + to_vpc.project_id,
            },
            peer_network: 'projects/%s/global/networks/%s' % [to_vpc.project_id, to_vpc.network.name],
            // Fields below are the metadata of the peered VPC from jsonnet model, so can be used respectively by other jsonnet framework parts.
            peer_jsonnet:: {  // peer jsonnet environment metadata
              base:: to_vpc.base,
              vpc_name:: to_vpc.vpc_name,
            },
            peer_project_id:: to_vpc.base.project_id,
            local_vpc_name:: from_vpc.vpc_name,
          }

          // Case 3: so called "external project peering"
          else if 'not_jsonnet_project' in to_vpc then {
            base:: base {  // useful in downstream logic, e.g. to_vpc.peering_mixin.
              from: from,
              to: to_vpc.vpc_name,
              external_project_id_infix: '-' + to_vpc.project_id,
            },
            name: name % self.base,
            peer_network: 'projects/%s/global/networks/%s' % [to_vpc.project_id, to_vpc.vpc_name],
          } + to_vpc.peering_mixin

          else error 'Unsupported peering type to %s' % std.toString(to)
        )
        + customization,
      ],
    },
  },

  // IMPORTANT: Used only as "to" arg in peering() above for non-jsonnet projects.
  // E.g.
  // + vpc.peering(
  //   'servers',
  //   vpc.non_jsonnet_peer_to_vpc('cloudping-dev3', 'some-network'),
  // )
  // Args:
  //   project_id:    string, project id of the peered VPC.
  //   vpc_name:      string, name of the peered VPC.
  //   peering_mixin: optional object, merged to peering resource.
  //                  E.g. can be used to pass additional data for downstream
  //                  processors of peerings (e.g. miracl).
  non_jsonnet_peer_to_vpc(project_id, vpc_name, peering_mixin={}): {
    not_jsonnet_project:: true,
    peering_mixin:: peering_mixin,
    project_id: project_id,
    vpc_name: vpc_name,
  },

  // Env-level mixin.
  // Adds a router to a specific vpc.
  // Args:
  //   region - optional, set description only in one region if provided.
  router_description(vpc_name, description, region=null): {
    vpcs+:: {
      [vpc_name]+: {
        [if region != null then region else 'each_region']+: {
          router+: {
            description: description,
          },
        },
      },
    },
  },
}
