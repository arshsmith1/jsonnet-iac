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

// Mixins for component-level configuration.

{
  // Defines hierarchical structure of a component with base, passed to each level
  // IMPORTANT: comp-level mixin used exlusively in environment.libsonnet
  main_structure:
    {
      //===== The main structure of a component ================================
      // by_region (of object type)
      //  {
      //    ...
      //    [fields that are expected on all regions]: default_value
      //    ...
      //  }
      // by_instance (of object type)
      //  {
      //    ...
      //    [fields that are expected on all VMs]: default_value
      //    ...
      //  }
      // component {
      //  regions (of array type)
      //  [
      //    - region 1 :inherit: by_region
      //    ...
      //    - region N :inherit: by_region
      //        instances (of array type)
      //        [
      //          - instance 1 :inherit by_instance
      //          ...
      //          - instance N :inherit by_instance
      //        ]
      //  ]
      // }
      // E.g. you can refer to `regions[0].instances[1].rigging.resource`
      //
      // Base propagation (listing from the bottom):
      // 1. *an instance* has base from by_instance + base of current region + current VM index
      // 2. *a region* has base from by_region + region_metadata (name, zone, etc)
      // 3. *by_instance* has base from by_region
      // 4. *by_region* has base from a component
      local base = self.base,
      local count = self.count,
      local by_instance = self.by_instance,
      by_region:: {
        base:: base,  // propagating base of the component to the region template
      },
      regions:
        [
          self.by_region {
            base+:: region_metadata,
            local region_base = self.base,
            local region = self,
            instances: [
              by_instance {
                region:: region,  // reference to the region current instance belongs to
                base+:: region_base { index:: x },
              }
              for x in std.range(1, count)
            ],

          }
          for region_metadata in base.regions
        ],
      //===== End of main structure of a component =============================

      local region_template_base = self.by_region.base,
      by_instance:: {
        // propagating base of the region template to the instance template
        base:: region_template_base {
          index:: error "'index' field should be added to this object downstream",
          // e.g. app12
          hostname:: '%(comp)s%(region_number)s%(index)d' % self,
          zone:: self.zones[(self.index + 1) % std.length(self.zones)],
          zone_letter:: self.zone_letters[(self.index + 1) % std.length(self.zone_letters)],
          // This is where devdapp12.us-central1-a.c.dasinfra-dev-business-prod1.internal is built
          internal_domain:: '%(zone)s.c.%(project_id)s.internal' % self,
          fqdn:: '%(hostname)s.%(internal_domain)s' % self,
        },
      },

      // A placeholder for subcomponents, which can be added
      // by additional_embedded() mixin (see below in this file)
      sub_comps: {},
    } + vm.instance,

  // Component-level mixin.
  // This way environment.component() mixin can omit usage of name arg.
  // E.g.
  // environment.component(
  //   component.name('app')
  //   + vm.count(3)
  // ))
  // instead of
  // environment.component(
  //   name='app',
  //   mixins=
  //   vm.count(3)
  //   + vm.type.e2_standard_4,
  // )
  // Arg:
  //   name: string.
  name(name):: {
    base+:: {
      comp:: name,
    },
  },

  // Set the pattern for the name of the instance.
  // It's used to generate name of VMs and other resources.
  // Arg:
  //   name_pattern: string. It should be a string format notation like "foo-%(var)s-bar",
  //                 where 'var' can be any field in the instance's base object
  //                 (e.g., comp, region_number, index).
  // Usage:
  //   comp:: component.rhel
  //      + component.instance_name('some-name%(index)s'),
  instance_name(name_pattern): {
    by_instance+:: {
      base+:: {
        hostname:: name_pattern % self,
      },
    },
  },

  // Component-level mixin to define custom metadata at the instance level.
  // This allows metadata to be correctly scoped to instances and override regional metadata
  // when applied via mixins like on_vm().
  custom_metadata(custom_metadata): {
    by_instance+: {
      base+:: custom_metadata,
    },
  },

  // Component-level mixin.
  // Apply comp-level mixin to particular VMs
  // Example:
  //   + component.on_vms(['devlslapp53', 'devlslapp54'], vm.type.e2_standard_4)
  on_vms(insts, mixin):: {
    local comp = self,
    regions: [
      r {
        instances: [
          if std.setMember(i.base.hostname, std.set(insts))
          then
            i
            + (
              comp {
                by_instance:: {},  // don't need anything in comp in this field.
              }  //  so comp-level mixins can reference to self as comp.
              + mixin
            )
            .by_instance
          else i
          for i in super.instances
        ],
      }
      for r in super.regions
    ],
    // apply mixin also to sub-components, as we consider those part of component
    sub_comps+: {
      [c]+: $.on_vms(insts, mixin)
      for c in std.objectFields(super.sub_comps)
    },
  },

  // Component-level mixin.
  // Apply comp-level mixin to one particular VMs.
  // (similar to on_vms() above, but for one VM only)
  // Example:
  //   + component.on_vm('devlslapp53', vm.type.e2_standard_4)
  on_vm(inst, mixin):: $.on_vms([inst], mixin),

  // Component-level mixin.
  // Apply comp-level mixin to all VMs in provided regions.
  // Example:
  //   + component.on_regions([regions.east1], vm.type.e2_standard_4)
  on_regions(regions, mixin):: {
    local matches_region(base) =
      (base.region + base.region_number) in {
        [r.region + r.region_number]: null
        for r in regions
      },
    regions:
      if std.objectHasAll(mixin, 'by_instance') then [
        r {
          instances: [
            if matches_region(i.base) then i + mixin.by_instance else i
            for i in super.instances
          ],
        }
        for r in super.regions
      ]
      else [
        if matches_region(r.base) then r + mixin else r
        for r in super.regions
      ],
  },

  // Component-level mixin.
  // Apply component-level mixin to one particular region.
  // (similar to on_regions() above, but for one region only)
  // Example:
  //   + component.on_region(regions.east1, vm.type.e2_standard_4)
  on_region(region, mixin):: $.on_regions([region], mixin),

  // Component-level mixin.
  // Override default regions inherited from environment level.
  // NOTE: This is helpful when an environment has default regions defined,
  //      but only one component needs to be in a different region as exception.
  // Example:
  //   + component.set_regions([env.regions_metadata.us_central1, env.regions_metadata.us_east4])
  set_regions(regions):: {
    base+:: {
      regions:: regions,
    },
  },

  // Component-level mixin.
  // Allows a component have additional sub-component which only derives base.
  // Name of the resources will inherit main component and sub-component names:
  // e.g. if db compoent has mm subcomponent then sub-component VMs will have
  // names like sapddbmm11 where dbmm is "db" + "mm"
  additional_embedded(sub_comp):: {
    local base = self.base,
    local env = self.env,
    sub_comps: {
      [sub_comp.base.comp]: $.main_structure { base:: base, env:: env } + sub_comp {
        base+:: { comp: base.comp + super.comp },
      },
    },
  },
}
