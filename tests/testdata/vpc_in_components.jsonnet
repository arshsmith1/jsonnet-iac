local component = import '../component.libsonnet';
local disk = import '../disk.libsonnet';
local environment = import '../environment.libsonnet';
local load_balancer = import '../load_balancer.libsonnet';
local vm = import '../vm.libsonnet';
local vpc = import '../vpc.libsonnet';

local env =
  environment.gcp(env='test', project_id='my-project')
  + environment.regional_metadata(region='us-central1', number='1', zone_letters=['a', 'b'])
  // VPC resources
  + vpc.network(logical_name='servers')
  + vpc.subnet('servers', region='us-central1', ip_range='10.0.0.0/24')
  // additional subnet in the same region
  + vpc.subnet('servers', region='us-central1', ip_range='10.0.1.0/24')

  // Case 1: Default VPC assignment (uses subnet_number=1 by default)
  + environment.component(
    component.name('app')
    + vm.count(1)
  )
  // Case 2: Using the second subnet for all instances in a component
  + environment.component(
    component.name('db')
    + vm.count(1)
    + vm.subnet_number(2)
  )
  // Case 3: Using a specific subnet for a load balancer within the component
  + environment.component(
    component.name('bar')
    + vm.count(1)
    + load_balancer.default_regional
    + load_balancer.regional_subnet_n(2)
  )

  // Case 4: Overriding the subnet for specific instances within a component
  + environment.component(
    component.name('foo')
    + vm.count(2)
    + component.on_vms(['testfoo3', 'testfoo4'], vm.subnet_number(2))
  )


  // =====================
  // mixins applied to each component above (!! not to components below if any defined)
  + environment.bulk_apply_to_components(
    vm.machine_type('e2-standard-4')
    + vm.net(name='servers')  // each component uses the same VPC network
    + disk.boot(image='image-family/my-image')
    + vm.sa_scopes(['cloud-platform'])
    + vm.service_account_id(account_id='my-sa')
  )
  // =====================

  // Use case 5: Another VPC network and subnet
  + vpc.network(logical_name='data')
  + vpc.subnet('data', region='us-central1', ip_range='10.10.0.0/24')
  + environment.component(
    component.name('another')
    + vm.count(1)
    + vm.machine_type('e2-standard-4')
    + vm.sa_scopes(['cloud-platform'])
    + vm.service_account_id(account_id='my-sa')
    + disk.boot(image='image-family/my-image')
    + vm.net('data')  // use the 'data' VPC network, 'data' is logical name, might be different from actual VPC cloud resource name
    // NOTE that "+ vm.subnet_number(1)" is not needed here, because it's the first subnet by default
  );

env
