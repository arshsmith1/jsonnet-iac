# Jsonnet Infrastructure-as-Code (jsonnet_iac)

NOTE See the code at [jsonnet_iac](https://github.com/google/jsonnet-iac)
repository.

![Jsonnet IAC logo](assets/logo.png){style="width:120px; height:120px"}

-   **hcl.libsonnet** library transforming jsonnet into terraform (hcl language)
-   logically coherent building blocks (**mixins**) to generate GCP terraform
    resources

## License

Apache 2.0. See [LICENSE](LICENSE) for more details.

## When to use

For managing complicated GCP cloud environments at scale, when single source of
truth generates terraform and other config files.

This approach is successfully used to manage large-scale infrastructure with
thousands of VMs and tens of GCP projects.

There is a little benefit to use this framework for a few cloud resources
(though still possible).

See [Model and IaC Separation](#model-and-iac-separation) for more details.

## Jsonnet language

Learn jsonnet on https://jsonnet.org

> TIP Make sure you understand the following concepts:
>
> -   hidden fields `::`
> -   `self` and `super`
> -   `Inheritance` (including `+:` and `+::`). We call it "deep merge of
>     objects".
> -   `manifest` functions (transform jsonnet object to text as yaml, py etc)

## Examples of actual code

See `tests/testdata/*.jsonnet` files, which are used for high-level testing and
give a basic impression of what real code looks like (each file is dedicated to
one theme, so it's not a real environment, but all of them together can be used
to produce real configuration).

## Generating Configuration Files

To materialize the actual output configuration files (such as Terraform `.tf`
files and JSON files) from a high-level `.jsonnet` model, install the
open-source [jsonnet](https://jsonnet.org) CLI and run it with the `-m`
(multi-file) option:

```bash
jsonnet -J . -J tests -m out/ tests/testdata/iam_use_cases.jsonnet
```

> [!NOTE] The `-J . -J tests` flags specify the library search paths so the
> Jsonnet interpreter can correctly resolve imported `.libsonnet` files from
> both the repository root and the tests directory.

> [!TIP] For a more comprehensive, production-ready workflow, you can automate
> this generation step in your existing CI/CD pipelines, Makefiles, or custom
> build scripts. This lets you wrap the `jsonnet` binary to automatically locate
> dependencies, handle multi-file outputs across different environments, and
> perform **diff testing** ensuring that jsonnet changes and generated files
> match.

## Testing

To verify the library logic and run unit tests natively with Go, use standard Go
tools: `bash go test -v ./...`

> [!IMPORTANT] - **go.mod**: Sits at the repository root and defines
> dependencies for all packages, including subdirectories like `tests/`. -
> **go.sum**: Holds cryptographically secure dependency checksums to guarantee
> reproducible builds. Always run `go mod tidy` and commit `go.sum` to ensure
> tests run reliably in CI/CD such as GitHub Actions.

## hcl.libsonnet library

NOTE Used to materialize terraform content from jsonnet object to hcl text.

hcl.libsonnet

Key concepts:

*   `hcl.resource` marks an object where it's used as a terraform resource
*   `hcl.manifest()` method recursively walks through the tree of fields, stops
    at the object marked as terraform resource and converts the object to a
    Terraform string.

Example:

```yaml {highlight="context:hcl.resource context:hcl.manifest(self.foo)"}
{
  foo:: {
    some_level: {
      # it can be array
      service_accounts: [
        hcl.resource {
          hcllabels:: [
            'google_service_account',
            hcl.strToSnake(self.account_id),
          ],
          project: "gcp-proj",
          account_id: 'sap-my-role-my',
        },
        # ... more array items can be added
      ],
      component_db: {
        disk: hcl.resource {
          hcllabels:: [
            'google_compute_disk',
            hcl.strToSnake(self.name),
          ],
          project: "gcp-proj",
          size: 256,
        },
      },
    },
  },

  tf: hcl.manifest(self.foo),
}
```

`tf` field will contain the following string:

```
resource "google_compute_disk" "data" {
  project = "gcp-proj"
  size    = 256
}

resource "google_service_account" "service_account_my" {
  account_id = "sap-my-role-my"
  project     = "gcp-proj"
}
```

## Environment structure

Every GCP environment is described in a `<env_name>.jsonnet` file.

When processed by jsonnet binary (with -m option) it creates files, one per each
visible field.

Conceptually the env file looks like this:

```yaml
{
  # Section 1 - hidden fields
  # These fields contain structured data about environment.

  hidden_field1:: {},
  hidden_field2:: {},
  example:: self.hidden_field1 + self.hidden_field2,
  # reserved field for components, each field inside represent component object
  components:: {},

  # Section 2 - visible fields
  # These fields are used to produce files:
  #       field name is a file name,
  #       content of the field is the file content.

  'example.json': self.example, # jsonnet materialize regular json by default
  'db.tf': hcl.manifest(self.components.db), # turn db comp to a terraform content
  'some.txt': 'raw content',
  'example.yml': std.manifestYaml({<some jsonnet content>}),
}
```

There are also:

*   `base` hidden field used as container for common metadata used by other
    mixins.
*   `project` hidden field used as container for terraform resources used on
    environment project level (materialized into project.tf file)

See actual code environment.libsonnet

### Component structure

A component is added to an environment by `environment.component()` env-level
mixin, which additionally does:

*   makes component inherit `base` field from env object
*   adds `env` field to a component, so comp-level mixins can refer objects from
    env-level fields
*   adds to environment the `{comp name}.tf` visible field with content as
    `hcl.manifest(self.components.{comp name})` which is materialized to actual
    tf file.

Every component has:

*   `by_region` hidden field, contains common logic for regions
*   `regions` visible field is array of regions objects which contain tf
    resources per region
*   `by_instance` hidden field, contains common logic for VM instances

And `regions` array contains region objects, where each region object has:

*   `instances` visible field is array of instance objects which contain tf
    resources per VM instance

For additional details see component.libsonnet

### Idea of `mixin`

To hide details of implementation of the object we can split it on ==separate
objects== (which are doing one thing and contains ==highly coupled==
information).

Then we merge them (in jsonnet it's called inheritance).

Lets create for environment example above `mixins.jsonnet` file with mixins:

```yaml
# mixins.jsonnet file
{
  # example mixin
  example: {
    hidden_field1:: {},
    hidden_field2:: {},
    example:: self.hidden_field1 + self.hidden_field2,
    'example.tf': hcl.manifest(self.example),
  },

  # bar mixin
  bar: {
    bar:: {},
    'bar.tf': hcl.manifest(self.bar),
  },

  # foo mixin
  foo: {
    'foo.txt': 'raw content',
  },
}
```

Import mixins.jsonnet file in our env.jsonnet file:

```yaml
# environment file
local mixins = import 'mixins.jsonnet';

  mixins.example
+ mixins.bar
+ mixins.foo
```

## mixin types, `base` field usage, and propagation:

IMPORTANT all mixins should be one of those 2 types or both

There are primarily **two types of mixins**:

1.  **Environment-level Mixins:** These are designed to be applied to the main
    environment object, typically defined in files like `dev5.jsonnet`. They add
    or modify environment-wide configurations, resources, or components.
    Examples can be found in `environment.libsonnet` (e.g., `gcp()`,
    `component()`, `apis()`).

2.  **Component-level Mixins:** These are applied to individual components
    within an environment. Components are usually defined using
    `environment.component()` in the environment file. Component-level mixins
    add or modify resources specific to that component, such as VMs, disks, or
    instance-specific metadata. Examples are found in files like
    `component.libsonnet` (e.g., `instance_name()`, `on_vm()`, `set_regions()`)
    and `vm.libsonnet`.

**The `base` Field and its Propagation**

The `base` field is a hidden object (`base::`) used as a container for common
metadata and configuration properties. It's propagated hierarchically from the
environment down to individual instances, with fields being added or overridden
at each level. This ensures that lower levels have access to context from higher
levels.

Here's how `base` is used and propagated:

1.  **Environment Level (`environment.libsonnet`):**

    *   The `environment.gcp()` mixin initializes the environment's `base`.
    *   **Default Fields Added:**
        *   `service_name`: Logical service group (e.g., 'sap').
        *   `project_id`: GCP project ID.
        *   `env`: Environment name (e.g., 'dev5').
        *   `regions`: An array to be populated with region metadata objects
            (initially empty, filled by `vpc.regional()`).
        *   `project`: Reference to the project data resource.
    *   `environment.custom_metadata()` allows merging an arbitrary object into
        `base`.

2.  **Component Level (Inside `environment.component()`):**

    *   When a component is added using `environment.component(c, name)`, the
        component's `base` is created by **inheriting from the environment's
        `base`** and adding the component's name.
    *   `base:: env.base { comp:: n }`
    *   **Default Fields Added:** `comp` (the component name, e.g., 'app',
        'db'). All fields from the environment `base` are also present.

3.  **Region Level (`component.libsonnet` - `main_structure`):**

    *   The component's `base` is propagated to a template called `by_region`:
        `by_region:: { base:: base }`.
    *   When the actual regions are instantiated (based on the `regions` array
        in the environment's `base`), the specific `region_metadata` for that
        region (e.g., name, zones) is merged into the `base`.
    *   `self.by_region { base+:: region_metadata, ... }`
    *   **Default Fields Added:** Fields from the `region_metadata` object, such
        as:
        *   `region`: Region name (e.g., 'us-central1').
        *   `region_number`: Region number/suffix.
        *   `zones`: List of zones in the region.
        *   `zone_letters`: Corresponding letters for the zones.

4.  **Instance Level (`component.libsonnet` - `main_structure`):**

    *   The region's `base` is propagated to a template called `by_instance`:
        `by_instance:: { base:: region_template_base { ... } }`.
    *   When individual VM instances are created within a region, further
        instance-specific properties are added to the `base`.
    *   `by_instance { base+:: region_base { index:: x }, ... }`
    *   **Default Fields Added:**
        *   `index`: The instance number (1-based).
        *   `hostname`: Generated hostname (e.g., 'sapdapp51').
        *   `zone`: The specific zone for this instance, selected from
            `base.zones`.
        *   `zone_letter`: The letter for the instance's zone.
        *   `internal_domain`: The internal DNS domain.
        *   `fqdn`: The fully qualified domain name.

**In summary:**

*   Mixins are either **Env-level** or **Comp-level**.
*   The `base` object acts as a thread of context, carrying information from the
    environment definition down to each VM instance.
*   It starts with project and environment details at the top level.
*   The component name is added when a component is defined.
*   Regional information is merged in for each region the component deploys to.
*   Instance-specific details like index and hostname are added at the lowest
    level.
*   The `+::` operator is key for merging, allowing lower levels to extend the
    `base` inherited from above.

## Basic algorithm to introduce new mixin

1.  Start from understanding which cloud resources (and related terraform) are
    being created.
1.  Identify on which logical level those new resources should be placed (e.g.
    resource dedicated for each VM should be on instance level (like disk), if
    one resource per group of VMs then it's component (like ILB)). Or maybe
    there might be multiple resources on different levels linking each other.
1.  Find similar resources in existing code (which placed on expected logical
    level)
1.  Create those mixins with minimal fields first to generate initial terraform
    and confirm that the logical level placement was chosen correctly.
1.  Finally add all necessary fields (make sure you follow style guide below and
    rely on metadata propagation and reference other resources fields though
    related .self_ref() functions)

## Style guide

### hcl.resource

Hidden (::) fields go 1st, then visible (:) fields. Visible fields represent
actual args in terraform resource.

Don't hardcode `name` pattern

Introduce arg `name='something_with_%(placeholder)s'` and format using `base` of
given mixin level (comp or env) `placeholder` defined either in base or merged
with base object.

If there is `name` arg in terraform resource, hcllabels always should have
`std.strToSnake(self.name)`

Put `hcllabels` and `tfimport` fields first (they are used by `hcl.resource`)

> [!WARNING]
> Bad practice:
> ```yaml
> my_comp_resource(): {
>   hcl.resource {
>     name: base.env,
>     tfimport:: '%s/%s' % [base.project_id, self.name],
>     dns_name: '%s.gcp.sapcloud.goog.' % self.name,
>     hcllabels:: ['google_dns_managed_zone', std.strToSnake(self.name)],
>   },
> },
> ```

> [!NOTE]
> Good practice:
> ```yaml
> my_comp_resource(
>   name='%(env)s-%(special_value)s',
>   dns_name='%(env)s.gcp.sapcloud.goog.'
> ): {
>   hcl.resource {
>     hcllabels:: ['google_dns_managed_zone', std.strToSnake(self.name)],
>     tfimport:: '%s/%s' % [base.project_id, self.name],
>     name: name % base {
>       // can be dynamically calculated, e.g. std.asciiUpper(base.project_id)
>       special_value: 123,
>     },
>     dns_name: dns_name % base,
>   },
> },
> ```

### Abstract `hcl.resource`

It's important to know which resource is being created.

Avoid creating abstract `hcl.resource` objects that contain the `hcllabels`
field, which are then extended to create the final resource.

However, if there is a need to avoid logic duplication then create a common
object that contains the other shared fields of the resource.

> [!WARNING]
> Bad practice:
> ```yaml
> local abstract_cname = hcl.resource {
>   hcllabels:: ['google_dns_managed_zone', std.strToSnake(self.name)],
>   dns_name: '%s.gcp.sapcloud.goog.' % self.name,
>   project: self.project_id,
>   <... other fields ...>
> };
>
> cname: abstract_cname {
>   name: self.env,
> },
> ```

> [!NOTE]
> Good practice:
> ```yaml
> local my_common_fields = hcl.resource {
>   dns_name: '%s.gcp.sapcloud.goog.' % self.name,
>   project: self.project_id,
>   <... other fields ...>
> };
>
> cname: hcl.resource {
>   hcllabels:: ['google_dns_managed_zone', std.strToSnake(self.name)],
>   name: self.env,
> } + my_common_fields,
> ```

### Metadata for both `env` and `component` levels

There are cases when a value is used on component level, but it has env-level
default.

For example, `foo` is set for entire environment, it also can be set for each
component individually.

In this case we set it into `base` field using `environment.custom_metadata`.

```yaml
# env.jsonnet file
env =
...
+ environment.custom_metadata({ foo: 1 })
...
+ environment.component(
  ...
  // override for a component
  + environment.custom_metadata({ foo: 2 })
)
```

### Mixins

Prefer separate named mixins for clarity

> [!WARNING]
> Bad practice:
> ```yaml
>   + cloud_monitoring.include(true)
>     ...
>   + cloud_monitoring.include(false)
> ```

> [!NOTE]
> Good practice:
> ```yaml
>   + cloud_monitoring.include
>     ...
>   + cloud_monitoring.exclude
> ```

### Environment related logic should be in env.jsonnet files

It can be tempting to "save extra couple lines of code" but will end up in
additional layer of indirection, which in a long run will make it hard to
understand the code

> [!WARNING]
> Bad practice:
> ```yaml
> # project.libsonnet file
> {
> central: feature1 + feature2,
> }
>
> # central_sbx.jsonnet file
> ...
> project.central
> ...
>
> # central_prod.jsonnet file
> ...
> project.central
> ...
> ```

> [!NOTE]
> Good practice:
> ```yaml
> # central_sbx.jsonnet file
> ...
> + feature1
> + feature2
> ...
>
> # central_prod.jsonnet file
> ...
> + feature1
> + feature2
> ...
> ```

### Every field on a new line

Following that rule will help for jsonnet readers' eye easier read object
structures.

> [!WARNING]
> Bad practice:
> ```yaml
> foo_mixin(name, resource):: { bar+:: { [name]+: { resources+:: {
> internal+: resource } }, } },
> ```

> [!NOTE]
> Good practice:
> ```yaml
> foo_mixin(name, resource):: {
>   bar+:: {
>     [name]+: {
>       resources+:: {
>         internal+: resource,
>       },
>     },
>   },
> },
> ```

### Local fields

Declare a field `local` if it's used in current scope (file or object)

> [!WARNING]
> Bad practice:
> ```yaml
> foo_mixin: {
>   ...
> }
>
> main_object: {
>   a_field: $.foo_mixin,
> }
> ```

> [!NOTE]
> Good practice:
> ```yaml
> main_object: {
>   local foo_mixin = {
>     ...
>   },
>   a_field: foo_mixin,
> }
> ```

### Resources references

Reference resource attributes through `hcl.self_link` and
`hcl.self_ref('field')` instead of ~~`hcl.expression`~~

This way there is no need to manipulate strings and re-construct resource name
again. So the name of the resource is defined in only one place where it's
created, and later renaming will be used by all referencing resources
automatically.

> [!WARNING]
> Bad practice:
> ```yaml
> foo_resource: hcl.resource {
>   hcllabels:: ['google_compute_instance', 'foo_name'],
> }
>
> bar_resource: hcl.resource {
>   hcllabels:: ['google_compute_instance', 'bar_name'],
>   foo_id: hcl.expression('google_compute_instance.foo_name.id')
>   foo_ref: hcl.expression('google_compute_instance.foo_name')
> }
> ```

> [!NOTE]
> Good practice:
> ```yaml
> # This code produces the same terraform code as the code above.
>
> foo_resource: hcl.resource {
>   hcllabels:: ['google_compute_instance', 'foo_name'],
> },
>
> local foo_resource = self.foo_resource,
> bar_resource: hcl.resource {
>   hcllabels:: ['google_compute_instance', std.strToSnake(self.name)],
>   name: 'bar_name',
>   foo_id: foo_resource.self_ref('id')
>   foo_ref: foo_resource.self_link
> }
> ```

### Mixins description

Description template is like the below (with <...> placeholders)

> [!NOTE]
> Recommended template:
> ```yaml
>   // <Env-level or comp-level> mixin.
>   // Creates <tf resource name> terraform resource.
>   // NOTE <if there is something important to mention, e.g. usual use case>
>   // IMPORTANT: <e.g. dependencies on other mixins>
>   // Args:
>   //   arg1: <optional if has default value>, <description>.
>   // Example: e.g. for component level like below
>   // + environment.component(
>   //     ...
>   //     + vm.attach_regional_disk('my-regional-disk')
> ```

## How to extend functionality

When there is a need to modify existing or add **"project-specific"** mixins to
this library, it can be done by just importing a library to same-named file with
additional logic and using this file in local project instead of generic one

Example:

```jsonnet

# Library file jsonnet_iac/disk.libsonnet
....

# Project-specific library file my_project/lib/disk.libsonnet
import '../...../jsonnet_iac/disk.libsonnet' {

  // extend logic of existting disk.boot() mixin
  boot(image, snapshot_policy=null, size=50): super.boot(image, snapshot_policy, size) {
    additional_field:: {...something...},
  }

  my_new_mixins:{
    .....
  }
}

# Environment file my_project/dev.jsonnet
local disk = import 'my_project/lib/disk.libsonnet';

environment.gcp(
  env='test',
  project_id='my-project',
)
...
+ environment.component(
  vm.count(vms_count=1)
...
  + disk.boot(image='image-family/my-image')
  + disk.my_new_mixins
)

```

## Model and IaC Separation

The core philosophy is to **separate** the description of **resources**
(Terraform) from the logical **"model"** (abstractions, naming conventions,
relationships).

**Flow:** `Model (Jsonnet) -> Generator (jsonnet compiler binary) ->
Non-abstract Intent (Terraform) -> Resources (GCP)`

### Benefits compared to "just Terraform" modules

*   **Non-abstract Intent:** Terraform files become purely declarative and flat.
    We avoid complex dynamic features like `count`, `for_each`, and dynamic
    expressions in Terraform. This makes the "Intent" (Terraform code) easy to
    read, audit with line-by-line commit history, and understand by anyone with
    basic Terraform knowledge without need to run terraform plan.
*   **Logic Isolation:** Complex logic (naming conventions, hierarchy, component
    structure) resides in the Model (Jsonnet) and Generator. The resulting
    Terraform is stable and explicit.
*   **Granular Control:** It is easy to modify a specific resource (e.g., add a
    disk to a single VM in a cluster) without needing to refactor a complex,
    generic Terraform module or introduce workarounds.
*   **Auditability:** Changes to resources are clearly visible in the generated
    Terraform diffs, providing a non-abstract history of what exactly is
    changing in the infrastructure.

### Example scenario

**Goal:** Add a temporary test disk to one specific VM in a cluster of 6 VMs for
an end-to-end refresh test.

*   **With standard Terraform modules:** This would often require refactoring
    the module logic (which might be assuming all VMs are identical) or
    introducing complex `if/else` logic or variable overrides just for this
    one-off case.
*   **With Jsonnet/Model separation:** You simply add the disk definition to the
    specific instance in the Jsonnet model. The generator produces the updated
    Terraform file where one `google_compute_instance` resource now has an extra
    attached disk. No other resources are affected, and the Terraform diff
    clearly shows the addition of the disk resource and its attachment.

    **Generated Terraform Diff:**

    Because the output is a flat Terraform file, the diff is immediately obvious
    without running `terraform plan`:

    ```diff
    + resource "google_compute_disk" "test_disk" {
    +   name    = "test-disk-1"
    +   type    = "pd-ssd"
    +   zone    = "us-central1-a"
    +   size    = 100
    + }

      resource "google_compute_instance" "app_server_1" {
        name = "app-server-1"
        # ... other fields ...
    +   attached_disk {
    +     source = google_compute_disk.test_disk.self_link
    +   }
      }
    ```

## Authors / Contributors

-   [artembar](https://github.com/artembar)
-   [davegalos](https://github.com/davegalos)
