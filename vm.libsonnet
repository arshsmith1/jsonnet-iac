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
  // Component-level mixin.
  // Defines the number of VMs to be created in a component.
  // All VMs will be evenly distributed between defined zones in a region.
  // Every region will have "count" VMs.
  // Example:
  //  + environment.component(
  //     ...
  //      + vm.count(4)
  count(vms_count): {
    count:: vms_count,
  },

  // Component-level mixin.
  // Add an additional NIC to the VM.
  // A VPC name and subnet number are mandatory arguments.
  // Purpose of this function is to allow VM sto use an additional NIC
  // to access internal e.g non peered/routed networks constrained to
  // the GCP project only
  // Example:
  // + environment.component(
  //     ...
  //     + vm.additional_nic('bw-internal'),
  additional_nic(vpc_name, subnet_number=1):: {
    local env = self.env,
    by_instance+: {
      local base = self.base,
      compute+: {
        vm+: {
          network_interface+: {
            blocks+:: [
              {
                subnetwork: env.vpcs[vpc_name][base.region].subnet_tuples[subnet_number - 1].subnet.self_link,
              },
            ],
          },
        },
      },
    },
  },

  // Component-level mixin.
  // Sets the desired status of the VM to RUNNING.
  always_running_state: {
    by_instance+: {
      compute+: {
        vm+: {
          desired_status: 'RUNNING',
        },
      },
    },
  },

  // Component-level mixin.
  // Forces a VM to be in TERMINATED status
  always_terminated_state: {
    by_instance+: {
      compute+: {
        vm+: {
          desired_status: 'TERMINATED',
        },
      },
    },
  },

  // Component-level mixin.
  // To set another (not 1st which is default) subnet from the list of subnets for given vpc of current component
  // Example:
  // + vpc.regional(
  //   ...
  //   networks=[
  //     vpc.net('servers', [sap.ipdb_net_range(25), sap.ipdb_net_range(26)]),
  //     vpc.net('reverse-proxies', [sap.ipdb_net_range(29)]),
  //   ],
  // )
  // the first ipdb(25) is default and to use second block for given component or VM do
  //     + environment.component(
  //     ...
  //      + vm.subnet_number(2)
  //
  // for one VM change: + component.on_vm('sappapp55', vm.subnet_number(3))
  // This function is used to modify the subnet number of the first NIC only.
  subnet_number(number):: {
    by_instance+: {
      compute+: {
        vm+: {
          network_interface+: {
            default_interface+:: {
              subnet_number:: number,
            },
          },
        },
      },
    },
  },

  // Comp-level mixin.
  // Declares VPC network "logical" name for the component.
  net(name): {
    by_instance+:: {
      net:: {
        name: name,
      },
    },
  },

  // Component-level mixin.
  // Sets the stack_type for the default network interface.
  // Example:
  // + environment.component(
  //     ...
  //      + vm.network_interface_stack_type('IPV4_IPV6')
  network_interface_stack_type(stack_type):: {
    by_instance+: {
      compute+: {
        vm+: {
          network_interface+: {
            default_interface+: {
              stack_type: stack_type,
            },
          },
        },
      },
    },
  },

  // Dedicated to be used exclusively in component.libsonnet to create VMs.
  // One might ask: "why it's not in compoent.libsonnet then?".
  // The answer: we isolate all instnce realted logic in this file,
  // so compoent logic is focused only on the logical structure of a component.
  instance: {
    local env = self.env,
    by_instance+:: {
      local net = self.net,
      local base = self.base,
      local boot_disk = self.disk_by_name.boot,
      compute: {
        vm: hcl.resource {
          tfimport:: '%s/%s/%s' % [base.project_id, self.zone, self.name],
          hcllabels:: ['google_compute_instance', hcl.strToSnake(base.hostname)],
          name: base.hostname,
          project: base.project,
          boot: hcl.block('boot_disk') {
            auto_delete: false,
            source: boot_disk.self_link,
            device_name: 'persistent-disk-0',
          },
          machine_type: error 'machine_type field should be set by vm.type.* mixin',
          network_interface: hcl.repeated_block('network_interface') {
            default_interface:: {
              subnet_number:: 1,  // by default we use 1st subnet
              subnetwork: env.vpcs[net.name][base.region].subnet_tuples[self.subnet_number - 1].subnet.self_link,
            },
            blocks:: [self.default_interface],
          },
          lifecycle: hcl.nested_block {
            // since pacemaker can change these ips, we ignore changes on them.
            ignore_changes: [
              hcl.expression('min_cpu_platform'),
              hcl.expression('network_interface[0].alias_ip_range'),
            ],
          },
          service_account: hcl.nested_block {
            assert std.length(self.scopes) > 0 : 'SA scopes should be set by vm.sa_scopes() or vm.sa_scope() mixins for %s component' % base.comp,
            scopes: [],
            email: error 'email field should be set by vm.service_account_id() or iam.sa() mixins',
          },
          labels: {},
          metadata: {},
          tags: [],
          zone: base.zone,
          scheduling: hcl.nested_block {
            automatic_restart: true,
            on_host_maintenance: 'MIGRATE',
            preemptible: false,
          },
        },
      },
    },
  },

  // Component-level mixin.
  // Creates stable internal IP address for VMs of a component.
  stable_internal_ip(name='%(hostname)s-internal'): {
    by_instance+: {
      local base = self.base,
      compute+: {
        local vm = self.vm,
        internal_ip: hcl.resource {
          hcllabels:: ['google_compute_address', hcl.strToSnake(self.name)],
          tfimport:: '%s/%s/%s' % [base.project_id, base.region, self.name],
          name: name % base,
          project: base.project,
          region: base.region,
          address_type: 'INTERNAL',
          subnetwork: vm.network_interface.blocks[0].subnetwork,
        },
        local internal_ip = self.internal_ip,
        vm+: {
          network_interface+: {
            default_interface+:: {
              network_ip: internal_ip.self_ref('address'),
            },
          },
        },
      },
    },
  },

  // Component-level mixin.
  // Attaches zonal disk to VMs of a component.
  // If as_attached_disk_resource=true, creates google_compute_attached_disk
  // terraform resource, otherwise adds attached_disk block to the VM.
  // Args:
  //   disk_name: logical name of the disk to attach.
  //   as_attached_disk_resource: optional, if true, the attached disk will be
  //                              declared as a separate resource.
  // Example:
  // + environment.component(
  //     ...
  //     + vm.attach_disk(disk_name='my-disk')
  attach_disk(disk_name, as_attached_disk_resource=false): {
    by_instance+:: {
      local base = self.base,
      local d = self.disk_by_name[disk_name],
      local vm = self.compute.vm,
      [if as_attached_disk_resource then 'disk_attachments']+: {
        [if !('removed' in d) then disk_name]: hcl.resource {
          hcllabels:: ['google_compute_attached_disk', hcl.strToSnake(base.hostname + '_' + disk_name)],
          tfimport:: '%s/%s/%s/%s' % [base.project_id, base.zone, vm.name, d.name],
          instance: vm.self_link,
          disk: d.self_link,
          project: base.project,
          zone: base.zone,
          device_name: d.name,
        },
      },
      compute+: {
        [if !as_attached_disk_resource then 'vm']+: {
          attached_disks+: hcl.repeated_block('attached_disk') {
            blocks+: if !('removed' in d) then [{
              device_name: d.self_ref('name'),
              source: d.self_link,
            }] else [],
          },
        },
      },
    },
  },

  // Component-level mixin.
  // Attaches regional disk to VMs of a component.
  // If as_attached_disk_resource=true, creates google_compute_attached_disk
  // terraform resource, otherwise adds attached_disk block to the VM.
  // Args:
  //   disk_name: optional, logical name of the disk to attach.
  //              Exactly one of disk_name or source_link must be provided.
  //   as_attached_disk_resource: optional, if true, the attached disk will be
  //                              declared as a separate resource.
  //   device_name: optional, The device name of the disk attachment.
  //   source_link: optional, source link of disk to attach.
  //                Valid only if as_attached_disk_resource=false.
  //                Exactly one of disk_name or source_link must be provided.
  // Example:
  // + environment.component(
  //     ...
  //     + vm.attach_regional_disk(disk_name='my-regional-disk')
  attach_regional_disk(disk_name=null, as_attached_disk_resource=false, device_name=null, source_link=null): {
    assert as_attached_disk_resource == false || source_link == null : 'source_link is not valid with as_attached_disk_resource=true',
    assert (disk_name != null) != (source_link != null) : 'Exactly one of disk_name or source_link must be provided',
    by_instance+:: {
      local base = self.base,
      local d = self.region.regional_disks[disk_name],
      local vm = self.compute.vm,
      [if as_attached_disk_resource then 'regional_disk_attachments']+: {
        [disk_name]: hcl.resource {
          hcllabels:: ['google_compute_attached_disk', hcl.strToSnake(base.hostname + '_' + disk_name)],
          tfimport:: '%s/%s/%s/%s' % [base.project_id, base.zone, vm.name, d.name],
          instance: vm.self_link,
          disk: d.self_link,
          project: base.project,
          zone: base.zone,
          device_name: if device_name != null then device_name else d.name,
        },
      },
      compute+: {
        [if !as_attached_disk_resource then 'vm']+: {
          attached_disks+: hcl.repeated_block('attached_disk') {
            blocks+: [{
              device_name: if device_name != null then device_name else d.self_ref('name'),
              source: if source_link != null then source_link else d.self_link,
            }],
          },
        },
      },
    },
  },

  // Component-level mixin.
  // Sets metadata entry for the VM.
  // Example:
  // + environment.component(
  //     ...
  //     + vm.metadata('my_key', 'my_value')
  metadata(key, value): {
    by_instance+: {
      local base = self.base,
      compute+: {
        vm+: {
          metadata+: {
            [key]: value % base,
          },
        },
      },
    },
  },

  // Component-level mixin.
  // Sets service account scopes to VMs of a component.
  // IMPORTANT: It overrides any scopes set before.
  // NOTE: don't provide prefix 'https://www.googleapis.com/auth/',
  //       just name of the scope, e.g. 'cloud-platform'
  //       for 'https://www.googleapis.com/auth/cloud-platform'.
  // Example:
  // + environment.component(
  //     ...
  //      + vm.sa_scopes(['cloud-platform', 'logging.write'])
  sa_scopes(scopes):: {
    by_instance+: {
      compute+: {
        vm+: {
          service_account+: {
            scopes: ['https://www.googleapis.com/auth/' + s for s in scopes],
          },
        },
      },
    },
  },

  // Component-level mixin.
  // Adds an additional scope to the VM service account.
  // NOTE: don't provide prefix 'https://www.googleapis.com/auth/',
  //       just name of the scope, e.g. 'cloud-platform'
  //       for 'https://www.googleapis.com/auth/cloud-platform'.
  // Example:
  // + environment.component(
  //     ...
  //      + vm.sa_scope('cloud-platform')
  sa_scope(scope): {
    by_instance+: {
      compute+: {
        vm+: {
          service_account+: {
            scopes+: ['https://www.googleapis.com/auth/' + scope],
          },
        },
      },
    },
  },

  // Component-level mixin.
  // Sets network tags to VMs of a component.
  // Example:
  // + environment.component(
  //     ...
  //      + vm.network_tags(['my_tag'])
  network_tags(tags): {
    by_instance+: {
      local base = self.base,
      compute+: {
        vm+: {
          tags:
            local resolve(t) = if std.isString(t) then t % base else t;
            if std.isArray(tags) then [resolve(t) for t in tags]
            else [resolve(tags)],
        },
      },
    },
  },

  // Component-level mixin.
  // Adds an additional network tag to VMs of a component.
  // Example.
  // + environment.component(
  //     ...
  //     + vm.network_tag('fancy_gcp_feature_tag')
  network_tag(tag): {
    by_instance+: {
      local base = self.base,
      compute+: {
        vm+: {
          tags+: [tag % base],
        },
      },
    },
  },

  // Component-level mixin.
  // Sets auto_delete flag for the boot disk of the VM.
  // Example:
  // + environment.component(
  //     ...
  //      + vm.boot_auto_delete(false)
  boot_auto_delete(auto_delete=true): {
    by_instance+: {
      compute+: {
        vm+: {
          boot+: {
            auto_delete: auto_delete,
          },
        },
      },
    },
  },

  // Component-level mixin.
  // Sets allow_stopping_for_update flag for the VM.
  // NOTE: allow_stopping_for_update is false by default is not set.
  // Example:
  // + environment.component(
  //     ...
  //      + vm.allow_stopping_for_update(true)
  allow_stopping_for_update(allow): {
    by_instance+: {
      compute+: {
        vm+: {
          allow_stopping_for_update: allow,
        },
      },
    },
  },

  // Component-level mixin.
  // Sets email field of service account of the VM resource.
  // Format:
  //        <account_id>@<project_id>.iam.gserviceaccount.com
  // Example:
  //      + vm.service_account_id('my-%(comp)s')
  // will result in: my-app@<project_id>.iam.gserviceaccount.com
  service_account_id(account_id): {
    by_instance+: {
      local base = self.base,
      compute+: {
        vm+: {
          service_account+: {
            email: '%s@%s.iam.gserviceaccount.com' % [account_id % base, base.project_id],
          },
        },
      },
    },
  },

  // Component-level mixin.
  // Sets the machine type to all VMs of the component.
  // Example:
  // + environment.component(
  //     ...
  //     + vm.machine_type('n2-standard-16')
  machine_type(t): {
    by_instance+: {
      compute+: {
        vm+: {
          machine_type: t,
        },
      },
    },
  },

  // Component-level mixin.
  // Sets a label on the VM.
  // null value will remove the label.
  // Example:
  // + environment.component(
  //     ...
  //     + vm.label('my_key', 'my_value')
  label(label_name, value): {
    by_instance+: {
      local base = self.base,
      compute+: {
        vm+: {
          // If the label value is null, we set the field to be hidden, thereby
          // removing the label from our final manifestation.
          labels+: {
            [if value != null then label_name]: if std.isString(value) then value % base else value,
            [if value == null then label_name]:: null,
          },
        },
      },
    },
  },

  // Component-level mixin.
  // Makes VMs of the component depend of "dependency".
  // dependency - if string then treated like expression,
  //              or can be object obtained from any hcl.resource by self_ref()
  depend_on(dependency): {
    by_instance+: {
      local base = self.base,
      compute+: {
        vm+: {
          depends_on+: [
            if std.isString(dependency) then hcl.expression(dependency) else dependency,
          ],
        },
      },
    },
  },
}
