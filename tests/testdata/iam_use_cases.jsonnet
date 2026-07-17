local bucket = import '../bucket.libsonnet';
local component = import '../component.libsonnet';
local disk = import '../disk.libsonnet';
local environment = import '../environment.libsonnet';
local iam = import '../iam.libsonnet';
local vm = import '../vm.libsonnet';
local vpc = import '../vpc.libsonnet';

// NOTE: SAs created by iam.sa() in components are available globally by their logical names.
// SAs with logical name matching component name are used as VMs default SA of that component (unless overridden by vm.service_account_id()).
// To aboid confusion, check iam.libsonnet mixins docs for more details and default naming patterns.

local my_reusable_role = iam.role(
  role_id='my_reusable_custom_role',
  title='My Reusable Custom Role',
  permissions=['storage.buckets.get', 'storage.buckets.list']
);

local env =
  environment.gcp(env='test', project_id='my-project')
  + environment.regional_metadata(region='us-central1', number='1', zone_letters=['a'])
  + vpc.network(logical_name='servers')
  + vpc.subnet('servers', region='us-central1', ip_range='10.0.0.0/24')

  // Case 1: Env-level project binding with a standard role
  + iam.project_binding('roles/compute.viewer', ['user:alice@google.com', 'group:admins@google.com'])

  // Case 2: Env-level project binding with a custom role defined inline
  + iam.project_binding(
    iam.role(
      role_id='my_custom_role',
      title='My Custom Role',
      permissions=['compute.instances.get', 'compute.instances.list']
    ),
    ['user:bob@google.com']
  )

  // Case 3: Env-level project member
  + iam.project_member('roles/storage.objectViewer', 'user:charlie@google.com')

  // Case 4: Using iam.role() stored in a local variable
  + iam.project_binding(
    my_reusable_role,
    binding_members=['user:eve@google.com']
  )

  // Case 5: Component with default service account
  // (logical_sa_name and account_id matches component name)
  + environment.component(
    component.name('app')
    + vm.count(1)
    + iam.sa()
  )

  // Case 6: Component with specific service account ID, and binding a role to that SA for a specific user
  + environment.component(
    component.name('db')
    + vm.count(1)
    // creates default compoent SA with email my-db@my-project.iam.gserviceaccount.com
    // logical_sa_name matches component name as default (see iam.libsonnet)
    + iam.sa(account_id='my-%(comp)s')
    + iam.sa_binding(
      // ommiting sa_logical_name on component level defaults to component name ('db')
      sa_binding_members=['user:dbadmin@google.com'],
      sa_binding_role='roles/iam.serviceAccountUser'
    )
  )

  // Case 7: Component with multiple service accounts (using logical names) and binding
  + environment.component(
    component.name('proxy')
    + vm.count(1)
    + iam.sa(
      sa_logical_name='reader',  // this logical name is global, any other compoent using iam.sa('reader') logical name will step on it.
    )
    + iam.sa(
      sa_logical_name='writer-%(comp)s',  // example how to create SA with name derived from component name
    )
    + iam.sa()  // default SA required for the component
    // bind member to reader
    + iam.sa_binding(
      sa_logical_name='reader',
      sa_binding_members=['user:reader@google.com'],
      sa_binding_role='roles/iam.serviceAccountTokenCreator'
    )
  )

  // Case 8: Component assigning a project-level role to its default SA
  + environment.component(
    component.name('worker')
    + vm.count(1)
    + iam.sa()
    // By omitting binding_members, it defaults to ['%(comp)s'], which resolves to the component's default SA
    + iam.project_binding('roles/pubsub.publisher')
  )

  // Case 9: Component with SA that has a duplicated account ID (e.g. to share same account ID across different components)
  + environment.component(
    component.name('shared_worker')
    + vm.count(1)
    + iam.sa()  // default SA required for the component
    + iam.sa_duplicated_account_id(
      sa_logical_name='shared-sa',
      account_id='my-shared-account'
    )
  )

  // Case 10: Referencing a service account by its logical name in a binding
  + environment.component(
    component.name('notifier')
    + vm.count(1)
    + iam.sa()  // default SA required for the component
    // Bind 'writer' of 'proxy' component (logical name in this case will be 'writer-proxy') to a project role
    // This is useful when we want to bind a role to a SA from another component in the presense of this component
    + iam.project_binding('roles/pubsub.publisher', binding_members=['writer-proxy'])
    + iam.sa_binding(
      // Bind 'reader' (logical name of SA from 'proxy' component available globally) to the 'notifier' service account
      sa_binding_members=['reader'],
      sa_binding_role=my_reusable_role
    )
  )

  // Case 11: Binding with skip_missing_members=true
  // This is useful when the list of members is generated dynamically and some SAs might not exist in the current environment
  // This can happen when we dynamically add components to the environment from the library of components
  // and we want that adding bingins generated automatically based on existence of related SAs.
  + iam.project_binding(
    'roles/storage.objectViewer',
    binding_members=['app', 'non_existent_sa'],
    skip_missing_members=true
  )

  // Case 12: Referencing a service account by its logical name in a bucket IAM binding
  + bucket.add('my_bucket')
  + bucket.iam_binding(
    'my_bucket',
    'roles/storage.objectViewer',
    [
      'app',  // default SA of 'app' component above
      'notifier',  // logical name of SA from 'notifier' component above
      'user:frank@google.com',
    ]
  )

  // IMPORTANT: Generating the iam.tf file (must be added at the end)
  + iam.generate_tf

  // =====================
  // required default mixins applied to each component above
  + environment.bulk_apply_to_components(
    vm.machine_type('e2-standard-4')
    + vm.net(name='servers')  // each component uses the same VPC network
    + disk.boot(image='image-family/my-image')
    + vm.sa_scopes(['cloud-platform'])
  );

env
