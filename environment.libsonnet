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

// Collections of mixins for defining logical GCP environments.
// All mixins are environment-level.
local component = import 'component.libsonnet';
local hcl = import 'hcl.libsonnet';
local vpc = import 'vpc.libsonnet';

{
  // Env-level mixin to define environment properties (including GCP project information).
  // Creates `project` hidden field as a placeholder for gcp project level resources with initial project data resources.
  // `project` field is materialized into project.tf file.
  //
  // Args:
  //   env:            The name of the env, e.g. 'dev1' or 'uat4'.
  //   project_id:     GCP project ID.
  //   service_name:   [optional] The service ID, e.g. 'myservice'.
  //                   It's a logical group of environments
  //                   (which are separate GCP projects).
  //   tf_comments:    [optional] true by default.
  //                   If true, tf comments for the Terraform resources.
  //   existing_project: [optional] true by default.
  //                     If false, the project is assumed to exist and the terraform data is used to refer to it.
  //                     If true, the project is created by terraform.
  //   project_custom:   [optional] custom fields to merge into the project resource.
  //
  // Examples:
  //
  // 1. Existing project:
  //
  // environment.gcp(
  //   env='prod',
  //   project_id='my-existing-project',
  //   service_name='bar',
  // )
  //
  // 2. New project with labels:
  //
  // environment.gcp(
  //   env='dev',
  //   project_id='my-new-project',
  //   service_name='bar',
  //   existing_project=false,
  //   project_custom={
  //     tags: {
  //       'env': 'dev',
  //     },
  //     billing_account: '...',
  //   },
  // )
  gcp(env, project_id, service_name='', tf_comments=true, existing_project=true, project_custom={}): {
    local proj = self.project,
    base+:: {
      service_name:: service_name,
      project_id:: project_id,
      env:: env,
      regions+:: [],
      tf_comments:: tf_comments,
      // exception, as it's not metadata, but convenient reference to depend on project instead of hardcoding project_id string.
      project:: proj.google_project.self_ref('project_id'),
    },

    project+:: {
      [if existing_project then 'google_project']: hcl.data {
        hcllabels:: ['google_project', hcl.strToSnake(self.project_id)],
        project_id: project_id,
      },
      [if !existing_project then 'google_project']: hcl.resource {
        hcllabels:: ['google_project', hcl.strToSnake(self.project_id)],
        project_id: project_id,
        name: project_id,
      } + project_custom,
    },
    components+:: {},
    'project.tf': hcl.manifest(self.project, self.base.tf_comments),

    // Tihs field is used when it's need to refer to the region metadata in
    // on_region() mixin or in filestore mixins.
    // (e.g. + component.on_region(env.regions_metadata.us_west2, vm.type.hmem_64))
    // where "env" is the variable of current environment.
    // regions_metadata is populated by vpc.regional() mixin.
    //
    // Adiitionally merge regions_metadata of components.
    // As sometimes the region is defined exclusivley in component.
    // (if you curious why implemented this way):
    // It would be simpler to merge in component() below as 1 line "+" operation,
    // but GO-jsonnet compiler errors out on that (though scala one works).
    regions_metadata+:: std.foldl(
      function(acc, c)
        if std.objectHasAll(c, 'regions_metadata')
        then acc + c.regions_metadata
        else acc,
      std.objectValues(self.components),
      {}
    ),
  },

  // Env-level mixin to define custom metadata (map of keys and values)
  // which can be used in custom logic extending default set of mixins.
  custom_metadata(custom_metadata): {
    base+:: custom_metadata,
  },

  // Env-level and comp-level mixin.
  // Args:
  //   region: string, the name of the region (e.g., 'us-central1').
  //   number: string, a number used as alias for the region. Useful in names generation.
  //           E.g. '1' or '2' in 'us-central1-a' or 'us-central1-b'.
  //   zone_letters: array of strings, letters of the zones in the region (e.g., ['a', 'b']).
  //   custom: optional object, additional fields to merge into the region metadata.
  //           E.g. to add a new field 'new_field' with value 'new_value':
  //           custom={ new_field: 'new_value' }
  //           And then this metadata can be used in name patterns of resources
  //           like name='%(new_field)s_disk'.
  regional_metadata(region, number, zone_letters, custom={}): {
    local r = {
      zones:: [self.region + '-' + l for l in self.zone_letters],  // if region is 'us-east1' and letter is 'a' then zone will be 'us-east1-a'
      region_number:: number,
      region:: region,
      zone_letters:: zone_letters,
    } + custom,
    regions_metadata+:: {
      [hcl.strToSnake(region)]+: r {
        ['num_%s' % number]: r,
      },
    },
    local m = self.regions_metadata,
    base+:: {
      regions:: std.sort(std.objectValues(m), keyF=function(r) r.region_number),
    },
  },

  // Env-level mixin to define a component.
  // IMPORTANT: when name is not specified,
  //            then component.name() mixin must be used.
  // Args:
  //   mixins: The component object.
  //   name[optional]: Either specified or component.name() mixin must be used
  //                   in mixins. See component.name() for details.
  component(mixins, name=null):
    local n = if name == null then mixins.base.comp else name;
    assert name != null || 'comp' in mixins.base : 'component name is not specified, either pass name or use component.name() mixin';
    {
      local env = self,
      components+:: {
        [n]: component.main_structure {
          // propagating base of the env to the component
          base:: env.base { comp:: n },
          // we also want make env available to the component, as env field
          env:: env,
        } + mixins,
      },
      ['%s.tf' % n]: hcl.manifest(self.components[n], env.base.tf_comments),
    },

  // Env-level mixin.
  // Bulk apply component level mixin to all components
  // (and optionally to all subcomponents).
  //
  // Args:
  //   mixin: The component-level mixin to apply to all components.
  //   include: [optional] If set, apply mixin only to components with given name.
  //             NOTE: if component in include doesn't exist, it's just skipped.
  //   exclude: [optional] If set, apply mixin only to components without given name.
  //   subcomp: [optional] If true, apply mixin to all subcomponents as well.
  bulk_apply_to_components(mixin, include=null, exclude=[], subcomp=false): {
    local components = super.components,
    components+:: {
      [c]+: mixin {
        [if subcomp && 'sub_comps' in components[c] then 'sub_comps']+: {
          [sc]+: mixin
          for sc in std.objectFields(super.sub_comps)
        },
      }
      for c in std.objectFields(components)
      if !std.member(exclude, c)
      if include == null || std.member(include, c)
    },
  },

  // Porject level mixin.
  // Creates apis.tf with resources defining the list of enabled APIs.
  //
  // Args:
  //   apis: A list of APIs to enable.
  // For example:
  // + apis([
  //     'spanner.googleapis.com',
  //     'pubsub.googleapis.com',
  //   ])
  // will generate these resources:
  //   resource "google_project_service" "service_spanner_googleapis_com" {
  //     disable_on_destroy = false
  //     project            = data.google_project.dasinfra-sap-business-{env}.project_id
  //     service            = "spanner.googleapis.com"
  //   }
  // and
  //   resource "google_project_service" "service_pubsub_googleapis_com" {
  //     disable_on_destroy = false
  //     project            = data.google_project.dasinfra-sap-business-{env}.project_id
  //     service            = "pubsub.googleapis.com"
  //   }
  apis(apis, disable_on_destroy=false): {
    local base = self.base,
    project+:: {
      apis+:: {
        services+:: apis,
        by_service: {
          [s]: hcl.resource {
            hcllabels:: ['google_project_service', hcl.strToSnake(self.service)],
            project: base.project,
            tfimport:: base.project_id + '/' + s,
            disable_on_destroy: disable_on_destroy,
            service: s,
          }
          for s in self.services
        },
      },
    },
    'apis.tf': hcl.manifest(self.project.apis, base.tf_comments),
  },
}
