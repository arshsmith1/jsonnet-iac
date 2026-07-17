local environment = import '../environment.libsonnet';

environment.gcp(
  env='test',
  project_id='my-project',
)
