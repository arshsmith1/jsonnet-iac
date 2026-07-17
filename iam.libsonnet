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

// This file contains IAM related mixins producing following tf resources:
// - google_service_account
// - google_service_account_iam_binding
// - google_project_iam_binding
// - google_project_iam_member
// - google_project_iam_custom_role

{
  // Env-level mixin.
  // Generates iam.tf file.
  generate_tf: {
    // merge iam from all components and sub-comps (SA resources are at component level)
    iam+:: std.foldl(
      function(acc, c) if 'iam' in c then acc + c.iam + std.foldl(
        function(acc, sc) if 'iam' in sc then acc + sc.iam else acc,
        std.objectValues(c.sub_comps),
        {}
      ) else acc,
      std.objectValues(self.components),
      {
        roles+: {},
        sas+: {},
      }
    ),
    local iam = self.iam,
    'iam.tf': hcl.manifest(iam, self.base.tf_comments),
  },

  // Env-level mixin.
  // NOTE: usually used as parameter for iam.sa() and iam.project_binding()
  //       Can be appended to env directly,
  //       when need to create role but not use it in bindings.
  // Created custom role terraform resource.
  role(role_id, title, permissions, description=null, stage='GA'): {
    local project_id = self.base.project_id,
    iam+:: {
      roles+: {
        [role_id]: hcl.resource {
          hcllabels:: ['google_project_iam_custom_role', role_id],
          tfimport:: 'projects/%s/roles/%s' % [project_id, self.role_id],
          role_id: role_id,
          project: project_id,
          title: title,
          permissions: permissions,
          stage: stage,
          [if description != null then 'description']: description,
        },
      },
    },
  },

  // It's a common part of google_service_account_iam_binding and
  // google_project_iam_binding terraform resources.
  // Inlining doesn't improve readability, so decided to avoid logic duplication.
  local _binding_members_and_role(base, sas, roles, binding_members, skip_missing_members, role) = {
    plain_text_role:: if role in roles then roles[role].tfimport else role,
    role:
      if role in roles
      then hcl.expression('"projects/%s/roles/${%s}"', [base.project_id, roles[role].self_ref('role_id')])
      else role,
    local bm = [m % base for m in binding_members],
    comp_sa_members+:: {  // comp SA can be defined with overlapping account_id, so using account_id as a key to avoid duplicate binding members.
      // TODO(artembar): For now don't reference, so import doesn't show diff. After migration done, uncomment.
      // hcl.expression('"serviceAccount:${%s}"', sas[m].sa.self_ref('email'))
      [sas[m].sa.account_id]: 'serviceAccount:' + sas[m].sa.email
      for m in bm
      if !std.member(m, ':')
      if !skip_missing_members || m in sas
    },
    other_members+:: [
      m % base
      for m in bm
      if std.member(m, ':')
    ],
    members: std.sort(
      std.set(
        std.objectValues(self.comp_sa_members) + self.other_members
      )
    ),
  },

  // Both env-level and comp-level mixin.
  // Creates google_service_account terraform resource.
  //
  // NOTE: for SA bindings use iam.sa_binding().
  //
  // Args:
  //   sa_logical_name: [optional] a logical name of the service account.
  //                     default: <comp name>
  //                     NOTE: default will fail on env level,
  //                           so should be explicitly defined.
  //   account_id: [optional] account_id of the service account.
  //                If not provided, then the same as sa_logical_name.
  //   display_name: [optional] display name of the service account.
  //   create_ignore_already_exists: [optional, default=true] if true, then
  //                                 create SA even if it already exists.
  //   description: [optional] description of the service account.
  //   is_default_vm_sa: [optional] if true, then set current SA as default VM SA.
  // Example:
  //   + iam.sa()
  sa(
    sa_logical_name='%(comp)s',
    account_id=sa_logical_name,
    display_name='%(account_id)s',
    description=null,
    create_ignore_already_exists=true,
    is_default_vm_sa=sa_logical_name == '%(comp)s'
  ): {
    local base = self.base,
    iam+:: {
      sas+: {
        [sa_logical_name % base]+: {
          sa: hcl.resource {
            hcllabels:: ['google_service_account', hcl.strToSnake(self.account_id)],
            email:: '%s@%s.iam.gserviceaccount.com' % [self.account_id, base.project_id],
            tfimport:: 'projects/%s/serviceAccounts/%s' % [self.project, self.email],
            account_id: account_id % base,
            local a = self.account_id,
            [if display_name != null then 'display_name']: display_name % base { account_id: a },
            [if description != null then 'description']: description % base { account_id: a },
            [if create_ignore_already_exists then 'create_ignore_already_exists']: true,
            project: base.project_id,
          },
        },
      },
    },
    local sas = self.iam.sas,
    [if is_default_vm_sa then 'by_instance']+:: {
      compute+: {
        vm+: {
          service_account+: {
            email: sas[sa_logical_name % base].sa.self_ref('email'),
          },
        },
      },
    },
  },

  // Merges SAs with the same account_id but different logical name.
  // SA is referred by it's logical name.
  // Makes sure that in case of account_id colliosions from different components,
  // only one SA wlll be created.
  // Args:
  //   sa_logical_name: [optional] a logical name of the service account.
  //                     default: <comp name>
  //                     NOTE: default will fail on env level,
  //                           so should be explicitly defined.
  //   account_id: new account_id for the SA.
  // Example:
  //   + iam.sa_duplicated_account_id(sa_logical_name='foo', account_id='bar')
  sa_duplicated_account_id(sa_logical_name='%(comp)s', account_id, is_default_vm_sa=false):
    $.sa(sa_logical_name, account_id, is_default_vm_sa=is_default_vm_sa) {
      local base = self.base,
      local _sa_logical_name = sa_logical_name % base,
      iam+:: {
        sas+: {
          [_sa_logical_name]+:: {},  // hide existing SA, still referensable.
          [account_id]+: self[_sa_logical_name],  // group by account_id
        },
      },
    },

  // Both env and component level mixin.
  // Creates google_service_account_iam_binding terraform resource.
  // Args:
  //   sa_logical_name: [optional] a logical name of the service account.
  //                     default: <comp name>
  //                     NOTE: default will fail on env level,
  //                           so should be explicitly defined.
  //   sa_binding_members: [optional] list of members to bind to the service account.
  //                               Can be logcal name of SA in this env,
  //                               or a string like 'user:foo' or 'group:bar'.
  //   sa_binding_role: binding role for the service account.
  //                    Can be a string or iam.role() object.
  //   skip_missing_members: [optional] if true, skip logical names of binding
  //                                  members which are not defined in this env.
  // Example:
  //   + iam.sa( // default name is <comp_name>
  //           sa_binding_members=['comp_name', 'group:foo', 'serviceAccount:bar'],
  //           sa_binding_role='roles/iam.serviceAccountUser'
  //       )
  //   + iam.sa(
  //           sa_logical_name='foo',
  //           sa_binding_members=['comp_name', 'group:foo', 'serviceAccount:bar'],
  //           sa_binding_role=iam.role(role_id='foo', title='bar', permissions=['foo.bar'])
  //       )
  sa_binding(sa_logical_name='%(comp)s', sa_binding_members=['%(comp)s'], sa_binding_role, skip_missing_members=false):
    (if std.isObject(sa_binding_role) then sa_binding_role else {}) {
      local base = self.base,
      local role = if std.isObject(sa_binding_role) then std.objectFields(sa_binding_role.iam.roles)[0] else sa_binding_role,
      iam+:: {
        local sas = self.sas,
        local roles = self.roles,
        sas+: {
          [sa_logical_name % base]+: {
            local sa = self.sa,
            bindings+: {
              [role]+: hcl.resource {
                hcllabels:: ['google_service_account_iam_binding', hcl.strToSnake(sa.account_id + '_' + role)],
                tfimport:: 'projects/%s/serviceAccounts/%s %s' % [base.project_id, sa.email, self.plain_text_role],
                service_account_id: sa.self_ref('name'),
              } + _binding_members_and_role(base, sas, roles, sa_binding_members, skip_missing_members, role),
            },
          },
        },
      },
    },

  // Both env and component level mixin.
  // Creates google_project_iam_binding terraform resource.
  // Args:
  //   role: String of role or iam.role() object.
  //                               Can be a string or iam.role() object.
  //   binding_members: [optional] Omit on comp level to refer defaul SA of component.
  //                    Can be logcal name of SA in this env,
  //                    or a string like 'user:foo' or 'group:bar'.
  //   skip_missing_members: [optional] if true, skip logical names of binding
  //                                  members which are not defined in this env.
  // Example:
  //   + iam.project_binding('roles/bigquery.dataEditor', ['comp_name', 'group:foo'])
  // or
  //   + environment.component(
  //      ...
  //     + iam.project_binding('roles/secretmanager.secretAccessor')
  project_binding(role, binding_members=['%(comp)s'], skip_missing_members=false):
    (if std.isObject(role) then role else {})  //  implicitly merging custom role into iam structure.
    {
      local base = self.base,
      local _role = if std.isObject(role) then std.objectFields(role.iam.roles)[0] else role,
      iam+:: {
        local roles = self.roles,
        local sas = self.sas,
        bindings+: {
          [_role]+: hcl.resource {
            hcllabels:: ['google_project_iam_binding', hcl.strToSnake(_role)],
            tfimport:: '%s %s' % [self.project, self.plain_text_role],
            project: base.project_id,
          } + _binding_members_and_role(base, sas, roles, binding_members, skip_missing_members, _role),
        },
      },
    },

  // Both env and component level mixin.
  // Creates google_project_iam_member terraform resource.
  // Args:
  //   role: role for project member. Can be a string or iam.role() object.
  //   member: [optional] member to bind to project role.
  //           Defaults to component SA if used on component level and omitted.
  //           Can be a logical name of SA in this env,
  //           or a string like 'user:foo' or 'group:bar'.
  // Example:
  //   + iam.project_member('roles/bigquery.dataEditor', 'user:foo@google.com')
  //   + iam.project_member('roles/bigquery.dataEditor', 'logical_name_of_sa')
  project_member(role, member='%(comp)s'):
    (if std.isObject(role) then role else {}) {
      local base = self.base,
      local _role = if std.isObject(role) then std.objectFields(role.iam.roles)[0] else role,
      iam+:: {
        local roles = self.roles,
        local sas = self.sas,
        local m = member % base,
        members+: {
          [hcl.strToSnake(_role)]+: {
            [hcl.strToSnake(m)]: hcl.resource {
              hcllabels:: ['google_project_iam_member', hcl.strToSnake(_role + '_' + m)],
              tfimport:: '%s %s %s' % [base.project_id, _role, if std.member(member, ':') then member else 'serviceAccount:' + sas[m].sa.email],
              project: base.project_id,
              role:
                if _role in roles
                then hcl.expression('"projects/%s/roles/${%s}"', [base.project_id, roles[_role].self_ref('role_id')])
                else role,
              member:
                if std.member(member, ':')
                then m
                else hcl.expression('"serviceAccount:${%s}"', sas[m].sa.self_ref('email')),
            },
          },
        },
      },
    },


}
