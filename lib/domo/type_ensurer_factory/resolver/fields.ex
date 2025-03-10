defmodule Domo.TypeEnsurerFactory.Resolver.Fields do
  @moduledoc false

  alias Domo.TypeEnsurerFactory.Precondition
  alias Domo.TypeEnsurerFactory.Alias
  alias Domo.TypeEnsurerFactory.Resolver.Fields.Arguments
  alias Domo.TypeEnsurerFactory.ModuleInspector

  @max_arg_combinations_count 4096

  def resolve(mfe, preconds, remote_types_as_any, resolvable_structs) do
    {module, fields, env} = mfe

    {field_types, field_errors, all_deps} =
      Enum.reduce(fields, {%{}, [], []}, fn {field_name, quoted_type}, {field_types, field_errors, all_deps} ->
        env_preconds_anys_resolvables = {env, preconds, remote_types_as_any, resolvable_structs}
        {types, errors, deps} = resolve_type(quoted_type, module, nil, env_preconds_anys_resolvables, {[], [], []})

        types =
          types
          |> Enum.reverse()
          |> Enum.uniq()

        updated_field_types = Map.put(field_types, field_name, types)

        {updated_field_types, errors ++ field_errors, all_deps ++ deps}
      end)

    struct_precondition = get_precondition(preconds, module, :t)

    {module, {field_types, struct_precondition}, field_errors, all_deps}
  end

  def preconditions_hash(types_precond_description) do
    types_precond_description |> :erlang.term_to_binary() |> :erlang.md5()
  end

  defp get_precondition(preconds, module, type_name) do
    preconds
    |> Map.get(module, [])
    |> Enum.find(&match?({^type_name, _description}, &1))
    |> cast_to_precondition(module)
  end

  defp cast_to_precondition(nil, _module) do
    nil
  end

  defp cast_to_precondition({type, description}, module) do
    Precondition.new(module: module, type_name: type, description: description)
  end

  # Literals

  @type types_errs_deps :: {[Macro.t()], [{:error, any()}], [module]}

  defp resolve_type({:|, _meta, [arg1, arg2]} = type, module, precond, env_preconds_anys_resolvables, {types, errs, deps} = acc) do
    if is_nil(precond) do
      resolve_type(
        arg2,
        module,
        precond,
        env_preconds_anys_resolvables,
        resolve_type(arg1, module, nil, env_preconds_anys_resolvables, acc)
      )
    else
      type_string = Macro.to_string(type)

      error =
        {:error,
         """
         Precondition for value of | or type is not allowed. You can extract each element \
         of #{type_string} type to @type definitions and set precond for each of it.\
         """}

      {types, [error | errs], deps}
    end
  end

  defp resolve_type([{:..., _meta, _arg}], module, precond, _env_preconds, {types, errs, deps}) do
    joint_type = {quote(context: module, do: nonempty_list(any())), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type([type, {:..., _meta2, _arg2}], module, precond, env_preconds_anys_resolvables, acc) do
    combine_or_args(
      [type],
      module,
      env_preconds_anys_resolvables,
      & &1,
      fn [type] -> {quote(context: module, do: nonempty_list(unquote(type))), precond} end,
      acc
    )
  end

  # Remote Types

  defp resolve_type({{:., _, [rem_module, rem_type]}, _, _}, _module, precond, env_preconds_anys_resolvables, {types, errs, deps}) do
    {env, preconds_map, remote_types_as_any, _resolvables} = env_preconds_anys_resolvables

    rem_module_alias =
      if is_atom(rem_module) and not Alias.erlang_module_atom?(rem_module) do
        {:__aliases__, [], [Alias.atom_drop_elixir_prefix(rem_module)]}
      else
        rem_module
      end

    rem_module = Macro.expand_once(rem_module_alias, env)

    cond do
      Enum.member?(remote_types_as_any[rem_module] || [], rem_type) ->
        joint_type = {:any, [], []}
        {[joint_type | types], errs, deps}

      rem_module == MapSet ->
        joint_type = {
          quote(context: MapSet, do: %MapSet{}),
          precond
        }

        {[joint_type | types], errs, deps}

      true ->
        rem_type_precond = get_precondition(preconds_map, rem_module, rem_type)

        with {:ok, type_list} <- ModuleInspector.beam_types(rem_module),
             {:ok, type, dereferenced_types} <- ModuleInspector.find_type_quoted(rem_type, type_list),
             dereferenced_preconds = Enum.map(dereferenced_types, &get_precondition(preconds_map, rem_module, &1)),
             {:ok, precond} <- get_valid_precondition([precond, rem_type_precond | dereferenced_preconds]) do
          resolve_type(type, rem_module, precond, env_preconds_anys_resolvables, {types, errs, [rem_module | deps]})
        else
          {:error, {:type_not_found, missing_type}} ->
            err = {:error, {:type_not_found, {rem_module, missing_type, Alias.string_by_concat(rem_module, rem_type) <> "()"}}}
            {types, [err | errs], deps}

          {:error, _} = err ->
            {types, [err | errs], deps}
        end
    end
  end

  # Basic and Built-in Types

  defp resolve_type({:boolean = kind, _meta, _args}, _module, precond, _env_preconds, {types, errs, deps}) do
    if is_nil(precond) do
      {[true, false | types], errs, deps}
    else
      error = {:error, precondition_not_supported_message(kind)}
      {types, [error | errs], deps}
    end
  end

  defp resolve_type({:identifier = kind, _meta, _args}, module, precond, _env_preconds, {types, errs, deps}) do
    if is_nil(precond) do
      joint_types = [
        quote(context: module, do: reference()),
        quote(context: module, do: port()),
        quote(context: module, do: pid())
      ]

      {joint_types ++ types, errs, deps}
    else
      error = {:error, precondition_not_supported_message(kind)}
      {types, [error | errs], deps}
    end
  end

  defp resolve_type({:iodata = kind, _meta, _args}, module, precond, env_preconds_anys_resolvables, {types, errs, deps} = acc) do
    if is_nil(precond) do
      resolve_type(
        quote(context: module, do: binary() | iolist()),
        module,
        nil,
        env_preconds_anys_resolvables,
        acc
      )
    else
      error = {:error, precondition_not_supported_message(kind)}
      {types, [error | errs], deps}
    end
  end

  defp resolve_type({:iolist = kind, _meta, _args}, module, precond, env_preconds_anys_resolvables, {types, errs, deps} = acc) do
    if is_nil(precond) do
      resolve_type(
        quote(context: module, do: maybe_improper_list(byte() | binary(), binary() | [])),
        module,
        nil,
        env_preconds_anys_resolvables,
        acc
      )
    else
      error = {:error, precondition_not_supported_message(kind)}
      {types, [error | errs], deps}
    end
  end

  defp resolve_type({:number, _meta, _args}, module, precond, _env_preconds, {types, errs, deps}) do
    joint_types = [
      {quote(context: module, do: float()), precond},
      {quote(context: module, do: integer()), precond}
    ]

    {joint_types ++ types, errs, deps}
  end

  defp resolve_type({:timeout = kind, _meta, _args}, module, precond, _env_preconds, {types, errs, deps}) do
    if is_nil(precond) do
      type_no_preconds = [
        {quote(context: module, do: non_neg_integer()), nil},
        quote(context: module, do: :infinity)
      ]

      {type_no_preconds ++ types, errs, deps}
    else
      error = {:error, precondition_not_supported_message(kind)}
      {types, [error | errs], deps}
    end
  end

  defp resolve_type({type, _meta, _args}, module, precond, _env_preconds, {types, errs, deps})
       when type in [:arity, :byte] do
    joint_type = {quote(context: module, do: 0..255), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type({:binary, _meta, _args}, module, precond, _env_preconds, {types, errs, deps}) do
    joint_type = {quote(context: module, do: <<_::_*8>>), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type({:bitstring, _meta, _args}, module, precond, _env_preconds, {types, errs, deps}) do
    # credo:disable-for-next-line
    joint_type = {quote(context: module, do: <<_::_*1>>), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type({:char, _meta, _args}, module, precond, _env_preconds, {types, errs, deps}) do
    joint_type = {quote(context: module, do: 0..0x10FFFF), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type({:charlist, _meta, _args}, module, precond, _env_preconds, {types, errs, deps}) do
    joint_type = {quote(context: module, do: [{0..0x10FFFF, nil}]), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type({:nonempty_charlist, _meta, _args}, module, precond, _env_preconds, {types, errs, deps}) do
    joint_type = {quote(context: module, do: nonempty_list({0..0x10FFFF, nil})), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type({type, _meta, _args}, module, precond, _env_preconds, {types, errs, deps})
       when type in [:fun, :function] do
    joint_type = {quote(context: module, do: (... -> any)), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type({:list, _meta, []}, module, precond, _env_preconds, {types, errs, deps}) do
    joint_type = {quote(context: module, do: [any()]), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type({:nonempty_list, _meta, []}, module, precond, _env_preconds, {types, errs, deps}) do
    joint_type = {quote(context: module, do: nonempty_list(any())), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type({maybe_list_kind, _meta, []}, module, precond, _env_preconds, {types, errs, deps})
       when maybe_list_kind in [:maybe_improper_list, :nonempty_maybe_improper_list] do
    joint_type = {quote(context: module, do: unquote(maybe_list_kind)(any(), any())), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type({:mfa, _meta, _args}, module, precond, _env_preconds, {types, errs, deps}) do
    joint_type = {quote(context: module, do: {{module(), nil}, {atom(), nil}, {0..255, nil}}), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type({type, _meta, _args}, module, precond, _env_preconds, {types, errs, deps})
       when type in [:module, :node] do
    joint_type = {quote(context: module, do: atom()), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type({:struct, _meta, _args}, module, precond, _env_preconds, {types, errs, deps}) do
    joint_type = {
      quote(context: module, do: %{:__struct__ => {atom(), nil}, optional({atom(), nil}) => any()}),
      precond
    }

    {[joint_type | types], errs, deps}
  end

  defp resolve_type({type, _meta, _args}, module, precond, _env_preconds, {types, errs, deps})
       when type in [:none, :no_return] do
    if is_nil(precond) do
      quoted_type = quote(context: module, do: {})
      {[quoted_type | types], errs, deps}
    else
      error = {:error, precondition_not_supported_message(type)}
      {types, [error | errs], deps}
    end
  end

  # Parametrized literals, basic, and built-in types

  defp resolve_type({:keyword, _meta, []}, module, precond, _env_preconds, {types, errs, deps}) do
    joint_type = {quote(context: module, do: [{atom(), any()}]), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type({:keyword, _meta, [type]}, module, precond, env_preconds_anys_resolvables, {types, errs, deps} = acc) do
    if is_nil(precond) do
      combine_or_args(
        [type],
        module,
        env_preconds_anys_resolvables,
        & &1,
        fn [type] -> {quote(context: module, do: [{atom(), unquote(type)}]), nil} end,
        acc
      )
    else
      error =
        {:error,
         """
         Precondition for value of keyword(t) type is not allowed. \
         You can extract t as a user @type and define precondition for it.\
         """}

      {types, [error | errs], deps}
    end
  end

  defp resolve_type({:list, _meta, [arg]}, module, precond, env_preconds_anys_resolvables, acc) do
    combine_or_args(
      [arg],
      module,
      env_preconds_anys_resolvables,
      & &1,
      &{quote(context: module, do: unquote(&1)), precond},
      acc
    )
  end

  defp resolve_type({:nonempty_list, _meta, [arg]}, module, precond, env_preconds_anys_resolvables, acc) do
    combine_or_args(
      [arg],
      module,
      env_preconds_anys_resolvables,
      & &1,
      fn [arg] -> {quote(context: module, do: nonempty_list(unquote(arg))), precond} end,
      acc
    )
  end

  defp resolve_type({:as_boolean, _meta, [type]}, module, precond, env_preconds_anys_resolvables, {types, errs, deps} = acc) do
    if is_nil(precond) do
      combine_or_args(
        [type],
        module,
        env_preconds_anys_resolvables,
        & &1,
        fn [type] -> quote(context: module, do: unquote(type)) end,
        acc
      )
    else
      error =
        {:error,
         """
         Precondition for value of as_boolean(t) type is not allowed. \
         You can extract t as a user @type and define precondition for it.\
         """}

      {types, [error | errs], deps}
    end
  end

  defp resolve_type([{:->, _meta, [[], _]}] = type, _module, precond, _env_preconds, {types, errs, deps}) do
    joint_type = {type, precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type([{:->, _meta, [[{:..., _, _}], _]}] = type, _module, precond, _env_preconds, {types, errs, deps}) do
    joint_type = {type, precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type([{:->, _meta, [[_ | _] = args, _return_type]}], module, precond, env_preconds_anys_resolvables, acc) do
    combine_or_args(
      args,
      module,
      env_preconds_anys_resolvables,
      & &1,
      &{quote(context: module, do: (unquote_splicing(&1) -> any())), precond},
      acc
    )
  end

  defp resolve_type({:%{}, _meta, [{{kind, _km, [key_type]}, value_type}]}, module, precond, env_preconds_anys_resolvables, acc) do
    combine_or_args(
      [key_type, value_type],
      module,
      env_preconds_anys_resolvables,
      & &1,
      fn [key_type, value_type] ->
        {quote(context: module, do: %{unquote(kind)(unquote(key_type)) => unquote(value_type)}), precond}
      end,
      acc
    )
  end

  defp resolve_type({:%{}, _meta, [{{kind, _, [_key]}, _value} | _] = kkv}, module, precond, env_preconds_anys_resolvables, {types, errs, deps})
       when kind in [:required, :optional] do
    {resolved_kv, resolved_errs, resolved_deps} =
      kkv
      |> Enum.map(fn {{_kind, _, [key]}, value} -> {key, value} end)
      |> (&quote(context: module, do: %{unquote_splicing(&1)})).()
      |> resolve_type(module, precond, env_preconds_anys_resolvables, {[], [], []})

    joint_types =
      Enum.map(resolved_kv, fn {{:%{}, _meta, kv_list}, precond} ->
        args =
          for {{key, value}, idx} <- Enum.with_index(kv_list) do
            {{kind, _, [_key]}, _value} = Enum.at(kkv, idx)
            {{kind, [], [key]}, value}
          end

        {quote(context: module, do: %{unquote_splicing(args)}), precond}
      end)

    {joint_types ++ types, resolved_errs ++ errs, deps ++ resolved_deps}
  end

  defp resolve_type({:%{}, _meta, [{_key, _value} | _] = kv_list}, module, precond, env_preconds_anys_resolvables, acc) do
    combine_or_args(
      kv_list,
      module,
      env_preconds_anys_resolvables,
      &drop_kv_precond/1,
      &{quote(context: module, do: %{unquote_splicing(&1)}), precond},
      acc
    )
  end

  defp resolve_type(
         {:%, _meta, [struct_alias, {:%{}, _kvm, [{_key, _value} | _]}]},
         module,
         field_precond,
         env_preconds_anys_resolvables,
         {types, errs, deps}
       ) do
    {_env, preconds, _remote_types_as_any, resovable_structs} = env_preconds_anys_resolvables
    struct_module = Alias.alias_to_atom(struct_alias)
    t_precond = get_precondition(preconds, struct_module, :t)
    precond = t_precond || field_precond

    if ensurable_struct?(struct_module, resovable_structs) do
      joint_type = {
        quote(context: module, do: %unquote(Alias.atom_to_alias(struct_alias)){}),
        precond
      }

      {[joint_type | types], errs, deps}
    else
      struct_module_name = Alias.atom_to_string(struct_module)

      error = """
      Consider to use Domo in #{struct_module_name} struct for validation speed.
      If you don't own the struct you can define custom user type and validate fields \
      in the precondition function attached like the following:

          @type unowned_struct :: term()
          precond unowned_struct: &validate_unowned_struct/1

          def validate_unowned_struct(value) do
            case value do
              %#{struct_module_name}{} -> ...validate fields here...
              _ -> {:error, "expected #{struct_module_name} struct value."}
            end
          end
      """

      {types, [error | errs], deps}
    end
  end

  defp resolve_type([_] = args, module, precond, env_preconds_anys_resolvables, acc) do
    combine_or_args(
      args,
      module,
      env_preconds_anys_resolvables,
      &drop_kv_precond/1,
      &{quote(context: module, do: [unquote_splicing(&1)]), precond},
      acc
    )
  end

  defp resolve_type([_ | _] = list, module, precond, env_preconds_anys_resolvables, {types, errs, deps} = acc) do
    keyword? =
      Enum.all?(list, fn
        {key, _value} -> is_atom(key)
        _ -> false
      end)

    if keyword? do
      combine_or_args(
        list,
        module,
        env_preconds_anys_resolvables,
        &drop_kv_precond/1,
        &{quote(context: module, do: [unquote_splicing(&1)]), precond},
        acc
      )
    else
      {types, [:keyword_list_should_has_atom_keys | errs], deps}
    end
  end

  defp resolve_type({list_kind, _meta, [_elem_type, _tail_type] = el_types}, module, precond, env_preconds_anys_resolvables, acc)
       when list_kind in [
              :maybe_improper_list,
              :nonempty_improper_list,
              :nonempty_maybe_improper_list
            ] do
    combine_or_args(
      el_types,
      module,
      env_preconds_anys_resolvables,
      & &1,
      fn [elem_type, tail_type] ->
        {
          quote(
            context: module,
            do: unquote(list_kind)(unquote(elem_type), unquote(tail_type))
          ),
          precond
        }
      end,
      acc
    )
  end

  defp resolve_type({:{} = kind, _meta, []}, module, precond, _env_preconds, {types, errs, deps}) do
    if is_nil(precond) do
      joint_type = quote(context: module, do: {})
      {[joint_type | types], errs, deps}
    else
      error = {:error, precondition_not_supported_message(to_string(kind))}
      {types, [error | errs], deps}
    end
  end

  defp resolve_type({:{}, _meta, [_ | _] = args}, module, precond, env_preconds_anys_resolvables, acc) do
    combine_or_args(
      args,
      module,
      env_preconds_anys_resolvables,
      & &1,
      &{quote(context: module, do: {unquote_splicing(&1)}), precond},
      acc
    )
  end

  defp resolve_type({arg1, arg2}, module, precond, env_preconds_anys_resolvables, acc) do
    combine_or_args(
      [arg1, arg2],
      module,
      env_preconds_anys_resolvables,
      & &1,
      fn [arg1, arg2] -> {quote(context: module, do: {unquote(arg1), unquote(arg2)}), precond} end,
      acc
    )
  end

  defp resolve_type({kind_any, _meta, args}, _module, precond, _env_preconds, {types, errs, deps})
       when kind_any in [:term, :any] do
    if is_nil(precond) do
      {[{:any, [], args}], errs, deps}
    else
      error = {:error, precondition_not_supported_message(kind_any)}
      {types, [error | errs], deps}
    end
  end

  defp resolve_type(_type, _module, _precond, _env_preconds, {[{:any, _, _}], _errs, _deps} = acc) do
    acc
  end

  defp resolve_type({type_name, _, []} = type, _module, precond, _env_preconds, {types, errs, deps})
       when type_name in [
              :<<>>,
              :%{}
            ] do
    if is_nil(precond) do
      type = drop_line_metadata(type)
      {[type | types], errs, deps}
    else
      error = {:error, precondition_not_supported_message(to_string(type_name))}
      {types, [error | errs], deps}
    end
  end

  defp resolve_type({type_name, _, []} = type, _module, precond, _env_preconds, {types, errs, deps})
       when type_name in [
              :port,
              :pid,
              :reference
            ] do
    if is_nil(precond) do
      type = drop_line_metadata(type)
      {[type | types], errs, deps}
    else
      error = {:error, precondition_not_supported_message(type_name)}
      {types, [error | errs], deps}
    end
  end

  defp resolve_type({:<<>> = type_name, _, [{:"::", _, [_, 0]}]} = type, _module, precond, _env_preconds, {types, errs, deps}) do
    if is_nil(precond) do
      type = drop_line_metadata(type)
      {[type | types], errs, deps}
    else
      error = {:error, precondition_not_supported_message(to_string(type_name))}
      {types, [error | errs], deps}
    end
  end

  defp resolve_type({type_name, _, _} = type, _module, precond, _env_preconds, {types, errs, deps})
       when type_name in [
              :<<>>,
              :%,
              :..,
              :-,
              :float,
              :atom,
              :integer,
              :neg_integer,
              :non_neg_integer,
              :pos_integer,
              :tuple,
              :map
            ] do
    joint_type = {drop_line_metadata(type), precond}
    {[joint_type | types], errs, deps}
  end

  defp resolve_type({:"::", _, [_var_name, type]}, module, precond, env_preconds_anys_resolvables, acc) do
    resolve_type(type, module, precond, env_preconds_anys_resolvables, acc)
  end

  defp resolve_type({type_name, _, _}, module, precond, env_preconds_anys_resolvables, {types, errs, deps} = acc) do
    {_env, preconds_map, remote_types_as_any, _resolvables} = env_preconds_anys_resolvables
    type_precond = get_precondition(preconds_map, module, type_name)

    if Enum.member?(remote_types_as_any[module] || [], type_name) do
      joint_type = {:any, [], []}
      {[joint_type | types], errs, deps}
    else
      with {:ok, type_list} <- ModuleInspector.beam_types(module),
           {:ok, type, dereferenced_types} <- ModuleInspector.find_type_quoted(type_name, type_list),
           dereferenced_preconds = Enum.map(dereferenced_types, &get_precondition(preconds_map, module, &1)),
           {:ok, precond} <- get_valid_precondition([precond, type_precond | dereferenced_preconds]) do
        resolve_type(type, module, precond, env_preconds_anys_resolvables, acc)
      else
        {:error, {:type_not_found, missing_type}} ->
          err = {:error, {:type_not_found, {Alias.alias_to_atom(module), missing_type, Alias.string_by_concat(module, type_name) <> "()"}}}
          {types, [err | errs], deps}

        {:error, _} = err ->
          {types, [err | errs], deps}
      end
    end
  end

  defp resolve_type(type, _module, precond, _env_preconds, {types, errs, deps})
       when is_number(type) or is_atom(type) or type == [] do
    if is_nil(precond) do
      not_preconditionable_type = type
      {[not_preconditionable_type | types], errs, deps}
    else
      error = {:error, precondition_not_supported_message(inspect(type))}
      {types, [error | errs], deps}
    end
  end

  defp resolve_type(type, _module, precond, _env_preconds, {types, errs, deps}) do
    joint_type = {type, precond}
    {[joint_type | types], errs, deps}
  end

  defp combine_or_args(args, module, env_preconds_anys_resolvables, map_resolved_fn, quote_fn, {types, errs, deps}) do
    {args_resolved, errs_resolved, deps_resolved} =
      args
      |> Enum.map(&resolve_type(&1, module, nil, env_preconds_anys_resolvables, {[], [], []}))
      |> Enum.reduce({[], [], []}, fn {args_el, errs_el, deps_el}, {args_resolved, errs_resolved, deps_resolved} ->
        {[args_el | args_resolved], [errs_el | errs_resolved], [deps_el | deps_resolved]}
      end)

    {args_resolved, errs_resolved, deps_resolved} = {
      Enum.reverse(args_resolved) |> Enum.map(&map_resolved_fn.(&1)),
      Enum.reverse(errs_resolved),
      Enum.reverse(deps_resolved)
    }

    args_combinations_count = Enum.reduce(args_resolved, 1, fn sublist, acc -> Enum.count(sublist) * acc end)

    if args_combinations_count > @max_arg_combinations_count do
      err =
        {:error,
         """
         Failed to generate #{args_combinations_count} type combinations with max. allowed #{@max_arg_combinations_count}. \
         Consider reducing number of | options or change the container type to struct using Domo.\
         """}

      {types, [err | errs], deps}
    else
      combined_types =
        args_resolved
        |> Arguments.all_combinations()
        |> Enum.map(&quote_fn.(&1))

      {
        combined_types ++ types,
        List.flatten(errs_resolved) ++ errs,
        deps ++ List.flatten(deps_resolved)
      }
    end
  end

  defp get_valid_precondition(preconditions) do
    preconditions = Enum.reject(preconditions, &is_nil/1)

    if Enum.count(preconditions) >= 2 do
      refferal_precond = Enum.at(preconditions, 0)
      refferring_precond = Enum.at(preconditions, 1)
      refferal_type = Alias.string_by_concat(refferal_precond.module, refferal_precond.type_name) <> "()"
      refferring_type = Alias.string_by_concat(refferring_precond.module, refferring_precond.type_name) <> "()"

      {:error,
       """
       Precondition conflict for types #{refferal_type} and #{refferring_type} \
       referring one another. You can define only one precondition for either type.\
       """}
    else
      {:ok, List.first(preconditions)}
    end
  end

  defp precondition_not_supported_message(type) do
    type_string = if is_binary(type), do: type, else: to_string(type) <> "()"
    "Precondition for value of #{type_string} type is not allowed."
  end

  defp drop_line_metadata(type), do: Macro.update_meta(type, &Keyword.delete(&1, :line))

  defp drop_kv_precond(kv_list) do
    Enum.map(kv_list, fn
      {{_key, _value} = kv, _precond} -> kv
      value -> value
    end)
  end

  defp ensurable_struct?(module, resolvable_structs) do
    MapSet.member?(resolvable_structs, module) or ModuleInspector.has_type_ensurer?(module)
  end
end
