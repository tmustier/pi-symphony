defmodule SymphonyElixir.MapUtils do
  @moduledoc """
  Shared map normalization, field access, and string helpers used across
  orchestration policy, lifecycle, workpad, and presenter modules.
  """

  @doc """
  Deeply normalizes a map by converting all keys (including nested) to strings.

  Returns `%{}` for `nil` or non-map input.
  """
  @spec normalize_map(term()) :: map()
  def normalize_map(nil), do: %{}

  def normalize_map(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {stringify_key(key), normalize_map_value(nested_value)}
    end)
  end

  def normalize_map(_value), do: %{}

  @doc """
  Fetches a value from a map by atom key, falling back to its string equivalent.

  Returns `nil` when the key is absent or the input is not a map.
  """
  @spec fetch_value(map() | nil, atom()) :: term()
  def fetch_value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  def fetch_value(_map, _key), do: nil

  @doc """
  Trims a binary and returns `nil` for blank or non-binary input.
  """
  @spec normalize_optional_string(term()) :: String.t() | nil
  def normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_optional_string(_value), do: nil

  @doc """
  Converts an atom or any term to a string key.
  """
  @spec stringify_key(term()) :: String.t()
  def stringify_key(value) when is_atom(value), do: Atom.to_string(value)
  def stringify_key(value), do: to_string(value)

  @doc """
  Returns the first non-blank binary from a list of candidates.
  """
  @spec pick_string([term()]) :: String.t() | nil
  def pick_string(values) when is_list(values) do
    Enum.find_value(values, fn
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          normalized -> normalized
        end

      _ ->
        nil
    end)
  end

  defp normalize_map_value(value) when is_map(value), do: normalize_map(value)
  defp normalize_map_value(value) when is_list(value), do: Enum.map(value, &normalize_map_value/1)
  defp normalize_map_value(value), do: value
end
