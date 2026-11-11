defmodule SymphonyElixir.IntelligencePolicy do
  @moduledoc "Operator-owned gain and task profiles shared by every model launcher."
  alias SymphonyElixir.{ModelRouting, Service, SmartassMode, Tracker.Issue}
  @complexities ~w(routine standard complex exceptional)
  @risks ~w(low normal high)

  @spec enabled?() :: boolean()
  def enabled?, do: match?(%{intelligence_policy: %{"enabled" => true}}, Service.current())

  @spec status(Service.t() | nil) :: map()
  def status(service \\ Service.current()) do
    enabled = match?(%{intelligence_policy: %{"enabled" => true}}, service)
    base = %{enabled: enabled, gain: 1.0, revision: "default", version: "gain-v1", error: nil}
    if service, do: read_status(service, base), else: base
  end

  defp read_status(service, base) do
    case File.read(path(service)) do
      {:error, :enoent} -> base
      {:ok, data} -> decode_status(data, base)
      {:error, _} -> %{base | error: "intelligence policy is unreadable"}
    end
  end

  defp decode_status(data, base) do
    with {:ok, %{"gain" => gain, "revision" => revision}} <- Jason.decode(data),
         true <- valid_gain?(gain) and is_binary(revision) do
      %{base | gain: gain, revision: revision}
    else
      _ -> %{base | error: "intelligence policy is invalid"}
    end
  end

  @spec set(Service.t(), map()) :: {:ok, map()} | {:error, String.t()}
  def set(service, %{"gain" => gain} = args) when map_size(args) == 1 do
    if valid_gain?(gain) do
      revision = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      data = %{"gain" => gain, "revision" => revision, "updated_at" => DateTime.to_iso8601(DateTime.utc_now())}
      with :ok <- write_json(path(service), data), do: {:ok, status(service)}
    else
      {:error, "gain must be a finite number from 0 to 2"}
    end
  end

  def set(_service, _args), do: {:error, "supply only gain"}

  @spec valid_gain?(term()) :: boolean()
  def valid_gain?(value), do: is_number(value) and value >= 0 and value <= 2

  @spec validate_profile(term()) :: :ok | {:error, String.t()}
  def validate_profile(%{"complexity" => complexity, "risk" => risk, "reason" => reason} = profile) do
    if complexity in @complexities and risk in @risks and is_binary(reason) and String.trim(reason) != "" and
         is_list(profile["evidence_refs"]) and Enum.all?(profile["evidence_refs"], &is_binary/1), do: :ok, else: {:error, "profile requires complexity, risk, reason and evidence_refs"}
  end

  def validate_profile(_), do: {:error, "profile requires complexity, risk, reason and evidence_refs"}

  @spec profile(Issue.t()) :: map() | nil
  def profile(issue) do
    prefix = SymphonyElixir.Config.settings!().labels.prefix
    labels = Issue.label_names(issue)
    complexity = for label <- labels, value <- @complexities, label == prefix <> ":complexity:" <> value, do: value
    risk = for label <- labels, value <- @risks, label == prefix <> ":risk:" <> value, do: value

    case {Enum.uniq(complexity), Enum.uniq(risk)} do
      {[c], [r]} -> %{"complexity" => c, "risk" => r, "reason" => "Published task classification", "evidence_refs" => [issue.identifier]}
      _ -> nil
    end
  end

  @doc "Research tasks carry their acceptance in the rendered prompt, rather than an issue description."
  @spec task_contract(Issue.t()) :: String.t() | nil
  def task_contract(%Issue{kind: :research} = issue), do: SymphonyElixir.PromptBuilder.build_prompt(issue)
  def task_contract(%Issue{} = issue), do: issue.description

  @spec role_profile(String.t()) :: map()
  def role_profile(role) do
    %{
      "complexity" => if(role == "helper", do: "routine", else: "standard"),
      "risk" => if(role in ["helper", "classifier"], do: "low", else: "normal"),
      "reason" => "Bounded #{role} role",
      "evidence_refs" => []
    }
  end

  @spec resolve(map(), String.t(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve(profile, role, identity, opts \\ []) do
    policy = Keyword.get_lazy(opts, :policy, &status/0)

    smartass =
      Keyword.get_lazy(opts, :smartass, fn ->
        service = Service.current()
        service != nil and SmartassMode.status(service).enabled
      end)

    with nil <- policy.error,
         :ok <- validate_profile(profile) do
      ModelRouting.gain_route(profile, role, identity, policy, Keyword.put(opts, :smartass, smartass))
    else
      error when is_binary(error) -> {:error, error}
      error -> error
    end
  end

  @spec admit_native(map() | nil) :: :ok | {:error, term()}
  def admit_native(%{"policy" => _, "model" => model, "effort" => effort}) do
    file = Path.join(System.get_env("CODEX_HOME") || Path.expand("~/.codex"), "models_cache.json")

    with :ok <- quota_admission(model),
         {:ok, data} <- File.read(file),
         {:ok, %{"models" => models}} when is_list(models) <- Jason.decode(data),
         %{} = entry <- Enum.find(models, &(is_map(&1) and &1["slug"] == model)),
         levels when is_list(levels) <- entry["supported_reasoning_levels"],
         true <- Enum.any?(levels, &(is_map(&1) and &1["effort"] == effort)) do
      :ok
    else
      {:error, reason} when reason in [:model_quota_hold, :quota_unknown] -> {:error, reason}
      _ -> {:error, :unsupported_intelligence_route}
    end
  end

  def admit_native(_), do: :ok

  defp quota_admission(model) do
    if SymphonyElixir.Governor.running?() do
      avoid = SymphonyElixir.Governor.snapshot().throttle.avoid
      if Map.has_key?(avoid, model), do: {:error, :model_quota_hold}, else: :ok
    else
      :ok
    end
  catch
    :exit, _ -> {:error, :quota_unknown}
  end

  @spec write_json(Path.t(), map()) :: :ok | {:error, term()}
  def write_json(file, value) do
    temp = file <> ".#{System.pid()}.#{System.unique_integer([:positive])}.next"

    try do
      with :ok <- File.mkdir_p(Path.dirname(file)), :ok <- File.write(temp, Jason.encode!(value)), :ok <- File.chmod(temp, 0o600), do: File.rename(temp, file)
    after
      File.rm(temp)
    end
  end

  @spec digest(term()) :: String.t()
  def digest(value), do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)

  defp path(service), do: Path.join(Service.state_root(service), "intelligence-policy.json")
end
