defmodule Domo.TypeEnsurerFactory.ResolvePlannerTest do
  use Domo.FileCase

  alias Mix.Tasks.Compile.DomoCompiler, as: DomoMixTask
  alias Domo.MixProjectHelper
  alias Domo.TypeEnsurerFactory.ResolvePlanner

  describe "ResolvePlanner for sake of start should" do
    test "be started once for a plan file" do
      plan_path = DomoMixTask.manifest_path(MixProjectStubCorrect, :plan)
      preconds_path = DomoMixTask.manifest_path(MixProjectStubCorrect, :preconds)

      {:ok, pid} = ResolvePlanner.start(plan_path, preconds_path)

      on_exit(fn ->
        GenServer.stop(pid)
      end)

      assert {:error, {:already_started, pid}} == ResolvePlanner.start(plan_path, preconds_path)

      name = ResolvePlanner.via(plan_path)
      assert pid == GenServer.whereis(name)
    end

    test "return same {:ok, pid} answer if already started" do
      plan_path = DomoMixTask.manifest_path(MixProjectStubCorrect, :plan)
      preconds_path = DomoMixTask.manifest_path(MixProjectStubCorrect, :preconds)
      {:ok, pid} = ResolvePlanner.ensure_started(plan_path, preconds_path)

      on_exit(fn ->
        GenServer.stop(pid)
      end)

      assert {:error, {:already_started, pid}} == ResolvePlanner.start(plan_path, preconds_path)

      assert {:ok, pid} == ResolvePlanner.ensure_started(plan_path, preconds_path)
    end
  end

  test "ResolvePlanner should return that its compile when it is running" do
    # stop global server that may run due to compilation of structs
    project = MixProjectHelper.global_stub()
    plan_path = DomoMixTask.manifest_path(project, :plan)
    preconds_path = DomoMixTask.manifest_path(MixProjectStubCorrect, :preconds)
    ResolvePlanner.stop(plan_path)

    assert ResolvePlanner.compile_time?() == false

    plan_path = "some_path_1"
    {:ok, _pid} = ResolvePlanner.start(plan_path, preconds_path)

    assert ResolvePlanner.compile_time?() == true

    ResolvePlanner.stop(plan_path)

    assert ResolvePlanner.compile_time?() == false
  end

  describe "ResolvePlanner for sake of planning should" do
    @describetag start_server: true

    setup tags do
      plan_path = DomoMixTask.manifest_path(MixProjectStubCorrect, :plan)
      preconds_path = DomoMixTask.manifest_path(MixProjectStubCorrect, :preconds)

      if tags.start_server do
        {:ok, pid} = ResolvePlanner.start(plan_path, preconds_path)

        on_exit(fn ->
          GenServer.stop(pid)
        end)
      end

      %{plan_path: plan_path, preconds_path: preconds_path}
    end

    test "accept struct field's type for the resolve plan", %{plan_path: plan_path} do
      assert :ok ==
               ResolvePlanner.plan_types_resolving(
                 plan_path,
                 TwoFieldStruct,
                 :first,
                 quote(do: integer)
               )
    end

    test "accept empty struct for the resolve plan", %{plan_path: plan_path} do
      assert :ok == ResolvePlanner.plan_empty_struct(plan_path, TwoFieldStruct)
    end

    test "accept struct module's environment for further remote types resolve", %{
      plan_path: plan_path
    } do
      assert :ok == ResolvePlanner.keep_module_environment(plan_path, TwoFieldStruct, __ENV__)
    end

    test "accept type names and module having precond functions handling the names", %{
      plan_path: plan_path
    } do
      assert :ok ==
               ResolvePlanner.plan_precond_checks(
                 plan_path,
                 TwoFieldStruct,
                 title: "func_body",
                 duration: "func_body"
               )
    end

    test "accept struct fields for postponed integrity ensurance", %{plan_path: plan_path} do
      assert :ok ==
               ResolvePlanner.plan_struct_integrity_ensurance(
                 plan_path,
                 TwoFieldStruct,
                 [title: "Hello", duration: 15],
                 "/module_path.ex",
                 9
               )
    end

    test "accept struct defaults for postponed ensurance", %{plan_path: plan_path} do
      assert :ok ==
               ResolvePlanner.plan_struct_defaults_ensurance(
                 plan_path,
                 TwoFieldStruct,
                 [title: "Hello"],
                 "/module_path.ex",
                 2
               )
    end

    test "accept types to treat as any", %{plan_path: plan_path} do
      assert :ok ==
               ResolvePlanner.keep_global_remote_types_to_treat_as_any(
                 plan_path,
                 %{Module => [:t]}
               )

      assert :ok ==
               ResolvePlanner.keep_remote_types_to_treat_as_any(
                 plan_path,
                 TwoFieldStruct,
                 %{Module => [:name], Module1 => [:type1, :type2]}
               )
    end

    test "be able to flush all planned types to disk", %{plan_path: plan_path} do
      ResolvePlanner.plan_types_resolving(
        plan_path,
        TwoFieldStruct,
        :first,
        quote(do: integer)
      )

      ResolvePlanner.plan_types_resolving(
        plan_path,
        TwoFieldStruct,
        :second,
        quote(do: float)
      )

      ResolvePlanner.plan_types_resolving(
        plan_path,
        IncorrectDefault,
        :second,
        quote(do: Generator.a_str())
      )

      ResolvePlanner.plan_empty_struct(
        plan_path,
        EmptyStruct
      )

      env = __ENV__
      ResolvePlanner.keep_module_environment(plan_path, TwoFieldStruct, env)

      ResolvePlanner.plan_struct_integrity_ensurance(
        plan_path,
        TwoFieldStruct,
        [title: "Hello", duration: 15],
        "/module_path.ex",
        9
      )

      ResolvePlanner.plan_struct_defaults_ensurance(
        plan_path,
        TwoFieldStruct,
        [title: "Hello"],
        "/module_path.ex",
        2
      )

      ResolvePlanner.keep_global_remote_types_to_treat_as_any(
        plan_path,
        %{Module => [:t]}
      )

      ResolvePlanner.keep_global_remote_types_to_treat_as_any(
        plan_path,
        %{Module => [:title]}
      )

      ResolvePlanner.keep_remote_types_to_treat_as_any(
        plan_path,
        TwoFieldStruct,
        %{Module => [:name], Module1 => [:type1, :type2]}
      )

      ResolvePlanner.keep_remote_types_to_treat_as_any(
        plan_path,
        IncorrectDefault,
        %{Module2 => [:name]}
      )

      assert :ok == ResolvePlanner.flush(plan_path)

      plan =
        plan_path
        |> File.read!()
        |> :erlang.binary_to_term()

      assert %{
               filed_types_to_resolve: %{
                 TwoFieldStruct => %{first: quote(do: integer), second: quote(do: float)},
                 IncorrectDefault => %{second: quote(do: Generator.a_str())},
                 EmptyStruct => %{}
               },
               environments: %{TwoFieldStruct => env},
               structs_to_ensure: [
                 {TwoFieldStruct, [title: "Hello", duration: 15], "/module_path.ex", 9}
               ],
               struct_defaults_to_ensure: [
                 {TwoFieldStruct, [title: "Hello"], "/module_path.ex", 2}
               ],
               remote_types_as_any_by_module: %{
                 :global => %{Module => [:title]},
                 TwoFieldStruct => %{Module => [:name], Module1 => [:type1, :type2]},
                 IncorrectDefault => %{Module2 => [:name]}
               }
             } == plan
    end

    test "be able to flush all planned precond checks to disk", %{plan_path: plan_path, preconds_path: preconds_path} do
      ResolvePlanner.plan_precond_checks(
        plan_path,
        TwoFieldStruct,
        title: "&String.length(&1) < 256",
        duration: "fn val -> 5 < val and val < 15 end"
      )

      assert :ok == ResolvePlanner.flush(plan_path)

      preconds =
        preconds_path
        |> File.read!()
        |> :erlang.binary_to_term()

      assert %{
               TwoFieldStruct => [
                 title: "&String.length(&1) < 256",
                 duration: "fn val -> 5 < val and val < 15 end"
               ]
             } == preconds
    end

    test "overwrite existing struct field's type in plan (f.e. on fixing errors in type definitions and recompilation)", %{plan_path: plan_path} do
      ResolvePlanner.plan_types_resolving(
        plan_path,
        TwoFieldStruct,
        :first,
        quote(do: integer)
      )

      atom_type = quote(do: atom)

      ResolvePlanner.plan_types_resolving(
        plan_path,
        TwoFieldStruct,
        :first,
        atom_type
      )

      assert :ok == ResolvePlanner.flush(plan_path)

      plan =
        plan_path
        |> File.read!()
        |> :erlang.binary_to_term()

      expected_field_types = %{TwoFieldStruct => %{first: atom_type}}
      assert %{filed_types_to_resolve: ^expected_field_types} = plan
    end

    @tag start_server: false
    test "be able to merge made plan with the plan from disk", %{plan_path: plan_path, preconds_path: preconds_path} do
      incorrect_default_env = %{__ENV__ | module: IncorrectDefault}

      plan_binary =
        :erlang.term_to_binary(%{
          filed_types_to_resolve: %{IncorrectDefault => %{second: quote(do: Generator.a_str())}},
          environments: %{IncorrectDefault => incorrect_default_env},
          structs_to_ensure: [
            {TwoFieldStruct, [title: "Hello", duration: 15], "/module_path.ex", 9}
          ],
          struct_defaults_to_ensure: [
            {TwoFieldStruct, [title: "Hello"], "/module_path.ex", 2},
            {Module, [field: 1], "/module_path.ex", 2}
          ],
          remote_types_as_any_by_module: %{
            :global => %{Module => [:t]},
            TwoFieldStruct => %{Module => [:number]}
          }
        })

      File.write!(plan_path, plan_binary)

      {:ok, pid} = ResolvePlanner.start(plan_path, preconds_path)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      ResolvePlanner.plan_types_resolving(
        plan_path,
        TwoFieldStruct,
        :first,
        quote(do: integer)
      )

      env = __ENV__
      ResolvePlanner.keep_module_environment(plan_path, TwoFieldStruct, env)

      ResolvePlanner.plan_struct_integrity_ensurance(
        plan_path,
        TwoFieldStruct,
        [title: "World", duration: 20],
        "/other_module_path.ex",
        12
      )

      ResolvePlanner.plan_struct_defaults_ensurance(
        plan_path,
        TwoFieldStruct,
        [title: "World"],
        "/other_module_path.ex",
        3
      )

      ResolvePlanner.plan_struct_defaults_ensurance(
        plan_path,
        Module1,
        [id: 5],
        "/module_path1.ex",
        2
      )

      ResolvePlanner.keep_global_remote_types_to_treat_as_any(
        plan_path,
        %{Module => [:title]}
      )

      ResolvePlanner.keep_remote_types_to_treat_as_any(
        plan_path,
        TwoFieldStruct,
        %{Module => [:name], Module1 => [:type1, :type2]}
      )

      assert :ok == ResolvePlanner.flush(plan_path)

      plan =
        plan_path
        |> File.read!()
        |> :erlang.binary_to_term()

      assert %{
               filed_types_to_resolve: %{
                 TwoFieldStruct => %{first: quote(do: integer)},
                 IncorrectDefault => %{second: quote(do: Generator.a_str())}
               },
               environments: %{
                 TwoFieldStruct => env,
                 IncorrectDefault => incorrect_default_env
               },
               structs_to_ensure: [
                 {TwoFieldStruct, [title: "Hello", duration: 15], "/module_path.ex", 9},
                 {TwoFieldStruct, [title: "World", duration: 20], "/other_module_path.ex", 12}
               ],
               struct_defaults_to_ensure: [
                 {TwoFieldStruct, [title: "World"], "/other_module_path.ex", 3},
                 {Module, [field: 1], "/module_path.ex", 2},
                 {Module1, [id: 5], "/module_path1.ex", 2}
               ],
               remote_types_as_any_by_module: %{
                 :global => %{Module => [:title]},
                 TwoFieldStruct => %{Module => [:name, :number], Module1 => [:type1, :type2]}
               }
             } == plan
    end

    @tag start_server: false
    test "be able to merge preconds with the preconds from disk", %{plan_path: plan_path, preconds_path: preconds_path} do
      preconds_binary = :erlang.term_to_binary(%{IncorrectDefault => [field: "&byze_site(&1) == 150"]})

      File.write!(preconds_path, preconds_binary)

      {:ok, pid} = ResolvePlanner.start(plan_path, preconds_path)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      ResolvePlanner.plan_precond_checks(
        plan_path,
        TwoFieldStruct,
        title: "&String.length(&1) < 256",
        duration: "fn val -> 5 < val and val < 15 end"
      )

      assert :ok == ResolvePlanner.flush(plan_path)

      preconds =
        preconds_path
        |> File.read!()
        |> :erlang.binary_to_term()

      assert %{
               IncorrectDefault => [field: "&byze_site(&1) == 150"],
               TwoFieldStruct => [
                 title: "&String.length(&1) < 256",
                 duration: "fn val -> 5 < val and val < 15 end"
               ]
             } == preconds
    end
  end

  describe "ResolvePlanner for sake of stop should" do
    setup do
      plan_path = DomoMixTask.manifest_path(MixProjectStubCorrect, :plan)
      preconds_path = DomoMixTask.manifest_path(MixProjectStubCorrect, :preconds)
      {:ok, plan_path: plan_path, preconds_path: preconds_path}
    end

    test "flush the plan and stop", %{plan_path: plan_path, preconds_path: preconds_path} do
      {:ok, pid} = ResolvePlanner.start(plan_path, preconds_path)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert :ok = ResolvePlanner.ensure_flushed_and_stopped(plan_path)

      refute Process.alive?(pid)
      assert File.exists?(plan_path)
    end

    test "Not flush and stop if already stopped", %{plan_path: plan_path} do
      assert :ok == ResolvePlanner.ensure_flushed_and_stopped(plan_path)
    end

    test "stop without flush", %{plan_path: plan_path, preconds_path: preconds_path} do
      {:ok, pid} = ResolvePlanner.start(plan_path, preconds_path)

      on_exit(fn ->
        if Process.alive?(pid), do: GenServer.stop(pid)
      end)

      assert :ok == ResolvePlanner.stop(plan_path)
      refute Process.alive?(pid)
    end

    test "Not stop if already stopped", %{plan_path: plan_path} do
      assert :ok == ResolvePlanner.stop(plan_path)
    end
  end
end
