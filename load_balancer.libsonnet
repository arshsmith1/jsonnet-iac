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

// NOTE:
//
// There is no single terraform resource LB, as load balancer is actually a
// group of resources: compute_forwarding_rule, compute_health_check,
//                     compute_instance_group, compute_backend_service.
// They are depend on each other like:
//                                   |->health_check
// forwarding_rule->backend_service->|
//                                   |->instance_group.
{

  // Comp-level mixin.
  // Creates all resources for regional ILB with default naming.
  // For dafult namings see related mixins used to compose that LB.
  default_regional:
    $.forwarding_rule()
    + $.instance_groups()
    + $.health_check()
    + $.region_backend_service(),

  // Comp-level mixin.
  // Creates all resources for global LB with default naming.
  // For dafult namings see related mixins used to compose that LB.
  default_global:
    $.global_forwarding_rule()
    + $.health_check(request_path='/')
    + $.managed_ssl_certificate()
    + $.backend_service()
    + $.url_map()
    + $.target_https_proxy()
    + $.instance_groups(),


  // --- common mixins for both regional and global LB -------------------------

  // Comp-level mixin.
  // Creates google_compute_health_check terraform resource.
  // Args:
  //   port: optional, port for tcp health check or https health check.
  //   request_path: optional, optional, request path for https health check. If provided, https_health_check is used.
  //   name: optional, default '%(env)s-%(comp)s', the name of the health check.
  //   timeout_sec: optional, default 10, how long to wait until timeout.
  //   check_interval_sec: optional, default 10, how often to perform the check.
  //   response: optional, expected response for https health check.
  //   tf_resource_name: optional, default based on name, the name of the terraform resource.
  // Example:
  //   + environment.component(
  //     ...
  //     + load_balancer.health_check(port=60000)
  //   )
  health_check(port=null, request_path=null, name='%(env)s-%(comp)s', timeout_sec=10, check_interval_sec=10, response=null, tf_resource_name=null): {
    local base = self.base,
    load_balancer+: {
      health_check: hcl.resource {
        hcllabels:: ['google_compute_health_check', if tf_resource_name != null then tf_resource_name % base else hcl.strToSnake(self.name)],
        tfimport:: '%s/%s' % [base.project_id, self.name],
        name: name % base,
        project: base.project,
        timeout_sec: timeout_sec,
        check_interval_sec: check_interval_sec,
        [if request_path == null then 'tcp_health_check']: hcl.nested_block {
          port: port,
        },
        [if request_path != null then 'https_health_check']: hcl.nested_block {
          request_path: request_path,
          [if port != null then 'port']: port,
          [if response != null then 'response']: response,
        },
      },
    },
  },


  // Comp-level mixin.
  // Creates a google_compute_https_health_check terraform resource for rpx.
  // NOTE, LEGACY: google_compute_https_health_check is a legacy health check.
  // The newer google_compute_health_check should be preferred.
  legacy_https_health_check(name='%(env)s-%(comp)s', request_path='/', timeout_sec=30, check_interval_sec=30, response=null, tf_resource_name=null, port=null): {
    local base = self.base,
    load_balancer+: {
      health_check: hcl.resource {
        hcllabels:: ['google_compute_https_health_check', if tf_resource_name != null then tf_resource_name % base else hcl.strToSnake(self.name)],
        tfimport:: '%s/%s' % [base.project_id, self.name],
        name: name % base,
        project: base.project,
        timeout_sec: timeout_sec,
        check_interval_sec: check_interval_sec,
        request_path: request_path,
        [if response != null then 'response']: response,
        [if port != null then 'port']: port,
      },
    },
  },

  // Comp-level mixin.
  // Creates google_compute_instance_group terraform resources with instances referensing VMs.
  // NOTE: instances are grouped by name pattern, so instances which produce the same name pattern
  //       will be in the same instance group. See default name pattern in args.
  // Args:
  //   name: optional, default '%(hostname)s', the name of the instance group.
  //   description: optional, default name, a human-readable description of the resource.
  //   named_ports: optional, default null. If null then no named_ports are
  //     created, otherwise it's a list of objects {name: 'name', port: 1234}.
  //   tf_resource_name: optional, default based on name, the name of the terraform resource.
  // Example:
  //   + environment.component(
  //     ...
  //     + load_balancer.instance_groups()
  //   )
  instance_groups(name='%(hostname)s', description=null, named_ports=null, tf_resource_name=null): {
    local regions = self.regions,
    load_balancer+: {
      instance_groups: std.foldl(
        function(acc, i)
          local base = i.base;
          local vm = i.compute.vm;
          acc {  // grouping by name, so instances which produce the same name pattern will be in the same instance group (see instances+: field).
            [name % base]+: hcl.resource {
              hcllabels:: ['google_compute_instance_group', if tf_resource_name != null then tf_resource_name % base else hcl.strToSnake(self.name)],
              tfimport:: '%s/%s/%s' % [base.project_id, self.zone, self.name],
              instances_group+:: [i],  // so we can use actual instances in filtering in downstream logic
              name: name % base,
              project: base.project,
              [if description != null then 'description']: description % base,
              zone: base.zone,
              instances+: [vm.self_link],
              [if named_ports != null then 'named_port']: hcl.repeated_block() {
                blocks:: named_ports,
              },
            },
          },
        [i for r in regions for i in r.instances],
        {}
      ),
    },
  },

  // Comp-level mixin.
  // Sets log config for backend service.
  // Args:
  //   log_config: A tuple with log configuration fields.
  // Example:
  //     environment.component(
  //       + load_balancer.backend_log_config({
  //           enable: true,
  //           sample_rate: 1,
  //         })
  backend_log_config(log_config): {
    load_balancer+: {
      backend+: {
        log_config: hcl.nested_block + log_config,
      },
    },
  },

  // --- end common mixins for both regional and global LB ---------------------

  // --- regional LB mixins ----------------------------------------------------

  // Comp-level mixin.
  // Modifies the google_compute_forwarding_rule to use a different subnet.
  // Args:
  //   n: integer, the index of the subnet to use for IP allocation (1-based).
  // Example:
  // + vpc.regional(
  //   ...
  //   networks=[
  //     vpc.net('servers', ['10.0.1.0/25', '10.0.2.0/26']),
  //     vpc.net('reverse-proxies', ['10.0.3.0/26']),
  //   ],
  // )
  // The first '10.0.1.0/25' is default. To use the second '10.0.2.0/26' block for ILBs:
  //     app: components.app { count:: 6 }
  //      + load_balancer.regional_subnet_n(2)
  regional_subnet_n(n): {
    by_region+: {
      local subnetwork = self.instances[0].compute.vm.network_interface { default_interface+:: { subnet_number:: n } }.blocks[0].subnetwork,
      load_balancer+: {
        forwarding_rule+: {
          subnetwork: subnetwork,
        },
      },
    },
  },

  // Comp-level mixin.
  // Creates google_compute_forwarding_rule terraform resource.
  // Args:
  //   name: optional, default '%(env)s-%(comp)s-%(region)s', the name of the forwarding rule.
  //   ports: optional, default null. If null then all_ports=true on
  //     forwarding rule, otherwise it's a list of ports.
  //   tf_resource_name: optional, default based on name, the name of the terraform resource.
  // Example:
  //   + environment.component(
  //     ...
  //     + load_balancer.forwarding_rule()
  //   )
  forwarding_rule(name='%(env)s-%(comp)s-%(region)s', ports=null, tf_resource_name=null): {
    local network = self.env.vpcs[self.by_instance.net.name].network.self_link,
    by_region+: {
      local base = self.base,
      // By default relying on the subnet of the 1st VM of the component in this region.
      // NOTE: it can happen that an environment used all IPs of this subnet
      //       (some new VMs in this component were created in 2nd IP range).
      //       In this case additional override of subnetwork will be needed
      //       to auto-allocate IPs in another IP range.
      local subnetwork = self.instances[0].compute.vm.network_interface.blocks[0].subnetwork,
      load_balancer+: {
        local lb = self,
        forwarding_rule: hcl.resource {
          hcllabels:: ['google_compute_forwarding_rule', if tf_resource_name != null then tf_resource_name % base else hcl.strToSnake(self.name)],
          tfimport:: '%s/%s/%s' % [base.project_id, base.region, self.name],
          name: name % base,
          project: base.project,
          load_balancing_scheme: 'INTERNAL',
          ip_protocol: 'TCP',
          allow_global_access: true,
          region: base.region,
          [if ports == null then 'all_ports']: true,
          [if ports != null then 'ports']: ports,
          backend_service: lb.region_backend.self_link,
          network: network,
          subnetwork: subnetwork,
        },
      },
    },
  },

  // Comp-level mixin.
  // Creates google_compute_region_backend_service terraform resource.
  // Args:
  //   name: optional, default '%(env)s-%(comp)s-%(region)s', the name of the backend service.
  //   description: optional, default null, a human-readable description of the resource.
  //   timeout_sec: optional, default 10, backend service timeout in seconds.
  // Example:
  //   + environment.component(
  //     ...
  //     + load_balancer.region_backend_service()
  //   )
  region_backend_service(name='%(env)s-%(comp)s-%(region)s', description=null, tf_resource_name=null, timeout_sec=10): {
    local lb = self.load_balancer,
    by_region+: {
      local base = self.base,
      load_balancer+: {
        region_backend: hcl.resource {
          hcllabels:: ['google_compute_region_backend_service', if tf_resource_name != null then tf_resource_name % base else hcl.strToSnake(name % base)],
          tfimport:: '%s/%s/%s' % [base.project_id, base.region, if tf_resource_name != null then tf_resource_name % base else hcl.strToSnake(self.name)],
          name: name % base,
          project: base.project,
          protocol: 'TCP',
          [if description != null then 'description']: description % base,
          timeout_sec: timeout_sec,
          session_affinity: 'CLIENT_IP',
          region: base.region,
          backend: hcl.repeated_block() {
            blocks: [
              { group: ig.self_link }
              for ig in std.objectValues(lb.instance_groups)
              if ig.instances_group[0].base.region == base.region  // taking only instance groups from the region of current lb.
            ],
          },
          health_checks: [lb.health_check.self_link],
        },
      },
    },
  },

  // --- end regional LB mixins ------------------------------------------------

  // ---- Below are mixins for global LB ---------------------------------------

  // Comp-level mixin.
  // Creates google_compute_global_address and google_compute_global_forwarding_rule terraform resources.
  // IMPORTANT: depends on load_balancer.target_https_proxy mixin.
  // Args:
  //   ip_name: string, the name of the global IP address.
  //   rule_name: string, the name of the global forwarding rule.
  //   is_ipv6: optional, default false, whether to use IPv6.
  //   tf_resource_ip_name: optional, default based on ip_name, the name of the terraform resource.
  //   tf_resource_rule_name: optional, default based on rule_name, the name of the terraform resource.
  global_forwarding_rule(
    ip_name='%(env)s-%(comp)s-global-' + if is_ipv6 then 'ipv6' else 'ipv4',
    rule_name='%(env)s-%(comp)s-global-' + if is_ipv6 then 'ipv6' else 'ipv4',
    is_ipv6=false,
    tf_resource_ip_name=null,
    tf_resource_rule_name=null
  ): {
    local base = self.base,
    load_balancer+: {
      local lb = self,
      [if is_ipv6 then 'ipv6' else 'ipv4']: {
        ip: hcl.resource {
          hcllabels:: ['google_compute_global_address', if tf_resource_ip_name != null then tf_resource_ip_name % base else hcl.strToSnake(self.name)],
          tfimport:: '%s/%s' % [base.project_id, self.name],
          name: ip_name % base,
          project: base.project,
          ip_version: if is_ipv6 then 'IPV6' else 'IPV4',
        },
        local ip = self.ip,
        fw_rule: hcl.resource {
          hcllabels:: ['google_compute_global_forwarding_rule', if tf_resource_rule_name != null then tf_resource_rule_name % base else hcl.strToSnake(self.name)],
          tfimport:: '%s/%s' % [base.project_id, self.name],
          name: rule_name % base,
          project: base.project,
          port_range: '443',
          target: lb.target_https_proxy.self_link,
          ip_address: ip.self_ref('address'),
        },
      },
    },
  },

  // Comp-level mixin.
  // Creates google_compute_managed_ssl_certificate terraform resource.
  // Args:
  //   name: optional, default '%(env)s-%(comp)s', the name of the certificate.
  //   domains: optional, default null, a list of domains to be included in the certificate.
  //   description: optional, default null, a human-readable description of the resource.
  //   tf_resource_name: optional, default based on name, the name of the terraform resource.
  managed_ssl_certificate(name='%(env)s-%(comp)s', domains=null, description=null, tf_resource_name=null): {
    local base = self.base,
    load_balancer+: {
      certificate: hcl.resource {
        hcllabels:: ['google_compute_managed_ssl_certificate', if tf_resource_name != null then tf_resource_name % base else hcl.strToSnake(self.name)],
        name: name % base,
        project: base.project,
        [if description != null then 'description']: description % base { env_upper: std.asciiUpper(base.env) },
        [if domains != null then 'managed']: hcl.nested_block {
          domains: [d % base for d in domains],
        },
      },
    },
  },


  // Comp-level mixin.
  // Creates a self-signed google_compute_ssl_certificate terraform resource.
  // Args:
  //   name: optional, default based on env and comp.
  //   private_key: required,
  //                Example:
  //                private_key=
  //                  |||
  //                    -----BEGIN PRIVATE KEY-----
  //                    .....
  //                  -----END PRIVATE KEY-----
  //                |||
  //         ),
  //   certificate: required. use hcl.escape_quotes_newlines() to escape the certificate.
  //   description: optional, the description for the SSL certificate.
  //   tf_resource_name: optional, default based on name, the name of the terraform resource.
  //   ignore_changes: optional, default [], a list of fields to ignore changes for.
  ssl_certificate(name='%(env)s-%(comp)s', private_key, certificate, description=null, tf_resource_name=null, ignore_changes=[]): {
    local base = self.base,
    load_balancer+: {
      certificate: hcl.resource {
        hcllabels:: ['google_compute_ssl_certificate', if tf_resource_name != null then tf_resource_name % base else hcl.strToSnake(self.name)],
        tfimport:: '%s/%s' % [base.project_id, self.name],
        name: name % base,
        [if description != null then 'description']: description % base,
        project: base.project,
        [if std.length(ignore_changes) > 0 then 'lifecycle']: hcl.nested_block {
          ignore_changes: [hcl.expression(i) for i in ignore_changes],
        },
        private_key: hcl.escape_quotes_newlines(private_key),
        certificate: hcl.escape_quotes_newlines(certificate),
      },
    },
  },

  // Comp-level mixin.
  // Creates google_compute_backend_service terraform resource.
  // Args:
  //   name: optional, default '%(env)s-%(comp)s', the name of the backend service.
  //   description: optional, default null, a human-readable description of the resource.
  //   session_affinity: optional, default null, the type of session affinity, e.g., 'CLIENT_IP'.
  //   timeout_sec: optional, default 10, backend service timeout in seconds.
  //   params: optional, default {}, additional backend parameters.
  //   log_config: optional, default null, log configuration block.
  //   ig_filter: optional, default no filtering.
  //              A function that takes (instance_group) and returns true to include the it in the backend service.
  //   port_name: optional, default 'https', the name of the port.
  //   protocol: optional, default 'HTTPS', the protocol used by the backend service.
  //   connection_draining_timeout_sec: optional, default null, The time in seconds to wait for the existing
  //                                    connections to finish draining.
  //   tf_resource_name: optional, default based on name, the name of the terraform resource.
  // Example:
  //   + environment.component(
  //     ...
  //     + load_balancer.backend_service(session_affinity='CLIENT_IP', timeout_sec=30, params={})
  //   )
  backend_service(
    name='%(env)s-%(comp)s',
    description=null,
    session_affinity=null,
    timeout_sec=10,
    params={},
    log_config=null,
    ig_filter=function(ig) true,
    port_name='https',
    protocol='HTTPS',
    connection_draining_timeout_sec=null,
    tf_resource_name=null
  ): {
    local base = self.base,
    load_balancer+: {
      local lb = self,
      backend: hcl.resource {
        hcllabels:: ['google_compute_backend_service', if tf_resource_name != null then tf_resource_name % base else hcl.strToSnake(self.name)],
        tfimport:: '%s/%s' % [base.project_id, self.name],
        name: name % base,
        project: base.project,
        [if description != null then 'description']: description % base { env_upper: std.asciiUpper(base.env) },
        timeout_sec: timeout_sec,
        [if port_name != null then 'port_name']: port_name,
        protocol: protocol,
        [if connection_draining_timeout_sec != null then 'connection_draining_timeout_sec']: connection_draining_timeout_sec,
        backend: hcl.repeated_block() {
          blocks:: [
            {
              group: ig.self_link,
            } + params
            for ig in std.objectValues(lb.instance_groups)
            if ig_filter(ig)
          ],
        },
        [if session_affinity != null then 'session_affinity']: session_affinity,
        health_checks: [lb.health_check.self_link],
        [if log_config != null then 'log_config']: hcl.nested_block + log_config,
      },
    },
  },

  // Comp-level mixin.
  // Creates google_compute_url_map terraform resource.
  // Args:
  //   name: optional, default '%(env)s-%(comp)s', the name of the URL map.
  //   description: optional, default null, a human-readable description of the resource.
  //   tf_resource_name: optional, default based on name, the name of the terraform resource.
  url_map(name='%(env)s-%(comp)s', description=null, tf_resource_name=null): {
    local base = self.base,
    load_balancer+: {
      local lb = self,
      url_map: hcl.resource {
        hcllabels:: ['google_compute_url_map', if tf_resource_name != null then tf_resource_name % base else hcl.strToSnake(self.name)],
        tfimport:: '%s/%s' % [base.project_id, self.name],
        name: name % base,
        project: base.project,
        [if description != null then 'description']: description % base,
        default_service: lb.backend.self_link,
      },
    },
  },

  // Comp-level mixin.
  // Creates google_compute_target_https_proxy terraform resource.
  // Args:
  //   name: optional, default '%(env)s-%(comp)s', the name of the target HTTPS proxy.
  //   description: optional, default null, a human-readable description of the resource.
  //   tf_resource_name: optional, default based on name, the name of the terraform resource.
  target_https_proxy(name='%(env)s-%(comp)s', description=null, tf_resource_name=null): {
    local base = self.base,
    load_balancer+: {
      local lb = self,
      target_https_proxy: hcl.resource {
        hcllabels:: ['google_compute_target_https_proxy', if tf_resource_name != null then tf_resource_name % base else hcl.strToSnake(self.name)],
        tfimport:: '%s/%s' % [base.project_id, self.name],
        name: name % base,
        project: base.project,
        [if description != null then 'description']: description % base,
        url_map: lb.url_map.self_link,
        ssl_certificates: [lb.certificate.self_link],
      },
    },
  },
}
