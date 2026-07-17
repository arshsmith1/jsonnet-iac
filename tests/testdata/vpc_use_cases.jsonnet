local environment = import '../environment.libsonnet';
local hcl = import '../hcl.libsonnet';
local vpc = import '../vpc.libsonnet';

// See use case 2.1 below.
local dynamic_subnet_ip_range = {
  local base = self.subnet_level_base,
  custom_tf_ip_range_resource: hcl.data {
    hcllabels:: ['ip_range_resource', hcl.strToSnake(self.name)],
    name: 'ip-range-for-%(network_name)s-%(region)s-%(subnet_index)s' % base,
    region: base.region,
  },
  local my_data = self.custom_tf_ip_range_resource,
  subnet+: {
    // 1) (shown here)this can be any hcl.self_ref() or hcl.expression() depending on what field data we are reading from our custom resource.
    // 2) this can be just custom logic calculating cidr string based on values in base object (vpc subnet level base)
    ip_cidr_range: my_data.self_link,
  },
};

// See use case 4.1 below.
local other_jsonnet_env =
  environment.gcp(env='prod', project_id='other-jsonnet-project')
  + vpc.network('net');

local env =
  environment.gcp(env='test', project_id='my-project')
  + environment.regional_metadata(region='us-central1', number='1', zone_letters=['a', 'b'])
  + environment.regional_metadata(region='us-east1', number='2', zone_letters=['b', 'c', 'd'])

  // Use case 1: The most simple network configuration: a single simple network without any NAT or router
  + vpc.network('isolated-vpc')
  + vpc.subnet('isolated-vpc', 'us-east1', '10.2.0.0/24')

  // Use case 2: The syntax sugar of vpc.network_subnets_router_nat() wrapping 3 mixins into one.
  + vpc.network_subnets_router_nat(
    vpc_logical_name='vpc1',
    regions=['us-central1', 'us-east1'],  // can be referenced as object or as just string
    ip_ranges={
      'us-central1': ['10.0.0.0/24'],
      'us-east1': ['10.0.1.0/24'],
    }
  )

  // Use case 2.1: vpc.network_subnets_router_nat() with custom IP range object implementation
  // Custom additional data tf resources is created and referenced as the source of IP ranges for subnets (field subnet.ip_cidr_range).
  + vpc.network_subnets_router_nat(
    vpc_logical_name='my_ip_ranges',
    router=false,
    regions=['us-central1', 'us-east1'],
    ip_ranges=[dynamic_subnet_ip_range],
  )

  // Use case 3: Building a VPC explicitly using individual mixins with a custom router NAT and external IPs
  + vpc.network('vpc2')
  + vpc.subnet('vpc2', 'us-central1', '10.1.0.0/24', subnet_index=1)
  + vpc.subnet('vpc2', 'us-central1', '10.1.1.0/24', subnet_index=2)
  + vpc.router('vpc2', 'us-central1')
  + vpc.router_nat('vpc2', 'us-central1', external_ip_count=2)
  + vpc.router_description('vpc2', 'Custom router description for environment %(env)s', region='us-central1')

  // Use case 4: Peering within the same project
  + vpc.peering('vpc1', 'vpc2', name='custom-name-for-vpc1-to-vpc2')  // by default don't pass name as it has default pattern, see vpc.libsonnet for details

  // Use case 4.1: Peering to another VPC in another jsonnet environment referencing env vpc object
  + vpc.peering(from='vpc1', to=other_jsonnet_env.vpcs.net)

  // Use case 4.2: Simple peering to an external non-jsonnet project
  + vpc.peering(
    from='vpc2',
    to='projects/external-project/global/networks/external-network'
  )

  // Use case 4.3: Peering to an external non-jsonnet project with mixin with additional fields
  // Useful for custom logic when peering object is used to generate other configs and require some 'additional_field' value for example.
  + vpc.peering(
    'vpc1',
    vpc.non_jsonnet_peer_to_vpc(
      project_id='external-project',
      vpc_name='external-network',
      peering_mixin={ additional_field:: 'some value' }
    ),
  )
;

env
