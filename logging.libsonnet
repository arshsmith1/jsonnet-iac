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
  // Creates a default log bucket.
  // Args:
  //   bucket_id: optional, The ID of the log bucket. Default: '_Default'.
  //   description: optional, The description of the log bucket. Default: null.
  //   retention_days: optional, The number of days to retain logs. Default: null.
  //   location: optional, The location of the log bucket. Default: 'global'.
  //   enable_analytics: optional, Whether to enable analytics on the log bucket. Default: false. The field is only added if true.
  //   custom_fields_mixin: optional, mixin with extra bucket resource fields.
  //                        Default: {}.
  bucket_config(
    bucket_id='_Default',
    description=null,
    retention_days=null,
    location='global',
    enable_analytics=false,
    customization={}
  ): {
    local base = self.base,
    project+:: {
      bucket_config: hcl.resource {
        hcllabels:: ['google_logging_project_bucket_config', 'default'],
        project: base.project_id,
        bucket_id: bucket_id,
        [if description != null then 'description']: description,
        [if enable_analytics == true then 'enable_analytics']: enable_analytics,
        location: location,
        locked: false,
        [if retention_days != null then 'retention_days']: retention_days,
      } + customization,
    },
  },
}
