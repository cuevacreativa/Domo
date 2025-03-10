defmodule Domo.TypeEnsurerFactory.GeneratorTypeEnsurerModuleStructFieldTest do
  use Domo.FileCase, async: false
  use Placebo

  import GeneratorTestHelper

  alias Domo.TypeEnsurerFactory.Precondition

  setup do
    on_exit(fn ->
      :code.purge(TypeEnsurer)
      :code.delete(TypeEnsurer)
    end)

    :ok
  end

  def call_ensure_type({_field, _value} = subject) do
    apply(TypeEnsurer, :ensure_field_type, [subject])
  end

  # There is a compilation error for referenced structs not using Domo at resolver phase

  describe "TypeEnsurer module for field having type of struct that use Domo" do
    test "ensures field's value by delegating to the struct's TypeEnsurer" do
      load_type_ensurer_module_with_no_preconds(%{
        first: [
          quote(do: %CustomStructUsingDomo{}),
          quote(do: %CustomStructUsingDomo{title: nil})
        ]
      })

      allow Domo._validate_fields_ok(any(), any(), any()), meck_options: [:passthrough], exec: fn _, struct, _ -> {:ok, struct} end

      instance = %CustomStructUsingDomo{title: :one}
      call_ensure_type({:first, instance})

      assert_called Domo._validate_fields_ok(CustomStructUsingDomo.TypeEnsurer, instance, [])
    end

    test "ensures field's value by delegating to struct's TypeEnsurer and using precondition" do
      struct_precondition = Precondition.new(module: UserTypes, type_name: :capital_title, description: "capital_title_func")

      load_type_ensurer_module(
        {%{
           first: [
             {
               quote(context: String, do: %CustomStructWithEnsureOk{title: {<<_::_*8>>, nil}}),
               struct_precondition
             }
           ]
         }, nil}
      )

      assert :ok == call_ensure_type({:first, %CustomStructWithEnsureOk{title: "Hello"}})
      assert {:error, _} = call_ensure_type({:first, %CustomStructWithEnsureOk{title: "hello"}})
    end
  end
end
