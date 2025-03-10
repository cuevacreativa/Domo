defmodule Domo.TypeEnsurerFactory.Resolver.RemoteTest do
  use Domo.FileCase

  alias Domo.TypeEnsurerFactory.Error
  alias Domo.TypeEnsurerFactory.Resolver

  import ResolverTestHelper

  setup [:setup_project_planner]

  describe "TypeEnsurerFactory.Resolver should" do
    test "treat remote types to any() according to global setting joined with one for given module", %{
      plan_file: plan_file,
      preconds_file: preconds_file,
      types_file: types_file,
      deps_file: deps_file
    } do
      plan(plan_file, RemoteUserType, :field1, quote(do: Module.t()))
      plan(plan_file, RemoteUserType, :field2, quote(do: LocalUserType.int()))
      plan(plan_file, RemoteUserType, :field3, quote(do: local_int()))
      plan(plan_file, RemoteUserType, :field4, quote(do: Module1.name()))
      plan(plan_file, RemoteUserType, :field5, quote(do: Module1.field()))

      keep_env(plan_file, RemoteUserType, RemoteUserType.env())

      keep_global_remote_types_to_treat_as_any(plan_file, %{Module => [:t], RemoteUserType => [:local_int]})
      keep_remote_types_to_treat_as_any(plan_file, RemoteUserType, %{Module1 => [:field, :name]})

      flush(plan_file)

      :ok = Resolver.resolve(plan_file, preconds_file, types_file, deps_file, false)

      expected =
        add_empty_precond_to_spec(%{
          field1: [quote(do: any())],
          field2: [quote(do: integer())],
          field3: [quote(do: any())],
          field4: [quote(do: any())],
          field5: [quote(do: any())]
        })

      assert %{RemoteUserType => expected} == read_types(types_file)
    end

    test "resolve String.t() to <<_::_*8>>", %{
      planner: planner,
      plan_file: plan_file,
      preconds_file: preconds_file,
      types_file: types_file,
      deps_file: deps_file
    } do
      plan_types([quote(context: TwoFieldStruct, do: String.t())], planner)

      :ok = Resolver.resolve(plan_file, preconds_file, types_file, deps_file, false)

      expected = map_idx_list([quote(context: String, do: <<_::_*8>>)])
      assert %{TwoFieldStruct => expected} == read_types(types_file)
    end

    test "resolve user remote type to primitive type", %{
      planner: planner,
      plan_file: plan_file,
      preconds_file: preconds_file,
      types_file: types_file,
      deps_file: deps_file
    } do
      plan(
        planner,
        RemoteUserType,
        :field,
        {{:., [], [{:__aliases__, [], [:Submodule]}, :t]}, [], []}
      )

      keep_env(planner, RemoteUserType, RemoteUserType.env())
      flush(planner)

      :ok = Resolver.resolve(plan_file, preconds_file, types_file, deps_file, false)

      expected =
        add_empty_precond_to_spec(%{
          field: [quote(context: RemoteUserType, do: atom())]
        })

      assert %{RemoteUserType => expected} == read_types(types_file)
    end

    test "resolve several user types each referring next one in context of a remote module to the primitive type",
         %{
           planner: planner,
           plan_file: plan_file,
           preconds_file: preconds_file,
           types_file: types_file,
           deps_file: deps_file
         } do
      plan(
        planner,
        RemoteUserType,
        :field,
        {{:., [], [{:__aliases__, [], [:Submodule]}, :sub_float]}, [], []}
      )

      keep_env(planner, RemoteUserType, RemoteUserType.env())
      flush(planner)

      :ok = Resolver.resolve(plan_file, preconds_file, types_file, deps_file, false)

      expected =
        add_empty_precond_to_spec(%{
          field: [quote(context: RemoteUserType, do: float())]
        })

      assert %{RemoteUserType => expected} == read_types(types_file)
    end

    test "resolve remote user type that has or | to list of primitive types", %{
      planner: planner,
      plan_file: plan_file,
      preconds_file: preconds_file,
      types_file: types_file,
      deps_file: deps_file
    } do
      plan(
        planner,
        RemoteUserType,
        :field,
        {{:., [], [{:__aliases__, [], [:ModuleNested]}, :various_type]}, [], []}
      )

      keep_env(planner, RemoteUserType, RemoteUserType.env())
      flush(planner)

      :ok = Resolver.resolve(plan_file, preconds_file, types_file, deps_file, false)

      expected =
        add_empty_precond_to_spec(%{
          field: [
            quote(context: RemoteUserType, do: atom()),
            quote(context: RemoteUserType, do: integer()),
            quote(context: RemoteUserType, do: float()),
            quote(context: RemoteUserType, do: [any()])
          ]
        })

      assert %{RemoteUserType => expected} == read_types(types_file)
    end

    test "return error type_not_found for nonexistent type", %{
      planner: planner,
      plan_file: plan_file,
      preconds_file: preconds_file,
      types_file: types_file,
      deps_file: deps_file
    } do
      plan(
        planner,
        RemoteUserType,
        :field,
        quote(context: RemoteUserType, do: RemoteUserType.nonexistent_type())
      )

      keep_env(planner, RemoteUserType, RemoteUserType.env())
      flush(planner)

      module_file = RemoteUserType.env().file

      assert {:error,
              [
                %Error{
                  compiler_module: Resolver,
                  file: ^module_file,
                  struct_module: RemoteUserType,
                  message: {:type_not_found, {RemoteUserType, :nonexistent_type, "RemoteUserType.nonexistent_type()"}}
                }
              ]} = Resolver.resolve(plan_file, preconds_file, types_file, deps_file, false)
    end

    test "return error no_beam_file for nonexistent type", %{
      planner: planner,
      plan_file: plan_file,
      preconds_file: preconds_file,
      types_file: types_file,
      deps_file: deps_file
    } do
      plan(
        planner,
        NonexistingModule,
        :field,
        quote(context: NonexistingModule, do: NonexistingModule.a_type())
      )

      keep_env(planner, NonexistingModule, __ENV__)
      flush(planner)

      module_file = __ENV__.file

      assert {:error,
              [
                %Error{
                  compiler_module: Resolver,
                  file: ^module_file,
                  struct_module: NonexistingModule,
                  message: {:no_beam_file, NonexistingModule}
                }
              ]} = Resolver.resolve(plan_file, preconds_file, types_file, deps_file, false)
    end

    test "return several errors in one list", %{
      planner: planner,
      plan_file: plan_file,
      preconds_file: preconds_file,
      types_file: types_file,
      deps_file: deps_file
    } do
      plan(
        planner,
        RemoteUserType,
        :field,
        quote(context: RemoteUserType, do: RemoteUserType.nonexistent_type())
      )

      keep_env(planner, RemoteUserType, RemoteUserType.env())

      plan(
        planner,
        NonexistingModule,
        :field,
        quote(context: NonexistingModule, do: NonexistingModule.a_type())
      )

      keep_env(planner, NonexistingModule, __ENV__)

      flush(planner)

      remote_user_type_file = RemoteUserType.env().file
      nonexisting_module_file = __ENV__.file

      assert {:error,
              [
                %Error{
                  compiler_module: Resolver,
                  file: ^remote_user_type_file,
                  struct_module: RemoteUserType,
                  message: {:type_not_found, {RemoteUserType, :nonexistent_type, "RemoteUserType.nonexistent_type()"}}
                },
                %Error{
                  compiler_module: Resolver,
                  file: ^nonexisting_module_file,
                  struct_module: NonexistingModule,
                  message: {:no_beam_file, NonexistingModule}
                }
              ]} = Resolver.resolve(plan_file, preconds_file, types_file, deps_file, false)
    end
  end
end
