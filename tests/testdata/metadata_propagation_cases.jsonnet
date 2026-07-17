local bucket = import '../bucket.libsonnet';
local component = import '../component.libsonnet';
local disk = import '../disk.libsonnet';
local environment = import '../environment.libsonnet';
local iam = import '../iam.libsonnet';
local vm = import '../vm.libsonnet';
local vpc = import '../vpc.libsonnet';

local env =
  environment.gcp(env='test', project_id='my-project')
  + environment.regional_metadata(
    region='us-central1',
    number='1',
    zone_letters=['a', 'b']
  )
  + environment.regional_metadata(
    region='us-central1',
    number='1',
    zone_letters=['a', 'b'],
    custom={
      reg_level_var: 'reg_val',
      reg_shared_var: 'from_reg',
    }
  )
  + vpc.network(logical_name='servers')
  + vpc.subnet('servers', region='us-central1', ip_range='10.0.0.0/24')

  // Case 1: Environment-level metadata
  + environment.custom_metadata({
    env_level_var: 'env_val',
    reg_shared_var: 'from_env',
    comp_env_var: 'from_env',
  })


  // Case 2: Component-level metadata
  + environment.component(
    component.name('app')
    + vm.count(2)
    + vm.machine_type('e2-standard-4')
    + disk.boot('my-image')
    + vm.sa_scope('cloud-platform')
    + vm.net('servers')
    + environment.custom_metadata({
      comp_level_var: 'comp_val',
      reg_shared_var: 'from_comp',  // Note: This will be overridden by regional metadata!
      comp_env_var: 'from_comp',  // Correctly overrides env level metadata
    })

    // Usage: we can use these metadata variables in labels, tags, names, etc.
    + vm.label('env-var-label', '%(env_level_var)s')
    + vm.label('comp-var-label', '%(comp_level_var)s')
    + vm.label('comp-env-var-label', '%(comp_env_var)s')
    // This will evaluate to 'from_reg' because regional metadata overrides component metadata
    + vm.label('shared-var-label', '%(reg_shared_var)s')

    // Case 5: Instance-level metadata override
    // Only metadata applied per instance (e.g. via on_vm) will overwrite regional metadata.
    + component.on_vm('app11', component.custom_metadata({ reg_shared_var: 'from_instance' }))

    // Dynamic logical name based on environment level metadata and because it
    // has a different form component name then we explicitly tell that it's default VM SA.
    + iam.sa(sa_logical_name='sa-%(env_level_var)s', account_id='sa-%(reg_shared_var)s', is_default_vm_sa=true)

    // Case 3: Region-level metadata
    + vm.label('reg-var-label', '%(reg_level_var)s')

  )
  // Case 4: Bucket with dynamic name using environment metadata passed to environment.gcp()
  // Indicates that args passed to environment.gcp() can also be used as placeholders.
  + bucket.add(logical_name='my-bucket', name='bucket-%(project_id)s-%(env)s');

env
