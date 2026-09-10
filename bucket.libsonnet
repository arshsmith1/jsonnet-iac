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
  // Adds a google_storage_bucket resource.
  // Args:
  //   logical_name: logical name of the bucket used to reference bucket in IAM mixins.
  //   name: optional, bucket name in GCP. It can be a format string using fields in base object. Default: '%(project_id)s-%(logical_name)s'.
  //   enable_versioning: optional, Whether to enable versioning on the bucket. Default: true.
  //   location: optional, The location of the bucket. Default: 'US'.
  //   storage_class: optional, The storage class of the bucket. Default: 'MULTI_REGIONAL'.
  //   uniform_bucket_level_access: optional, Whether to enable uniform bucket-level access. Default: null.
  //   customization: optional, mixin to merge with bucket resource fields, to customize default behaviors such as lifetime, recursive deletion, etc.
  //                        Default: {}.
  //                        E.g.:
  //                        {
  //                          lifecycle_rule: hcl.nested_block {
  //                            condition: hcl.nested_block {
  //                              age: 30,
  //                            },
  //                            action: hcl.nested_block {
  //                              type: 'Delete',
  //                            },
  //                          },
  //                        },
  add(logical_name,
      name='%(project_id)s-%(logical_name)s',
      enable_versioning=true,
      location='US',
      storage_class='MULTI_REGIONAL',
      uniform_bucket_level_access=null,
      customization={}): {
    local base = self.base,
    buckets+:: {
      [logical_name]+: {
        bucket: hcl.resource {
          assert std.length(self.name) <= 63 : 'bucket name should not exceed 63 characters: ' + self.name,
          hcllabels:: ['google_storage_bucket', hcl.strToSnake(self.name)],
          tfimport:: '%s/%s' % [base.project_id, self.name],
          project: base.project,
          name: name % base { logical_name: logical_name },
          location: std.asciiUpper(location),
          storage_class: std.asciiUpper(storage_class),
          [if uniform_bucket_level_access != null then 'uniform_bucket_level_access']: uniform_bucket_level_access,
          [if enable_versioning then 'versioning']: hcl.nested_block {
            enabled: true,
          },
        } + customization,
      },
    } + std.foldl(
      function(acc, c)
        acc + if 'buckets' in c then c.buckets else {},
      std.objectValues(self.components),
      {}
    ),
    ['bucket_' + logical_name + '.tf']: hcl.manifest(self.buckets[logical_name], base.tf_comments),
  },

  // Env-level mixin.
  // Creates a google_storage_bucket data resource for an existing bucket.
  // Args:
  //   logical_name: The logical name of the bucket.
  //   name: The actual bucket name pattern.
  existing(logical_name, name='%(project_id)s-%(logical_name)s'): {
    local base = self.base,
    buckets+:: {
      [logical_name]+: {
        bucket: hcl.data {
          hcllabels:: ['google_storage_bucket', hcl.strToSnake(logical_name)],
          name: name % base { logical_name: logical_name },
        },
      },
    },
    ['bucket_' + logical_name + '.tf']: hcl.manifest(self.buckets[logical_name], base.tf_comments),
  },

  // Env-level and comp-level mixin.
  // Adds a google_storage_bucket_iam_binding resource.
  // Args:
  //   bucket_logical_name: The logical name of bucket defined with add().
  //   role: The IAM role.
  //     e.g. 'roles/storage.objectViewer'
  //   members: list of members. Can be logical name of SA in this env
  //          (see iam.libsonnet), or a string like 'user:foo' or 'group:bar'
  //   skip_missing: optional, whether to skip members that are not found in iam.
  //   append: optional, whether to append to existing members. Default: false.
  //          If true, existing members will be kept. If false, existing members will be replaced.
  iam_binding(bucket_logical_name, role, members, skip_missing=false, append=false): {
    local base = self.base,
    // below works for comp and env level, always read sas and buckets from env level
    local env = if 'env' in self then self.env else self,
    local sas = env.iam.sas,
    buckets+:: {
      [bucket_logical_name]+: {
        local b = self.bucket,
        iam_binding+: {
          [hcl.strToSnake(role)]+: hcl.resource {
            hcllabels:: ['google_storage_bucket_iam_binding', hcl.strToSnake(bucket_logical_name + '_' + role)],
            tfimport:: 'b/%s %s' % [b.name, role],
            bucket: b.self_ref('name'),
            role: role,
            local ms = [
              if std.member(m, ':')
              then m
              else hcl.expression('"serviceAccount:${%s}"', sas[m].sa.self_ref('email'))
              for m in [m % base for m in members]
              if m != null && m != '' && m != 'null'
              if !skip_missing || std.member(m, ':') || m in sas
            ],
            [if append then 'members']+: ms,
            [if !append then 'members']: ms,
          },
        },
      },
    },
  },

  // Env-level and comp-level mixin.
  // Adds a google_storage_bucket_iam_member resource.
  // Args:
  //   bucket_logical_name: The logical name of bucket defined with add().
  //   role: The IAM role.
  //   member: The IAM member. Can be logical name of SA in this env
  //           (see iam.libsonnet), or a string like 'user:foo' or 'group:bar'
  iam_member(bucket_logical_name, role, member): {
    local base = self.base,
    // below works for comp and env level, always read sas and buckets from env level
    local env = if 'env' in self then self.env else self,
    local b = env.buckets[bucket_logical_name].bucket,
    local sas = env.iam.sas,
    local m = member % base,
    buckets+:: {
      [bucket_logical_name]+: {
        iam_member+: {
          [hcl.strToSnake(role + '_' + m)]+: hcl.resource {
            hcllabels:: ['google_storage_bucket_iam_member', hcl.strToSnake(bucket_logical_name + '_' + role + '_' + m)],
            tfimport:: 'b/%s %s %s' % [
              b.name,
              role,
              if std.member(m, ':') then m else 'serviceAccount:' + sas[m].sa.email,
            ],
            bucket: b.self_ref('name'),
            role: role,
            member:
              if std.member(m, ':')
              then m
              else hcl.expression('"serviceAccount:${%s}"', sas[m].sa.self_ref('email')),
          },
        },
      },
    },
  },
}
