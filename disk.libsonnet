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
local vm = import 'vm.libsonnet';
{
  // Component-level mixin.
  // Created google_compute_disk terraform resource.
  // Attaches the disk to the VM.
  // Required for a component deinition.
  // Args:
  //   image: the image of the disk, e.g. 'projects/enterpriselinux-trusted-images/global/images/family/google-rhel-8-6-sap-ha-stable'.
  //   snapshot_policy: the mixin disk.snapshot_policy() of snapshot policy to attach to the disk.
  //   size: size of the disk in GB.
  boot(image, snapshot_policy=null, size=50): {
    by_instance+: {
      local base = self.base,
      local vm_name = self.compute.vm.name,
      disk_by_name+: {
        boot: hcl.resource {
          labelname:: std.join('-', [base.hostname, self.zone_suffix]),
          hcllabels:: ['google_compute_disk', hcl.strToSnake(self.labelname)],
          tfimport:: '%s/%s/%s' % [base.project_id, self.zone, self.name],
          zone_suffix:: base.zone,
          project: base.project,
          zone: base.zone,
          name: vm_name,
          image: image % base,
          type: 'pd-ssd',
          lifecycle: hcl.nested_block {
            ignore_changes: [
              hcl.expression('snapshot'),
              hcl.expression('image'),
            ],
          },
          timeouts: hcl.nested_block {
            create: '1h',
            update: '1h',
            delete: '1h',
          },
          size: size,
        },
      },
    },
  } + (if snapshot_policy != null then $.snapshot_policy_attachments('boot', snapshot_policy) else {}),

  // Component-level mixin.
  // Creates google_compute_disk terraform resource.
  // Attaches the disk to the VM.
  // Args:
  //   disk_name: logical name of the disk (e.g. 'nfs-ha', where real resource name will be <vm_name>-<disk_name>).
  //   size: size of the disk in GB.
  //   standard: if true, the disk will be created as pd-standard.
  //   hdx: if true, the disk will be created as hyperdisk-extreme.
  //   iops: number of IOPS for hyperdisk-extreme disks.
  //   snapshot_policy: the mixin disk.snapshot_policy() of snapshot policy to attach to the disk.
  //   as_attached_disk_resource: if true, creates google_compute_attached_disk
  //                              terraform resource, otherwise adds attached_disk
  //                              block to the VM. Set to null to not create
  //                              attached disk resource at all.
  add(disk_name,
      size,
      standard=false,
      hdx=false,
      iops=$.hdx_default_iops,
      snapshot_policy=null,
      as_attached_disk_resource=false):
    {
      assert (!(hdx && standard)) :
             'Cannot set disk type to both hdd and hyperdisk-extreme at the same time',
      by_instance+:: {
        local base = self.base,
        local vm = self.compute.vm,
        disk_by_name+: {
          [disk_name]: hcl.resource {
            hcllabels:: ['google_compute_disk', hcl.strToSnake(self.labelname)],
            tfimport:: '%s/%s/%s' % [base.project_id, self.zone, self.name],
            labelname:: std.join('-', [base.hostname, self.suffix, self.zone_suffix]),
            zone_suffix:: base.zone,
            suffix:: disk_name,
            name: '%s-%s' % [vm.name, self.suffix],
            size: size,
            project: base.project,
            zone: base.zone,
            type: 'pd-ssd',
            lifecycle: hcl.nested_block {
              ignore_changes: [hcl.expression('snapshot')],
            },
            timeouts: hcl.nested_block {
              create: '1h',
              update: '1h',
              delete: '1h',
            },
          },
        },
      },
    }
    + (if as_attached_disk_resource != null then vm.attach_disk(disk_name, as_attached_disk_resource) else {})
    + (if snapshot_policy != null then $.snapshot_policy_attachments(disk_name, snapshot_policy) else {})
    + (if standard then $.standard(disk_name) else {})
    + (if hdx then $.hyperdisk(disk_name, iops) else {}),

  // Component-level mixin.
  // Removes the disk from the component.
  remove(disk_name): {
    by_instance+:: {
      disk_by_name+: {
        // hide and mark removed
        [disk_name]+:: { removed:: true },
      },
    },
  },

  // Component-level mixin.
  // removes a list of disks.
  // only use this if you are sure that the instance is not using the disk.
  remove_list(removable_disks): std.foldl(
    function(acc, disk_name) acc + $.remove(disk_name),
    removable_disks,
    {}
  ),

  // Component-level mixin.
  // removes all none-boot disks attached to instances.
  // only use this if you are sure that the instance is not using the disk.
  // example use case: sunset a SAP component.
  remove_all_attached: {
    by_instance+:: {
      disk_by_name+: std.foldl(
        function(acc, disk_name) acc {
          // hide and mark removed, except for boot disk
          [if disk_name != 'boot' then disk_name]+:: { removed:: true },
        },
        std.objectFields(super.disk_by_name),
        {}
      ),
    },
  },

  // Component-level mixin.
  // Sets auto_delete to true for the boot disk of the instance.
  autoDeleteBoot: {
    by_instance+: {
      compute+: {
        vm+: {
          boot+: {
            auto_delete: true,
          },
        },
      },
    },
  },

  // Component-level mixin.
  // Creates google_compute_disk_resource_policy_attachment terraform resources
  // (which attaches policy to a disk) for all <disk_suffix> disks of the component.
  // Args:
  //   disk_suffix: logical name of the disk (e.g. 'nfs-ha', where real resource name will be <vm_name>-<disk_suffix>).
  //   snapshot_policy: the mixin disk.snapshot_policy() of snapshot policy to attach to the disk.
  //
  // NOTE: this mixin is not used for regional disks. Use snapshot_policy_attachments_regional instead.
  snapshot_policy_attachments(disk_suffix, snapshot_policy): {
    local regions = self.regions,
    project+:: {
      // aggregate snapshot policies for all instances in all regions.
      // This will be used to aggregate all snapshot policies
      // from all components on env level.
      snapshot_policies+: std.foldl(
        function(acc, i)
          acc {
            [i.base.region]+: i.project.snapshot_policies,
          },
        [
          i
          for r in regions
          for i in r.instances
        ],
        {},
      ),
    },
    by_instance+:: snapshot_policy {
      local base = self.base,
      local p = self.project.snapshot_policies[snapshot_policy.project.snapshot_policies.logical_name],
      local d = self.disk_by_name[disk_suffix],
      snapshot_policy_attachments+: {
        [if !('removed' in d) then disk_suffix]: hcl.resource {
          hcllabels:: ['google_compute_disk_resource_policy_attachment', hcl.strToSnake(d.labelname)],
          tfimport:: '%s/%s/%s/%s' % [base.project_id, base.zone, d.name, p.name],
          suffix:: d.suffix,
          disk: d.self_ref('name'),
          project: base.project,
          name: p.self_ref('name'),
          zone: base.zone,
        },
      },
    },
  },

  // Component-level mixin.
  // Removes the snapshot policy attachments for all disks of the component.
  remove_snapshot_policy_attachments: {
    by_instance+:: {
      snapshot_policy_attachments: {},
    },
    by_region+:: {
      snapshot_policy_attachments: {},
    },
  },

  // Env-level mixin.
  // Creates thegoogle_compute_resource_policy terraform resources for given region.
  // NOTE
  //      Main use-case is to be passed in as a snapshot_policy argument
  //      to disk.add() or disk.add_regional()
  //      Usually not used at env level directly.

  // IMPORTANT: use disk.snapshot_policies_from_components at env level to materialize the snapshot policies in the project.tf file.
  //
  // Args:
  //   logical_name: logical name of the snapshot policy (e.g. 'nfs-snapshot-policy', where real resource name will be <logical_name>-<region>).
  //   name: optional, if not provided, will be derived from logical_name and region.
  //   tf_resource_name: optional, if not provided, will be derived from logical_name.
  //   region: optional, if not provided, will be derived from the component's default region.
  //   start_time: time of the day (in UTC) when snapshots will be created.
  //   days_in_cycle: number of days in the snapshot cycle for daily schedules.
  //   hours_in_cycle: number of hours in the snapshot cycle for hourly schedules.
  //   retention_days: number of days to keep snapshots before deleting them.
  //   snapshot_properties: optional, a block of snapshot properties, e.g. {storage_locations: ['us']}.
  //   on_source_disk_delete: either KEEP_AUTO_SNAPSHOTS or APPLY_RETENTION_POLICY.
  snapshot_policy(logical_name, name=null, tf_resource_name=null, region=null, start_time, days_in_cycle=null, hours_in_cycle=null, retention_days, snapshot_properties=null, on_source_disk_delete='KEEP_AUTO_SNAPSHOTS'): {
    local base = self.base,
    project+:: {
      snapshot_policies+: {
        logical_name:: logical_name,  // used in snapshot_policy_attachments mixin to resolve the logical name to be able to find the policy in the project.snapshot_policies
        [logical_name]: hcl.resource {
          hcllabels:: ['google_compute_resource_policy', self.tf_resource_name % base],
          tf_resource_name::
            if tf_resource_name != null
            then tf_resource_name
            else hcl.strToSnake(self.name % base),
          project: base.project,
          name: if name != null then name % base else '%s-%s' % [logical_name, self.region],
          region: if region != null then region else base.region,
          snapshot_schedule_policy: hcl.nested_block {
            retention_policy: hcl.nested_block {
              on_source_disk_delete: on_source_disk_delete,
              max_retention_days: retention_days,
            },
            [if snapshot_properties != null then 'snapshot_properties']: hcl.nested_block + snapshot_properties,
            schedule+: hcl.nested_block {
              [if days_in_cycle != null then 'daily_schedule']+: hcl.nested_block {
                days_in_cycle: days_in_cycle,
                start_time: start_time,
              },
              [if hours_in_cycle != null then 'hourly_schedule']+: hcl.nested_block {
                hours_in_cycle: hours_in_cycle,
                start_time: start_time,
              },
            },
          },
        },
      },
    },
  },

  // Env-level mixin.
  // Aggregates all snapshot policies from all components
  // google_compute_resource_policy terraform resources will be created in project.tf
  snapshot_policies_from_components: {
    local components = std.objectValues(self.components),
    project+:: {
      snapshot_policies+: std.foldl(
        function(acc, c)
          if 'project' in c && 'snapshot_policies' in c.project
          then acc + c.project.snapshot_policies else acc,
        components,
        {}
      ),
    },
  },

  // Component-level mixin.
  resize(disk_name, gb): {
    by_instance+:: {
      disk_by_name+: {
        [disk_name]+: { size: gb },
      },
    },
  },

  // Component-level mixin.
  // Adds count scratch disks to the hosts in the selected component.
  // Supported interfaces are NVME(default) and SCSI.
  local_ssd(count, interface='NVME'): {
    by_instance+:: {
      compute+: {
        vm+: {
          scratch_disks: hcl.repeated_block('scratch_disk') {
            blocks: [
              { interface: interface }
              for _ in std.range(0, count - 1)
            ],
          },
        },
      },
    },
  },

  // Component-level mixin.
  // Sets the disk type to pd-ssd.
  ssd(disk_name): {
    by_instance+:: {
      disk_by_name+: {
        [disk_name]+: { type: 'pd-ssd' },
      },
    },
  },

  // Component-level mixin.
  // Sets the disk type to pd-standard.
  standard(disk_name): {
    by_instance+:: {
      disk_by_name+: {
        [disk_name]+: { type: 'pd-standard' },
      },
    },
  },

  // Component-level mixin.
  // Sets the disk type to pd-balanced.
  balanced(disk_name): {
    by_instance+:: {
      disk_by_name+: {
        [disk_name]+: { type: 'pd-balanced' },
      },
    },
  },

  // X4 instances need hyperdisk balanced disks and you must
  // set both throughput and IOPS
  hdx_balanced_default_iops:: 24000,
  hdx_balanced_default_throughput:: 2400,

  // Component-level mixin.
  // Sets the disk type to hyperdisk-balanced.
  hyperdisk_balanced(disk_name, iops=$.hdx_balanced_default_iops, throughput=$.hdx_balanced_default_throughput): {
    by_instance+:: {
      disk_by_name+: {
        [disk_name]+: {
          provider: hcl.expression('google-beta'),
          type: 'hyperdisk-balanced',
          provisioned_iops: iops,
          provisioned_throughput: throughput,
        },
      },
    },
  },

  hdx_default_iops:: 80000,

  // Component-level mixin.
  // Sets the disk type to hyperdisk-extreme.
  hyperdisk(disk_name, iops=$.hdx_default_iops): {
    by_instance+:: {
      local base = self.base,
      disk_by_name+: {
        [disk_name]+: {
          // TODO(dgarmash): provisioned_iops are not supported in the checked in
          // version of the non-beta provider yet. Stop using the beta provider once
          // the non-beta provider is recent enough.
          provider: hcl.expression('google-beta'),
          type: 'hyperdisk-extreme',
          provisioned_iops: iops,
        },
      },
    },
  },

  // Component-level mixin.
  // Creates a google_compute_region_disk terraform resource for a component.
  // A regional disk will have the component name as a prefix,
  // and it will be suffixed by the region name
  //
  // Args:
  //   disk_name: logical name of the disk (e.g. 'nfs-ha', where real resource
  //              name will be according to name pattern).
  //   size: optional, size of the disk in GB.
  //   name: optional, if not provided, will be derived from
  //                        the component name, region and disk name.
  //   snapshot_policy: optional, the mixin disk.snapshot_policy() of snapshot
  //                    policy to attach to the disk.
  //   replica_zones: optional, list of zones to use for disk replicas.
  //
  // Example:
  // app: components.app
  //    + disk.add_regional('my-disk', 10)
  add_regional(disk_name,
               size=null,
               name='%(comp)s-%(region)s-%(disk_name)s',
               snapshot_policy=null,
               replica_zones=null): {
    by_region+:: {
      local base = self.base,
      regional_disks+: {
        [disk_name]: hcl.resource {
          hcllabels:: ['google_compute_region_disk', hcl.strToSnake(self.labelname)],
          suffix:: base.region,
          labelname:: std.join('-', [base.comp, disk_name, self.suffix]),
          snapshot_policy:: snapshot_policy,
          name: name % base { disk_name:: disk_name },
          replica_zones: if replica_zones != null then replica_zones else base.zones,
          region: base.region,
          project: base.project,
          type: 'pd-ssd',
          [if size != null then 'size']: size,
          lifecycle: hcl.nested_block {
            ignore_changes: [hcl.expression('snapshot')],
          },
          timeouts: hcl.nested_block {
            create: '1h',
            update: '1h',
            delete: '1h',
          },
        },
      },
    },
  } + (if snapshot_policy != null then $.snapshot_policy_attachments_regional(disk_name, snapshot_policy) else {}),

  // Component-level mixin.
  // Creates google_compute_region_disk_resource_policy_attachment terraform resources
  // (which attaches policy to a disk) for all <disk_suffix> regional disks of the component.
  // Args:
  //   disk_suffix: logical name of the regional disk (e.g. 'nfs-ha', where real resource name will be <disk_suffix>-<region>).
  //   snapshot_policy: the mixin disk.snapshot_policy() of snapshot policy to attach to the disk.
  //
  // NOTE: this mixin is not used for zonal disks. Use snapshot_policy_attachments instead.
  snapshot_policy_attachments_regional(disk_suffix, snapshot_policy): {
    local regions = self.regions,
    project+:: {
      // aggregate snapshot policies for all instances in all regions.
      // This will be used to aggregate all snapshot policies
      // from all components on env level.
      snapshot_policies+: std.foldl(
        function(acc, r)
          acc {
            [r.base.region]+: r.project.snapshot_policies,
          },
        regions,
        {},
      ),
    },
    by_region+:: snapshot_policy {
      local base = self.base,
      local d = self.regional_disks[disk_suffix],
      local p = self.project.snapshot_policies[snapshot_policy.project.snapshot_policies.logical_name],
      snapshot_policy_attachments+: {
        [disk_suffix]: hcl.resource {
          hcllabels:: ['google_compute_region_disk_resource_policy_attachment', hcl.strToSnake(d.labelname)],
          tfimport:: '%s/%s/%s/%s' % [base.project_id, base.region, d.name, p.name],
          suffix:: d.suffix,
          disk: d.name,
          project: base.project,
          name: p.self_ref('name'),
          region: base.region,
          depends_on: [
            d.self_ref(),
          ],
        },
      },
    },
  },
}
