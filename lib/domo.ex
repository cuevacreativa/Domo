defmodule Domo do
  @moduledoc Domo.Doc.readme_doc("[//]: # (Documentation)")

  @new_doc Domo.Doc.readme_doc("[//]: # (new!/1)")
  @new_ok_doc Domo.Doc.readme_doc("[//]: # (new/2)")
  @ensure_type_doc Domo.Doc.readme_doc("[//]: # (ensure_type!/1)")
  @ensure_type_ok_doc Domo.Doc.readme_doc("[//]: # (ensure_type/2)")
  @typed_fields_doc Domo.Doc.readme_doc("[//]: # (typed_fields/1)")
  @required_fields_doc Domo.Doc.readme_doc("[//]: # (required_fields/1)")

  @callback new!() :: struct()
  @doc @new_doc
  @callback new!(enumerable :: Enumerable.t()) :: struct()
  @callback new() :: {:ok, struct()} | {:error, any()}
  @callback new(enumerable :: Enumerable.t()) :: {:ok, struct()} | {:error, any()}
  @doc @new_ok_doc
  @callback new(enumerable :: Enumerable.t(), opts :: keyword()) :: {:ok, struct()} | {:error, any()}
  @doc @ensure_type_doc
  @callback ensure_type!(struct :: struct()) :: struct()
  @callback ensure_type(struct :: struct()) :: {:ok, struct()} | {:error, any()}
  @doc @ensure_type_ok_doc
  @callback ensure_type(struct :: struct(), opts :: keyword()) :: {:ok, struct()} | {:error, any()}
  @callback typed_fields() :: [atom()]
  @doc @typed_fields_doc
  @callback typed_fields(opts :: keyword()) :: [atom()]
  @callback required_fields() :: [atom()]
  @doc @required_fields_doc
  @callback required_fields(opts :: keyword()) :: [atom()]

  alias Domo.ErrorBuilder
  alias Domo.MixProjectHelper
  alias Domo.Raises
  alias Domo.TypeEnsurerFactory
  alias Mix.Tasks.Compile.DomoCompiler, as: DomoMixTask

  @doc """
  Uses Domo in the current struct's module to add constructor, validation,
  and reflection functions.

      defmodule Model do
        use Domo

        defstruct [:first_field, :second_field]
        @type t :: %__MODULE__{first_field: atom() | nil, second_field: any() | nil}

        # have added:
        # new!/1
        # new/2
        # ensure_type!/1
        # ensure_type/2
        # typed_fields/1
        # required_fields/1
      end

  `use Domo` can be called only within the struct module having
  `t()` type defined because it's used to generate `__MODULE__.TypeEnsurer`
  with validation functions for each field in the definition.

  See details about `t()` type definition in Elixir
  [TypeSpecs](https://hexdocs.pm/elixir/typespecs.html) document.

  The macro collects `t()` type definitions for the `:domo_compiler` which
  generates `TypeEnsurer` modules during the second pass of the compilation
  of the project. Generated validation functions rely on guards appropriate
  for the field types.

  The generated code of each `TypeEnsurer` module can be found
  in `_build/MIX_ENV/domo_generated_code` folder. However, that is for information
  purposes only. The following compilation will overwrite all changes there.

  The macro adds the following functions to the current module, that are the
  facade for the generated `TypeEnsurer` module:
  `new!/1`, `new/2`, `ensure_type!/1`, `ensure_type/2`, `typed_fields/1`,
  `required_fields/1`.

  ## Options

    * `ensure_struct_defaults` - if set to `false`, disables the validation of
      default values given with `defstruct/1` to conform to the `t()` type
      at compile time. Default is `true`.

    * `name_of_new_function` - the name of the constructor function added
      to the module. The ok function name is generated automatically from
      the given one by omitting trailing `!` if any, and appending `_ok`.
      Defaults are `new!` and `new` appropriately.

    * `unexpected_type_error_as_warning` - if set to `true`, prints warning
      instead of throwing an error for field type mismatch in the raising
      functions. Default is `false`.

    * `remote_types_as_any` - keyword list of type lists by modules that should
      be treated as `any()`. F.e. `[ExternalModule: [:t, :name], OtherModule: :t]`
      Default is `nil`.

  The option value given to the macro overrides one set globally in the
  configuration with `config :domo, option: value`.
  """
  # credo:disable-for-lines:332
  defmacro __using__(opts) do
    Raises.raise_use_domo_out_of_module!(__CALLER__)
    Raises.raise_absence_of_domo_compiler!(Mix.Project.config(), opts, __CALLER__)

    start_resolve_planner()

    global_anys = Application.get_env(:domo, :remote_types_as_any)
    local_anys = Keyword.get(opts, :remote_types_as_any)

    unless is_nil(global_anys) and is_nil(local_anys) do
      plan_path = get_plan_path()
      TypeEnsurerFactory.collect_types_to_treat_as_any(plan_path, __CALLER__.module, global_anys, local_anys)
    end

    new_fun_name = :new!

    new_ok_fun_name = :new

    type_ensurer = TypeEnsurerFactory.type_ensurer(__CALLER__.module)

    long_module = TypeEnsurerFactory.module_name_string(__CALLER__.module)
    short_module = long_module |> String.split(".") |> List.last()

    quote do
      Module.register_attribute(__MODULE__, :domo_options, accumulate: false)
      Module.put_attribute(__MODULE__, :domo_options, unquote(opts))

      import Domo, only: [precond: 1]

      @doc """
      #{unquote(@new_doc)}

      ## Examples

          alias #{unquote(long_module)}

          #{unquote(short_module)}.#{unquote(new_fun_name)}(first_field: value1, second_field: value2, ...)
      """
      def unquote(new_fun_name)(enumerable \\ []) do
        skip_ensurance? =
          if TypeEnsurerFactory.compile_time?() do
            Domo._plan_struct_integrity_ensurance(__MODULE__, enumerable)
            true
          else
            false
          end

        struct = struct!(__MODULE__, enumerable)

        unless skip_ensurance? do
          Raises.maybe_raise_add_domo_compiler(__MODULE__)

          {errors, t_precondition_error} = Domo._do_validate_fields(unquote(type_ensurer), struct, :pretty_error)

          unless Enum.empty?(errors) do
            Raises.raise_or_warn_values_should_have_expected_types(unquote(opts), __MODULE__, errors)
          end

          unless is_nil(t_precondition_error) do
            Raises.raise_or_warn_struct_precondition_should_be_true(unquote(opts), t_precondition_error)
          end
        end

        struct
      end

      @doc """
      #{unquote(@new_ok_doc)}

      ## Examples

          alias #{unquote(long_module)}

          #{unquote(short_module)}.#{unquote(new_ok_fun_name)}(first_field: value1, second_field: value2, ...)
      """
      def unquote(new_ok_fun_name)(enumerable \\ [], opts \\ []) do
        skip_ensurance? =
          if TypeEnsurerFactory.compile_time?() do
            Domo._plan_struct_integrity_ensurance(__MODULE__, enumerable)
            true
          else
            false
          end

        struct = struct(__MODULE__, enumerable)

        if skip_ensurance? do
          {:ok, struct}
        else
          Raises.maybe_raise_add_domo_compiler(__MODULE__)

          {errors, t_precondition_error} = Domo._do_validate_fields(unquote(type_ensurer), struct, :pretty_error_by_key, opts)

          cond do
            not Enum.empty?(errors) -> {:error, errors}
            not is_nil(t_precondition_error) -> {:error, [t_precondition_error]}
            true -> {:ok, struct}
          end
        end
      end

      @doc """
      #{unquote(@ensure_type_doc)}

      ## Examples

          alias #{unquote(long_module)}

          struct = #{unquote(short_module)}.#{unquote(new_fun_name)}(first_field: value1, second_field: value2, ...)

          #{unquote(short_module)}.ensure_type!(%{struct | first_field: new_value})

          struct
          |> Map.put(:first_field, new_value1)
          |> Map.put(:second_field, new_value2)
          |> #{unquote(short_module)}.ensure_type!()
      """
      def ensure_type!(struct) do
        %name{} = struct

        unless name == __MODULE__ do
          Raises.raise_struct_should_be_passed(__MODULE__, instead_of: name)
        end

        skip_ensurance? =
          if TypeEnsurerFactory.compile_time?() do
            Domo._plan_struct_integrity_ensurance(__MODULE__, Map.from_struct(struct))
            true
          else
            false
          end

        unless skip_ensurance? do
          Raises.maybe_raise_add_domo_compiler(__MODULE__)

          {errors, t_precondition_error} = Domo._do_validate_fields(unquote(type_ensurer), struct, :pretty_error)

          unless Enum.empty?(errors) do
            Raises.raise_or_warn_values_should_have_expected_types(unquote(opts), __MODULE__, errors)
          end

          unless is_nil(t_precondition_error) do
            Raises.raise_or_warn_struct_precondition_should_be_true(unquote(opts), t_precondition_error)
          end
        end

        struct
      end

      @doc """
      #{unquote(@ensure_type_ok_doc)}

      Options are the same as for `#{unquote(new_ok_fun_name)}/2`.

      ## Examples

          alias #{unquote(long_module)}

          struct = #{unquote(short_module)}.#{unquote(new_fun_name)}(first_field: value1, second_field: value2, ...)

          {:ok, _updated_struct} =
            #{unquote(short_module)}.ensure_type(%{struct | first_field: new_value})

          {:ok, _updated_struct} =
            struct
            |> Map.put(:first_field, new_value1)
            |> Map.put(:second_field, new_value2)
            |> #{unquote(short_module)}.ensure_type()
      """
      def ensure_type(struct, opts \\ []) do
        %name{} = struct

        unless name == __MODULE__ do
          Raises.raise_struct_should_be_passed(__MODULE__, instead_of: name)
        end

        skip_ensurance? =
          if TypeEnsurerFactory.compile_time?() do
            Domo._plan_struct_integrity_ensurance(__MODULE__, Map.from_struct(struct))
            true
          else
            false
          end

        if skip_ensurance? do
          {:ok, struct}
        else
          Raises.maybe_raise_add_domo_compiler(__MODULE__)
          Domo._validate_fields_ok(unquote(type_ensurer), struct, opts)
        end
      end

      @doc unquote(@typed_fields_doc)
      def typed_fields(opts \\ []) do
        field_kind =
          cond do
            opts[:include_any_typed] && opts[:include_meta] -> :typed_with_meta_with_any
            opts[:include_meta] -> :typed_with_meta_no_any
            opts[:include_any_typed] -> :typed_no_meta_with_any
            true -> :typed_no_meta_no_any
          end

        apply(unquote(type_ensurer), :fields, [field_kind])
      end

      @doc unquote(@required_fields_doc)
      def required_fields(opts \\ []) do
        field_kind = if opts[:include_meta], do: :required_with_meta, else: :required_no_meta
        apply(unquote(type_ensurer), :fields, [field_kind])
      end

      @before_compile {Raises, :raise_not_in_a_struct_module!}
      @before_compile {Raises, :raise_no_type_t_defined!}
      @before_compile {Domo, :_plan_struct_defaults_ensurance}

      @after_compile {Domo, :_collect_types_for_domo_compiler}
    end
  end

  defp start_resolve_planner do
    plan_path = get_plan_path()
    preconds_path = get_precond_path()

    {:ok, _pid} = TypeEnsurerFactory.start_resolve_planner(plan_path, preconds_path)

    plan_path
  end

  defp get_plan_path do
    project = MixProjectHelper.global_stub() || Mix.Project
    DomoMixTask.manifest_path(project, :plan)
  end

  defp get_precond_path do
    project = MixProjectHelper.global_stub() || Mix.Project
    DomoMixTask.manifest_path(project, :preconds)
  end

  @doc false
  def _plan_struct_defaults_ensurance(env) do
    plan_path = get_plan_path()
    TypeEnsurerFactory.plan_struct_defaults_ensurance(plan_path, env)
  end

  @doc false
  def _collect_types_for_domo_compiler(env, bytecode) do
    plan_path = get_plan_path()
    TypeEnsurerFactory.collect_types_for_domo_compiler(plan_path, env, bytecode)
  end

  @doc false
  def _plan_struct_integrity_ensurance(module, enumerable) do
    plan_path = get_plan_path()
    TypeEnsurerFactory.plan_struct_integrity_ensurance(plan_path, module, enumerable)
  end

  @doc false
  def _validate_fields_ok(type_ensurer, struct, opts) do
    {errors, t_precondition_error} = Domo._do_validate_fields(type_ensurer, struct, :pretty_error_by_key, opts)

    cond do
      not Enum.empty?(errors) -> {:error, errors}
      not is_nil(t_precondition_error) -> {:error, [t_precondition_error]}
      true -> {:ok, struct}
    end
  end

  def _do_validate_fields(type_ensurer, struct, err_fun, opts \\ []) do
    maybe_filter_precond_errors = Keyword.get(opts, :maybe_filter_precond_errors, false)
    typed_no_any_fields = apply(type_ensurer, :fields, [:typed_with_meta_no_any])

    errors =
      Enum.reduce(typed_no_any_fields, [], fn field, errors ->
        field_value = {field, Map.get(struct, field)}

        case apply(type_ensurer, :ensure_field_type, [field_value]) do
          {:error, _} = error ->
            [apply(ErrorBuilder, err_fun, [error, maybe_filter_precond_errors]) | errors]

          _ ->
            errors
        end
      end)

    t_precondition_error =
      if Enum.empty?(errors) do
        case apply(type_ensurer, :t_precondition, [struct]) do
          {:error, _} = error -> apply(ErrorBuilder, err_fun, [error, maybe_filter_precond_errors])
          :ok -> nil
        end
      end

    {errors, t_precondition_error}
  end

  @doc """
  Defines a precondition function for a field's type or the struct's type.

  The `type_fun` argument is one element `[type: fun]` keyword list where
  `type` is the name of the type defined with the `@type` attribute
  and `fun` is a single argument user-defined precondition function.

  The precondition function validates the value of the given type to match
  a specific format or to fulfil a set of invariants for the field's type
  or struct's type respectfully.

  The macro should be called with a type in the same module where the `@type`
  definition is located. If that is no fulfilled, f.e., when the previously
  defined type has been renamed, the macro raises an `ArgumentError`.

      defstruct [id: "I-000", amount: 0, limit: 15]

      @type id :: String.t()
      precond id: &validate_id/1

      defp validate_id(id), do: match?(<<"I-", _::8*3>>, id)

      @type t :: %__MODULE__{id: id(), amount: integer(), limit: integer()}
      precond t: &validate_invariants/1

      defp validate_invariants(s) do
        cond do
          s.amount >= s.limit ->
            {:error, "Amount \#{s.amount} should be less then limit \#{s.limit}."}

          true ->
            :ok
        end
      end

  `TypeEnsurer` module generated by Domo calls the precondition function with
  value of the valid type. Precondition function should return the following
  values: `true | false | :ok | {:error, any()}`.

  In case of `true` or `:ok` return values `TypeEnsurer` finishes
  the validation of the field with ok.
  For the `false` return value, the `TypeEnsurer` generates an error message
  referencing the failed precondition function. And for the `{:error, message}`
  return value, it passes the `message` as one of the errors for the field value.
  `message` can be of any shape.

  Macro adds the `__precond__/2` function to the current module that routes
  a call to the user-defined function. The added function should be called
  only by Domo modules.

  Attaching a precondition function to the type via this macro can be helpful
  to keep the same level of consistency across the domains modelled
  with structs sharing the given type.
  """
  defmacro precond([{type_name, {fn?, _, _} = fun}] = _type_fun)
           when is_atom(type_name) and fn? in [:&, :fn] do
    module = __CALLER__.module

    unless Module.has_attribute?(module, :domo_precond) do
      Module.register_attribute(module, :domo_precond, accumulate: true)
      Module.put_attribute(module, :after_compile, {Domo, :_plan_precond_checks})
    end

    fun_as_string = Macro.to_string(fun)
    precond_name_description = {type_name, fun_as_string}
    Module.put_attribute(module, :domo_precond, precond_name_description)

    quote do
      def __precond__(unquote(type_name), value) do
        apply(unquote(fun), [value])
      end
    end
  end

  defmacro precond(_arg) do
    Raises.raise_precond_arguments()
  end

  @doc false
  def _plan_precond_checks(env, bytecode) do
    # precond macro can be called via import Domo, so need to start resolve planner
    plan_path = start_resolve_planner()
    TypeEnsurerFactory.plan_precond_checks(plan_path, env, bytecode)
  end

  @doc """
  Checks whether the `TypeEnsurer` module exists for the given struct module.

  Structs having `TypeEnsurer` can be validated with `Domo` generated callbacks.
  """
  defdelegate has_type_ensurer?(struct_module), to: TypeEnsurerFactory
end
