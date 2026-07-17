local component = import '../component.libsonnet';
local disk = import '../disk.libsonnet';
local environment = import '../environment.libsonnet';
local vm = import '../vm.libsonnet';
local vpc = import '../vpc.libsonnet';

environment.gcp(
  env='test',
  project_id='my-project',
)
+ environment.regional_metadata(region='us-central1', number='1', zone_letters=['a'])
// VPC resources
+ vpc.network(logical_name='default')
+ vpc.subnet('default', region='us-central1', ip_range='10.0.0.0/24')
+ vpc.router('default', region='us-central1')
+ vpc.router_nat('default', region='us-central1', external_ip_count=1)
// app component
+ environment.component(
  component.name('app')
  + vm.count(1)
  + vm.machine_type('e2-standard-4')
  + vm.net(name='default')
  + vm.sa_scopes(['cloud-platform'])
  + vm.service_account_id(account_id='my-sa')
  + disk.boot(image='image-family/my-image')
  + disk.add(disk_name='data', size=100),
)
