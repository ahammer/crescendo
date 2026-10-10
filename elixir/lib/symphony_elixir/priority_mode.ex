defmodule SymphonyElixir.PriorityMode do
  @moduledoc "Operator-owned, service-wide Codex Fast mode, read again at every turn boundary."

  alias SymphonyElixir.Service

  @spec current_tier() :: String.t() | nil
  def current_tier do
    case Service.current() do
      nil -> nil
      service -> status(service).service_tier
    end
  end

  @spec status(Service.t(), DateTime.t()) :: map()
  def status(service, now \\ DateTime.utc_now()) do
    case File.read(path(service)) do
      {:error, :enoent} -> describe(false, nil, nil, now)
      {:ok, data} -> read_policy(data, now)
      {:error, _} -> Map.put(describe(false, nil, nil, now), :error, "priority policy is unreadable")
    end
  end

  @spec set(Service.t(), map(), DateTime.t()) :: {:ok, map()} | {:error, String.t()}
  def set(service, params, now \\ DateTime.utc_now()) do
    with :ok <- validate(params, now) do
      policy = %{"enabled" => params["enabled"], "expires_at" => params["expires_at"], "updated_at" => DateTime.to_iso8601(now)}
      file = path(service)
      temporary = file <> ".#{System.pid()}.#{System.unique_integer([:positive])}"

      try do
        with :ok <- File.mkdir_p(Path.dirname(file)),
             :ok <- File.write(temporary, Jason.encode!(policy)),
             :ok <- File.chmod(temporary, 0o600),
             :ok <- File.rename(temporary, file) do
          {:ok, describe(policy["enabled"], policy["expires_at"], policy["updated_at"], now)}
        else
          {:error, _} -> {:error, "could not write priority policy"}
        end
      after
        File.rm(temporary)
      end
    end
  end

  defp path(service), do: Path.join(Service.state_root(service), "priority-mode.json")

  defp validate(params, now) do
    cond do
      Map.keys(params) -- ["enabled", "expires_at"] != [] -> {:error, "unknown priority parameter"}
      not is_boolean(params["enabled"]) -> {:error, "enabled must be a boolean"}
      is_nil(params["expires_at"]) -> :ok
      not is_binary(params["expires_at"]) -> {:error, "expires_at must be an ISO 8601 timestamp"}
      true -> validate_expiry(params["expires_at"], now)
    end
  end

  defp validate_expiry(value, now) do
    case DateTime.from_iso8601(value) do
      {:ok, expires, _} -> if DateTime.compare(expires, now) == :gt, do: :ok, else: {:error, "expires_at must be in the future"}
      _ -> {:error, "expires_at must be an ISO 8601 timestamp with a timezone"}
    end
  end

  defp read_policy(data, now) do
    with {:ok, %{"enabled" => enabled, "expires_at" => expires, "updated_at" => updated}} <- Jason.decode(data),
         true <- is_boolean(enabled) and is_binary(updated),
         true <- is_nil(expires) or valid_timestamp?(expires) do
      describe(enabled, expires, updated, now)
    else
      _ -> Map.put(describe(false, nil, nil, now), :error, "priority policy is invalid")
    end
  end

  defp valid_timestamp?(value) when is_binary(value), do: match?({:ok, _, _}, DateTime.from_iso8601(value))
  defp valid_timestamp?(_), do: false

  defp describe(enabled, expires, updated, now) do
    expired = not is_nil(expires) and expiry_reached?(expires, now)
    active = enabled and not expired

    %{
      enabled: active,
      service_tier: if(active, do: "fast", else: "default"),
      expires_at: expires,
      expired: expired,
      updated_at: updated,
      error: nil
    }
  end

  defp expiry_reached?(value, now) do
    {:ok, expires, _} = DateTime.from_iso8601(value)
    DateTime.compare(expires, now) != :gt
  end
end
