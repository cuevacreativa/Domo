# Domo

[![Build Status](https://travis-ci.com/IvanRublev/domo.svg?branch=master)](https://travis-ci.com/IvanRublev/domo)
[![Method TDD](https://img.shields.io/badge/method-TDD-blue)](#domo)
[![hex.pm version](http://img.shields.io/hexpm/v/domo.svg?style=flat)](https://hex.pm/packages/domo)

:warning: This library generates code for structures that can bring suboptimal compilation times increased to approx 20%

:information_source: The usage example is in [/example_avialia](/example_avialia) directory.

:information_source: Examples of integration with `TypedStruct` and `TypedEctoSchema` are in [/example_typed_integrations](/example_typed_integrations) directory.

:information_source: JSON parsing and validation example is in [/example_json_parse](/example_json_parse) directory.

---

[//]: # (Documentation)

A library to ensure the consistency of structs modelling a business domain via
their `t()` types and associated precondition functions.

Used in a struct's module, the library adds constructor, validation, 
and reflection functions. Constructor and validation functions 
guarantee the following at call time:

  * A complex struct conforms to its `t()` type. 
  * Structs are validated to be consistent to follow given business rules by
    precondition functions associated with struct types.

If the conditions described above are not met, the constructor 
and validation functions return an error.

Because precondition function associates with type the validation can be shared
across all structs referencing the type.

In terms of Domain Driven Design the invariants relating structs to each other
can be defined with types and associated precondition functions.

Let's say that we have a `PurchaseOrder` and `LineItem` structs with relating
invariant that is the sum of line item amounts should be less then order's
approved limit. That can be expressed like the following:

    defmodule PurchaseOrder do
      use Domo

      defstruct [id: 1000, approved_limit: 200, items: []]

      @type id :: non_neg_integer()
      precond id: &(1000 <= &1 and &1 <= 5000)

      @type t :: %__MODULE__{
        id: id(),
        approved_limit: pos_integer(),
        items: [LineItem.t()]
      }
      precond t: &validate_invariants/1

      defp validate_invariants(po) do
        cond do
          po.items |> Enum.map(& &1.amount) |> Enum.sum() > po.approved_limit ->
            {:error, "Sum of line item amounts should be <= to approved limit"}

          true ->
            :ok
        end
      end
    end

    defmodule LineItem do
      use Domo

      defstruct [amount: 0]

      @type t :: %__MODULE__{amount: non_neg_integer()}
    end

Then `PurchaseOrder` struct can be constructed consistently like that:

    iex> {:ok, po} = PurchaseOrder.new()
    {:ok, %PurchaseOrder{approved_limit: 200, id: 1000, items: []}}

    iex> PurchaseOrder.new(id: 500, approved_limit: 0)
    {:error,
     [
       id: "Invalid value 500 for field :id of %PurchaseOrder{}. Expected the 
       value matching the non_neg_integer() type. And a true value from 
       the precondition function \"&(1000 <= &1 and &1 <= 5000)\" 
       defined for PurchaseOrder.id() type.",
       approved_limit: "Invalid value 0 for field :approved_limit of %PurchaseOrder{}. 
       Expected the value matching the pos_integer() type."
     ]}

    iex> updated_po = %{po | items: [LineItem.new!(amount: 150), LineItem.new!(amount: 100)]}
    %PurchaseOrder{
      approved_limit: 200,
      id: 1000,
      items: [%LineItem{amount: 150}, %LineItem{amount: 100}]
    }

    iex> PurchaseOrder.ensure_type(updated_po)
    {:error, [t: "Sum of line item amounts should be <= to approved limit"]}
    
    iex> updated_po = %{po | items: [LineItem.new!(amount: 150)]}
    %PurchaseOrder{approved_limit: 200, id: 1000, items: [%LineItem{amount: 150}]}
    
    iex> PurchaseOrder.ensure_type(updated_po)
    {:ok, %PurchaseOrder{approved_limit: 200, id: 1000, items: [%LineItem{amount: 150}]}}

See the [Callbacks](#callbacks) section for more details about functions added to the struct.

## Compile-time and Run-time validations

At the project's compile-time, Domo can perform the following checks:

  * It automatically validates that the default values given with `defstruct/1`
    conform to struct's type and fulfill preconditions.

  * It ensures that the struct using Domo built with `new!/1` function
    to be a function's default argument or a struct field's default value
    matches its type and preconditions.

Domo validates struct type conformance with appropriate `TypeEnsurer` modules 
built during the project's compilation at the application's run-time.
These modules rely on guards and pattern matchings. See `__using__/1` for 
more details.

## Depending types tracking

Suppose the given structure field's type depends on a type defined in
another module. When the latter type or its precondition changes,
Domo recompiles the former module automatically to update its
`TypeEnsurer` to keep type validation in current state.

That works similarly for any number of intermediate modules
between module defining the struct's field and module defining the field's final type.

## Setup

To use Domo in a project, add the following line to `mix.exs` dependencies:

    {:domo, "~> 1.2.0"}

And the following line to the compilers:

    compilers: Mix.compilers() ++ [:domo_compiler],

To avoid `mix format` putting extra parentheses around `precond/1` macro call,
add the following import to the `.formatter.exs`:

    [
      import_deps: [:domo]
    ]

## Usage with Phoenix hot reload

To call functions added by Domo from a Phoenix controller, add the following 
line to the endpoint's configuration in the `config.exs` file:

    config :my_app, MyApp.Endpoint,
      reloadable_compilers: [:phoenix] ++ Mix.compilers() ++ [:domo_compiler],

Otherwise, type changes wouldn't be hot-reloaded by Phoenix.

## Usage with Ecto

Ecto schema changeset can be automatically validated to conform to `t()` type
and fulfil associated preconditions.

See `Domo.Changeset` module documentation for details.

See the example app using Domo to validate Ecto changesets 
in the `/example_avialia` folder of this repository.

## Usage with libraries generating t() type for a struct

Domo is compatible with most libraries that generate `t()` type for a struct
or an Ecto schema. Just `use Domo` in the module, and that's it.

An advanced example is in the `/example_typed_integrations` folder 
of this repository.

[//]: # (Documentation)

## <a name="callbacks"></a>Constructor, validation, and reflection functions added to the current module

### new!/1/0

<blockquote>

[//]: # (new!/1)

Creates a struct validating type conformance and preconditions.

The argument is any `Enumerable` that emits two-element tuples
(key-value pairs) during enumeration.

Returns the instance of the struct built from the given `enumerable`.
Does so only if struct's field values conform to its `t()` type
and all field's type and struct's type precondition functions return ok.

Raises an `ArgumentError` if conditions described above are not fulfilled.

This function will check if every given key-value belongs to the struct
and raise `KeyError` otherwise.

[//]: # (new!/1)

</blockquote>

### new/2/1/0

<blockquote>

[//]: # (new/2)

Creates a struct validating type conformance and preconditions.

The argument is any `Enumerable` that emits two-element tuples
(key-value pairs) during enumeration.

Returns the instance of the struct built from the given `enumerable`
in the shape of `{:ok, struct_value}`. Does so only if struct's
field values conform to its `t()` type and all field's type and struct's
type precondition functions return ok.

If conditions described above are not fulfilled, the function
returns an appropriate error in the shape of `{:error, message_by_field}`.
`message_by_field` is a keyword list where the key is the name of
the field and value is the string with the error message.

Keys in the `enumerable` that don't exist in the struct
are automatically discarded.

## Options

  * `maybe_filter_precond_errors` - when set to `true`, the values in
    `message_by_field` instead of string become a list of error messages
    from precondition functions. If there are no error messages from
    precondition functions for a field's type, then all errors are returned
    unfiltered. Helpful in taking one of the custom errors after executing
    precondition functions in a deeply nested type to communicate
    back to the user. F.e. when the field's type is another struct.
    Default is `false`.

[//]: # (new/2)

</blockquote>

### ensure_type!/1

<blockquote>

[//]: # (ensure_type!/1)

Ensures that struct conforms to its `t()` type and all preconditions
are fulfilled.

Returns struct when it's valid. Raises an `ArgumentError` otherwise.

Useful for struct validation when its fields changed with map syntax
or with `Map` module functions.

[//]: # (ensure_type!/1)

</blockquote>

### ensure_type/2/1

<blockquote>

[//]: # (ensure_type/2)

Ensures that struct conforms to its `t()` type and all preconditions
are fulfilled.

Returns struct when it's valid in the shape of `{:ok, struct}`.
Otherwise returns the error in the shape of `{:error, message_by_field}`.

Useful for struct validation when its fields changed with map syntax
or with `Map` module functions.

[//]: # (ensure_type/2)

</blockquote>

### typed_fields/1/0

<blockquote>

[//]: # (typed_fields/1)

Returns the list of struct's fields defined with its `t()` type.

Does not return meta fields with `__underscored__` names and fields
having `any()` type by default.

Includes fields that have `nil` type into the return list.

## Options

  * `:include_any_typed` - when set to `true`, adds fields with `any()`
    type to the return list. Default is `false`.

  * `:include_meta` - when set to `true`, adds fields
    with `__underscored__` names to the return list. Default is `false`.

[//]: # (typed_fields/1)

</blockquote>

### required_fields/1/0

<blockquote>

[//]: # (required_fields/1)

Returns the list of struct's fields having type others then `nil` or `any()`.

Does not return meta fields with `__underscored__` names.

Useful for validation of the required fields for emptiness.
F.e. with `validate_required/2` call in the `Ecto` changeset.

## Options

  * `:include_meta` - when set to `true`, adds fields
    with `__underscored__` names to the return list. Default is `false`.

[//]: # (required_fields/1)

</blockquote>

## Limitations

The recursive types like `@type t :: :end | {integer, t()}` are not supported. 
Because of that types like `Macro.t()` or `Path.t()` are not supported.

Parametrized types are not supported. Library returns `{:type_not_found, :key}` 
error for `@type dict(key, value) :: [{key, value}]` type definition.

`MapSet.t(value)` just checks that the struct is of `MapSet`. Precondition
can be used to verify set values.

Domo doesn't check struct fields default value explicitly; instead,
it fails when one creates a struct with wrong defaults.

Generated submodule with TypedStruct's `:module` option is not supported.

## Migration

To complete the migration to a new version of Domo, please, clean and recompile
the project with `mix clean --deps && mix compile` command.

## Adoption

It's possible to adopt Domo library in the project having user-defined
constructor functions as the following:

1. Add `:domo` dependency to the project, configure compilers as described in
   the [setup](#setup) section
2. Set the name of the Domo generated constructor function by adding
   `config :domo, :name_of_new_function, :constructor_name` option into
   the `confix.exs` file, to prevent conflict with original constructor
   function names if any
3. Add `use Domo` to existing struct
4. Change the calls to build the struct for Domo generated constructor
   function with name set on step 3 and remove original constructor function
5. Repeat for each struct in the project

## Performance 🐢

On the average, the current version of the library makes struct operations 
about 20% sower what may seem plodding. And it may look like non-performant
to run in production.

It's not that. The library ensures the correctness of data types at runtime and
it comes with the price of computation. As the result users get the application 
with correct states at every update that is valid in many business contexts.

Please, find the output of `mix benchmark` command below.

    Generate 10000 inputs, may take a while.
    =========================================

    Construction of a struct
    =========================================
    Operating System: macOS
    CPU Information: Intel(R) Core(TM) i7-4870HQ CPU @ 2.50GHz
    Number of Available Cores: 8
    Available memory: 16 GB
    Elixir 1.12.3
    Erlang 24.0.1

    Benchmark suite executing with the following configuration:
    warmup: 2 s
    time: 5 s
    memory time: 0 ns
    parallel: 1
    inputs: none specified
    Estimated total run time: 14 s

    Benchmarking __MODULE__.new!(arg)...
    Benchmarking struct!(__MODULE__, arg)...

    Name                               ips        average  deviation         median         99th %
    struct!(__MODULE__, arg)       14.35 K       69.69 μs    ±62.62%          70 μs         151 μs
    __MODULE__.new!(arg)           12.04 K       83.05 μs    ±51.32%          84 μs         157 μs

    Comparison: 
    struct!(__MODULE__, arg)       14.35 K
    __MODULE__.new!(arg)           12.04 K - 1.19x slower +13.36 μs

    A struct's field modification
    =========================================
    Operating System: macOS
    CPU Information: Intel(R) Core(TM) i7-4870HQ CPU @ 2.50GHz
    Number of Available Cores: 8
    Available memory: 16 GB
    Elixir 1.12.3
    Erlang 24.0.1

    Benchmark suite executing with the following configuration:
    warmup: 2 s
    time: 5 s
    memory time: 0 ns
    parallel: 1
    inputs: none specified
    Estimated total run time: 14 s

    Benchmarking %{tweet | user: arg} |> __MODULE__.ensure_type!()...
    Benchmarking struct!(tweet, user: arg)...

    Name                                                        ips        average  deviation         median         99th %
    struct!(tweet, user: arg)                               15.45 K       64.71 μs    ±68.57%          67 μs         142 μs
    %{tweet | user: arg} |> __MODULE__.ensure_type!()       13.64 K       73.34 μs    ±60.02%          73 μs         149 μs

    Comparison: 
    struct!(tweet, user: arg)                               15.45 K
    %{tweet | user: arg} |> __MODULE__.ensure_type!()       13.64 K - 1.13x slower +8.63 μs

## Contributing

1. Fork the repository and make a feature branch

2. Working on the feature, please add typespecs

3. After working on the feature format code with

       mix format

   run the tests to ensure that all works as expected with

       mix test

4. Make a PR to this repository

## Changelog

### 1.3.2
* Support remote types in erlang modules like `:inet.port_number()`

* Shorten the invalid value output in the error message

* Increase validation speed by skipping fields that are not in `t()` type spec or have the `any()` type

* Fix bug to skip validation of struct's enforced keys default value because they are ignored during the construction anyway

* Increase validation speed by generating `TypeEnsurer` modules for `Date`, `Date.Range`, `DateTime`, `File.Stat`, `File.Stream`, `GenEvent.Stream`, `IO.Stream`, `Macro.Env`, `NaiveDateTime`, `Range`, `Regex`, `Task`, `Time`, `URI`, and `Version` structs from the standard library at the first project compilation

* Fix bug to call the `precond` function of the user type pointing to a struct

* Increase validation speed by encouraging to use Domo or to make a `precond` function for struct referenced by a user type

* Add `Domo.has_type_ensurer?/1` that checks whether a `TypeEnsurer` module was generated for the given struct.

* Add example of parsing with validating of the Contentful JSON reply via `Jason` + `ExJSONPath` + `Domo`

### 1.3.1
* Fix bug to validate defaults having | nil type.

### 1.3.0 
* Change the default name of the constructor function to `new!` to follow Elixir naming convention.
  You can always change the name with the `config :domo, :name_of_new_function, :new_func_name_here` app configuration.

* Fix bug to validate defaults for every required field in a struct except `__underscored__` fields at compile-time.

* Check whether the precondition function associated with `t()` type returns `true` at compile time regarding defaults correctness check.

* Add examples of integrations with `TypedStruct` and `TypedEctoSchema`.

### 1.2.9
* Fix bug to acknowledge that type has been changed after a failed compilation.

* Fix bug to match structs not using Domo with a field of `any()` type with and without precondition.

* Add `typed_fields/1` and `required_fields/1` functions.

* Add `maybe_filter_precond_errors: true` option that filters errors from precondition functions for better output for the user.

### 1.2.8
* Add `Domo.Changeset.validate_type/*` functions to validate Echo.Changeset field changes matching the t() type.

* Fix the bug to return custom error from precondition function as underlying error for :| types.

### 1.2.7
* Fix the bug to make recompilation occur when fixing alias for remote type.

* Support custom errors to be returned from functions defined with `precond/1`.

### 1.2.6
* Validates type conformance of default values given with `defstruct/1` to the
  struct's `t()` type at compile-time.

* Includes only the most matching type error into the error message.

### 1.2.5
* Add `remote_types_as_any` option to disable validation of specified complex
  remote types. What can be replaced by precondition for wrapping user-defined type.

### 1.2.4
* Speedup resolving of struct types
* Limit the number of allowed fields types combinations to 4096
* Support `Range.t()` and `MapSet.t()`
* Keep type ensurers source code after compiling umbrella project
* Remove preconditions manifest file on `mix clean` command
* List processed structs giving mix `--verbose` option

### 1.2.3
* Support struct's attribute introduced in Elixir 1.12.0 for error checking
* Add user-defined precondition functions to check the allowed range of values
  with `precond/1` macro

### 1.2.2
* Add support for `new/1` calls at compile time f.e. to specify default values

### 1.2.1
* Domo compiler is renamed to `:domo_compiler`
* Compile `TypeEnsurer` modules only if struct changes or dependency type changes 
* Phoenix hot-reload with `:reloadable_compilers` option is fully supported

### 1.2.0 
* Resolve all types at compile time and build `TypeEnsurer` modules for all structs
* Make Domo library work with Elixir 1.11.x and take it as the required minimum version
* Introduce `---/2` operator to make tag chains with `Domo.TaggedTuple` module

### 0.0.x - 1.0.x 
* MVP like releases, resolving types at runtime. Adds `new` constructor to a struct

## Roadmap

* [x] Check if the field values passed as an argument to the `new/1`, 
      and `put/3` matches the field types defined in `typedstruct/1`.

* [x] Support the keyword list as a possible argument for the `new/1`.

* [x] Add module option to put a warning in the console instead of raising 
      of the `ArgumentError` exception on value type mismatch.

* [x] Make global environment configuration options to turn errors into 
      warnings that are equivalent to module ones.

* [x] Move type resolving to the compile time.

* [x] Keep only bare minimum of generated functions that are `new/1`,
      `ensure_type!/1` and their _ok versions.

* [x] Make the `new/1` and `ensure_type!/1` speed to be less or equal 
      to 1.5 times of the `struct!/2` speed.

* [x] Support `new/1` calls in macros to specify default values f.e. in other 
      structures. That is to check if default value matches type at compile time.

* [x] Support `precond/1` macro to specify a struct field value's contract 
      with a boolean function.

* [ ] Evaluate full recompilation time for 1000 structs using Domo.

* [x] Add use option to specify names of the generated functions.

* [x] Add documentation to the generated for `new(_ok)/1`, and `ensure_type!(_ok)/1`
      functions in a struct.


## License

Copyright © 2021 Ivan Rublev

This project is licensed under the [MIT license](LICENSE).
